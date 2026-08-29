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

    func testBundledCatalogRetainsGeneratedRequestMetadata() throws {
        let catalog = try BuiltinModelCatalog.bundled()
        let vertex = try XCTUnwrap(
            catalog.model(provider: "google-vertex", id: "gemini-2.5-flash")
        )
        XCTAssertEqual(
            vertex.baseURLTemplate,
            "https://{location}-aiplatform.googleapis.com"
        )
        let anthropic = try XCTUnwrap(
            catalog.model(provider: "anthropic", id: "claude-fable-5")
        )
        XCTAssertEqual(anthropic.compatibilityBool("forceAdaptiveThinking"), true)
        XCTAssertEqual(anthropic.thinkingLevelMapValue(.off), .null)
        XCTAssertEqual(anthropic.requestThinkingValue(.xhigh), "xhigh")
        let copilot = try XCTUnwrap(
            catalog.model(provider: "github-copilot", id: "claude-fable-5")
        )
        XCTAssertEqual(copilot.headers?["Copilot-Integration-Id"], "vscode-chat")
        let bedrock = try XCTUnwrap(
            catalog.model(
                provider: "amazon-bedrock",
                id: "anthropic.claude-opus-4-6-v1"
            )
        )
        let payload = try ProviderPayloadBuilder.build(
            model: bedrock,
            context: Context(),
            options: StreamOptions(thinking: .high)
        )
        XCTAssertEqual(
            jsonPath(payload, "additionalModelRequestFields", "thinking", "type"),
            "adaptive"
        )
        XCTAssertEqual(
            jsonPath(payload, "additionalModelRequestFields", "output_config", "effort"),
            "high"
        )
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

    func testResponsesAndBedrockPayloadsUseProviderSpecificContentAndTools() throws {
        let context = Context(
            messages: [
                .user(
                    UserMessage(
                        content: [
                            .text(text: "look"),
                            .image(data: "aGVsbG8=", mimeType: "image/png"),
                        ],
                        timestamp: 1
                    )
                ),
                .assistant(
                    AssistantMessage(
                        content: [
                            .toolCall(
                                ToolCall(
                                    id: "call-1",
                                    name: "read",
                                    arguments: ["path": "README.md"]
                                )
                            )
                        ],
                        api: "bedrock-converse-stream",
                        provider: "amazon-bedrock",
                        model: "claude",
                        stopReason: .toolUse
                    )
                ),
                .toolResult(
                    ToolResultMessage(
                        toolCallId: "call-1",
                        toolName: "read",
                        content: [.text(text: "done")],
                        isError: false
                    )
                ),
            ],
            tools: [
                ToolDefinition(
                    name: "read",
                    description: "Read a file",
                    parameters: ["type": "object"]
                )
            ]
        )
        let responses = Model(
            id: "gpt",
            name: "GPT",
            api: "openai-responses",
            provider: "openai",
            baseURL: URL(string: "https://example.com/v1")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        let responsesPayload = try ProviderPayloadBuilder.build(
            model: responses,
            context: context,
            options: StreamOptions()
        )
        XCTAssertEqual(
            jsonPath(responsesPayload, "input", "0", "content", "0", "type"),
            "input_text"
        )
        XCTAssertEqual(
            jsonPath(responsesPayload, "input", "0", "content", "1", "type"),
            "input_image"
        )
        XCTAssertEqual(jsonPath(responsesPayload, "tools", "0", "name"), "read")
        XCTAssertNil(jsonPath(responsesPayload, "tools", "0", "function"))

        let bedrock = Model(
            id: "anthropic.claude-test",
            name: "Claude",
            api: "bedrock-converse-stream",
            provider: "amazon-bedrock",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 100,
            maximumTokens: 10,
            compat: ["supportsStrictMode": true]
        )
        let bedrockPayload = try ProviderPayloadBuilder.build(
            model: bedrock,
            context: context,
            options: StreamOptions()
        )
        XCTAssertEqual(
            jsonPath(bedrockPayload, "messages", "1", "content", "0", "toolUse", "toolUseId"),
            "call-1"
        )
        XCTAssertEqual(
            jsonPath(bedrockPayload, "messages", "2", "content", "0", "toolResult", "status"),
            "success"
        )
        XCTAssertEqual(
            jsonPath(bedrockPayload, "toolConfig", "tools", "0", "toolSpec", "name"),
            "read"
        )
        XCTAssertEqual(
            jsonPath(bedrockPayload, "toolConfig", "tools", "0", "toolSpec", "strict"),
            true
        )
    }

    func testOpenAICompatAndThinkingMetadataAffectPayload() throws {
        let model = Model(
            id: "reasoning",
            name: "Reasoning",
            api: "openai-completions",
            provider: "compatible",
            baseURL: URL(string: "https://example.com/v1")!,
            reasoning: true,
            contextWindow: 100,
            maximumTokens: 10,
            compat: [
                "supportsUsageInStreaming": false,
                "supportsDeveloperRole": true,
                "supportsStrictMode": true,
                "maxTokensField": "max_tokens",
                "thinkingFormat": "openrouter",
            ],
            thinkingLevelMap: ["high": "provider-high"]
        )
        let payload = try ProviderPayloadBuilder.build(
            model: model,
            context: Context(
                systemPrompt: "system",
                messages: [.user(UserMessage("hello"))],
                tools: [
                    ToolDefinition(
                        name: "read",
                        description: "Read",
                        parameters: ["type": "object"]
                    )
                ]
            ),
            options: StreamOptions(maximumTokens: 7, thinking: .high)
        )
        XCTAssertNil(jsonPath(payload, "stream_options"))
        XCTAssertEqual(jsonPath(payload, "max_tokens"), 7)
        XCTAssertNil(jsonPath(payload, "max_completion_tokens"))
        XCTAssertEqual(jsonPath(payload, "reasoning", "effort"), "provider-high")
        XCTAssertEqual(jsonPath(payload, "messages", "0", "role"), "developer")
        XCTAssertEqual(jsonPath(payload, "tools", "0", "function", "strict"), true)
    }

    func testProviderPayloadsRejectNonFiniteTemperatures() {
        let apis = [
            "openai-completions",
            "openai-responses",
            "anthropic-messages",
            "google-generative-ai",
            "bedrock-converse-stream",
            "pi-messages",
        ]
        for api in apis {
            let model = Model(
                id: "model",
                name: "Model",
                api: api,
                provider: "provider",
                baseURL: URL(string: "https://example.com")!,
                contextWindow: 100,
                maximumTokens: 10
            )
            for temperature in [Double.nan, Double.infinity, -Double.infinity] {
                XCTAssertThrowsError(
                    try ProviderPayloadBuilder.build(
                        model: model,
                        context: Context(),
                        options: StreamOptions(temperature: temperature)
                    ),
                    "Expected \(api) to reject \(temperature)"
                )
            }
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

    func testProviderEventReducerPreservesParallelOpenAIToolCalls() throws {
        let model = Model(
            id: "model",
            name: "Model",
            api: "openai-completions",
            provider: "openai",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        var reducer = ProviderEventReducer(model: model)
        let starts = try reducer.consume([
            "choices": .array([
                [
                    "delta": [
                        "tool_calls": .array([
                            [
                                "index": 0,
                                "id": "call-a",
                                "function": ["name": "read", "arguments": "{\"path\":\"A"],
                            ],
                            [
                                "index": 1,
                                "id": "call-b",
                                "function": ["name": "write", "arguments": "{\"path\":\"B"],
                            ],
                        ])
                    ]
                ]
            ])
        ])
        XCTAssertEqual(starts.filter { if case .toolCallStart = $0 { true } else { false } }.count, 2)
        _ = try reducer.consume([
            "choices": .array([
                [
                    "delta": [
                        "tool_calls": .array([
                            ["index": 1, "function": ["arguments": "\"}"]],
                            ["index": 0, "function": ["arguments": "\"}"]],
                        ])
                    ]
                ]
            ])
        ])
        let ends = try reducer.consume([
            "choices": .array([["delta": [:], "finish_reason": "tool_calls"]])
        ])
        XCTAssertEqual(ends.filter { if case .toolCallEnd = $0 { true } else { false } }.count, 2)
        guard case .toolCall(let first) = reducer.partial.content[0],
            case .toolCall(let second) = reducer.partial.content[1]
        else {
            return XCTFail("Expected parallel tool calls")
        }
        XCTAssertEqual(first.id, "call-a")
        XCTAssertEqual(first.name, "read")
        XCTAssertEqual(first.arguments, ["path": "A"])
        XCTAssertEqual(second.id, "call-b")
        XCTAssertEqual(second.name, "write")
        XCTAssertEqual(second.arguments, ["path": "B"])
    }

    func testProviderEventReducerDecodesEveryGeminiPart() throws {
        let model = Model(
            id: "gemini",
            name: "Gemini",
            api: "google-generative-ai",
            provider: "google",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        var reducer = ProviderEventReducer(model: model)
        let events = try reducer.consume([
            "responseId": "response-1",
            "candidates": .array([
                [
                    "content": [
                        "parts": .array([
                            [
                                "text": "reason",
                                "thought": true,
                                "thoughtSignature": "thinking-signature",
                            ],
                            [
                                "text": "answer",
                                "thoughtSignature": "text-signature",
                            ],
                            [
                                "functionCall": [
                                    "id": "call-a",
                                    "name": "read",
                                    "args": ["path": "A"],
                                ],
                                "thoughtSignature": "tool-signature",
                            ],
                            [
                                "functionCall": [
                                    "name": "write",
                                    "args": ["path": "B"],
                                ]
                            ],
                        ])
                    ],
                    "finishReason": "STOP",
                ]
            ]),
            "usageMetadata": [
                "promptTokenCount": 10,
                "cachedContentTokenCount": 3,
                "candidatesTokenCount": 4,
                "thoughtsTokenCount": 2,
                "totalTokenCount": 16,
            ],
        ])

        XCTAssertEqual(
            events.filter { if case .toolCallStart = $0 { true } else { false } }.count,
            2
        )
        XCTAssertEqual(
            events.filter { if case .toolCallDelta = $0 { true } else { false } }.count,
            2
        )
        XCTAssertEqual(
            events.filter { if case .toolCallEnd = $0 { true } else { false } }.count,
            2
        )
        XCTAssertEqual(reducer.partial.content.count, 4)
        XCTAssertEqual(
            reducer.partial.content[0],
            .thinking(text: "reason", signature: "thinking-signature")
        )
        XCTAssertEqual(
            reducer.partial.content[1],
            .text(text: "answer", signature: "text-signature")
        )
        guard case .toolCall(let first) = reducer.partial.content[2],
            case .toolCall(let second) = reducer.partial.content[3]
        else {
            return XCTFail("Expected parallel Gemini tool calls")
        }
        XCTAssertEqual(first.id, "call-a")
        XCTAssertEqual(first.name, "read")
        XCTAssertEqual(first.arguments, ["path": "A"])
        XCTAssertEqual(first.thoughtSignature, "tool-signature")
        XCTAssertEqual(second.name, "write")
        XCTAssertEqual(second.arguments, ["path": "B"])
        XCTAssertEqual(reducer.partial.responseId, "response-1")
        XCTAssertEqual(reducer.partial.stopReason, .toolUse)
        XCTAssertEqual(reducer.partial.usage.input, 7)
        XCTAssertEqual(reducer.partial.usage.output, 6)
        XCTAssertEqual(reducer.partial.usage.cacheRead, 3)
        XCTAssertEqual(reducer.partial.usage.reasoning, 2)
        XCTAssertEqual(reducer.partial.usage.totalTokens, 16)
    }

    func testProviderEventReducerPreservesAnthropicThinkingMetadata() throws {
        let model = Model(
            id: "claude",
            name: "Claude",
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
            "content_block": ["type": "thinking", "thinking": "why"],
        ])
        _ = try reducer.consume([
            "type": "content_block_delta",
            "index": 0,
            "delta": ["type": "signature_delta", "signature": "opaque"],
        ])
        _ = try reducer.consume([
            "type": "content_block_start",
            "index": 1,
            "content_block": ["type": "redacted_thinking", "data": "encrypted"],
        ])
        XCTAssertEqual(
            reducer.partial.content[0],
            .thinking(text: "why", signature: "opaque")
        )
        XCTAssertEqual(
            reducer.partial.content[1],
            .thinking(
                text: "[Reasoning redacted]",
                signature: "encrypted",
                redacted: true
            )
        )
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

    func testVertexRequestResolvesTemplateAndGeneratedHeaders() async throws {
        let catalog = try BuiltinModelCatalog.bundled()
        var model = try XCTUnwrap(
            catalog.model(provider: "google-vertex", id: "gemini-2.5-flash")
        )
        model.headers = ["X-Generated": "catalog"]
        let provider = HTTPProvider(
            configuration: ProviderConfiguration(
                id: model.provider,
                api: model.api,
                baseURL: model.baseURL,
                models: [model],
                apiKeyEnvironmentVariables: []
            ),
            environment: { [:] }
        )
        let request = try await provider.buildRequest(
            model: model,
            context: Context(),
            apiKey: "key",
            options: StreamOptions(),
            environment: [
                "GOOGLE_CLOUD_PROJECT": "sample-project",
                "GOOGLE_CLOUD_LOCATION": "us-central1",
            ]
        )
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://us-central1-aiplatform.googleapis.com/v1/projects/sample-project/locations/us-central1/publishers/google/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Generated"), "catalog")
    }

    func testSSEDecoderPreservesUnicodeSeparators() {
        var decoder = SSEDecoder()
        let input = "event: message\ndata: {\"text\":\"a\u{2028}b\"}\n\n"
        let records = input.utf8.flatMap { decoder.push($0) }
        XCTAssertEqual(records, [SSERecord(event: "message", data: "{\"text\":\"a\u{2028}b\"}")])
    }

    func testSSEDecoderSplitsCRLFRecords() {
        var decoder = SSEDecoder()
        let input = "event: first\r\ndata: one\r\n\r\nevent: second\r\ndata: two\r\n\r\n"
        let records = input.utf8.flatMap { decoder.push($0) }
        XCTAssertEqual(
            records,
            [
                SSERecord(event: "first", data: "one"),
                SSERecord(event: "second", data: "two"),
            ]
        )
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

private func jsonPath(_ value: JSONValue, _ path: String...) -> JSONValue? {
    var current = value
    for component in path {
        if case .object(let object) = current, let next = object[component] {
            current = next
        } else if case .array(let array) = current,
            let index = Int(component), array.indices.contains(index)
        {
            current = array[index]
        } else {
            return nil
        }
    }
    return current
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
