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

    func testRejectsOverlongPath() {
        XCTAssertThrowsError(try UnixServerListener(path: "/tmp/" + String(repeating: "x", count: 104)) { _ in })
    }
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
