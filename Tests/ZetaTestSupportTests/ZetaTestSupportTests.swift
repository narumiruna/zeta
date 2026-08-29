import Foundation
import XCTest

@testable import ZetaTestSupport

final class ZetaTestSupportTests: XCTestCase {
    func testDeterministicClockGateAndIDs() async {
        let clock = DeterministicClock()
        let completed = Flag()
        let sleeper = Task {
            await clock.sleep(milliseconds: 10)
            await completed.set()
        }
        await Task.yield()
        let before = await completed.current()
        XCTAssertFalse(before)
        await clock.advance(by: 10)
        await sleeper.value
        let after = await completed.current()
        XCTAssertTrue(after)

        let ids = DeterministicIDs(start: 3)
        let firstID = await ids.next()
        let secondID = await ids.next(prefix: "run")
        XCTAssertEqual(firstID, "id-3")
        XCTAssertEqual(secondID, "run-4")
    }

    func testLocalHTTPAndScriptedSocketCleanup() async throws {
        let server = try LocalHTTPServer.serverSentEvents([#"{"delta":"ok"}"#])
        let (data, response) = try await URLSession.shared.data(from: server.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "data: {\"delta\":\"ok\"}\n\n")
        XCTAssertTrue(server.capturedRequests().first?.starts(with: Data("GET / HTTP/1.1".utf8)) == true)
        server.stop()

        let socket = ScriptedSocket(inbound: [Data("one".utf8)])
        let received = await socket.receive()
        XCTAssertEqual(received, Data("one".utf8))
        await socket.send(Data("two".utf8))
        let sent = await socket.sent()
        XCTAssertEqual(sent, [Data("two".utf8)])
    }

    func testByteFragmenterAndFailureInjector() async throws {
        let data = Data([1, 2, 3, 4])
        XCTAssertEqual(ByteFragmenter.everySplit(data).count, 3)
        XCTAssertTrue(
            ByteFragmenter.everySplit(data).allSatisfy {
                $0.reduce(Data(), +) == data
            }
        )
        let storage = FailureInjector<Int>(failurePoints: [2])
        try await storage.append(1)
        do {
            try await storage.append(2)
            XCTFail("Expected injected failure")
        } catch {}
        let snapshot = await storage.snapshot()
        XCTAssertEqual(snapshot, [1])
    }
}

private actor Flag {
    private var value = false
    func set() { value = true }
    func current() -> Bool { value }
}
