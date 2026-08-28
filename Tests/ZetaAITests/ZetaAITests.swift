import XCTest
import ZetaCore

@testable import ZetaAI

final class ZetaAITests: XCTestCase {
    func testBundledCatalogContainsEveryGeneratedProvider() throws {
        let catalog = try BuiltinModelCatalog.bundled()
        XCTAssertGreaterThanOrEqual(catalog.providers.count, 39)
        XCTAssertGreaterThanOrEqual(catalog.models.count, 1_200)
        XCTAssertNotNil(catalog.model(provider: "openai", id: "gpt-4o-mini"))
    }

    func testDynamicCatalogPersistenceRefreshAndCaseInsensitiveHeaders() async throws {
        let model = Model(
            id: "dynamic",
            name: "Dynamic",
            api: "openai-completions",
            provider: "dynamic",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        let store = InMemoryModelCatalogStore()
        let provider = DynamicModelProvider(
            id: "dynamic",
            store: store,
            fetch: { _ in StoredModelCatalog(models: [model], checkedAt: 1) },
            stream: { model, _, _ in
                let stream = AssistantEventStream()
                await stream.failBeforeStart(
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    error: ProviderError.invalidResponse("test")
                )
                return stream
            }
        )
        try await provider.refresh()
        let refreshedModels = await provider.models
        XCTAssertEqual(refreshedModels, [model])
        let restored = DynamicModelProvider(
            id: "dynamic",
            store: store,
            fetch: { _ in StoredModelCatalog(models: []) },
            stream: { _, _, _ in AssistantEventStream() }
        )
        try await restored.restore()
        let restoredModels = await restored.models
        XCTAssertEqual(restoredModels, [model])
        let result = await ModelRefresh.all([restored], allowNetwork: false)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertEqual(result.refreshed, ["dynamic"])

        var headers = CaseInsensitiveHeaders(["Authorization": "one", "X-Test": "a"])
        headers.merge(["authorization": "two", "x-test": nil])
        XCTAssertEqual(headers["AUTHORIZATION"], "two")
        XCTAssertNil(headers["X-Test"])
    }

    func testProviderPayloadFamiliesPreserveToolAndThinkingSemantics() throws {
        let context = Context(
            systemPrompt: "system",
            messages: [
                .user(UserMessage("hello", timestamp: 1)),
                .assistant(
                    AssistantMessage(
                        content: [
                            .thinking(text: "reason", signature: "opaque"),
                            .toolCall(ToolCall(id: "call", name: "read", arguments: ["path": "a"])),
                        ],
                        api: "test",
                        provider: "test",
                        model: "test",
                        stopReason: .toolUse,
                        timestamp: 2
                    )
                ),
                .toolResult(
                    ToolResultMessage(
                        toolCallId: "call",
                        toolName: "read",
                        content: [.text(text: "result")],
                        isError: false,
                        timestamp: 3
                    )
                ),
            ],
            tools: [ToolDefinition(name: "read", description: "Read", parameters: ["type": "object"])]
        )
        for api in [
            "openai-completions", "openai-responses", "anthropic-messages",
            "google-generative-ai", "bedrock-converse-stream", "pi-messages",
        ] {
            let model = Model(
                id: "model",
                name: "Model",
                api: api,
                provider: "provider",
                baseURL: URL(string: "https://example.com")!,
                reasoning: true,
                contextWindow: 100,
                maximumTokens: 20
            )
            let payload = try ProviderPayloadBuilder.build(
                model: model,
                context: context,
                options: StreamOptions(thinking: .high, sessionID: "session")
            )
            let encoded = OrderedJSON.string(payload)
            if api != "google-generative-ai" && api != "bedrock-converse-stream" {
                XCTAssertTrue(encoded.contains("model"))
            }
            XCTAssertFalse(encoded.isEmpty)
        }
    }

    func testProviderEventReducerHandlesTextThinkingToolsAndUsage() throws {
        let model = Model(
            id: "model",
            name: "Model",
            api: "anthropic-messages",
            provider: "anthropic",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        var reducer = ProviderEventReducer(model: model)
        _ = try reducer.consume([
            "type": "content_block_start",
            "index": 0,
            "content_block": ["type": "thinking"],
        ])
        let thinking = try reducer.consume([
            "type": "content_block_delta",
            "index": 0,
            "delta": ["thinking": "reason"],
        ])
        XCTAssertTrue(
            thinking.contains {
                if case .thinkingDelta(0, "reason", _) = $0 { true } else { false }
            }
        )
        _ = try reducer.consume([
            "type": "content_block_start",
            "index": 1,
            "content_block": [
                "type": "tool_use",
                "id": "call",
                "name": "read",
            ],
        ])
        _ = try reducer.consume([
            "type": "content_block_delta",
            "index": 1,
            "delta": ["partial_json": "{\"path\":\"README"],
        ])
        let end =
            try reducer.consume([
                "type": "content_block_delta",
                "index": 1,
                "delta": ["partial_json": ".md\"}"],
            ])
            + reducer.consume([
                "type": "content_block_stop",
                "index": 1,
            ])
        XCTAssertTrue(end.contains { if case .toolCallEnd = $0 { true } else { false } })
        _ = try reducer.consume([
            "type": "message_delta",
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 2, "output_tokens": 3],
        ])
        XCTAssertEqual(reducer.partial.stopReason, .toolUse)
        XCTAssertEqual(reducer.partial.usage.totalTokens, 5)
    }

    func testCrossProviderTransformsRepairToolsAndRetryClassification() {
        let source = AssistantMessage(
            content: [
                .thinking(text: "reason", signature: "opaque"),
                .toolCall(ToolCall(id: "call/unsafe", name: "read", arguments: [:])),
            ],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude",
            stopReason: .toolUse
        )
        let target = Model(
            id: "gpt",
            name: "GPT",
            api: "openai-responses",
            provider: "openai",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        let transformed = MessageTransforms.forModel(
            [.assistant(source), .user(UserMessage("continue"))],
            target: target
        )
        XCTAssertEqual(transformed.count, 3)
        guard case .assistant(let assistant) = transformed[0] else {
            return XCTFail("Expected assistant")
        }
        XCTAssertTrue(
            assistant.content.contains {
                if case .text(let text, _) = $0 { text.contains("<thinking>") } else { false }
            }
        )
        guard case .toolResult(let missing) = transformed[1] else {
            return XCTFail("Expected synthetic tool result")
        }
        XCTAssertEqual(missing.toolCallId, "callunsafe")
        XCTAssertTrue(MessageTransforms.classifyOverflow(status: 400, message: "context length exceeded"))
        XCTAssertEqual(MessageTransforms.retryDelay(attempt: 3), 8_000)
        XCTAssertNil(
            MessageTransforms.retryDelay(
                attempt: 1,
                requestedMilliseconds: 70_000
            )
        )
    }

    func testOpenRouterImageGenerationAndInBandErrors() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = ImageModel(
            id: "image-model",
            name: "Image",
            api: "openrouter-images",
            provider: "openrouter",
            baseURL: URL(string: "https://example.com/v1")!,
            input: ["text", "image"],
            output: ["text", "image"]
        )
        ImageURLProtocol.response = (
            200,
            #"{"id":"response","choices":[{"message":{"content":"done","images":[{"image_url":{"url":"data:image/png;base64,aGVsbG8="}}]}}]}"#
        )
        let provider = OpenRouterImageProvider(models: [model], session: session)
        let result = await provider.generate(
            model: model,
            input: [.text(text: "draw")],
            options: StreamOptions(apiKey: "key")
        )
        XCTAssertEqual(result.stopReason, .stop)
        XCTAssertEqual(result.output.count, 2)
        ImageURLProtocol.response = (500, "failed")
        let failed = await provider.generate(
            model: model,
            input: [.text(text: "draw")],
            options: StreamOptions(apiKey: "key")
        )
        XCTAssertEqual(failed.stopReason, .error)
        XCTAssertNotNil(failed.errorMessage)
    }

    func testMessageRoundTripPreservesOpaqueMetadata() throws {
        let message = AssistantMessage(
            content: [
                .thinking(text: "reason", signature: "opaque", redacted: true),
                .text(text: "answer", signature: "signature"),
                .toolCall(ToolCall(id: "call-1", name: "read", arguments: ["path": "README.md"])),
            ],
            api: "anthropic-messages",
            provider: "anthropic",
            model: "claude",
            stopReason: .toolUse,
            timestamp: 123
        )
        let data = try JSONEncoder().encode(message)
        XCTAssertEqual(try JSONDecoder().decode(AssistantMessage.self, from: data), message)
    }

    func testFauxProviderStreamsAndReturnsResult() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        let response = AssistantMessage(
            content: [.text(text: "ok")], api: model.api, provider: model.provider, model: model.id, stopReason: .stop,
            timestamp: 1)
        await provider.enqueue(response)
        let stream = await provider.stream(model: model, context: Context(), options: StreamOptions())
        var events: [AssistantEvent] = []
        for try await event in stream { events.append(event) }
        let result = await stream.result()
        XCTAssertEqual(result.content, response.content)
        XCTAssertEqual(result.stopReason, response.stopReason)
        XCTAssertEqual(result.usage.input, 1)
        XCTAssertEqual(result.usage.output, 1)
        XCTAssertTrue(events.contains { if case .textDelta(_, "o", _) = $0 { true } else { false } })
        XCTAssertTrue(events.contains { if case .done(.stop, _) = $0 { true } else { false } })
    }

    func testFauxProviderTracksCallsCachingAndDeferredHandles() async throws {
        let provider = FauxProvider(tokensPerSecond: 10_000)
        let model = await provider.models[0]
        var deferred = AssistantMessage(
            content: [.text(text: "queued")],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .deferred
        )
        deferred.deferred = DeferredHandle(
            provider: model.provider,
            modelID: model.id,
            api: model.api,
            id: "deferred-1"
        )
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "first")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "second")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        await provider.enqueue(deferred)
        let context = Context(messages: [.user(UserMessage("hello"))])
        let firstStream = await provider.stream(
            model: model,
            context: context,
            options: StreamOptions(sessionID: "session")
        )
        for try await _ in firstStream {}
        let first = await firstStream.result()
        let secondStream = await provider.stream(
            model: model,
            context: context,
            options: StreamOptions(sessionID: "session")
        )
        for try await _ in secondStream {}
        let second = await secondStream.result()
        let deferredStream = await provider.stream(
            model: model,
            context: context,
            options: StreamOptions(cacheRetention: .none)
        )
        for try await _ in deferredStream {}
        let deferredResult = await deferredStream.result()
        XCTAssertGreaterThan(first.usage.cacheWrite, 0)
        XCTAssertGreaterThan(second.usage.cacheRead, 0)
        XCTAssertEqual(deferredResult.deferred?.id, "deferred-1")
        let callCount = await provider.callCount()
        let calls = await provider.calls()
        let pendingCount = await provider.pendingCount()
        XCTAssertEqual(callCount, 3)
        XCTAssertEqual(calls.first?.sessionID, "session")
        XCTAssertEqual(pendingCount, 0)
    }

    func testSSEDecoderPreservesUnicodeSeparators() {
        var decoder = SSEDecoder()
        let input = "event: message\ndata: {\"text\":\"a\u{2028}b\"}\n\n"
        let records = input.utf8.flatMap { decoder.push($0) }
        XCTAssertEqual(records, [SSERecord(event: "message", data: "{\"text\":\"a\u{2028}b\"}")])
    }

    func testCodexWebSocketPoolReusesAndEvictsIdleConnections() async throws {
        let factory = WebSocketFactoryRecorder()
        let pool = CodexWebSocketPool(idleTimeout: .seconds(300)) { _, _ in
            await factory.make()
        }
        let key = CodexWebSocketPool.Key(account: "account", sessionID: "session")
        let url = URL(string: "wss://example.com")!
        let first = try await pool.withConnection(
            key: key,
            url: url,
            headers: [:]
        ) { $0.identifier }
        let second = try await pool.withConnection(
            key: key,
            url: url,
            headers: [:]
        ) { $0.identifier }
        XCTAssertEqual(first, second)
        await pool.evictIdle(now: .now.advanced(by: .seconds(301)))
        let poolCount = await pool.count()
        let factoryCount = await factory.count()
        XCTAssertEqual(poolCount, 0)
        XCTAssertEqual(factoryCount, 1)
    }

    func testCodexProviderUsesWebSocketSessionAndTerminates() async throws {
        let connection = ScriptedWebSocketConnection(frames: [
            Data(#"{"type":"response.output_text.delta","delta":"ok"}"#.utf8),
            Data(#"{"type":"response.completed","response":{"id":"response-1"}}"#.utf8),
        ])
        let pool = CodexWebSocketPool { _, _ in connection }
        let model = Model(
            id: "codex",
            name: "Codex",
            api: "openai-codex-responses",
            provider: "openai-codex",
            baseURL: URL(string: "https://example.com/v1")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        let provider = CodexWebSocketProvider(models: [model], pool: pool)
        let stream = await provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage("hello"))]),
            options: StreamOptions(apiKey: "test", sessionID: "session")
        )
        for try await _ in stream {}
        let result = await stream.result()
        XCTAssertEqual(result.stopReason, .stop)
        XCTAssertEqual(result.responseId, "response-1")
        XCTAssertTrue(result.content.contains { if case .text("ok", _) = $0 { true } else { false } })
        let sent = await connection.sent()
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(String(decoding: sent[0], as: UTF8.self).contains("response.create"))
    }

    func testUnknownProviderReturnsInBandError() async throws {
        let registry = ModelRegistry()
        let model = Model(
            id: "x", name: "X", api: "unknown", provider: "missing", baseURL: URL(string: "https://example.invalid")!,
            contextWindow: 1, maximumTokens: 1)
        let stream = await registry.stream(model: model, context: Context())
        var terminal: AssistantEvent?
        for try await event in stream { terminal = event }
        guard case .error(.error, let message) = terminal else { return XCTFail("Expected terminal error") }
        XCTAssertEqual(message.stopReason, .error)
    }
}

private actor WebSocketFactoryRecorder {
    private var created = 0
    func make() -> any WebSocketConnection {
        created += 1
        return MockWebSocketConnection()
    }
    func count() -> Int { created }
}

private actor MockWebSocketConnection: WebSocketConnection {
    nonisolated let identifier = UUID()
    private var closed = false
    func send(_ data: Data) throws {
        if closed { throw ProviderError.invalidResponse("closed") }
    }
    func receive() throws -> Data {
        if closed { throw ProviderError.invalidResponse("closed") }
        return Data()
    }
    func close() { closed = true }
}

private actor ScriptedWebSocketConnection: WebSocketConnection {
    nonisolated let identifier = UUID()
    private var frames: [Data]
    private var outgoing: [Data] = []

    init(frames: [Data]) { self.frames = frames }
    func send(_ data: Data) { outgoing.append(data) }
    func receive() throws -> Data {
        guard !frames.isEmpty else { throw ProviderError.invalidResponse("No scripted WebSocket frame") }
        return frames.removeFirst()
    }
    func close() {}
    func sent() -> [Data] { outgoing }
}

private final class ImageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (Int, String) = (200, "{}")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let value = Self.response
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: value.0,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(value.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
