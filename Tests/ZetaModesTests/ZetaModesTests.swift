import XCTest

@testable import ZetaModes

final class ZetaModesTests: XCTestCase {
    func testLFOnlyJSONLAndEOFRecord() throws {
        var decoder = LFJSONLDecoder()
        let records = try decoder.push(Data("{\"x\":\"a\u{2028}b\"}\r\nlast".utf8)) + decoder.finish()
        XCTAssertEqual(records.map { String(decoding: $0, as: UTF8.self) }, ["{\"x\":\"a\u{2028}b\"}", "last"])
    }

    func testStrictRPCPreservesTopLevelFieldsAndCommandSet() throws {
        let request = try StrictRPCRequest.decode(
            Data(
                #"{"id":"1","type":"prompt","message":"hello","streamingBehavior":"steer"}"#.utf8
            )
        )
        XCTAssertEqual(request.id, "1")
        XCTAssertEqual(request.command, .prompt)
        XCTAssertEqual(request.fields["message"], "hello")
        XCTAssertEqual(request.fields["streamingBehavior"], "steer")
        XCTAssertEqual(RPCCommandName.allCases.count, 33)
        let roundTrip = try StrictRPCRequest.decode(request.encoded())
        XCTAssertEqual(roundTrip, request)
    }

    func testConcurrentRPCResponseCarriesCorrelation() async throws {
        let sink = ResponseSink()
        let engine = RPCEngine { data in await sink.append(data) }
        await engine.register("echo") { $0.arguments }
        engine.accept(RPCRequest(id: "1", command: "echo", arguments: Data("ok".utf8)))
        try await Task.sleep(for: .milliseconds(20))
        let lines = await sink.values
        XCTAssertEqual(lines.count, 1)
        let response = try JSONDecoder().decode(RPCResponse.self, from: lines[0].dropLast())
        XCTAssertEqual(response.id, "1")
        XCTAssertTrue(response.success)
    }
}

private actor ResponseSink {
    var values: [Data] = []
    func append(_ data: Data) { values.append(data) }
}
