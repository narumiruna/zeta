import XCTest
import ZetaAI
import ZetaCore

@testable import ZetaAgent

final class ZetaAgentTests: XCTestCase {
    func testPromptToolLoopAndSubscriberBarrier() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [.toolCall(ToolCall(id: "1", name: "echo", arguments: ["text": "ok"]))], api: model.api,
                provider: model.provider, model: model.id, stopReason: .toolUse, timestamp: 1))
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "done")], api: model.api, provider: model.provider, model: model.id,
                stopReason: .stop, timestamp: 2))
        let tool = AgentTool(
            definition: ToolDefinition(name: "echo", description: "echo", parameters: [:]), label: "echo"
        ) { _, arguments, _ in AgentToolResult(content: [.text(text: "ok")], details: arguments) }
        let agent = Agent(state: AgentState(systemPrompt: "system", model: model, tools: [tool])) {
            model, context, options in await provider.stream(model: model, context: context, options: options)
        }
        let recorder = EventRecorder()
        await agent.subscribe { event in await recorder.append(event) }
        try await agent.prompt(UserMessage("go", timestamp: 0))
        let state = await agent.state()
        XCTAssertFalse(state.isStreaming)
        XCTAssertEqual(state.messages.count, 4)
        let events = await recorder.events
        XCTAssertEqual(events.first, .agentStart)
        guard case .agentEnd = events.last else { return XCTFail("Expected agent end") }
    }

    func testTransformsPreparationAndToolValidation() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [
                    .toolCall(
                        ToolCall(
                            id: "1",
                            name: "number",
                            arguments: ["value": "42"]
                        )
                    )
                ],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .toolUse
            )
        )
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "done")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let observed = ValueRecorder()
        let schema = JSONSchema.object(
            properties: [JSONSchemaProperty("value", .integer())]
        )
        let tool = AgentTool(
            definition: ToolDefinition(name: "number", description: "Number", parameters: [:]),
            label: "number",
            parameterSchema: schema
        ) { _, arguments, _ in
            await observed.set(arguments)
            return AgentToolResult(content: [.text(text: "ok")])
        }
        let agent = Agent(
            state: AgentState(systemPrompt: "system", model: model, tools: [tool])
        ) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        await agent.setTransformContext { messages in
            messages.filter { message in
                if case .user = message { true } else { false }
            }
        }
        await agent.setPrepareNextTurn { state in
            var state = state
            state.thinkingLevel = .high
            return state
        }
        try await agent.prompt(UserMessage("go"))
        let observedValue = await observed.value()
        let finalState = await agent.state()
        XCTAssertEqual(observedValue, ["value": 42])
        XCTAssertEqual(finalState.thinkingLevel, .high)
    }

    func testParallelPreflightCompletionOrderingAndLateUpdates() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [
                    .toolCall(ToolCall(id: "slow", name: "slow")),
                    .toolCall(ToolCall(id: "fast", name: "fast")),
                ],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .toolUse
            )
        )
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "done")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let execution = SequenceRecorder()
        let slow = AgentTool(
            definition: ToolDefinition(name: "slow", description: "slow", parameters: [:]),
            label: "slow"
        ) { _, _, update in
            try await Task.sleep(for: .milliseconds(20))
            Task {
                try? await Task.sleep(for: .milliseconds(30))
                await update(AgentToolResult(content: [.text(text: "late")]))
            }
            await execution.append("effect-slow")
            return AgentToolResult(content: [.text(text: "slow")])
        }
        let fast = AgentTool(
            definition: ToolDefinition(name: "fast", description: "fast", parameters: [:]),
            label: "fast"
        ) { _, _, _ in
            try await Task.sleep(for: .milliseconds(1))
            await execution.append("effect-fast")
            return AgentToolResult(content: [.text(text: "fast")])
        }
        let agent = Agent(
            state: AgentState(systemPrompt: "", model: model, tools: [slow, fast])
        ) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let events = EventRecorder()
        await agent.subscribe { await events.append($0) }
        await agent.setBeforeToolCall { call, _ in
            await execution.append("preflight-\(call.id)")
            return nil
        }
        try await agent.prompt(UserMessage("go"))
        try await Task.sleep(for: .milliseconds(60))
        let sequence = await execution.values()
        XCTAssertEqual(Array(sequence.prefix(2)), ["preflight-slow", "preflight-fast"])
        XCTAssertEqual(
            Array(sequence.suffix(2)),
            ["effect-fast", "effect-slow"]
        )
        let allEvents = await events.events
        let endIDs = allEvents.compactMap { event -> String? in
            if case .toolExecutionEnd(let id, _, _, _) = event { id } else { nil }
        }
        XCTAssertEqual(endIDs, ["fast", "slow"])
        XCTAssertFalse(
            allEvents.contains {
                if case .toolExecutionUpdate(_, _, let result) = $0 {
                    return result.content.contains {
                        if case .text(let text, _) = $0 { text == "late" } else { false }
                    }
                }
                return false
            }
        )
        let state = await agent.state()
        let resultNames = state.messages.compactMap { message -> String? in
            if case .toolResult(let result) = message { result.toolName } else { nil }
        }
        XCTAssertEqual(resultNames, ["slow", "fast"])
    }

    func testLengthStopProducesErrorsWithoutExecutingTools() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [.toolCall(ToolCall(id: "cut", name: "danger"))],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .length
            )
        )
        let count = IntegerCounter()
        let tool = AgentTool(
            definition: ToolDefinition(name: "danger", description: "danger", parameters: [:]),
            label: "danger"
        ) { _, _, _ in
            await count.increment()
            return AgentToolResult(content: [.text(text: "executed")])
        }
        let agent = Agent(
            state: AgentState(systemPrompt: "", model: model, tools: [tool])
        ) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        try await agent.prompt(UserMessage("go"))
        let executionCount = await count.value()
        XCTAssertEqual(executionCount, 0)
        let state = await agent.state()
        guard case .toolResult(let result)? = state.messages.last else {
            return XCTFail("Expected explanatory tool result")
        }
        XCTAssertTrue(result.isError)
        XCTAssertTrue(
            result.content.contains {
                if case .text(let text, _) = $0 { text.contains("length limit") } else { false }
            }
        )
    }

    func testCompactionSummaryReplacesHistoryAndRetainsTail() async throws {
        let provider = FauxProvider(tokensPerSecond: 10_000)
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "summary")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let tail: [Message] = [.user(UserMessage("recent"))]
        let agent = Agent(
            state: AgentState(
                systemPrompt: "",
                model: model,
                messages: [.user(UserMessage("old"))] + tail
            )
        ) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let summary = try await agent.compact(
            summaryPrompt: "summarize",
            retainedTail: tail
        )
        XCTAssertEqual(summary, "summary")
        let messages = await agent.state().messages
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last, tail.last)
    }

    func testTransientErrorRetriesWithoutReplayingFailedAssistant() async throws {
        let provider = FauxProvider(tokensPerSecond: 10_000)
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .error,
                errorMessage: "temporary"
            )
        )
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "recovered")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        await agent.configureRetry(maximumRetries: 1, baseDelayMilliseconds: 0)
        try await agent.prompt(UserMessage("go"))
        let callCount = await provider.callCount()
        let calls = await provider.calls()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(calls.map(\.messageCount), [1, 1])
        let state = await agent.state()
        XCTAssertEqual(state.messages.count, 3)
    }

    func testConcurrentPromptRejected() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "ok")], api: model.api, provider: model.provider, model: model.id,
                stopReason: .stop))
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let first = Task { try await agent.prompt(UserMessage("one")) }
        while !(await agent.state().isStreaming) { await Task.yield() }
        do {
            try await agent.prompt(UserMessage("two"))
            XCTFail("Expected already running")
        } catch {}
        try await first.value
    }
}

private actor EventRecorder {
    var events: [AgentEvent] = []
    func append(_ event: AgentEvent) { events.append(event) }
}

private actor ValueRecorder {
    private var stored: JSONValue?
    func set(_ value: JSONValue) { stored = value }
    func value() -> JSONValue? { stored }
}

private actor SequenceRecorder {
    private var stored: [String] = []
    func append(_ value: String) { stored.append(value) }
    func values() -> [String] { stored }
}

private actor IntegerCounter {
    private var stored = 0
    func increment() { stored += 1 }
    func value() -> Int { stored }
}
