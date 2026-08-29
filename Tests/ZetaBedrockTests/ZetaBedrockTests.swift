import Foundation
import XCTest
import ZetaAI
import ZetaAuth

@testable import ZetaBedrock

final class ZetaBedrockTests: XCTestCase {
    func testEventStreamFragmentationHeadersAndCRC() throws {
        let message = eventMessage(
            headers: [":message-type": "event", ":event-type": "chunk"],
            payload: Data("{\"contentBlockDelta\":{}}".utf8)
        )
        for split in 1..<message.count {
            var decoder = AWSEventStreamDecoder()
            XCTAssertTrue(try decoder.push(Data(message[..<split])).isEmpty)
            let decoded = try decoder.push(Data(message[split...]))
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0].headers[":event-type"], "chunk")
            try decoder.finish()
        }
    }

    func testEventStreamRejectsCRCAndTruncation() throws {
        var corrupted = eventMessage(headers: [:], payload: Data("x".utf8))
        corrupted[corrupted.count - 1] ^= 0xFF
        var decoder = AWSEventStreamDecoder()
        XCTAssertThrowsError(try decoder.push(corrupted))
        var truncated = AWSEventStreamDecoder()
        _ = try truncated.push(Data(eventMessage(headers: [:], payload: Data()).dropLast()))
        XCTAssertThrowsError(try truncated.finish())
    }

    func testEventStreamRejectsDeclaredLengthAboveLimitFromPrelude() throws {
        var prelude = Data()
        prelude.appendUInt32(1_025)
        prelude.appendUInt32(0)
        prelude.appendUInt32(0)
        var decoder = AWSEventStreamDecoder(maximumMessageLength: 1_024)

        XCTAssertThrowsError(try decoder.push(prelude)) { error in
            guard case AWSEventStreamError.invalidLength = error else {
                return XCTFail("Expected invalid length, got \(error)")
            }
        }
    }

    func testBearerAndSigV4RequestsUseDistinctAuthorization() throws {
        var request = URLRequest(url: URL(string: "https://bedrock.example.com/model/test")!)
        request.httpMethod = "POST"
        let body = Data("{}".utf8)
        let date = Date(timeIntervalSince1970: 0)

        let bearerCredential = try XCTUnwrap(
            CredentialResolver.aws(environment: [
                "AWS_BEARER_TOKEN_BEDROCK": "bedrock-token"
            ])
        )
        let bearer = try BedrockProvider.authorizedRequest(
            request,
            body: body,
            region: "us-east-1",
            credential: bearerCredential,
            date: date
        )
        XCTAssertEqual(
            bearer.value(forHTTPHeaderField: "Authorization"),
            "Bearer bedrock-token"
        )
        XCTAssertNil(bearer.value(forHTTPHeaderField: "x-amz-date"))
        XCTAssertNil(bearer.value(forHTTPHeaderField: "x-amz-security-token"))
        XCTAssertEqual(bearer.httpBody, body)

        let signed = try BedrockProvider.authorizedRequest(
            request,
            body: body,
            region: "us-east-1",
            credential: AWSCredential(
                accessKeyID: "access",
                secretAccessKey: "secret"
            ),
            date: date
        )
        XCTAssertTrue(
            signed.value(forHTTPHeaderField: "Authorization")?
                .hasPrefix("AWS4-HMAC-SHA256 Credential=access/") == true
        )
        XCTAssertNotNil(signed.value(forHTTPHeaderField: "x-amz-date"))
        XCTAssertEqual(signed.httpBody, body)
    }

    func testModelIDIsEncodedOnceAsOneBedrockPathSegment() throws {
        let url = try BedrockProvider.endpointURL(
            baseURL: URL(string: "https://bedrock.example.com/runtime")!,
            modelID: "arn:aws:bedrock:us-east-1:123:model/profile"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://bedrock.example.com/runtime/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A123%3Amodel%2Fprofile/converse-stream"
        )
        XCTAssertFalse(url.absoluteString.contains("%253A"))
    }

    func testFailureAfterStartPreservesBedrockPartial() async throws {
        var body = Data()
        body.append(
            eventMessage(
                headers: [":message-type": "event", ":event-type": "chunk"],
                payload: Data(
                    #"{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"text":"kept"}}}"#
                        .utf8
                )
            )
        )
        body.append(
            eventMessage(
                headers: [":message-type": "exception"],
                payload: Data("stream failed".utf8)
            )
        )
        BedrockStreamingURLProtocol.setBody(body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BedrockStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let credential = try XCTUnwrap(
            CredentialResolver.aws(environment: [
                "AWS_BEARER_TOKEN_BEDROCK": "synthetic-token"
            ])
        )
        let model = Model(
            id: "provider.model:0",
            name: "Model",
            api: "bedrock-converse-stream",
            provider: "amazon-bedrock",
            baseURL: URL(string: "https://bedrock.example.com")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        let provider = BedrockProvider(
            models: [model],
            region: "us-east-1",
            session: session
        ) {
            credential
        }

        let stream = await provider.stream(
            model: model,
            context: Context(),
            options: StreamOptions()
        )
        var events: [AssistantEvent] = []
        for try await event in stream { events.append(event) }

        guard case .error(.error, let message) = events.last else {
            return XCTFail("Expected terminal Bedrock streaming error")
        }
        XCTAssertEqual(message.content, [.text(text: "kept")])
        XCTAssertEqual(message.stopReason, .error)
        XCTAssertNotNil(message.errorMessage)
        let result = await stream.result()
        XCTAssertEqual(result, message)
        XCTAssertEqual(events.filter { if case .error = $0 { true } else { false } }.count, 1)
    }

    func testToolUseStreamParsesFragmentedInputAndStopReason() async throws {
        let credential = try XCTUnwrap(
            CredentialResolver.aws(environment: [
                "AWS_BEARER_TOKEN_BEDROCK": "unused"
            ])
        )
        let provider = BedrockProvider(models: [], region: "us-east-1") {
            credential
        }
        var partial = AssistantMessage(
            api: "bedrock-converse-stream",
            provider: "amazon-bedrock",
            model: "test-model"
        )
        var toolInputBuffers: [Int: String] = [:]
        let stream = AssistantEventStream()
        await stream.emit(.start(partial))
        let eventsTask = Task { () throws -> [AssistantEvent] in
            var events: [AssistantEvent] = []
            for try await event in stream { events.append(event) }
            return events
        }

        try await provider.consume(
            [
                bedrockMessage(
                    #"{"contentBlockStart":{"contentBlockIndex":0,"start":{"toolUse":{"toolUseId":"call-1","name":"weather"}}}}"#
                ),
                bedrockMessage(
                    #"{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"toolUse":{"input":"{\"city\":\"San"}}}}"#
                ),
                bedrockMessage(
                    #"{"contentBlockDelta":{"contentBlockIndex":0,"delta":{"toolUse":{"input":" Francisco\"}"}}}}"#
                ),
                bedrockMessage(#"{"contentBlockStop":{"contentBlockIndex":0}}"#),
                bedrockMessage(#"{"messageStop":{"stopReason":"tool_use"}}"#),
                bedrockMessage(
                    #"{"metadata":{"usage":{"inputTokens":7,"outputTokens":3}}}"#
                ),
            ],
            partial: &partial,
            toolInputBuffers: &toolInputBuffers,
            stream: stream
        )
        await stream.emit(.done(reason: partial.stopReason, message: partial))
        let events = try await eventsTask.value

        XCTAssertEqual(
            partial.content,
            [
                .toolCall(
                    ToolCall(
                        id: "call-1",
                        name: "weather",
                        arguments: ["city": "San Francisco"]
                    )
                )
            ]
        )
        XCTAssertEqual(partial.stopReason, .toolUse)
        XCTAssertEqual(partial.rawStopReason, "tool_use")
        XCTAssertEqual(partial.usage.totalTokens, 10)
        XCTAssertTrue(events.contains { if case .toolCallStart(0, _) = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .toolCallDelta(0, _, _) = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .toolCallEnd(0, _, _) = $0 { true } else { false } })
    }
}

private final class BedrockStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()

    static func setBody(_ value: Data) {
        lock.withLock { body = value }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/vnd.amazon.eventstream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.lock.withLock { Self.body })
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func bedrockMessage(_ payload: String) -> AWSEventStreamMessage {
    AWSEventStreamMessage(headers: [":message-type": "event"], payload: Data(payload.utf8))
}

private func eventMessage(headers: [String: String], payload: Data) -> Data {
    var headerData = Data()
    for key in headers.keys.sorted() {
        let name = Data(key.utf8)
        let value = Data(headers[key]!.utf8)
        headerData.append(UInt8(name.count))
        headerData.append(name)
        headerData.append(7)
        headerData.append(UInt8(value.count >> 8))
        headerData.append(UInt8(value.count & 0xFF))
        headerData.append(value)
    }
    let total = 16 + headerData.count + payload.count
    var message = Data()
    message.appendUInt32(UInt32(total))
    message.appendUInt32(UInt32(headerData.count))
    message.appendUInt32(crc32(message))
    message.append(headerData)
    message.append(payload)
    message.appendUInt32(crc32(message))
    return message
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0)
        }
    }
    return crc ^ 0xFFFF_FFFF
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
