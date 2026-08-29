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
    private(set) var detachCount = 0
    var attachCount: Int { attachments.count }

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
