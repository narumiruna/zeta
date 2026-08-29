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

    func testHandshakeAndConcurrentListRequest() async throws {
        let service = TestService()
        let server = try PiServer(serverID: "server", service: service)
        let connection = TestConnection()
        try await server.accept(connection)
        await server.receive(try encodeClientMessage(.hello(try ClientHello())), connectionID: connection.id)
        try await waitUntil { await connection.count >= 1 }
        let decoder = try ServerMessageDecoder()
        let first = try decoder.push(await connection.data[0])
        guard case .hello = first.first else { return XCTFail("Expected hello") }
        let request = try RequestEnvelope(id: "1", request: .list)
        await server.receive(try encodeClientMessage(.request(request)), connectionID: connection.id)
        try await waitUntil { await connection.count >= 2 }
        let second = try decoder.push(await connection.data[1])
        guard case .response(.success(id: "1", result: .list)) = second.first else {
            return XCTFail("Expected list response")
        }
        await server.close()
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
    nonisolated let id: String
    private(set) var data: [Data] = []
    private(set) var isClosed = false
    var count: Int { data.count }

    init(id: String = "connection") { self.id = id }

    func send(_ bytes: Data) async throws { data.append(bytes) }
    func close() async { isClosed = true }
}

private struct TestService: PiServerService {
    func listSessions() async throws -> [SessionMetadata] { [] }
    func listModels() async throws -> [ModelMetadata] { [] }
    func createSession(_ options: CreateCommandOptions) async throws -> any PiSessionRuntime {
        TestRuntime(id: "created")
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

private actor RuntimeTracker {
    private(set) var disposeCount = 0
    func recordDispose() { disposeCount += 1 }
}

private actor TestRuntime: PiSessionRuntime {
    nonisolated let id: String
    private let tracker: RuntimeTracker?

    init(id: String, tracker: RuntimeTracker? = nil) {
        self.id = id
        self.tracker = tracker
    }
    func snapshot(attached: Bool) throws -> SessionSnapshot { try makeSnapshot(attached: attached) }
    func prompt(_ text: String) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func steer(_ text: String) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func abort() throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func setModel(_ model: ModelReference) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func setThinking(_ level: ThinkingLevel) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func dispose() async { await tracker?.recordDispose() }
    private func makeSnapshot(attached: Bool) throws -> SessionSnapshot {
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
