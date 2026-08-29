import Foundation
import XCTest

@testable import ZetaAI

final class HTTPStreamLifecycleTests: XCTestCase {
    func testCleanSSEEOFWithoutTerminalEventFailsAndPreservesPartial() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncompleteStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = Model(
            id: "model",
            name: "Model",
            api: "openai-completions",
            provider: "test-provider",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 1_000,
            maximumTokens: 100
        )
        let provider = HTTPProvider(
            configuration: ProviderConfiguration(
                id: model.provider,
                api: model.api,
                baseURL: model.baseURL,
                models: [model],
                apiKeyEnvironmentVariables: []
            ),
            session: session
        )

        let stream = await provider.stream(
            model: model,
            context: Context(),
            options: StreamOptions(apiKey: "synthetic-key")
        )
        var events: [AssistantEvent] = []
        for try await event in stream { events.append(event) }

        guard case .error(.error, let message) = events.last else {
            return XCTFail("Expected incomplete SSE stream to fail")
        }
        XCTAssertEqual(message.content, [.text(text: "kept")])
        XCTAssertEqual(message.stopReason, .error)
        XCTAssertTrue(message.errorMessage?.contains("before a terminal event") == true)
    }
}

private final class IncompleteStreamingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                "data: {\"id\":\"response-1\",\"choices\":[{\"delta\":{\"content\":\"kept\"}}]}\n\n"
                    .utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
