import XCTest
import ZetaProtocol

@testable import ZetaServer

final class ZetaServerTests: XCTestCase {
    func testHandshakeTimeoutSendsFinalErrorAndCloses() async throws {
        let server = try PiServer(
            serverID: "server",
            handshakeTimeout: .milliseconds(10),
            service: TestService()
        )
        let connection = TestConnection()
        try await server.accept(connection)
        try await waitUntil { await connection.isClosed }
        let decoder = try ServerMessageDecoder()
        let messages = try decoder.push(await connection.data[0])
        guard case .helloError(let error) = messages.first else {
            return XCTFail("Expected hello error")
        }
        XCTAssertEqual(error.code, .invalidRequest)
    }

    func testImmediateRequestPublishedFromHelloSendSucceeds() async throws {
        let service = TestService()
        let server = try PiServer(serverID: "server", service: service)
        let connection = TestConnection()
        try await server.accept(connection)
        let request = try RequestEnvelope(id: "1", request: .list)
        let requestFrame = try encodeClientMessage(.request(request))
        await connection.setNextSendHook { _ in
            await server.receive(requestFrame, connectionID: connection.id)
        }

        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: connection.id)

        try await waitUntil { await connection.count >= 2 }
        let messages = try await decodedMessages(connection)
        guard case .hello = messages.first else { return XCTFail("Expected hello") }
        XCTAssertTrue(
            messages.contains {
                guard case .response(.success(id: "1", result: .list)) = $0 else { return false }
                return true
            })
        let isClosed = await connection.isClosed
        XCTAssertFalse(isClosed)
        await server.close()
    }

    func testRequestFramedImmediatelyAfterHelloWaitsForHandshake() async throws {
        let server = try PiServer(serverID: "server", service: TestService())
        let connection = TestConnection()
        try await server.accept(connection)
        var frames = try encodeClientMessage(.hello(try ClientHello()))
        frames.append(
            try encodeClientMessage(.request(try RequestEnvelope(id: "immediate", request: .list))))

        await server.receive(frames, connectionID: connection.id)

        try await waitUntil { await connection.count >= 2 }
        let messages = try await decodedMessages(connection)
        XCTAssertTrue(
            messages.contains {
                guard case .response(.success(id: "immediate", result: .list)) = $0 else { return false }
                return true
            })
        await server.close()
    }

    func testHandshakeSendFailureRollsBackReadinessAndCloses() async throws {
        let server = try PiServer(serverID: "server", service: TestService())
        let connection = TestConnection()
        try await server.accept(connection)
        await connection.setFailing(true)

        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: connection.id)

        try await waitUntil { await connection.isClosed }
        await connection.setFailing(false)
        let attempts = await connection.sendAttempts
        let request = try RequestEnvelope(id: "late", request: .list)
        await server.receive(try encodeClientMessage(.request(request)), connectionID: connection.id)
        try await Task.sleep(for: .milliseconds(20))
        let finalAttempts = await connection.sendAttempts
        XCTAssertEqual(finalAttempts, attempts)
    }

    func testMutationsBroadcastAuthoritativeSnapshotsToEveryAttachedClient() async throws {
        let server = try PiServer(serverID: "server", service: TestService())
        let first = TestConnection(id: "first")
        let second = TestConnection(id: "second")
        try await server.accept(first)
        try await server.accept(second)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: first.id)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: second.id)
        try await waitUntil {
            let firstReady = await first.count >= 1
            let secondReady = await second.count >= 1
            return firstReady && secondReady
        }
        let firstAttach = try RequestEnvelope(id: "attach-first", request: .attach(sessionID: "shared"))
        let secondAttach = try RequestEnvelope(id: "attach-second", request: .attach(sessionID: "shared"))
        await server.receive(try encodeClientMessage(.request(firstAttach)), connectionID: first.id)
        await server.receive(try encodeClientMessage(.request(secondAttach)), connectionID: second.id)
        try await waitUntil {
            let firstAttached = await first.count >= 2
            let secondAttached = await second.count >= 2
            return firstAttached && secondAttached
        }

        let commands: [Command] = [
            .prompt(sessionID: "shared", text: "prompt"),
            .steer(sessionID: "shared", text: "steer"),
            .abort(sessionID: "shared"),
            .setModel(sessionID: "shared", model: try ModelReference(provider: "test", id: "next")),
            .setThinking(sessionID: "shared", thinkingLevel: .high),
        ]
        for (offset, command) in commands.enumerated() {
            let requestID = "mutation-\(offset)"
            let firstCount = await first.count
            let secondCount = await second.count
            let request = try RequestEnvelope(id: requestID, request: command)
            await server.receive(try encodeClientMessage(.request(request)), connectionID: first.id)
            try await waitUntil {
                let firstReceived = await first.count >= firstCount + 2
                let secondReceived = await second.count >= secondCount + 1
                return firstReceived && secondReceived
            }

            let expectedRevision = Int64(offset + 1)
            let firstMessages = try await decodedMessages(first)
            let secondMessages = try await decodedMessages(second)
            let firstSnapshot = firstMessages.compactMap(sessionEventSnapshot).last
            let secondSnapshot = secondMessages.compactMap(sessionEventSnapshot).last
            XCTAssertEqual(firstSnapshot?.revision, expectedRevision)
            XCTAssertEqual(secondSnapshot?.revision, expectedRevision)
            XCTAssertEqual(firstSnapshot?.attached, true)
            XCTAssertEqual(secondSnapshot?.attached, true)
            let mutationResponse = firstMessages.compactMap { responseSnapshot($0, id: requestID) }.last
            XCTAssertEqual(mutationResponse?.revision, expectedRevision)
            XCTAssertEqual(mutationResponse?.attached, true)
        }
        await server.close()
    }

    func testSnapshotBroadcastFailureDoesNotFailMutationOrOtherClients() async throws {
        let server = try PiServer(serverID: "server", service: TestService())
        let requester = TestConnection(id: "requester")
        let failing = TestConnection(id: "failing")
        try await server.accept(requester)
        try await server.accept(failing)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: requester.id)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: failing.id)
        try await waitUntil {
            let requesterReady = await requester.count >= 1
            let failingReady = await failing.count >= 1
            return requesterReady && failingReady
        }
        await server.receive(
            try encodeClientMessage(
                .request(try RequestEnvelope(id: "attach-requester", request: .attach(sessionID: "shared")))),
            connectionID: requester.id)
        await server.receive(
            try encodeClientMessage(
                .request(try RequestEnvelope(id: "attach-failing", request: .attach(sessionID: "shared")))),
            connectionID: failing.id)
        try await waitUntil {
            let requesterAttached = await requester.count >= 2
            let failingAttached = await failing.count >= 2
            return requesterAttached && failingAttached
        }
        await failing.setFailing(true)
        let failingAttempts = await failing.sendAttempts

        let request = try RequestEnvelope(id: "mutation", request: .abort(sessionID: "shared"))
        await server.receive(try encodeClientMessage(.request(request)), connectionID: requester.id)
        try await waitUntil {
            let requesterReceived = await requester.count >= 4
            let failingAttempted = await failing.sendAttempts > failingAttempts
            return requesterReceived && failingAttempted
        }

        let messages = try await decodedMessages(requester)
        XCTAssertEqual(messages.compactMap(sessionEventSnapshot).last?.revision, 1)
        XCTAssertEqual(messages.compactMap { responseSnapshot($0, id: "mutation") }.last?.revision, 1)
        await server.close()
    }

    func testCreateSnapshotFailureDisposesWithoutPublishingOrRetainingRuntime() async throws {
        let tracker = RuntimeTracker()
        let service = FailingCreateService(tracker: tracker)
        let server = try PiServer(serverID: "server", service: service)
        let connection = TestConnection()
        try await server.accept(connection)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: connection.id)
        try await waitUntil { await connection.count == 1 }

        let create = try RequestEnvelope(id: "create", request: .create(try CreateCommandOptions()))
        await server.receive(try encodeClientMessage(.request(create)), connectionID: connection.id)
        try await waitUntil { await connection.count >= 2 }

        var messages = try await decodedMessages(connection)
        XCTAssertFalse(
            messages.contains {
                guard case .event(.serverSnapshot) = $0 else { return false }
                return true
            })
        XCTAssertTrue(
            messages.contains {
                guard case .response(.failure(id: "create", error: _)) = $0 else { return false }
                return true
            })
        let disposeCount = await tracker.disposeCount
        XCTAssertEqual(disposeCount, 1)

        let attach = try RequestEnvelope(id: "attach", request: .attach(sessionID: "created"))
        await server.receive(try encodeClientMessage(.request(attach)), connectionID: connection.id)
        try await waitUntil { await connection.count >= 3 }
        messages = try await decodedMessages(connection)
        XCTAssertTrue(
            messages.contains {
                guard case .response(.success(id: "attach", result: .attach)) = $0 else { return false }
                return true
            })
        let openCount = await service.openCount
        XCTAssertEqual(openCount, 1)
        await server.close()
    }

    func testConcurrentCreateDoesNotPublishRuntimeBeforeItsInitialSnapshot() async throws {
        let gate = SnapshotGate()
        let firstTracker = RuntimeTracker()
        let secondTracker = RuntimeTracker()
        let service = RacingCreateService(gate: gate, firstTracker: firstTracker, secondTracker: secondTracker)
        let server = try PiServer(serverID: "server", service: service)
        let connection = TestConnection()
        try await server.accept(connection)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: connection.id)
        try await waitUntil { await connection.count == 1 }

        let first = try RequestEnvelope(id: "create-first", request: .create(try CreateCommandOptions()))
        await server.receive(try encodeClientMessage(.request(first)), connectionID: connection.id)
        try await waitUntil { await firstTracker.snapshotCount == 1 }
        let countWhileFirstSnapshotPending = await connection.count
        XCTAssertEqual(countWhileFirstSnapshotPending, 1)

        let second = try RequestEnvelope(id: "create-second", request: .create(try CreateCommandOptions()))
        await server.receive(try encodeClientMessage(.request(second)), connectionID: connection.id)
        try await waitUntil { await connection.count >= 3 }
        var messages = try await decodedMessages(connection)
        XCTAssertTrue(
            messages.contains {
                guard case .response(.success(id: "create-second", result: .create)) = $0 else { return false }
                return true
            })
        let secondSnapshotCount = await secondTracker.snapshotCount
        XCTAssertEqual(secondSnapshotCount, 1)

        await gate.release()
        try await waitUntil { await connection.count >= 4 }
        messages = try await decodedMessages(connection)
        XCTAssertTrue(
            messages.contains {
                guard case .response(.failure(id: "create-first", error: _)) = $0 else { return false }
                return true
            })
        let firstDisposeCount = await firstTracker.disposeCount
        let secondDisposeCount = await secondTracker.disposeCount
        XCTAssertEqual(firstDisposeCount, 1)
        XCTAssertEqual(secondDisposeCount, 0)
        await server.close()
        let finalSecondDisposeCount = await secondTracker.disposeCount
        XCTAssertEqual(finalSecondDisposeCount, 1)
    }

    func testConcurrentAttachmentsShareOneRuntimeAndPreserveBothConnections() async throws {
        let tracker = RuntimeTracker()
        let service = CountingService(tracker: tracker)
        let server = try PiServer(serverID: "server", service: service)
        let first = TestConnection(id: "first")
        let second = TestConnection(id: "second")
        try await server.accept(first)
        try await server.accept(second)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: first.id)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: second.id)
        try await waitUntil {
            let firstReady = await first.count >= 1
            let secondReady = await second.count >= 1
            return firstReady && secondReady
        }

        let firstAttach = try RequestEnvelope(id: "attach-1", request: .attach(sessionID: "shared"))
        let secondAttach = try RequestEnvelope(id: "attach-2", request: .attach(sessionID: "shared"))
        await server.receive(try encodeClientMessage(.request(firstAttach)), connectionID: first.id)
        await server.receive(try encodeClientMessage(.request(secondAttach)), connectionID: second.id)
        try await waitUntil {
            let firstAttached = await first.count >= 2
            let secondAttached = await second.count >= 2
            return firstAttached && secondAttached
        }

        let openCount = await service.openCount
        XCTAssertEqual(openCount, 1)
        await server.disconnected(first.id)
        let disposeCountAfterFirstDisconnect = await tracker.disposeCount
        XCTAssertEqual(disposeCountAfterFirstDisconnect, 0)
        await server.disconnected(second.id)
        let finalDisposeCount = await tracker.disposeCount
        XCTAssertEqual(finalDisposeCount, 1)
    }
}

private actor TestConnection: ServerByteConnection {
    private struct SendFailure: Error {}

    nonisolated let id: String
    private(set) var data: [Data] = []
    private(set) var isClosed = false
    private(set) var sendAttempts = 0
    private var failing = false
    private var nextSendHook: (@Sendable (Data) async -> Void)?
    var count: Int { data.count }

    init(id: String = "connection") { self.id = id }

    func send(_ bytes: Data) async throws {
        sendAttempts += 1
        if failing { throw SendFailure() }
        data.append(bytes)
        let hook = nextSendHook
        nextSendHook = nil
        await hook?(bytes)
    }
    func close() { isClosed = true }
    func setFailing(_ value: Bool) { failing = value }
    func setNextSendHook(_ hook: @escaping @Sendable (Data) async -> Void) { nextSendHook = hook }
}

private struct TestService: PiServerService {
    func listSessions() async throws -> [SessionMetadata] { [] }
    func listModels() async throws -> [ModelMetadata] { [] }
    func createSession(_ options: CreateCommandOptions) async throws -> any PiSessionRuntime {
        TestRuntime(id: "created")
    }
    func openSession(_ id: String) async throws -> any PiSessionRuntime { TestRuntime(id: id) }
}

private actor FailingCreateService: PiServerService {
    private(set) var openCount = 0
    let tracker: RuntimeTracker

    init(tracker: RuntimeTracker) { self.tracker = tracker }

    func listSessions() async throws -> [SessionMetadata] { [] }
    func listModels() async throws -> [ModelMetadata] { [] }
    func createSession(_ options: CreateCommandOptions) async throws -> any PiSessionRuntime {
        TestRuntime(id: "created", tracker: tracker, snapshotFailure: true)
    }
    func openSession(_ id: String) async throws -> any PiSessionRuntime {
        openCount += 1
        return TestRuntime(id: id)
    }
}

private actor RacingCreateService: PiServerService {
    private var createCount = 0
    let gate: SnapshotGate
    let firstTracker: RuntimeTracker
    let secondTracker: RuntimeTracker

    init(gate: SnapshotGate, firstTracker: RuntimeTracker, secondTracker: RuntimeTracker) {
        self.gate = gate
        self.firstTracker = firstTracker
        self.secondTracker = secondTracker
    }

    func listSessions() async throws -> [SessionMetadata] { [] }
    func listModels() async throws -> [ModelMetadata] { [] }
    func createSession(_ options: CreateCommandOptions) async throws -> any PiSessionRuntime {
        createCount += 1
        if createCount == 1 {
            return TestRuntime(id: "created", tracker: firstTracker, snapshotGate: gate)
        }
        return TestRuntime(id: "created", tracker: secondTracker)
    }
    func openSession(_ id: String) async throws -> any PiSessionRuntime { TestRuntime(id: id) }
}

private actor CountingService: PiServerService {
    private(set) var openCount = 0
    let tracker: RuntimeTracker

    init(tracker: RuntimeTracker) { self.tracker = tracker }

    func listSessions() async throws -> [SessionMetadata] { [] }
    func listModels() async throws -> [ModelMetadata] { [] }
    func createSession(_ options: CreateCommandOptions) async throws -> any PiSessionRuntime {
        TestRuntime(id: "created", tracker: tracker)
    }
    func openSession(_ id: String) async throws -> any PiSessionRuntime {
        openCount += 1
        try await Task.sleep(for: .milliseconds(50))
        return TestRuntime(id: id, tracker: tracker)
    }
}

private actor SnapshotGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private actor RuntimeTracker {
    private(set) var disposeCount = 0
    private(set) var snapshotCount = 0
    func recordDispose() { disposeCount += 1 }
    func recordSnapshot() { snapshotCount += 1 }
}

private enum SnapshotFailure: Error { case expected }

private actor TestRuntime: PiSessionRuntime {
    nonisolated let id: String
    private let tracker: RuntimeTracker?
    private let snapshotFailure: Bool
    private let snapshotGate: SnapshotGate?
    private var revision: Int64 = 0

    init(
        id: String,
        tracker: RuntimeTracker? = nil,
        snapshotFailure: Bool = false,
        snapshotGate: SnapshotGate? = nil
    ) {
        self.id = id
        self.tracker = tracker
        self.snapshotFailure = snapshotFailure
        self.snapshotGate = snapshotGate
    }
    func snapshot(attached: Bool) async throws -> SessionSnapshot {
        await tracker?.recordSnapshot()
        await snapshotGate?.wait()
        if snapshotFailure { throw SnapshotFailure.expected }
        return try makeSnapshot(attached: attached)
    }
    func prompt(_ text: String) throws -> SessionSnapshot { try mutate() }
    func steer(_ text: String) throws -> SessionSnapshot { try mutate() }
    func abort() throws -> SessionSnapshot { try mutate() }
    func setModel(_ model: ModelReference) throws -> SessionSnapshot { try mutate() }
    func setThinking(_ level: ThinkingLevel) throws -> SessionSnapshot { try mutate() }
    func dispose() async { await tracker?.recordDispose() }
    private func mutate() throws -> SessionSnapshot {
        revision += 1
        return try makeSnapshot(attached: false)
    }
    private func makeSnapshot(attached: Bool) throws -> SessionSnapshot {
        try SessionSnapshot(
            id: id, cwd: "/tmp", createdAt: 0, updatedAt: revision, phase: .idle,
            model: ModelReference(provider: "test", id: "model"), thinkingLevel: .off, attached: attached,
            locked: false, revision: revision, transcript: [], queuedSteer: [], queuedSteerCount: 0)
    }
}

private func decodedMessages(_ connection: TestConnection) async throws -> [ServerMessage] {
    let decoder = try ServerMessageDecoder()
    var messages: [ServerMessage] = []
    for frame in await connection.data { messages.append(contentsOf: try decoder.push(frame)) }
    return messages
}

private func sessionEventSnapshot(_ message: ServerMessage) -> SessionSnapshot? {
    guard case .event(.sessionSnapshot(let snapshot)) = message else { return nil }
    return snapshot
}

private func responseSnapshot(_ message: ServerMessage, id: String) -> SessionSnapshot? {
    guard case .response(.success(let responseID, let result)) = message, responseID == id else { return nil }
    switch result {
    case .prompt(let snapshot), .steer(let snapshot), .abort(let snapshot), .setModel(let snapshot),
        .setThinking(let snapshot):
        return snapshot
    default:
        return nil
    }
}

private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out")
}
