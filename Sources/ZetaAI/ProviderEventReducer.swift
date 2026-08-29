import Foundation
import ZetaCore

public struct ProviderEventReducer: Sendable {
    static let maximumProviderContentIndex = 4_095

    public private(set) var partial: AssistantMessage
    private let model: Model
    private var toolArgumentBuffers: [Int: String] = [:]
    private var openAIToolContentIndices: [Int: Int] = [:]
    private var openAIResponseContentIndices: [Int: Int] = [:]
    private var openContentBlockIndices: Set<Int> = []
    private var googleCurrentBlockIndex: Int?
    private var googleToolCallCounter = 0

    public init(model: Model) {
        self.model = model
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
        try validateProviderContentIndexes(object)
        var events = consumeGoogleParts(object)
        if type == "response.output_item.added" {
            events += startOpenAIResponseToolCall(object)
        }

        if type == "content_block_start",
            case .object(let block)? = object["content_block"]
        {
            let index = object.integer("index") ?? partial.content.count
            switch block.string("type") {
            case "text":
                try ensureIndex(index, block: .text(text: ""))
                openContentBlockIndices.insert(index)
                events.append(.textStart(index: index, partial: partial))
            case "thinking":
                try ensureIndex(
                    index,
                    block: .thinking(
                        text: block.string("thinking") ?? "",
                        signature: block.string("signature")
                    )
                )
                openContentBlockIndices.insert(index)
                events.append(.thinkingStart(index: index, partial: partial))
            case "redacted_thinking":
                try ensureIndex(
                    index,
                    block: .thinking(
                        text: "[Reasoning redacted]",
                        signature: block.string("data"),
                        redacted: true
                    )
                )
                openContentBlockIndices.insert(index)
                events.append(.thinkingStart(index: index, partial: partial))
            case "tool_use":
                let call = ToolCall(
                    id: block.string("id") ?? "call",
                    name: block.string("name") ?? "tool"
                )
                try ensureIndex(index, block: .toolCall(call))
                toolArgumentBuffers[index] = ""
                events.append(.toolCallStart(index: index, partial: partial))
            default:
                break
            }
        }

        let textDelta =
            object.pathString(["delta", "text"])
            ?? object.pathString(["choices", "0", "delta", "content"])
            ?? (type.contains("output_text.delta") ? object.string("delta") : nil)
        if let textDelta, !textDelta.isEmpty {
            events += appendText(
                textDelta,
                responseOutputIndex: type.hasPrefix("response.")
                    ? object.integer("output_index") : nil
            )
        }

        let thinkingDelta =
            object.pathString(["delta", "thinking"])
            ?? object.pathString(["choices", "0", "delta", "reasoning_content"])
            ?? object.pathString(["choices", "0", "delta", "reasoning"])
            ?? object.pathString(["choices", "0", "delta", "reasoning_text"])
            ?? (type.contains("reasoning") ? object.string("delta") : nil)
        if let thinkingDelta, !thinkingDelta.isEmpty {
            events += appendThinking(
                thinkingDelta,
                responseOutputIndex: type.hasPrefix("response.")
                    ? object.integer("output_index") : nil
            )
        }

        events += consumeOpenAIChatToolCalls(object)

        if let signatureDelta = object.pathString(["delta", "signature"]),
            let providerIndex = object.integer("index"),
            partial.content.indices.contains(providerIndex),
            case .thinking(let text, let signature, let redacted) = partial.content[providerIndex]
        {
            partial.content[providerIndex] = .thinking(
                text: text,
                signature: (signature ?? "") + signatureDelta,
                redacted: redacted
            )
        }

        let toolDelta =
            object.pathString(["delta", "partial_json"])
            ?? (type.contains("function_call_arguments.delta")
                ? object.string("delta") : nil)
        if let toolDelta {
            let index = try toolContentIndex(for: object, type: type, events: &events)
            toolArgumentBuffers[index, default: ""] += toolDelta
            updateToolArguments(index)
            events.append(
                .toolCallDelta(index: index, delta: toolDelta, partial: partial)
            )
        }

        if type.contains("function_call_arguments.done") {
            let index = try toolContentIndex(for: object, type: type, events: &events)
            if let arguments = object.string("arguments") {
                let previous = toolArgumentBuffers[index] ?? ""
                toolArgumentBuffers[index] = arguments
                updateToolArguments(index)
                if arguments.hasPrefix(previous) {
                    let suffix = String(arguments.dropFirst(previous.count))
                    if !suffix.isEmpty {
                        events.append(.toolCallDelta(index: index, delta: suffix, partial: partial))
                    }
                }
            }
        } else if type == "content_block_stop" {
            let index = object.integer("index") ?? latestToolIndex() ?? 0
            if partial.content.indices.contains(index) {
                switch partial.content[index] {
                case .text, .thinking:
                    events += finishContentBlock(at: index)
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

        if type == "response.output_item.done" {
            events += finishOpenAIResponseOutputItem(object)
        } else if type == "response.output_text.done",
            let outputIndex = object.integer("output_index"),
            let contentIndex = openAIResponseContentIndices[outputIndex]
        {
            events += finishContentBlock(at: contentIndex)
        }

        if let stop = object.pathString(["choices", "0", "finish_reason"])
            ?? object.string("stop_reason")
        {
            if object.pathString(["choices", "0", "finish_reason"]) != nil {
                events += finishOpenAIContentBlocks()
                events += finishOpenAIChatToolCalls()
            }
            partial.rawStopReason = stop
            partial.stopReason = mapStopReason(stop)
        }
        if let stop = object.pathString(["candidates", "0", "finishReason"]) {
            events += finishGoogleContentBlock()
            partial.rawStopReason = stop
            partial.stopReason = mapStopReason(stop)
            if partial.stopReason == .stop,
                partial.content.contains(where: {
                    if case .toolCall = $0 { true } else { false }
                })
            {
                partial.stopReason = .toolUse
            }
        }
        if type == "response.completed"
            || type == "response.incomplete"
            || type == "response.done"
        {
            events += finishOpenAIContentBlocks()
            events += finishOpenAIResponseToolCalls()
        }
        if type == "message_stop"
            || type == "response.completed"
            || type == "response.incomplete"
            || type == "response.done"
        {
            if partial.stopReason == .pending { partial.stopReason = .stop }
        }
        if let responseID = object.string("id")
            ?? object.string("responseId")
            ?? object.pathString(["response", "id"])
        {
            partial.responseId = responseID
        }
        updateUsage(object)
        return events
    }

    private func validateProviderContentIndexes(
        _ object: OrderedJSONObject
    ) throws {
        try validateProviderContentIndex(object["index"], field: "index")
        try validateProviderContentIndex(
            object["output_index"],
            field: "output_index"
        )
        guard
            case .array(let toolCalls)? = object.path([
                "choices", "0", "delta", "tool_calls",
            ])
        else {
            return
        }
        guard toolCalls.count <= Self.maximumProviderContentIndex + 1 else {
            throw ProviderError.invalidResponse(
                "Provider tool-call count exceeds the content index limit"
            )
        }
        for value in toolCalls {
            guard case .object(let toolCall) = value else { continue }
            try validateProviderContentIndex(
                toolCall["index"],
                field: "tool_calls.index"
            )
        }
    }

    private func validateProviderContentIndex(
        _ value: JSONValue?,
        field: String
    ) throws {
        guard let value else { return }
        guard case .number(let number) = value,
            let index = number.safeIntegerValue,
            (0...Int64(Self.maximumProviderContentIndex)).contains(index)
        else {
            throw ProviderError.invalidResponse(
                "Provider \(field) must be an integer from 0 through "
                    + "\(Self.maximumProviderContentIndex)"
            )
        }
    }

    private mutating func consumeGoogleParts(
        _ object: OrderedJSONObject
    ) -> [AssistantEvent] {
        guard
            case .array(let values)? = object.path([
                "candidates", "0", "content", "parts",
            ])
        else {
            return []
        }
        var events: [AssistantEvent] = []
        for value in values {
            guard case .object(let part) = value else { continue }
            if case .string(let text)? = part["text"] {
                let thinking = part.boolean("thought") == true
                let signature = part.string("thoughtSignature")
                let needsBlock: Bool
                if let index = googleCurrentBlockIndex,
                    partial.content.indices.contains(index)
                {
                    switch partial.content[index] {
                    case .thinking: needsBlock = !thinking
                    case .text: needsBlock = thinking
                    default: needsBlock = true
                    }
                } else {
                    needsBlock = true
                }
                if needsBlock {
                    events += finishGoogleContentBlock()
                    let index = partial.content.count
                    googleCurrentBlockIndex = index
                    if thinking {
                        partial.content.append(.thinking(text: "", signature: signature))
                        openContentBlockIndices.insert(index)
                        events.append(.thinkingStart(index: index, partial: partial))
                    } else {
                        partial.content.append(.text(text: "", signature: signature))
                        openContentBlockIndices.insert(index)
                        events.append(.textStart(index: index, partial: partial))
                    }
                }
                guard let index = googleCurrentBlockIndex else { continue }
                switch partial.content[index] {
                case .thinking(let current, let existingSignature, let redacted):
                    partial.content[index] = .thinking(
                        text: current + text,
                        signature: retainedSignature(existingSignature, incoming: signature),
                        redacted: redacted
                    )
                    events.append(.thinkingDelta(index: index, delta: text, partial: partial))
                case .text(let current, let existingSignature):
                    partial.content[index] = .text(
                        text: current + text,
                        signature: retainedSignature(existingSignature, incoming: signature)
                    )
                    events.append(.textDelta(index: index, delta: text, partial: partial))
                default:
                    break
                }
            }

            if case .object(let functionCall)? = part["functionCall"] {
                events += finishGoogleContentBlock()
                let name = functionCall.string("name") ?? ""
                let providedID = functionCall.string("id")
                let duplicateID =
                    providedID.map { id in
                        partial.content.contains {
                            if case .toolCall(let call) = $0 { call.id == id } else { false }
                        }
                    } ?? true
                googleToolCallCounter += 1
                let id: String
                if let providedID, !duplicateID {
                    id = providedID
                } else {
                    id = "\(name.isEmpty ? "call" : name)-\(googleToolCallCounter)"
                }
                let arguments: JSONValue
                if let value = functionCall["args"], case .object = value {
                    arguments = value
                } else {
                    arguments = [:]
                }
                let call = ToolCall(
                    id: id,
                    name: name,
                    arguments: arguments,
                    thoughtSignature: part.string("thoughtSignature")
                )
                let index = partial.content.count
                partial.content.append(.toolCall(call))
                events.append(.toolCallStart(index: index, partial: partial))
                events.append(
                    .toolCallDelta(
                        index: index,
                        delta: OrderedJSON.string(arguments),
                        partial: partial
                    )
                )
                events.append(.toolCallEnd(index: index, call: call, partial: partial))
            }
        }
        return events
    }

    private mutating func finishGoogleContentBlock() -> [AssistantEvent] {
        guard let index = googleCurrentBlockIndex,
            partial.content.indices.contains(index)
        else {
            googleCurrentBlockIndex = nil
            return []
        }
        googleCurrentBlockIndex = nil
        return finishContentBlock(at: index)
    }

    private func retainedSignature(
        _ existing: String?,
        incoming: String?
    ) -> String? {
        if let incoming, !incoming.isEmpty { return incoming }
        return existing
    }

    private mutating func startOpenAIResponseToolCall(
        _ object: OrderedJSONObject
    ) -> [AssistantEvent] {
        guard let outputIndex = object.integer("output_index"),
            case .object(let item)? = object["item"],
            item.string("type") == "function_call"
        else {
            return []
        }
        if let contentIndex = openAIResponseContentIndices[outputIndex] {
            updateOpenAIResponseToolMetadata(item, at: contentIndex, outputIndex: outputIndex)
            return []
        }
        let contentIndex = partial.content.count
        let call = openAIResponseToolCall(item, outputIndex: outputIndex)
        partial.content.append(.toolCall(call))
        openAIResponseContentIndices[outputIndex] = contentIndex
        toolArgumentBuffers[contentIndex] = item.string("arguments") ?? ""
        updateToolArguments(contentIndex)
        return [.toolCallStart(index: contentIndex, partial: partial)]
    }

    private mutating func finishOpenAIResponseOutputItem(
        _ object: OrderedJSONObject
    ) -> [AssistantEvent] {
        guard let outputIndex = object.integer("output_index") else { return [] }
        if case .object(let item)? = object["item"],
            item.string("type") == "function_call"
        {
            var events = startOpenAIResponseToolCall(object)
            guard let contentIndex = openAIResponseContentIndices.removeValue(forKey: outputIndex) else {
                return events
            }
            updateOpenAIResponseToolMetadata(item, at: contentIndex, outputIndex: outputIndex)
            if let arguments = item.string("arguments") {
                toolArgumentBuffers[contentIndex] = arguments
            }
            updateToolArguments(contentIndex)
            guard partial.content.indices.contains(contentIndex),
                case .toolCall(let call) = partial.content[contentIndex]
            else {
                toolArgumentBuffers[contentIndex] = nil
                return events
            }
            events.append(.toolCallEnd(index: contentIndex, call: call, partial: partial))
            toolArgumentBuffers[contentIndex] = nil
            return events
        }
        guard let contentIndex = openAIResponseContentIndices[outputIndex] else { return [] }
        return finishContentBlock(at: contentIndex)
    }

    private mutating func finishOpenAIResponseToolCalls() -> [AssistantEvent] {
        var events: [AssistantEvent] = []
        let slots = openAIResponseContentIndices.sorted(by: { $0.key < $1.key })
        for (outputIndex, contentIndex) in slots {
            guard partial.content.indices.contains(contentIndex),
                case .toolCall = partial.content[contentIndex]
            else {
                continue
            }
            updateToolArguments(contentIndex)
            guard case .toolCall(let updated) = partial.content[contentIndex] else { continue }
            events.append(.toolCallEnd(index: contentIndex, call: updated, partial: partial))
            toolArgumentBuffers[contentIndex] = nil
            openAIResponseContentIndices[outputIndex] = nil
        }
        return events
    }

    private mutating func toolContentIndex(
        for object: OrderedJSONObject,
        type: String,
        events: inout [AssistantEvent]
    ) throws -> Int {
        if type.hasPrefix("response."), let outputIndex = object.integer("output_index") {
            if let contentIndex = openAIResponseContentIndices[outputIndex] {
                return contentIndex
            }
            let contentIndex = partial.content.count
            let call = ToolCall(
                id: object.string("call_id") ?? "call-\(outputIndex)",
                name: object.string("name") ?? "tool"
            )
            partial.content.append(.toolCall(call))
            openAIResponseContentIndices[outputIndex] = contentIndex
            toolArgumentBuffers[contentIndex] = ""
            events.append(.toolCallStart(index: contentIndex, partial: partial))
            return contentIndex
        }
        let index = object.integer("index") ?? latestToolIndex() ?? partial.content.count
        if !partial.content.indices.contains(index) {
            let call = ToolCall(
                id: object.string("call_id") ?? "call-\(index)",
                name: object.string("name") ?? "tool"
            )
            try ensureIndex(index, block: .toolCall(call))
            toolArgumentBuffers[index] = ""
            events.append(.toolCallStart(index: index, partial: partial))
        }
        return index
    }

    private func openAIResponseToolCall(
        _ item: OrderedJSONObject,
        outputIndex: Int
    ) -> ToolCall {
        let callID = item.string("call_id") ?? "call-\(outputIndex)"
        let id = item.string("id").map { "\(callID)|\($0)" } ?? callID
        return ToolCall(
            id: id,
            name: item.string("name") ?? "tool",
            namespace: item.string("namespace")
        )
    }

    private mutating func updateOpenAIResponseToolMetadata(
        _ item: OrderedJSONObject,
        at contentIndex: Int,
        outputIndex: Int
    ) {
        guard partial.content.indices.contains(contentIndex),
            case .toolCall(var call) = partial.content[contentIndex]
        else {
            return
        }
        let metadata = openAIResponseToolCall(item, outputIndex: outputIndex)
        call.id = metadata.id
        call.name = metadata.name
        call.namespace = metadata.namespace
        partial.content[contentIndex] = .toolCall(call)
    }

    private mutating func consumeOpenAIChatToolCalls(
        _ object: OrderedJSONObject
    ) -> [AssistantEvent] {
        guard
            case .array(let values)? = object.path([
                "choices", "0", "delta", "tool_calls",
            ])
        else {
            return []
        }
        var events: [AssistantEvent] = []
        for (position, value) in values.enumerated() {
            guard case .object(let toolCall) = value else { continue }
            let streamIndex = toolCall.integer("index") ?? position
            let id = toolCall.string("id")
            let name = toolCall.pathString(["function", "name"])
            let contentIndex: Int
            if let existing = openAIToolContentIndices[streamIndex] {
                contentIndex = existing
                if partial.content.indices.contains(contentIndex),
                    case .toolCall(var call) = partial.content[contentIndex]
                {
                    if let id, !id.isEmpty { call.id = id }
                    if let name, !name.isEmpty { call.name = name }
                    partial.content[contentIndex] = .toolCall(call)
                }
            } else {
                contentIndex = partial.content.count
                partial.content.append(
                    .toolCall(
                        ToolCall(
                            id: id ?? "call-\(streamIndex)",
                            name: name ?? "tool"
                        )
                    )
                )
                openAIToolContentIndices[streamIndex] = contentIndex
                toolArgumentBuffers[contentIndex] = ""
                events.append(.toolCallStart(index: contentIndex, partial: partial))
            }
            if let arguments = toolCall.pathString(["function", "arguments"]),
                !arguments.isEmpty
            {
                toolArgumentBuffers[contentIndex, default: ""] += arguments
                updateToolArguments(contentIndex)
                events.append(
                    .toolCallDelta(
                        index: contentIndex,
                        delta: arguments,
                        partial: partial
                    )
                )
            }
        }
        return events
    }

    private mutating func finishOpenAIChatToolCalls() -> [AssistantEvent] {
        var events: [AssistantEvent] = []
        for contentIndex in openAIToolContentIndices.values.sorted() {
            updateToolArguments(contentIndex)
            guard partial.content.indices.contains(contentIndex),
                case .toolCall(let call) = partial.content[contentIndex]
            else {
                continue
            }
            events.append(
                .toolCallEnd(index: contentIndex, call: call, partial: partial)
            )
            toolArgumentBuffers[contentIndex] = nil
        }
        openAIToolContentIndices.removeAll()
        return events
    }

    private mutating func appendText(
        _ delta: String,
        responseOutputIndex: Int? = nil
    ) -> [AssistantEvent] {
        let index: Int
        var events: [AssistantEvent] = []
        if let responseOutputIndex,
            let existing = openAIResponseContentIndices[responseOutputIndex],
            openContentBlockIndices.contains(existing),
            partial.content.indices.contains(existing),
            case .text = partial.content[existing]
        {
            index = existing
        } else if responseOutputIndex == nil,
            let existing = openContentBlockIndices.sorted().first(where: {
                if case .text = partial.content[$0] { true } else { false }
            })
        {
            index = existing
        } else {
            index = partial.content.count
            partial.content.append(.text(text: ""))
            openContentBlockIndices.insert(index)
            if let responseOutputIndex {
                openAIResponseContentIndices[responseOutputIndex] = index
            }
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

    private mutating func appendThinking(
        _ delta: String,
        responseOutputIndex: Int? = nil
    ) -> [AssistantEvent] {
        let index: Int
        var events: [AssistantEvent] = []
        if let responseOutputIndex,
            let existing = openAIResponseContentIndices[responseOutputIndex],
            openContentBlockIndices.contains(existing),
            partial.content.indices.contains(existing),
            case .thinking = partial.content[existing]
        {
            index = existing
        } else if responseOutputIndex == nil,
            let existing = openContentBlockIndices.sorted().first(where: {
                if case .thinking = partial.content[$0] { true } else { false }
            })
        {
            index = existing
        } else {
            index = partial.content.count
            partial.content.append(.thinking(text: ""))
            openContentBlockIndices.insert(index)
            if let responseOutputIndex {
                openAIResponseContentIndices[responseOutputIndex] = index
            }
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

    private mutating func finishOpenAIContentBlocks() -> [AssistantEvent] {
        openContentBlockIndices.sorted().flatMap { finishContentBlock(at: $0) }
    }

    private mutating func finishContentBlock(at index: Int) -> [AssistantEvent] {
        guard openContentBlockIndices.remove(index) != nil,
            partial.content.indices.contains(index)
        else {
            return []
        }
        openAIResponseContentIndices = openAIResponseContentIndices.filter {
            $0.value != index
        }
        switch partial.content[index] {
        case .text(let text, _):
            return [.textEnd(index: index, content: text, partial: partial)]
        case .thinking(let text, _, _):
            return [.thinkingEnd(index: index, content: text, partial: partial)]
        default:
            return []
        }
    }

    private mutating func ensureIndex(
        _ index: Int,
        block: ContentBlock
    ) throws {
        guard (0...Self.maximumProviderContentIndex).contains(index) else {
            throw ProviderError.invalidResponse(
                "Provider content index is outside the supported range"
            )
        }
        while partial.content.count < index {
            partial.content.append(.text(text: ""))
        }
        if partial.content.count == index {
            partial.content.append(block)
        } else {
            partial.content[index] = block
        }
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
        if case .object(let usage)? = object["usageMetadata"] {
            let cached = max(0, usage.integer("cachedContentTokenCount") ?? 0)
            let candidates = max(0, usage.integer("candidatesTokenCount") ?? 0)
            let thoughts = max(0, usage.integer("thoughtsTokenCount") ?? 0)
            partial.usage.input = max(
                0,
                (usage.integer("promptTokenCount") ?? 0) - cached
            )
            partial.usage.output = candidates + thoughts
            partial.usage.cacheRead = cached
            partial.usage.cacheWrite = 0
            partial.usage.reasoning = thoughts
            partial.usage.totalTokens = max(
                0,
                usage.integer("totalTokenCount")
                    ?? partial.usage.input + partial.usage.output + cached
            )
            updateCost()
            return
        }
        let usageValue =
            object["usage"]
            ?? object.path(["response", "usage"])
            ?? object.path(["message", "usage"])
            ?? object.path(["choices", "0", "usage"])
        guard case .object(let usage)? = usageValue else { return }
        let cacheRead =
            usage.pathInteger(["input_tokens_details", "cached_tokens"])
            ?? usage.pathInteger(["prompt_tokens_details", "cached_tokens"])
            ?? usage.integer("cache_read_input_tokens")
            ?? usage.integer("prompt_cache_hit_tokens")
            ?? usage.integer("cached_tokens")
        let cacheWrite =
            usage.pathInteger(["input_tokens_details", "cache_write_tokens"])
            ?? usage.pathInteger(["prompt_tokens_details", "cache_write_tokens"])
            ?? usage.integer("cache_creation_input_tokens")
        if let cacheRead { partial.usage.cacheRead = max(0, cacheRead) }
        if let cacheWrite { partial.usage.cacheWrite = max(0, cacheWrite) }
        if let cacheWrite1h = usage.pathInteger([
            "cache_creation", "ephemeral_1h_input_tokens",
        ]) {
            partial.usage.cacheWrite1h = max(0, cacheWrite1h)
        }
        if let rawInput = usage.integer("input_tokens")
            ?? usage.integer("prompt_tokens")
        {
            partial.usage.input =
                model.api == "anthropic-messages"
                ? max(0, rawInput)
                : max(
                    0,
                    rawInput - partial.usage.cacheRead - partial.usage.cacheWrite
                )
        }
        if let output = usage.integer("output_tokens")
            ?? usage.integer("completion_tokens")
        {
            partial.usage.output = max(0, output)
        }
        if let reasoning = usage.integer("reasoning_tokens")
            ?? usage.pathInteger(["output_tokens_details", "reasoning_tokens"])
            ?? usage.pathInteger(["completion_tokens_details", "reasoning_tokens"])
        {
            partial.usage.reasoning = max(0, reasoning)
        }
        partial.usage.totalTokens = max(
            0,
            usage.integer("total_tokens")
                ?? partial.usage.input + partial.usage.output
                + partial.usage.cacheRead + partial.usage.cacheWrite
        )
        updateCost()
    }

    private mutating func updateCost() {
        let rates = model.cost
        let cacheWrite = max(0, partial.usage.cacheWrite)
        let longWrite = min(cacheWrite, max(0, partial.usage.cacheWrite1h ?? 0))
        let shortWrite = cacheWrite - longWrite
        partial.usage.cost = Cost(
            input: cost(tokens: partial.usage.input, rate: rates.input),
            output: cost(tokens: partial.usage.output, rate: rates.output),
            cacheRead: cost(tokens: partial.usage.cacheRead, rate: rates.cacheRead),
            cacheWrite: cost(tokens: shortWrite, rate: rates.cacheWrite)
                + cost(tokens: longWrite, rate: safeRate(rates.input) * 2)
        )
    }

    private func cost(tokens: Int, rate: Double) -> Double {
        let value = Double(max(0, tokens)) * safeRate(rate) / 1_000_000
        return value.isFinite ? value : 0
    }

    private func safeRate(_ value: Double) -> Double {
        value.isFinite && value >= 0 ? value : 0
    }

    private func mapStopReason(_ raw: String) -> StopReason {
        switch raw.lowercased() {
        case "length", "max_tokens": .length
        case "tool_calls", "tool_use", "tooluse": .toolUse
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
    func boolean(_ key: String) -> Bool? {
        if case .bool(let value)? = self[key] { value } else { nil }
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
