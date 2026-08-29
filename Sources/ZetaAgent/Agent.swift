import Foundation
import ZetaAI
import ZetaCore

public enum AgentEvent: Sendable, Equatable {
    case agentStart
    case agentEnd([Message])
    case turnStart
    case turnEnd(AssistantMessage, [ToolResultMessage])
    case messageStart(Message)
    case messageUpdate(AssistantMessage, AssistantEvent)
    case messageEnd(Message)
    case toolExecutionStart(id: String, name: String, arguments: JSONValue)
    case toolExecutionUpdate(id: String, name: String, result: AgentToolResult)
    case toolExecutionEnd(id: String, name: String, result: AgentToolResult, isError: Bool)
}

public enum ToolExecutionMode: String, Codable, Sendable { case sequential, parallel }
public enum QueueDeliveryMode: String, Codable, Sendable {
    case all
    case oneAtATime = "one-at-a-time"
}

public struct AgentToolResult: Sendable, Equatable {
    public var content: [ContentBlock]
    public var details: JSONValue?
    public var usage: Usage?
    public var addedToolNames: [String]?
    public var terminate: Bool

    public init(
        content: [ContentBlock], details: JSONValue? = nil, usage: Usage? = nil, addedToolNames: [String]? = nil,
        terminate: Bool = false
    ) {
        self.content = content
        self.details = details
        self.usage = usage
        self.addedToolNames = addedToolNames
        self.terminate = terminate
    }
}

public struct AgentTool: Sendable {
    public var definition: ToolDefinition
    public var label: String
    public var executionMode: ToolExecutionMode?
    public var parameterSchema: JSONSchema?
    public var prepareArguments: @Sendable (JSONValue) throws -> JSONValue
    public var execute:
        @Sendable (_ id: String, _ arguments: JSONValue, _ update: @escaping @Sendable (AgentToolResult) async -> Void)
            async throws -> AgentToolResult

    public init(
        definition: ToolDefinition,
        label: String,
        executionMode: ToolExecutionMode? = nil,
        parameterSchema: JSONSchema? = nil,
        prepareArguments: @escaping @Sendable (JSONValue) throws -> JSONValue = { $0 },
        execute:
            @escaping @Sendable (String, JSONValue, @escaping @Sendable (AgentToolResult) async -> Void) async throws ->
            AgentToolResult
    ) {
        self.definition = definition
        self.label = label
        self.executionMode = executionMode
        self.parameterSchema = parameterSchema
        self.prepareArguments = prepareArguments
        self.execute = execute
    }
}

public struct AgentState: Sendable {
    public var systemPrompt: String
    public var model: Model
    public var thinkingLevel: ThinkingLevel
    public var tools: [AgentTool]
    public var messages: [Message]
    public fileprivate(set) var isStreaming = false
    public fileprivate(set) var streamingMessage: AssistantMessage?
    public fileprivate(set) var pendingToolCalls: Set<String> = []
    public fileprivate(set) var errorMessage: String?

    public init(
        systemPrompt: String, model: Model, thinkingLevel: ThinkingLevel = .off, tools: [AgentTool] = [],
        messages: [Message] = []
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.tools = tools
        self.messages = messages
    }
}

private struct PreparedToolCall: Sendable {
    var index: Int
    var call: ToolCall
    var tool: AgentTool
    var arguments: JSONValue
}

private actor ToolUpdateGate {
    private var open = true
    func accept() -> Bool { open }
    func close() { open = false }
}

public enum AgentError: Error, LocalizedError, Sendable {
    case alreadyRunning
    case invalidContinuation
    case unknownTool(String)
    case blocked(String)
    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "Agent is already running"
        case .invalidContinuation: "Cannot continue unless the last message is user or toolResult"
        case .unknownTool(let name): "Unknown tool: \(name)"
        case .blocked(let reason): reason
        }
    }
}

public actor Agent {
    public typealias StreamFunction = @Sendable (Model, Context, StreamOptions) async -> AssistantEventStream
    public typealias Subscriber = @Sendable (AgentEvent) async -> Void

    private var internalState: AgentState
    private let stream: StreamFunction
    private var subscribers: [(UUID, Subscriber)] = []
    private var steering: [UserMessage] = []
    private var followUps: [UserMessage] = []
    private var runTask: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    public var toolExecutionMode: ToolExecutionMode
    public var steeringMode: QueueDeliveryMode
    public var followUpMode: QueueDeliveryMode
    public var maximumRetries = 0
    public var retryBaseDelayMilliseconds = 2_000
    private var retryCancelled = false
    public var beforeToolCall:
        (@Sendable (ToolCall, JSONValue) async throws -> (blocked: Bool, reason: String?, terminate: Bool)?)?
    public var afterToolCall: (@Sendable (ToolCall, AgentToolResult, Bool) async throws -> AgentToolResult?)?
    public var shouldStopAfterTurn: (@Sendable (AssistantMessage, [ToolResultMessage]) async -> Bool)?
    public var transformContext: (@Sendable ([Message]) async -> [Message])?
    public var prepareNextTurn: (@Sendable (AgentState) async -> AgentState)?

    public init(state: AgentState, toolExecutionMode: ToolExecutionMode = .parallel, stream: @escaping StreamFunction) {
        internalState = state
        self.toolExecutionMode = toolExecutionMode
        steeringMode = .oneAtATime
        followUpMode = .oneAtATime
        self.stream = stream
    }

    public func state() -> AgentState { internalState }
    public func setModel(_ model: Model) { internalState.model = model }
    public func setThinkingLevel(_ level: ThinkingLevel) { internalState.thinkingLevel = level }
    public func setTools(_ tools: [AgentTool]) { internalState.tools = Array(tools) }
    public func setSteeringMode(_ mode: QueueDeliveryMode) { steeringMode = mode }
    public func setFollowUpMode(_ mode: QueueDeliveryMode) { followUpMode = mode }
    public func setTransformContext(
        _ transform: (@Sendable ([Message]) async -> [Message])?
    ) {
        transformContext = transform
    }
    public func setPrepareNextTurn(
        _ prepare: (@Sendable (AgentState) async -> AgentState)?
    ) {
        prepareNextTurn = prepare
    }
    public func setBeforeToolCall(
        _ hook: (
            @Sendable (ToolCall, JSONValue) async throws -> (
                blocked: Bool,
                reason: String?,
                terminate: Bool
            )?
        )?
    ) {
        beforeToolCall = hook
    }
    public func setAfterToolCall(
        _ hook: (
            @Sendable (
                ToolCall,
                AgentToolResult,
                Bool
            ) async throws -> AgentToolResult?
        )?
    ) {
        afterToolCall = hook
    }
    public func setShouldStopAfterTurn(
        _ hook: (@Sendable (AssistantMessage, [ToolResultMessage]) async -> Bool)?
    ) {
        shouldStopAfterTurn = hook
    }
    public func setMessages(_ messages: [Message]) throws {
        guard runTask == nil else { throw AgentError.alreadyRunning }
        internalState.messages = Array(messages)
    }

    @discardableResult
    public func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
        let id = UUID()
        subscribers.append((id, subscriber))
        return id
    }
    public func unsubscribe(_ id: UUID) { subscribers.removeAll { $0.0 == id } }

    public func prompt(_ message: UserMessage) async throws {
        guard runTask == nil else { throw AgentError.alreadyRunning }
        let task = Task { await self.run(initial: [.user(message)]) }
        runTask = task
        await task.value
    }

    public func `continue`() async throws {
        guard runTask == nil else { throw AgentError.alreadyRunning }
        guard let last = internalState.messages.last, { if case .assistant = last { false } else { true } }() else {
            throw AgentError.invalidContinuation
        }
        let task = Task { await self.run(initial: []) }
        runTask = task
        await task.value
    }

    public func steer(_ message: UserMessage) { steering.append(message) }
    public func followUp(_ message: UserMessage) { followUps.append(message) }
    public func clearQueues() {
        steering.removeAll()
        followUps.removeAll()
    }
    public func configureRetry(maximumRetries: Int, baseDelayMilliseconds: Int) {
        self.maximumRetries = max(0, maximumRetries)
        retryBaseDelayMilliseconds = max(0, baseDelayMilliseconds)
    }
    public func abortRetry() { retryCancelled = true }
    public func abort() { runTask?.cancel() }

    public func waitForIdle() async {
        if runTask == nil { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    public func reset() throws {
        guard runTask == nil else { throw AgentError.alreadyRunning }
        internalState.messages.removeAll()
        steering.removeAll()
        followUps.removeAll()
        internalState.errorMessage = nil
    }

    @discardableResult
    public func compact(
        summaryPrompt: String,
        retainedTail: [Message]
    ) async throws -> String {
        guard runTask == nil else { throw AgentError.alreadyRunning }
        let model = internalState.model
        let context = Context(
            messages: MessageTransforms.forModel(
                [.user(UserMessage(summaryPrompt))],
                target: model,
                knownTools: internalState.tools.map(\.definition)
            )
        )
        let response = await stream(
            model,
            context,
            StreamOptions(
                thinking: internalState.thinkingLevel,
                sessionID: UUID().uuidString,
                cacheRetention: .none
            )
        )
        for try await _ in response {}
        let assistant = await response.result()
        guard assistant.stopReason != .error,
            assistant.stopReason != .aborted
        else {
            throw AgentError.blocked(
                assistant.errorMessage ?? "Compaction summary failed"
            )
        }
        let summary = assistant.content.compactMap { block in
            if case .text(let text, _) = block { text } else { nil }
        }.joined()
        guard !summary.isEmpty else {
            throw AgentError.blocked("Compaction summary was empty")
        }
        internalState.messages =
            [
                .user(UserMessage("Summary of previous conversation:\n\(summary)"))
            ] + retainedTail
        return summary
    }

    private func run(initial: [Message]) async {
        internalState.isStreaming = true
        retryCancelled = false
        var retryAttempt = 0
        var retrying = false
        var newMessages: [Message] = []
        await emit(.agentStart)
        for message in initial {
            internalState.messages.append(message)
            newMessages.append(message)
            await emit(.messageStart(message))
            await emit(.messageEnd(message))
        }
        var continueTurns = true
        while continueTurns && !Task.isCancelled {
            await emit(.turnStart)
            let model = internalState.model
            let liveMessages =
                retrying
                ? internalState.messages.filter {
                    if case .assistant(let message) = $0, message.stopReason == .error { return false }
                    return true
                }
                : internalState.messages
            let transformedMessages =
                await transformContext?(liveMessages)
                ?? liveMessages
            let requestMessages = MessageTransforms.forModel(
                transformedMessages,
                target: model,
                knownTools: internalState.tools.map(\.definition)
            )
            let context = Context(
                systemPrompt: internalState.systemPrompt,
                messages: requestMessages,
                tools: internalState.tools.map(\.definition)
            )
            let responseStream = await stream(model, context, StreamOptions(thinking: internalState.thinkingLevel))
            var assistant: AssistantMessage?
            do {
                for try await event in responseStream {
                    switch event {
                    case .start(let partial):
                        internalState.streamingMessage = partial
                        await emit(.messageStart(.assistant(partial)))
                    case .done(_, let message), .error(_, let message): assistant = message
                    default:
                        if let partial = event.partial {
                            internalState.streamingMessage = partial
                            await emit(.messageUpdate(partial, event))
                        }
                    }
                }
                if assistant == nil {
                    assistant = await responseStream.result()
                }
            } catch {
                assistant = AssistantMessage(
                    api: model.api, provider: model.provider, model: model.id, stopReason: .error,
                    errorMessage: String(describing: error))
            }
            guard let assistant else { break }
            internalState.streamingMessage = nil
            internalState.messages.append(.assistant(assistant))
            newMessages.append(.assistant(assistant))
            internalState.errorMessage = assistant.errorMessage
            await emit(.messageEnd(.assistant(assistant)))
            let toolCalls: [ToolCall] = assistant.content.compactMap {
                if case .toolCall(let call) = $0 { call } else { nil }
            }
            let toolResults =
                assistant.stopReason == .length
                ? await truncatedToolResults(toolCalls)
                : await execute(calls: toolCalls, assistant: assistant)
            for result in toolResults {
                internalState.messages.append(.toolResult(result))
                newMessages.append(.toolResult(result))
                await emit(.messageStart(.toolResult(result)))
                await emit(.messageEnd(.toolResult(result)))
            }
            await emit(.turnEnd(assistant, toolResults))
            if assistant.stopReason == .error,
                retryAttempt < maximumRetries,
                !retryCancelled,
                !Task.isCancelled
            {
                retryAttempt += 1
                retrying = true
                let multiplier = 1 << min(retryAttempt - 1, 20)
                let delay = retryBaseDelayMilliseconds * multiplier
                try? await Task.sleep(for: .milliseconds(delay))
                continueTurns = !Task.isCancelled && !retryCancelled
                continue
            }
            retryAttempt = 0
            retrying = false
            if await shouldStopAfterTurn?(assistant, toolResults) == true {
                continueTurns = false
                continue
            }
            let terminating =
                !toolResults.isEmpty && toolResults.allSatisfy { $0.details?.bool(at: "terminate") == true }
            if terminating {
                continueTurns = false
                continue
            }
            let steered = drain(&steering, mode: steeringMode)
            if !steered.isEmpty {
                for message in steered {
                    internalState.messages.append(.user(message))
                    newMessages.append(.user(message))
                    await emit(.messageStart(.user(message)))
                    await emit(.messageEnd(.user(message)))
                }
                continueTurns = true
            } else if !toolCalls.isEmpty && assistant.stopReason != .length {
                continueTurns = true
            } else {
                let next = drain(&followUps, mode: followUpMode)
                for message in next {
                    internalState.messages.append(.user(message))
                    newMessages.append(.user(message))
                    await emit(.messageStart(.user(message)))
                    await emit(.messageEnd(.user(message)))
                }
                continueTurns = !next.isEmpty
            }
            if continueTurns, let prepareNextTurn {
                internalState = await prepareNextTurn(internalState)
                internalState.isStreaming = true
            }
        }
        await emit(.agentEnd(newMessages))
        internalState.isStreaming = false
        internalState.streamingMessage = nil
        runTask = nil
        idleWaiters.forEach { $0.resume() }
        idleWaiters.removeAll()
    }

    private func execute(
        calls: [ToolCall],
        assistant: AssistantMessage
    ) async -> [ToolResultMessage] {
        guard !calls.isEmpty else { return [] }
        var prepared: [PreparedToolCall] = []
        var results: [Int: ToolResultMessage] = [:]
        var forceSequential = toolExecutionMode == .sequential

        // Preflight is intentionally source ordered, even when effects run in parallel.
        for (index, call) in calls.enumerated() {
            internalState.pendingToolCalls.insert(call.id)
            await emit(
                .toolExecutionStart(
                    id: call.id,
                    name: call.name,
                    arguments: call.arguments
                )
            )
            do {
                guard
                    let tool = internalState.tools.first(where: {
                        $0.definition.name == call.name
                    })
                else {
                    throw AgentError.unknownTool(call.name)
                }
                let raw = try tool.prepareArguments(call.arguments)
                let arguments =
                    try tool.parameterSchema?.validate(
                        raw,
                        coerce: true
                    ) ?? raw
                let preflight = try await beforeToolCall?(call, arguments)
                if preflight?.blocked == true {
                    let error = AgentError.blocked(
                        preflight?.reason ?? "Tool call blocked"
                    )
                    results[index] = await finishError(
                        call: call,
                        error: error,
                        terminate: preflight?.terminate ?? false
                    )
                    continue
                }
                if tool.executionMode == .sequential { forceSequential = true }
                prepared.append(
                    PreparedToolCall(
                        index: index,
                        call: call,
                        tool: tool,
                        arguments: arguments
                    )
                )
            } catch {
                results[index] = await finishError(
                    call: call,
                    error: error,
                    terminate: false
                )
            }
        }

        if forceSequential {
            for item in prepared {
                results[item.index] = await perform(item)
            }
        } else {
            await withTaskGroup(of: (Int, ToolResultMessage).self) { group in
                for item in prepared {
                    group.addTask {
                        (item.index, await self.perform(item))
                    }
                }
                // End events are emitted by perform() in effect completion order.
                for await (index, result) in group { results[index] = result }
            }
        }
        return calls.indices.compactMap { results[$0] }
    }

    private func perform(_ item: PreparedToolCall) async -> ToolResultMessage {
        let gate = ToolUpdateGate()
        do {
            var result = try await item.tool.execute(
                item.call.id,
                item.arguments
            ) { update in
                guard await gate.accept() else { return }
                await self.emit(
                    .toolExecutionUpdate(
                        id: item.call.id,
                        name: item.call.name,
                        result: update
                    )
                )
            }
            await gate.close()
            if let replacement = try await afterToolCall?(
                item.call,
                result,
                false
            ) {
                result = replacement
            }
            await emit(
                .toolExecutionEnd(
                    id: item.call.id,
                    name: item.call.name,
                    result: result,
                    isError: false
                )
            )
            internalState.pendingToolCalls.remove(item.call.id)
            return toolResult(call: item.call, result: result, isError: false)
        } catch {
            await gate.close()
            return await finishError(
                call: item.call,
                error: error,
                terminate: false
            )
        }
    }

    private func finishError(
        call: ToolCall,
        error: Error,
        terminate: Bool
    ) async -> ToolResultMessage {
        let result = AgentToolResult(
            content: [.text(text: String(describing: error))],
            details: ["terminate": .bool(terminate)],
            terminate: terminate
        )
        await emit(
            .toolExecutionEnd(
                id: call.id,
                name: call.name,
                result: result,
                isError: true
            )
        )
        internalState.pendingToolCalls.remove(call.id)
        return toolResult(call: call, result: result, isError: true)
    }

    private func toolResult(
        call: ToolCall,
        result: AgentToolResult,
        isError: Bool
    ) -> ToolResultMessage {
        var details = result.details ?? [:]
        if case .object(var object) = details {
            object["terminate"] = .bool(result.terminate)
            details = .object(object)
        }
        return ToolResultMessage(
            toolCallId: call.id,
            toolName: call.name,
            content: result.content,
            details: details,
            usage: result.usage,
            addedToolNames: result.addedToolNames,
            isError: isError
        )
    }

    private func truncatedToolResults(
        _ calls: [ToolCall]
    ) async -> [ToolResultMessage] {
        var results: [ToolResultMessage] = []
        for call in calls {
            internalState.pendingToolCalls.insert(call.id)
            await emit(
                .toolExecutionStart(
                    id: call.id,
                    name: call.name,
                    arguments: call.arguments
                )
            )
            results.append(
                await finishError(
                    call: call,
                    error: AgentError.blocked(
                        "Tool call was not executed because the model response reached its length limit and arguments may be truncated"
                    ),
                    terminate: false
                )
            )
        }
        return results
    }

    private func drain(_ queue: inout [UserMessage], mode: QueueDeliveryMode) -> [UserMessage] {
        guard !queue.isEmpty else { return [] }
        if mode == .all {
            defer { queue.removeAll() }
            return queue
        }
        return [queue.removeFirst()]
    }

    private func emit(_ event: AgentEvent) async { for (_, subscriber) in subscribers { await subscriber(event) } }
}

private extension AssistantEvent {
    var partial: AssistantMessage? {
        switch self {
        case .start(let value), .textStart(_, let value), .textDelta(_, _, let value), .textEnd(_, _, let value),
            .thinkingStart(_, let value), .thinkingDelta(_, _, let value), .thinkingEnd(_, _, let value),
            .toolCallStart(_, let value), .toolCallDelta(_, _, let value), .toolCallEnd(_, _, let value):
            value
        case .done, .error: nil
        }
    }
}

private extension JSONValue {
    func bool(at key: String) -> Bool? {
        if case .object(let object) = self, case .bool(let value)? = object[key] { value } else { nil }
    }
}
