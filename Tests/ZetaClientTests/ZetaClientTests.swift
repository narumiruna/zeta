import XCTest
import ZetaProtocol

@testable import ZetaClient

final class ZetaClientTests: XCTestCase {
    func testHandshakeListAndDisconnect() async throws {
        let transportBox = TransportBox()
        let client = try PiClient { handlers in
            let transport = ScriptedTransport(handlers: handlers)
            await transportBox.set(transport)
            return transport
        }
        try await client.connect()
        let connected = await client.connectionState()
        XCTAssertEqual(connected, .connected)
        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions, [])
        await client.disconnect()
        let disconnected = await client.connectionState()
        XCTAssertEqual(disconnected, .disconnected)
    }

    func testConcurrentConnectsShareOneSuccessfulAttempt() async throws {
        let factory = ControlledConnectionFactory()
        let client = try PiClient { handlers in try await factory.open(handlers) }
        let completions = CompletionCounter()
        let tasks = (0..<3).map { _ in
            Task {
                try await client.connect()
                await completions.record()
            }
        }
        try await waitUntil { await factory.attemptCount == 1 }
        try await Task.sleep(for: .milliseconds(20))
        let completionCount = await completions.count
        XCTAssertEqual(completionCount, 0)

        await factory.succeed()

        for task in tasks { try await task.value }
        let finalCompletionCount = await completions.count
        XCTAssertEqual(finalCompletionCount, 3)
        let state = await client.connectionState()
        XCTAssertEqual(state, .connected)
        await client.disconnect()
    }

    func testConcurrentConnectFailureIsSharedAndLaterRetrySucceeds() async throws {
        let factory = ControlledConnectionFactory()
        let client = try PiClient { handlers in try await factory.open(handlers) }
        let tasks = (0..<3).map { _ in
            Task { () -> Bool in
                do {
                    try await client.connect()
                    return false
                } catch ConnectTestFailure.expected {
                    return true
                } catch {
                    return false
                }
            }
        }
        try await waitUntil { await factory.attemptCount == 1 }

        await factory.fail()

        for task in tasks {
            let receivedExpectedFailure = await task.value
            XCTAssertTrue(receivedExpectedFailure)
        }
        let failedState = await client.connectionState()
        XCTAssertEqual(failedState, .disconnected)
        let failedAttemptCount = await factory.attemptCount
        XCTAssertEqual(failedAttemptCount, 1)

        let retry = Task { try await client.connect() }
        try await waitUntil { await factory.attemptCount == 2 }
        await factory.succeed()
        try await retry.value
        let retriedState = await client.connectionState()
        XCTAssertEqual(retriedState, .connected)
        await client.disconnect()
    }

    func testExclusiveAndSharedOwnership() async throws {
        let client = try PiClient { ScriptedTransport(handlers: $0) }
        try await client.connect()
        let first = try await client.attachSession("s")
        _ = try await client.attachSession("s")
        do {
            _ = try await client.acquireSession("s", mode: .exclusive)
            XCTFail("Expected ownership error")
        } catch {}
        try await first.dispose()
    }

    func testConcurrentSharedAcquiresCoalesceAttachmentAndPreserveBothLeases() async throws {
        let box = ControlledTransportBox()
        let client = try PiClient { handlers in
            let transport = ControlledTransport(handlers: handlers)
            await box.set(transport)
            return transport
        }
        try await client.connect()
        let transport = await box.wait()

        let firstTask = Task { try await client.attachSession("shared") }
        let secondTask = Task { try await client.attachSession("shared") }
        try await waitUntil { await transport.attachCount == 1 }
        let exclusiveRejected = Task {
            do {
                let lease = try await client.acquireSession("shared", mode: .exclusive)
                try? await lease.dispose()
                return false
            } catch PiClientError.ownership {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let attachCount = await transport.attachCount
        XCTAssertEqual(attachCount, 1)
        await transport.completeAttachments()

        let first = try await firstTask.value
        let second = try await secondTask.value
        let rejected = await exclusiveRejected.value
        XCTAssertTrue(rejected)
        try await first.dispose()
        let detachCountAfterFirstRelease = await transport.detachCount
        XCTAssertEqual(detachCountAfterFirstRelease, 0)
        try await second.dispose()
        let finalDetachCount = await transport.detachCount
        XCTAssertEqual(finalDetachCount, 1)
    }

    func testInFlightExclusiveAcquireRejectsConcurrentSharedAcquire() async throws {
        let box = ControlledTransportBox()
        let client = try PiClient { handlers in
            let transport = ControlledTransport(handlers: handlers)
            await box.set(transport)
            return transport
        }
        try await client.connect()
        let transport = await box.wait()

        let exclusiveTask = Task { try await client.acquireSession("exclusive", mode: .exclusive) }
        try await waitUntil { await transport.attachCount == 1 }
        let sharedRejected = Task {
            do {
                let lease = try await client.attachSession("exclusive")
                try? await lease.dispose()
                return false
            } catch PiClientError.ownership {
                return true
            } catch {
                return false
            }
        }
        try await Task.sleep(for: .milliseconds(20))
        let attachCount = await transport.attachCount
        XCTAssertEqual(attachCount, 1)
        await transport.completeAttachments()

        let exclusive = try await exclusiveTask.value
        let rejected = await sharedRejected.value
        XCTAssertTrue(rejected)
        try await exclusive.dispose()
    }

    func testRequestCancellationReturnsBeforeResponseAndRacesResumeOnce() async throws {
        let box = ControlledTransportBox()
        let client = try PiClient { handlers in
            let transport = ControlledTransport(handlers: handlers)
            await box.set(transport)
            return transport
        }
        try await client.connect()
        let transport = await box.wait()

        let firstOutcome = RequestOutcomeBox()
        let cancelledRequest = Task {
            await firstOutcome.set(await listOutcome(from: client))
        }
        try await waitUntil { await transport.listCount == 1 }
        cancelledRequest.cancel()
        try await waitUntil { await firstOutcome.value != nil }
        let cancelledValue = await firstOutcome.value
        XCTAssertEqual(cancelledValue, .cancelled)

        await transport.completeList(at: 0)
        await cancelledRequest.value

        let completedRequest = Task { try await client.listSessions() }
        try await waitUntil { await transport.listCount == 2 }
        await transport.completeList(at: 1)
        let completedValue = try await completedRequest.value
        XCTAssertEqual(completedValue, [])
        completedRequest.cancel()

        let disconnectedRequest = Task { await listOutcome(from: client) }
        try await waitUntil { await transport.listCount == 3 }
        await client.disconnect()
        disconnectedRequest.cancel()
        await transport.completeList(at: 2)
        let disconnectedValue = await disconnectedRequest.value
        XCTAssertEqual(disconnectedValue, .disconnected)
    }
}

private enum ConnectTestFailure: Error { case expected }

private enum RequestOutcome: Equatable, Sendable {
    case success
    case cancelled
    case disconnected
    case otherFailure
}

private actor RequestOutcomeBox {
    private(set) var value: RequestOutcome?
    func set(_ value: RequestOutcome) { self.value = value }
}

private func listOutcome(from client: PiClient) async -> RequestOutcome {
    do {
        _ = try await client.listSessions()
        return .success
    } catch is CancellationError {
        return .cancelled
    } catch PiClientError.disconnected {
        return .disconnected
    } catch {
        return .otherFailure
    }
}

private actor CompletionCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor ControlledConnectionFactory {
    private var continuation: CheckedContinuation<any ByteTransport, Error>?
    private(set) var attemptCount = 0

    func open(_ handlers: ByteTransportHandlers) async throws -> any ByteTransport {
        attemptCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.handlers = handlers
        }
    }

    func succeed() {
        guard let continuation, let handlers else { return }
        self.continuation = nil
        self.handlers = nil
        continuation.resume(returning: HandshakeTransport(handlers: handlers))
    }

    func fail() {
        guard let continuation else { return }
        self.continuation = nil
        handlers = nil
        continuation.resume(throwing: ConnectTestFailure.expected)
    }

    private var handlers: ByteTransportHandlers?
}

private actor HandshakeTransport: ByteTransport {
    private let handlers: ByteTransportHandlers
    private let decoder = try! ClientMessageDecoder()

    init(handlers: ByteTransportHandlers) { self.handlers = handlers }

    func send(_ bytes: Data) throws {
        for message in try decoder.push(bytes) {
            guard case .hello = message else { continue }
            let snapshot = try ServerSnapshot(serverID: "server", revision: 0, sessions: [], models: [])
            handlers.onData(
                try encodeServerMessage(.hello(try ServerHello(connectionID: "connection", snapshot: snapshot))))
        }
    }

    func close() {}
}

private actor ControlledTransportBox {
    private var value: ControlledTransport?
    private var waiters: [CheckedContinuation<ControlledTransport, Never>] = []

    func set(_ value: ControlledTransport) {
        self.value = value
        waiters.forEach { $0.resume(returning: value) }
        waiters.removeAll()
    }

    func wait() async -> ControlledTransport {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor ControlledTransport: ByteTransport {
    private let handlers: ByteTransportHandlers
    private let decoder = try! ClientMessageDecoder()
    private var attachments: [RequestEnvelope] = []
    private var lists: [RequestEnvelope] = []
    private(set) var detachCount = 0
    var attachCount: Int { attachments.count }
    var listCount: Int { lists.count }

    init(handlers: ByteTransportHandlers) { self.handlers = handlers }

    func send(_ bytes: Data) throws {
        for message in try decoder.push(bytes) {
            switch message {
            case .hello:
                let snapshot = try ServerSnapshot(serverID: "server", revision: 0, sessions: [], models: [])
                handlers.onData(
                    try encodeServerMessage(.hello(try ServerHello(connectionID: "connection", snapshot: snapshot))))
            case .request(let request):
                switch request.request {
                case .list:
                    lists.append(request)
                case .attach:
                    attachments.append(request)
                case .detach(let id):
                    detachCount += 1
                    handlers.onData(
                        try encodeServerMessage(.response(.success(id: request.id, result: .detach(sessionID: id)))))
                default:
                    break
                }
            }
        }
    }

    func completeAttachments() {
        let pending = attachments
        for request in pending {
            guard case .attach(let id) = request.request else { continue }
            handlers.onData(
                try! encodeServerMessage(
                    .response(.success(id: request.id, result: .attach(try! makeSnapshot(id: id))))))
        }
    }

    func completeList(at index: Int) {
        guard lists.indices.contains(index) else { return }
        handlers.onData(
            try! encodeServerMessage(
                .response(.success(id: lists[index].id, result: .list([])))))
    }

    func close() {}

    private func makeSnapshot(id: String) throws -> SessionSnapshot {
        try SessionSnapshot(
            id: id, cwd: "/tmp", createdAt: 0, updatedAt: 0, phase: .idle,
            model: ModelReference(provider: "test", id: "model"), thinkingLevel: .off, attached: true,
            locked: false, revision: 0, transcript: [], queuedSteer: [], queuedSteerCount: 0)
    }
}

private actor TransportBox {
    var value: ScriptedTransport?
    func set(_ value: ScriptedTransport) { self.value = value }
}

private final class ScriptedTransport: ByteTransport, @unchecked Sendable {
    private let handlers: ByteTransportHandlers
    private let decoder = try! ClientMessageDecoder()
    init(handlers: ByteTransportHandlers) { self.handlers = handlers }

    func send(_ bytes: Data) async throws {
        for message in try decoder.push(bytes) {
            switch message {
            case .hello:
                let snapshot = try ServerSnapshot(serverID: "server", revision: 0, sessions: [], models: [])
                handlers.onData(
                    try encodeServerMessage(.hello(try ServerHello(connectionID: "connection", snapshot: snapshot))))
            case .request(let request):
                let result: CommandResult
                switch request.request {
                case .list: result = .list([])
                case .attach(let id): result = .attach(try snapshot(id: id, attached: true))
                case .detach(let id): result = .detach(sessionID: id)
                default: result = .prompt(try snapshot(id: "s", attached: true))
                }
                handlers.onData(try encodeServerMessage(.response(.success(id: request.id, result: result))))
            }
        }
    }
    func close() async {}

    private func snapshot(id: String, attached: Bool) throws -> SessionSnapshot {
        try SessionSnapshot(
            id: id, cwd: "/tmp", createdAt: 0, updatedAt: 0, phase: .idle,
            model: ModelReference(provider: "test", id: "model"), thinkingLevel: .off, attached: attached,
            locked: false, revision: 0, transcript: [], queuedSteer: [], queuedSteerCount: 0)
    }
}

private func waitUntil(_ condition: @escaping () async -> Bool) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out")
}
