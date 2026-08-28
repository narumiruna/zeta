import Foundation
import ZetaCore

public struct ProviderEventReducer: Sendable {
    public private(set) var partial: AssistantMessage
    private var toolArgumentBuffers: [Int: String] = [:]

    public init(model: Model) {
        partial = AssistantMessage(
            api: model.api,
            provider: model.provider,
            model: model.id
        )
    }

    public mutating func consume(
        _ value: JSONValue,
        eventName: String? = nil
    ) throws -> [AssistantEvent] {
        guard case .object(let object) = value else { return [] }
        if let error = object.string("error")
            ?? object.pathString(["error", "message"])
        {
            throw ProviderError.invalidResponse(error)
        }
        let type = object.string("type") ?? eventName ?? ""
        var events: [AssistantEvent] = []

        if type == "content_block_start",
            case .object(let block)? = object["content_block"]
        {
            let index = object.integer("index") ?? partial.content.count
            switch block.string("type") {
            case "text":
                ensureIndex(index, block: .text(text: ""))
                events.append(.textStart(index: index, partial: partial))
            case "thinking", "redacted_thinking":
                ensureIndex(index, block: .thinking(text: ""))
                events.append(.thinkingStart(index: index, partial: partial))
            case "tool_use":
                let call = ToolCall(
                    id: block.string("id") ?? "call",
                    name: block.string("name") ?? "tool"
                )
                ensureIndex(index, block: .toolCall(call))
                toolArgumentBuffers[index] = ""
                events.append(.toolCallStart(index: index, partial: partial))
            default:
                break
            }
        }

        let textDelta =
            object.string("delta")
            ?? object.pathString(["delta", "text"])
            ?? object.pathString(["choices", "0", "delta", "content"])
            ?? (type.contains("output_text.delta") ? object.string("delta") : nil)
            ?? object.pathString(["candidates", "0", "content", "parts", "0", "text"])
        if let textDelta, !textDelta.isEmpty {
            events += appendText(textDelta)
        }

        let thinkingDelta =
            object.pathString(["delta", "thinking"])
            ?? object.pathString(["choices", "0", "delta", "reasoning_content"])
            ?? (type.contains("reasoning") ? object.string("delta") : nil)
        if let thinkingDelta, !thinkingDelta.isEmpty {
            events += appendThinking(thinkingDelta)
        }

        let toolDelta =
            object.pathString(["delta", "partial_json"])
            ?? (type.contains("function_call_arguments.delta")
                ? object.string("delta") : nil)
            ?? object.pathString(["choices", "0", "delta", "tool_calls", "0", "function", "arguments"])
        if let toolDelta {
            let index =
                object.integer("index")
                ?? object.integer("output_index")
                ?? latestToolIndex()
                ?? partial.content.count
            if index == partial.content.count {
                let call = ToolCall(
                    id: object.string("call_id") ?? "call-\(index)",
                    name: object.string("name") ?? "tool"
                )
                ensureIndex(index, block: .toolCall(call))
                events.append(.toolCallStart(index: index, partial: partial))
            }
            toolArgumentBuffers[index, default: ""] += toolDelta
            updateToolArguments(index)
            events.append(
                .toolCallDelta(index: index, delta: toolDelta, partial: partial)
            )
        }

        if type == "content_block_stop"
            || type.contains("function_call_arguments.done")
        {
            let index =
                object.integer("index")
                ?? object.integer("output_index")
                ?? latestToolIndex()
                ?? 0
            if partial.content.indices.contains(index) {
                switch partial.content[index] {
                case .text(let text, _):
                    events.append(.textEnd(index: index, content: text, partial: partial))
                case .thinking(let text, _, _):
                    events.append(.thinkingEnd(index: index, content: text, partial: partial))
                case .toolCall:
                    updateToolArguments(index)
                    guard case .toolCall(let updated) = partial.content[index] else { break }
                    events.append(.toolCallEnd(index: index, call: updated, partial: partial))
                    toolArgumentBuffers[index] = nil
                case .image:
                    break
                }
            }
        }

        if let stop = object.pathString(["choices", "0", "finish_reason"])
            ?? object.string("stop_reason")
        {
            partial.rawStopReason = stop
            partial.stopReason = mapStopReason(stop)
        }
        if type == "message_stop" || type == "response.completed" {
            if partial.stopReason == .pending { partial.stopReason = .stop }
        }
        if let responseID = object.string("id") ?? object.pathString(["response", "id"]) {
            partial.responseId = responseID
        }
        updateUsage(object)
        return events
    }

    private mutating func appendText(_ delta: String) -> [AssistantEvent] {
        let index: Int
        var events: [AssistantEvent] = []
        if let existing = partial.content.firstIndex(where: {
            if case .text = $0 { true } else { false }
        }) {
            index = existing
        } else {
            index = partial.content.count
            partial.content.append(.text(text: ""))
            events.append(.textStart(index: index, partial: partial))
        }
        if case .text(let current, let signature) = partial.content[index] {
            partial.content[index] = .text(
                text: current + delta,
                signature: signature
            )
        }
        events.append(.textDelta(index: index, delta: delta, partial: partial))
        return events
    }

    private mutating func appendThinking(_ delta: String) -> [AssistantEvent] {
        let index: Int
        var events: [AssistantEvent] = []
        if let existing = partial.content.firstIndex(where: {
            if case .thinking = $0 { true } else { false }
        }) {
            index = existing
        } else {
            index = partial.content.count
            partial.content.append(.thinking(text: ""))
            events.append(.thinkingStart(index: index, partial: partial))
        }
        if case .thinking(let current, let signature, let redacted) = partial.content[index] {
            partial.content[index] = .thinking(
                text: current + delta,
                signature: signature,
                redacted: redacted
            )
        }
        events.append(
            .thinkingDelta(index: index, delta: delta, partial: partial)
        )
        return events
    }

    private mutating func ensureIndex(_ index: Int, block: ContentBlock) {
        while partial.content.count < index { partial.content.append(.text(text: "")) }
        if partial.content.count == index { partial.content.append(block) } else { partial.content[index] = block }
    }

    private mutating func updateToolArguments(_ index: Int) {
        guard partial.content.indices.contains(index),
            case .toolCall(var call) = partial.content[index],
            let raw = toolArgumentBuffers[index]
        else {
            return
        }
        call.arguments = partialJSONObject(raw)
        partial.content[index] = .toolCall(call)
    }

    private func partialJSONObject(_ raw: String) -> JSONValue {
        if let value = try? OrderedJSON.decode(raw), case .object = value {
            return value
        }
        var repaired = raw
        let openBraces = repaired.filter { $0 == "{" }.count
        let closeBraces = repaired.filter { $0 == "}" }.count
        if repaired.last == ":" { repaired += "null" }
        if repaired.last == "\"" {
            // Already closed.
        } else if repaired.filter({ $0 == "\"" }).count % 2 == 1 {
            repaired += "\""
        }
        repaired += String(repeating: "}", count: max(0, openBraces - closeBraces))
        if let value = try? OrderedJSON.decode(repaired), case .object = value {
            return value
        }
        return [:]
    }

    private func latestToolIndex() -> Int? {
        partial.content.lastIndex { if case .toolCall = $0 { true } else { false } }
    }

    private mutating func updateUsage(_ object: OrderedJSONObject) {
        let usageValue = object["usage"] ?? object.path(["response", "usage"])
        guard case .object(let usage)? = usageValue else { return }
        partial.usage.input =
            usage.integer("input_tokens")
            ?? usage.integer("prompt_tokens")
            ?? partial.usage.input
        partial.usage.output =
            usage.integer("output_tokens")
            ?? usage.integer("completion_tokens")
            ?? partial.usage.output
        partial.usage.reasoning =
            usage.integer("reasoning_tokens")
            ?? usage.pathInteger(["output_tokens_details", "reasoning_tokens"])
        partial.usage.totalTokens =
            usage.integer("total_tokens")
            ?? partial.usage.input + partial.usage.output
    }

    private func mapStopReason(_ raw: String) -> StopReason {
        switch raw {
        case "length", "max_tokens": .length
        case "tool_calls", "tool_use", "toolUse": .toolUse
        case "deferred": .deferred
        default: .stop
        }
    }
}

private extension OrderedJSONObject {
    func string(_ key: String) -> String? {
        if case .string(let value)? = self[key] { value } else { nil }
    }
    func integer(_ key: String) -> Int? {
        if case .number(let value)? = self[key], let integer = value.safeIntegerValue {
            Int(integer)
        } else {
            nil
        }
    }
    func path(_ path: [String]) -> JSONValue? {
        var current: JSONValue = .object(self)
        for key in path {
            if case .object(let object) = current, let value = object[key] {
                current = value
            } else if case .array(let array) = current,
                let index = Int(key), array.indices.contains(index)
            {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }
    func pathString(_ path: [String]) -> String? {
        guard case .string(let value)? = self.path(path) else { return nil }
        return value
    }
    func pathInteger(_ path: [String]) -> Int? {
        guard case .number(let value)? = self.path(path),
            let integer = value.safeIntegerValue
        else {
            return nil
        }
        return Int(integer)
    }
}
