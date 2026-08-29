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

    private func pricedModel(api: String) -> Model {
        Model(
            id: "priced",
            name: "Priced",
            api: api,
            provider: "provider",
            baseURL: URL(string: "https://example.com/v1")!,
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
