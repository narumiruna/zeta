import Darwin
import Foundation
import XCTest
import ZetaClient

@testable import ZetaUnixTransport

final class ZetaUnixTransportTests: XCTestCase {
    func testRoundTripPermissionsAndInodeSafeCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("server.sock").path
        let connectionBox = ConnectionBox()
        let listener = try UnixServerListener(path: path) { connection in
            Task { await connectionBox.set(connection) }
        }
        let received = DataBox()
        let client = try UnixByteTransport(
            path: path,
            handlers: ByteTransportHandlers(
                onData: { data in Task { await received.set(data) } },
                onClose: {},
                onError: { _ in }
            )
        )
        let serverConnection = await connectionBox.wait()
        serverConnection.start(
            onData: { data in
                Task { try? await serverConnection.send(data) }
            },
            onClose: {}
        )
        try await client.send(Data("hello".utf8))
        let echoed = await received.wait()
        XCTAssertEqual(echoed, Data("hello".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        await client.close()
        await serverConnection.close()

        unlink(path)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: path))
        listener.close()
        XCTAssertEqual(
            try String(contentsOfFile: path, encoding: .utf8),
            "replacement"
        )
    }

    func testWriteAfterPeerDisconnectReturnsErrorWithoutSIGPIPE() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("disconnect.sock").path
        let connectionBox = ConnectionBox()
        let listener = try UnixServerListener(path: path) { connection in
            Task { await connectionBox.set(connection) }
        }
        let client = try UnixByteTransport(
            path: path,
            handlers: ByteTransportHandlers(onData: { _ in }, onClose: {}, onError: { _ in }))
        let serverConnection = await connectionBox.wait()

        await client.close()
        var writeError: Error?
        for _ in 0..<100 {
            do {
                try await serverConnection.send(Data("after-close".utf8))
                try await Task.sleep(for: .milliseconds(5))
            } catch {
                writeError = error
                break
            }
        }

        XCTAssertNotNil(writeError)
        await serverConnection.close()
        listener.close()
    }

    func testCloseRejectsAcceptedQueuedWritesBeforeDescriptorClosure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("queued.sock").path
        let connectionBox = ConnectionBox()
        let listener = try UnixServerListener(path: path) { connection in
            Task { await connectionBox.set(connection) }
        }
        let lifecycleQueue = DispatchQueue(label: "zeta.unix.test.suspended-lifecycle")
        lifecycleQueue.suspend()
        var resumed = false
        defer {
            if !resumed { lifecycleQueue.resume() }
            listener.close()
        }
        let client = try UnixByteTransport(
            path: path,
            maximumPendingBytes: 16,
            handlers: ByteTransportHandlers(onData: { _ in }, onClose: {}, onError: { _ in }),
            queue: lifecycleQueue
        )
        let serverConnection = await connectionBox.wait()
        let first = Task { await sendSettlesClosed(client, Data("first".utf8)) }
        let second = Task { await sendSettlesClosed(client, Data("second".utf8)) }
        try await waitUntil { client.pendingByteCount == 11 }

        let close = Task { await client.close() }
        try await waitUntil { client.isClosed }
        lifecycleQueue.resume()
        resumed = true

        let firstClosed = await first.value
        let secondClosed = await second.value
        XCTAssertTrue(firstClosed)
        XCTAssertTrue(secondClosed)
        await close.value
        let lateClosed = await sendSettlesClosed(client, Data("late".utf8))
        XCTAssertTrue(lateClosed)
        await serverConnection.close()
    }

    func testRejectsOverlongPath() {
        XCTAssertThrowsError(try UnixServerListener(path: "/tmp/" + String(repeating: "x", count: 104)) { _ in })
    }
}

private func sendSettlesClosed(_ transport: UnixByteTransport, _ data: Data) async -> Bool {
    do {
        try await transport.send(data)
        return false
    } catch UnixTransportError.closed {
        return true
    } catch {
        return false
    }
}

private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<100 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    XCTFail("Timed out")
}

private actor ConnectionBox {
    private var value: UnixServerConnection?
    private var waiters: [CheckedContinuation<UnixServerConnection, Never>] = []

    func set(_ value: UnixServerConnection) {
        self.value = value
        waiters.forEach { $0.resume(returning: value) }
        waiters.removeAll()
    }

    func wait() async -> UnixServerConnection {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

private actor DataBox {
    private var value: Data?
    private var waiters: [CheckedContinuation<Data, Never>] = []

    func set(_ value: Data) {
        self.value = value
        waiters.forEach { $0.resume(returning: value) }
        waiters.removeAll()
    }

    func wait() async -> Data {
        if let value { return value }
        return await withCheckedContinuation { waiters.append($0) }
    }
}
