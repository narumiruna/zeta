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
