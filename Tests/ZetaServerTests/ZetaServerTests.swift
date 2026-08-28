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
}

private actor TestConnection: ServerByteConnection {
    nonisolated let id = "connection"
    private(set) var data: [Data] = []
    private(set) var isClosed = false
    var count: Int { data.count }
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

private actor TestRuntime: PiSessionRuntime {
    nonisolated let id: String
    init(id: String) { self.id = id }
    func snapshot(attached: Bool) throws -> SessionSnapshot { try makeSnapshot(attached: attached) }
    func prompt(_ text: String) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func steer(_ text: String) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func abort() throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func setModel(_ model: ModelReference) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func setThinking(_ level: ThinkingLevel) throws -> SessionSnapshot { try makeSnapshot(attached: true) }
    func dispose() {}
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
