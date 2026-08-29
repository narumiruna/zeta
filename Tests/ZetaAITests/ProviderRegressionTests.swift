import XCTest
import ZetaCore

@testable import ZetaAI

final class ProviderRegressionTests: XCTestCase {
    func testGeminiUsageMetadataUsesSelectedModelRates() throws {
        var reducer = ProviderEventReducer(model: pricedModel(api: "google-generative-ai"))

        _ = try reducer.consume([
            "usageMetadata": [
                "promptTokenCount": 100,
                "cachedContentTokenCount": 20,
                "candidatesTokenCount": 30,
                "thoughtsTokenCount": 10,
                "totalTokenCount": 140,
            ]
        ])

        XCTAssertEqual(reducer.partial.usage.input, 80)
        XCTAssertEqual(reducer.partial.usage.output, 40)
        XCTAssertEqual(reducer.partial.usage.cacheRead, 20)
        XCTAssertEqual(reducer.partial.usage.cacheWrite, 0)
        XCTAssertEqual(reducer.partial.usage.reasoning, 10)
        XCTAssertEqual(reducer.partial.usage.totalTokens, 140)
        XCTAssertEqual(reducer.partial.usage.cost.input, 0.000_16, accuracy: 1e-12)
        XCTAssertEqual(reducer.partial.usage.cost.output, 0.000_16, accuracy: 1e-12)
        XCTAssertEqual(reducer.partial.usage.cost.cacheRead, 0.000_02, accuracy: 1e-12)
        XCTAssertEqual(reducer.partial.usage.cost.total, 0.000_34, accuracy: 1e-12)
    }

    func testOpenAIAndAnthropicUsageApplyCacheAwareCosts() throws {
        var openAI = ProviderEventReducer(model: pricedModel(api: "openai-responses"))
        _ = try openAI.consume([
            "response": [
                "usage": [
                    "input_tokens": 100,
                    "output_tokens": 30,
                    "total_tokens": 130,
                    "input_tokens_details": [
                        "cached_tokens": 20,
                        "cache_write_tokens": 10,
                    ],
                    "output_tokens_details": ["reasoning_tokens": 5],
                ]
            ]
        ])
        XCTAssertEqual(openAI.partial.usage.input, 70)
        XCTAssertEqual(openAI.partial.usage.output, 30)
        XCTAssertEqual(openAI.partial.usage.cacheRead, 20)
        XCTAssertEqual(openAI.partial.usage.cacheWrite, 10)
        XCTAssertEqual(openAI.partial.usage.reasoning, 5)
        XCTAssertEqual(openAI.partial.usage.cost.input, 0.000_14, accuracy: 1e-12)
        XCTAssertEqual(openAI.partial.usage.cost.output, 0.000_12, accuracy: 1e-12)
        XCTAssertEqual(openAI.partial.usage.cost.cacheRead, 0.000_02, accuracy: 1e-12)
        XCTAssertEqual(openAI.partial.usage.cost.cacheWrite, 0.000_03, accuracy: 1e-12)

        var anthropic = ProviderEventReducer(model: pricedModel(api: "anthropic-messages"))
        _ = try anthropic.consume([
            "message": [
                "usage": [
                    "input_tokens": 70,
                    "cache_read_input_tokens": 20,
                    "cache_creation_input_tokens": 10,
                    "cache_creation": ["ephemeral_1h_input_tokens": 4],
                ]
            ]
        ])
        _ = try anthropic.consume(["usage": ["output_tokens": 30]])
        XCTAssertEqual(anthropic.partial.usage.input, 70)
        XCTAssertEqual(anthropic.partial.usage.totalTokens, 130)
        XCTAssertEqual(anthropic.partial.usage.cost.cacheWrite, 0.000_034, accuracy: 1e-12)
    }

    func testInvalidModelRatesCannotProduceInvalidUsageCosts() throws {
        var model = pricedModel(api: "openai-completions")
        model.cost = ModelCost(
            input: -.infinity,
            output: .nan,
            cacheRead: -1,
            cacheWrite: .infinity
        )
        var reducer = ProviderEventReducer(model: model)
        _ = try reducer.consume([
            "usage": [
                "prompt_tokens": 4,
                "completion_tokens": 3,
                "prompt_tokens_details": ["cached_tokens": 1],
            ]
        ])

        XCTAssertEqual(reducer.partial.usage.cost, Cost())
        XCTAssertTrue(reducer.partial.usage.cost.total.isFinite)
    }

    func testOpenAIChatFinishBalancesTextAndThinkingOnce() throws {
        var reducer = ProviderEventReducer(model: pricedModel(api: "openai-completions"))
        let updates = try reducer.consume([
            "choices": .array([
                [
                    "delta": [
                        "content": "answer",
                        "reasoning_content": "thought",
                    ]
                ]
            ])
        ])
        XCTAssertEqual(updates.filter(isTextStart).count, 1)
        XCTAssertEqual(updates.filter(isThinkingStart).count, 1)

        let finish = try reducer.consume([
            "choices": .array([["delta": [:], "finish_reason": "stop"]])
        ])
        XCTAssertEqual(finish.filter(isTextEnd).count, 1)
        XCTAssertEqual(finish.filter(isThinkingEnd).count, 1)

        let duplicateFinish = try reducer.consume([
            "choices": .array([["delta": [:], "finish_reason": "stop"]])
        ])
        XCTAssertEqual(duplicateFinish.filter(isTextEnd).count, 0)
        XCTAssertEqual(duplicateFinish.filter(isThinkingEnd).count, 0)
    }

    func testOpenAIResponsesCompletedClosesOnlyStillOpenBlocks() throws {
        var reducer = ProviderEventReducer(model: pricedModel(api: "openai-responses"))
        _ = try reducer.consume([
            "type": "response.reasoning_summary_text.delta",
            "output_index": 0,
            "delta": "thought",
        ])
        _ = try reducer.consume([
            "type": "response.output_text.delta",
            "output_index": 1,
            "delta": "answer",
        ])

        let itemDone = try reducer.consume([
            "type": "response.output_item.done",
            "output_index": 0,
            "item": ["type": "reasoning"],
        ])
        XCTAssertEqual(itemDone.filter(isThinkingEnd).count, 1)

        let completed = try reducer.consume([
            "type": "response.completed",
            "response": ["id": "response-1"],
        ])
        XCTAssertEqual(completed.filter(isTextEnd).count, 1)
        XCTAssertEqual(completed.filter(isThinkingEnd).count, 0)

        let duplicateCompleted = try reducer.consume([
            "type": "response.completed",
            "response": ["id": "response-1"],
        ])
        XCTAssertEqual(duplicateCompleted.filter(isTextEnd).count, 0)
        XCTAssertEqual(duplicateCompleted.filter(isThinkingEnd).count, 0)
    }

    func testOpenAIResponsesOutputItemsSeedAndBalanceParallelFunctionCalls() throws {
        var reducer = ProviderEventReducer(model: pricedModel(api: "openai-responses"))
        _ = try reducer.consume([
            "type": "response.reasoning_summary_text.delta",
            "output_index": 0,
            "delta": "thought",
        ])

        let firstStart = try reducer.consume([
            "type": "response.output_item.added",
            "output_index": 1,
            "item": [
                "type": "function_call",
                "id": "fc-a",
                "call_id": "call-a",
                "name": "read",
                "arguments": "",
            ],
        ])
        let secondStart = try reducer.consume([
            "type": "response.output_item.added",
            "output_index": 2,
            "item": [
                "type": "function_call",
                "id": "fc-b",
                "call_id": "call-b",
                "name": "write",
                "arguments": "",
            ],
        ])
        XCTAssertEqual(firstStart.compactMap(toolCallStartIndex), [1])
        XCTAssertEqual(secondStart.compactMap(toolCallStartIndex), [2])
        let firstStartedCall = firstStart.first.flatMap { toolCall(in: $0) }
        let secondStartedCall = secondStart.first.flatMap { toolCall(in: $0) }
        XCTAssertEqual(firstStartedCall?.id, "call-a|fc-a")
        XCTAssertEqual(firstStartedCall?.name, "read")
        XCTAssertEqual(secondStartedCall?.id, "call-b|fc-b")
        XCTAssertEqual(secondStartedCall?.name, "write")

        let secondDelta = try reducer.consume([
            "type": "response.function_call_arguments.delta",
            "output_index": 2,
            "delta": "{\"path\":\"B\"}",
        ])
        let firstDelta = try reducer.consume([
            "type": "response.function_call_arguments.delta",
            "output_index": 1,
            "delta": "{\"path\":\"A\"}",
        ])
        XCTAssertEqual(secondDelta.compactMap(toolCallDeltaIndex), [2])
        XCTAssertEqual(firstDelta.compactMap(toolCallDeltaIndex), [1])

        let firstArgumentsDone = try reducer.consume([
            "type": "response.function_call_arguments.done",
            "output_index": 1,
            "arguments": "{\"path\":\"A\"}",
        ])
        let secondArgumentsDone = try reducer.consume([
            "type": "response.function_call_arguments.done",
            "output_index": 2,
            "arguments": "{\"path\":\"B\"}",
        ])
        XCTAssertTrue(firstArgumentsDone.compactMap(toolCallEndIndex).isEmpty)
        XCTAssertTrue(secondArgumentsDone.compactMap(toolCallEndIndex).isEmpty)

        let firstEnd = try reducer.consume([
            "type": "response.output_item.done",
            "output_index": 1,
            "item": [
                "type": "function_call",
                "id": "fc-a",
                "call_id": "call-a",
                "name": "read",
                "arguments": "{\"path\":\"A\"}",
            ],
        ])
        let secondEnd = try reducer.consume([
            "type": "response.output_item.done",
            "output_index": 2,
            "item": [
                "type": "function_call",
                "id": "fc-b",
                "call_id": "call-b",
                "name": "write",
                "arguments": "{\"path\":\"B\"}",
            ],
        ])
        XCTAssertEqual(firstEnd.compactMap(toolCallEndIndex), [1])
        XCTAssertEqual(secondEnd.compactMap(toolCallEndIndex), [2])

        let completed = try reducer.consume([
            "type": "response.completed",
            "response": ["id": "response-1"],
        ])
        XCTAssertTrue(completed.compactMap(toolCallEndIndex).isEmpty)
        guard case .toolCall(let first) = reducer.partial.content[1],
            case .toolCall(let second) = reducer.partial.content[2]
        else {
            return XCTFail("Expected parallel Responses tool calls")
        }
        XCTAssertEqual(first, ToolCall(id: "call-a|fc-a", name: "read", arguments: ["path": "A"]))
        XCTAssertEqual(second, ToolCall(id: "call-b|fc-b", name: "write", arguments: ["path": "B"]))
    }

    func testProviderContentIndexesRejectUnsafeValuesBeforeMutation() throws {
        let invalidIndexes = [
            -1,
            ProviderEventReducer.maximumProviderContentIndex + 1,
        ]
        for index in invalidIndexes {
            var anthropic = ProviderEventReducer(
                model: pricedModel(api: "anthropic-messages")
            )
            XCTAssertThrowsError(
                try anthropic.consume([
                    "type": "content_block_start",
                    "index": .number(JSONNumber(index)),
                    "content_block": ["type": "text"],
                ])
            ) { error in
                guard let providerError = error as? ProviderError,
                    case .invalidResponse = providerError
                else {
                    return XCTFail("Expected an invalid provider response")
                }
            }
            XCTAssertTrue(anthropic.partial.content.isEmpty)

            var responses = ProviderEventReducer(
                model: pricedModel(api: "openai-responses")
            )
            XCTAssertThrowsError(
                try responses.consume([
                    "type": "response.output_text.delta",
                    "output_index": .number(JSONNumber(index)),
                    "delta": "must-not-append",
                ])
            )
            XCTAssertTrue(responses.partial.content.isEmpty)

            var chat = ProviderEventReducer(
                model: pricedModel(api: "openai-completions")
            )
            XCTAssertThrowsError(
                try chat.consume([
                    "choices": .array([
                        [
                            "delta": [
                                "tool_calls": .array([
                                    [
                                        "index": .number(JSONNumber(index)),
                                        "id": "call",
                                        "function": ["name": "read"],
                                    ]
                                ])
                            ]
                        ]
                    ])
                ])
            )
            XCTAssertTrue(chat.partial.content.isEmpty)
        }
    }

    func testNormalizedToolCallIDsStayUniqueAndPairWithResults() throws {
        let model = pricedModel(api: "openai-responses")
        let messages: [Message] = [
            .assistant(
                AssistantMessage(
                    content: [
                        .toolCall(ToolCall(id: "call.a", name: "first")),
                        .toolCall(ToolCall(id: "calla", name: "second")),
                    ],
                    api: "source-api",
                    provider: "source-provider",
                    model: "source-model",
                    stopReason: .toolUse
                )
            ),
            .toolResult(
                ToolResultMessage(
                    toolCallId: "calla",
                    toolName: "second",
                    content: [.text(text: "second-result")],
                    isError: false
                )
            ),
            .toolResult(
                ToolResultMessage(
                    toolCallId: "call.a",
                    toolName: "first",
                    content: [.text(text: "first-result")],
                    isError: false
                )
            ),
        ]

        let transformed = MessageTransforms.forModel(messages, target: model)
        guard case .assistant(let assistant) = transformed[0] else {
            return XCTFail("Expected transformed assistant message")
        }
        let calls = assistant.content.compactMap { block -> ToolCall? in
            if case .toolCall(let call) = block { call } else { nil }
        }
        let results = transformed.compactMap { message -> ToolResultMessage? in
            if case .toolResult(let result) = message { result } else { nil }
        }

        XCTAssertEqual(
            calls.map(\.id),
            ["calla-c65a0dc80edb1b80", "calla"]
        )
        XCTAssertEqual(Set(calls.map(\.id)).count, 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(
            results.first(where: { $0.toolName == "first" })?.toolCallId,
            calls.first(where: { $0.name == "first" })?.id
        )
        XCTAssertEqual(
            results.first(where: { $0.toolName == "second" })?.toolCallId,
            calls.first(where: { $0.name == "second" })?.id
        )
    }

    func testDynamicRefreshFailureLeavesPublishedAndStoredModelsUnchanged() async {
        let previous = pricedModel(api: "openai-completions", id: "previous")
        let fetched = pricedModel(api: "openai-completions", id: "fetched")
        let store = RejectingModelCatalogStore(
            entry: StoredModelCatalog(models: [previous])
        )
        let provider = DynamicModelProvider(
            id: previous.provider,
            initialModels: [previous],
            store: store,
            fetch: { _ in StoredModelCatalog(models: [fetched]) },
            stream: { _, _, _ in AssistantEventStream() }
        )

        do {
            try await provider.refresh()
            XCTFail("Expected model catalog persistence to fail")
        } catch {}

        let published = await provider.models
        let stored = try? await store.read(provider: previous.provider)
        XCTAssertEqual(published, [previous])
        XCTAssertEqual(stored?.models, [previous])
    }

    func testHTTPFailureAfterStartPreservesReducerPartialInError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingStreamingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = pricedModel(api: "openai-completions")
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
            return XCTFail("Expected terminal streaming error")
        }
        XCTAssertEqual(message.stopReason, .error)
        XCTAssertEqual(message.responseId, "response-1")
        XCTAssertEqual(message.content, [.text(text: "kept")])
        XCTAssertEqual(message.usage.input, 10)
        XCTAssertEqual(message.usage.output, 2)
        XCTAssertEqual(message.usage.cost.input, 0.000_02, accuracy: 1e-12)
        XCTAssertNotNil(message.errorMessage)
    }

    func testCancellationAfterDeltaPreservesLatestPartialAndSingleTerminal() async throws {
        let stream = AssistantEventStream()
        let producer = Task {
            var partial = AssistantMessage(
                api: "test-api",
                provider: "test-provider",
                model: "test-model"
            )
            await stream.emit(.start(partial))
            partial.content.append(.text(text: ""))
            await stream.emit(.textStart(index: 0, partial: partial))
            partial.content[0] = .text(text: "kept")
            await stream.emit(.textDelta(index: 0, delta: "kept", partial: partial))
            do {
                try await Task.sleep(for: .seconds(300))
            } catch {
                await stream.failBeforeStart(
                    api: "test-api",
                    provider: "test-provider",
                    model: "test-model",
                    error: error,
                    aborted: true
                )
            }
        }
        stream.attachProducer(producer)

        var iterator = stream.makeAsyncIterator()
        var events: [AssistantEvent] = []
        for _ in 0..<3 {
            if let event = try await iterator.next() { events.append(event) }
        }
        await stream.cancel(
            api: "test-api",
            provider: "test-provider",
            model: "test-model"
        )
        while let event = try await iterator.next() { events.append(event) }
        await producer.value

        let result = await stream.result()
        XCTAssertEqual(result.content, [.text(text: "kept")])
        XCTAssertEqual(result.stopReason, .aborted)
        XCTAssertEqual(
            events.filter {
                if case .done = $0 { return true }
                if case .error = $0 { return true }
                return false
            }.count,
            1
        )
        guard case .error(.aborted, let terminal) = events.last else {
            return XCTFail("Expected one aborted terminal event")
        }
        XCTAssertEqual(terminal, result)
    }

    func testDefaultAssistantEventBufferIsBoundedAndRetainsTerminalState() async throws {
        let stream = AssistantEventStream()
        var partial = AssistantMessage(
            api: "test-api",
            provider: "test-provider",
            model: "test-model"
        )
        await stream.emit(.start(partial))
        partial.content = [.text(text: "")]
        await stream.emit(.textStart(index: 0, partial: partial))
        for index in 0..<200 {
            let text = String(repeating: "x", count: index + 1)
            partial.content[0] = .text(text: text)
            await stream.emit(.textDelta(index: 0, delta: "x", partial: partial))
        }
        partial.stopReason = .stop
        await stream.emit(.done(reason: .stop, message: partial))

        var events: [AssistantEvent] = []
        for try await event in stream { events.append(event) }

        XCTAssertLessThanOrEqual(events.count, 64)
        guard case .done(.stop, let terminal) = events.last else {
            return XCTFail("Expected buffered terminal event")
        }
        XCTAssertEqual(terminal, partial)
        let result = await stream.result()
        XCTAssertEqual(result, partial)
    }

    func testCodexPoolPartitionsByCredentialAndEndpoint() async throws {
        let factory = CompletingCodexFactory()
        let pool = CodexWebSocketPool { url, headers in
            await factory.make(url: url, headers: headers)
        }
        let firstModel = pricedModel(
            api: "openai-codex-responses",
            baseURL: URL(string: "https://first.example/v1")!
        )
        let secondModel = pricedModel(
            api: "openai-codex-responses",
            baseURL: URL(string: "https://second.example/v1")!
        )
        let provider = CodexWebSocketProvider(
            id: firstModel.provider,
            models: [firstModel, secondModel],
            pool: pool
        )

        for (model, credential) in [
            (firstModel, "credential-a"),
            (firstModel, "credential-a"),
            (firstModel, "credential-b"),
            (secondModel, "credential-b"),
        ] {
            let stream = await provider.stream(
                model: model,
                context: Context(),
                options: StreamOptions(
                    apiKey: credential,
                    sessionID: "shared-session"
                )
            )
            for try await _ in stream {}
            let result = await stream.result()
            XCTAssertEqual(result.stopReason, .stop)
        }

        let created = await factory.count()
        let endpoints = await factory.endpoints()
        XCTAssertEqual(created, 3)
        XCTAssertEqual(Set(endpoints).count, 2)
    }

    func testCodexFailureAfterStartPreservesReducerPartial() async throws {
        let connection = FailingCodexConnection(frames: [
            Data(
                #"{"type":"response.output_text.delta","output_index":0,"delta":"kept"}"#
                    .utf8
            ),
            Data("not-json".utf8),
        ])
        let pool = CodexWebSocketPool { _, _ in connection }
        let model = pricedModel(api: "openai-codex-responses")
        let provider = CodexWebSocketProvider(
            id: model.provider,
            models: [model],
            pool: pool
        )

        let stream = await provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage("hello"))]),
            options: StreamOptions(apiKey: "synthetic-key", sessionID: "session")
        )
        var events: [AssistantEvent] = []
        for try await event in stream { events.append(event) }

        guard case .error(.error, let message) = events.last else {
            return XCTFail("Expected terminal Codex streaming error")
        }
        XCTAssertEqual(message.content, [.text(text: "kept")])
        XCTAssertEqual(message.stopReason, .error)
        XCTAssertNotNil(message.errorMessage)
        let result = await stream.result()
        XCTAssertEqual(result, message)
        XCTAssertEqual(events.filter { if case .error = $0 { true } else { false } }.count, 1)
    }

    func testCodexIncompleteTerminatesAtLengthWithoutAnotherReceive() async throws {
        let connection = FailingCodexConnection(frames: [
            Data(
                #"{"type":"response.output_text.delta","output_index":0,"delta":"truncated"}"#
                    .utf8
            ),
            Data(
                #"{"type":"response.incomplete","response":{"id":"response-1","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#
                    .utf8
            ),
        ])
        let pool = CodexWebSocketPool { _, _ in connection }
        let model = pricedModel(api: "openai-codex-responses")
        let provider = CodexWebSocketProvider(
            id: model.provider,
            models: [model],
            pool: pool
        )

        let stream = await provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage("hello"))]),
            options: StreamOptions(apiKey: "synthetic-key", sessionID: "session")
        )
        var events: [AssistantEvent] = []
        for try await event in stream { events.append(event) }

        guard case .done(.length, let message) = events.last else {
            return XCTFail("Expected terminal Codex length result")
        }
        XCTAssertEqual(message.content, [.text(text: "truncated")])
        XCTAssertEqual(message.responseId, "response-1")
        XCTAssertEqual(message.rawStopReason, "incomplete.max_output_tokens")
        let receiveCount = await connection.receiveCount()
        XCTAssertEqual(receiveCount, 2)
    }

    func testCodexFailedTerminatesWithPartialWithoutAnotherReceive() async throws {
        let connection = FailingCodexConnection(frames: [
            Data(
                #"{"type":"response.output_text.delta","output_index":0,"delta":"kept"}"#
                    .utf8
            ),
            Data(
                #"{"type":"response.failed","response":{"status":"failed","error":{"code":"synthetic_failure","message":"failed after partial"}}}"#
                    .utf8
            ),
        ])
        let pool = CodexWebSocketPool { _, _ in connection }
        let model = pricedModel(api: "openai-codex-responses")
        let provider = CodexWebSocketProvider(
            id: model.provider,
            models: [model],
            pool: pool
        )

        let stream = await provider.stream(
            model: model,
            context: Context(messages: [.user(UserMessage("hello"))]),
            options: StreamOptions(apiKey: "synthetic-key", sessionID: "session")
        )
        var events: [AssistantEvent] = []
        for try await event in stream { events.append(event) }

        guard case .error(.error, let message) = events.last else {
            return XCTFail("Expected terminal Codex failed error")
        }
        XCTAssertEqual(message.content, [.text(text: "kept")])
        XCTAssertTrue(message.errorMessage?.contains("failed after partial") == true)
        let receiveCount = await connection.receiveCount()
        XCTAssertEqual(receiveCount, 2)
    }

    func testSSEDecoderRejectsOversizedPendingRecord() throws {
        var decoder = SSEDecoder(maximumRecordBytes: 8)
        for byte in "data: 12".utf8 {
            XCTAssertTrue(try decoder.pushValidated(byte).isEmpty)
        }
        XCTAssertThrowsError(try decoder.pushValidated(UInt8(ascii: "3"))) { error in
            XCTAssertEqual(error as? SSEDecoderError, .recordTooLarge)
        }
    }

    func testImageProviderAppliesStreamTimeoutToRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TimeoutCapturingImageURLProtocol.self]
        let session = URLSession(configuration: configuration)
        TimeoutCapturingImageURLProtocol.reset()
        let model = ImageModel(
            id: "image-model",
            name: "Image",
            api: "openrouter-images",
            provider: "openrouter",
            baseURL: URL(string: "https://example.com/v1")!,
            input: ["text"],
            output: ["image"]
        )
        let provider = OpenRouterImageProvider(models: [model], session: session)

        let result = await provider.generate(
            model: model,
            input: [.text(text: "draw")],
            options: StreamOptions(apiKey: "synthetic-key", timeout: .milliseconds(250))
        )

        XCTAssertEqual(result.stopReason, .stop)
        XCTAssertEqual(
            try XCTUnwrap(TimeoutCapturingImageURLProtocol.capturedTimeout()),
            0.25,
            accuracy: 1e-9
        )
    }

    private func pricedModel(
        api: String,
        id: String = "priced",
        baseURL: URL = URL(string: "https://example.com/v1")!
    ) -> Model {
        Model(
            id: id,
            name: "Priced",
            api: api,
            provider: "provider",
            baseURL: baseURL,
            cost: ModelCost(input: 2, output: 4, cacheRead: 1, cacheWrite: 3),
            contextWindow: 1_000,
            maximumTokens: 100
        )
    }
}

private func toolCallStartIndex(_ event: AssistantEvent) -> Int? {
    if case .toolCallStart(let index, _) = event { index } else { nil }
}

private func toolCallDeltaIndex(_ event: AssistantEvent) -> Int? {
    if case .toolCallDelta(let index, _, _) = event { index } else { nil }
}

private func toolCallEndIndex(_ event: AssistantEvent) -> Int? {
    if case .toolCallEnd(let index, _, _) = event { index } else { nil }
}

private func toolCall(in event: AssistantEvent) -> ToolCall? {
    guard case .toolCallStart(let index, let partial) = event,
        partial.content.indices.contains(index),
        case .toolCall(let call) = partial.content[index]
    else {
        return nil
    }
    return call
}

private func isTextStart(_ event: AssistantEvent) -> Bool {
    if case .textStart = event { true } else { false }
}

private func isThinkingStart(_ event: AssistantEvent) -> Bool {
    if case .thinkingStart = event { true } else { false }
}

private func isTextEnd(_ event: AssistantEvent) -> Bool {
    if case .textEnd = event { true } else { false }
}

private func isThinkingEnd(_ event: AssistantEvent) -> Bool {
    if case .thinkingEnd = event { true } else { false }
}

private actor RejectingModelCatalogStore: ModelCatalogStore {
    private enum Failure: Error { case writeRejected }
    private var entry: StoredModelCatalog?

    init(entry: StoredModelCatalog?) {
        self.entry = entry
    }

    func read(provider: String) throws -> StoredModelCatalog? { entry }

    func write(provider: String, entry: StoredModelCatalog) throws {
        throw Failure.writeRejected
    }

    func delete(provider: String) {
        entry = nil
    }
}

private actor CompletingCodexFactory {
    private var createdEndpoints: [URL] = []

    func make(
        url: URL,
        headers: [String: String]
    ) -> any WebSocketConnection {
        createdEndpoints.append(url)
        return CompletingCodexConnection(completionCount: 2)
    }

    func count() -> Int { createdEndpoints.count }
    func endpoints() -> [URL] { createdEndpoints }
}

private actor CompletingCodexConnection: WebSocketConnection {
    nonisolated let identifier = UUID()
    private var frames: [Data]

    init(completionCount: Int) {
        frames = (0..<completionCount).map { _ in
            Data(#"{"type":"response.completed","response":{"id":"done"}}"#.utf8)
        }
    }

    func send(_ data: Data) {}

    func receive() throws -> Data {
        guard !frames.isEmpty else {
            throw ProviderError.invalidResponse("No completion frame")
        }
        return frames.removeFirst()
    }

    func close() {}
}

private actor FailingCodexConnection: WebSocketConnection {
    nonisolated let identifier = UUID()
    private var frames: [Data]
    private var received = 0

    init(frames: [Data]) { self.frames = frames }

    func send(_ data: Data) {}

    func receive() throws -> Data {
        received += 1
        guard !frames.isEmpty else {
            throw ProviderError.invalidResponse("No scripted WebSocket frame")
        }
        return frames.removeFirst()
    }

    func close() {}
    func receiveCount() -> Int { received }
}

private final class TimeoutCapturingImageURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var timeout: TimeInterval?

    static func reset() {
        lock.withLock { timeout = nil }
    }

    static func capturedTimeout() -> TimeInterval? {
        lock.withLock { timeout }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.timeout = request.timeoutInterval }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"choices":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class FailingStreamingURLProtocol: URLProtocol, @unchecked Sendable {
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
                "data: {\"id\":\"response-1\",\"choices\":[{\"delta\":{\"content\":\"kept\"}}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":2,\"total_tokens\":12}}\n\n"
                    .utf8
            )
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(
                self,
                didFailWithError: URLError(.networkConnectionLost)
            )
        }
    }

    override func stopLoading() {}
}
