import Foundation
import ZetaCore

public struct UserTranscriptItem: Sendable, Equatable, ProtocolJSONConvertible {
    public let id: String
    public let content: [UserContent]
    public let timestamp: Int64

    public init(id: String, content: [UserContent], timestamp: Int64) throws {
        guard !id.isEmpty, timestamp >= 0, timestamp <= javaScriptMaximumSafeInteger else {
            throw ProtocolModelError.invalid("Invalid user transcript item")
        }
        self.id = id
        self.content = content
        self.timestamp = timestamp
    }

    public func protocolJSONValue() -> JSONValue {
        [
            "id": .string(id), "role": "user", "content": .array(content.map { $0.protocolJSONValue() }),
            "timestamp": .number(JSONNumber(timestamp)),
        ]
    }
}

public enum AssistantStopReason: String, Sendable, Codable { case stop, length, toolUse }

public enum AssistantTranscriptState: Sendable, Equatable {
    case streaming
    case complete(AssistantStopReason)
    case error(message: String? = nil)
    case aborted(message: String? = nil)
}

public struct AssistantTranscriptItem: Sendable, Equatable, ProtocolJSONConvertible {
    public let id: String
    public let content: [AssistantContent]
    public let model: ModelReference
    public let responseModel: String?
    public let usage: Usage?
    public let timestamp: Int64
    public let state: AssistantTranscriptState

    public init(
        id: String,
        content: [AssistantContent],
        model: ModelReference,
        responseModel: String? = nil,
        usage: Usage? = nil,
        timestamp: Int64,
        state: AssistantTranscriptState
    ) throws {
        guard !id.isEmpty,
            responseModel.map({ !$0.isEmpty }) ?? true,
            timestamp >= 0, timestamp <= javaScriptMaximumSafeInteger
        else { throw ProtocolModelError.invalid("Invalid assistant transcript item") }
        if case let .error(message) = state, message?.isEmpty == true {
            throw ProtocolModelError.invalid("Assistant errorMessage must not be empty")
        }
        self.id = id
        self.content = content
        self.model = model
        self.responseModel = responseModel
        self.usage = usage
        self.timestamp = timestamp
        self.state = state
    }

    public var isTerminal: Bool {
        if case .streaming = state { false } else { true }
    }

    public func protocolJSONValue() -> JSONValue {
        var fields: [(String, JSONValue?)] = [
            ("id", .string(id)), ("role", "assistant"),
            ("content", .array(content.map { $0.protocolJSONValue() })), ("model", model.protocolJSONValue()),
            ("responseModel", responseModel.map(JSONValue.string)), ("usage", usage?.protocolJSONValue()),
            ("timestamp", .number(JSONNumber(timestamp))),
        ]
        switch state {
        case .streaming:
            fields.append(("status", "streaming"))
        case let .complete(reason):
            fields.append(("status", "complete"))
            fields.append(("stopReason", .string(reason.rawValue)))
        case let .error(message):
            fields.append(("status", "error"))
            fields.append(("stopReason", "error"))
            fields.append(("errorMessage", message.map(JSONValue.string)))
        case let .aborted(message):
            fields.append(("status", "aborted"))
            fields.append(("stopReason", "aborted"))
            fields.append(("errorMessage", message.map(JSONValue.string)))
        }
        return ProtocolEncoding.object(fields)
    }
}

public enum ToolTranscriptState: Sendable, Equatable { case running, complete, error }

public struct ToolTranscriptItem: Sendable, Equatable, ProtocolJSONConvertible {
    public let id: String
    public let toolCallID: String
    public let toolName: String
    public let input: JSONValue
    public let content: [ToolContent]
    public let details: JSONValue?
    public let usage: Usage?
    public let timestamp: Int64
    public let state: ToolTranscriptState

    public init(
        id: String,
        toolCallID: String,
        toolName: String,
        input: JSONValue,
        content: [ToolContent],
        details: JSONValue? = nil,
        usage: Usage? = nil,
        timestamp: Int64,
        state: ToolTranscriptState
    ) throws {
        guard !id.isEmpty, !toolCallID.isEmpty, !toolName.isEmpty,
            timestamp >= 0, timestamp <= javaScriptMaximumSafeInteger
        else { throw ProtocolModelError.invalid("Invalid tool transcript item") }
        try ProtocolDecoding.validateJSONValue(input)
        if let details { try ProtocolDecoding.validateJSONValue(details) }
        self.id = id
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.input = input
        self.content = content
        self.details = details
        self.usage = usage
        self.timestamp = timestamp
        self.state = state
    }

    public var isTerminal: Bool { state != .running }

    public func protocolJSONValue() -> JSONValue {
        let status: String
        let isError: Bool
        switch state {
        case .running:
            status = "running"
            isError = false
        case .complete:
            status = "complete"
            isError = false
        case .error:
            status = "error"
            isError = true
        }
        return ProtocolEncoding.object([
            ("id", .string(id)), ("role", "tool"), ("toolCallId", .string(toolCallID)),
            ("toolName", .string(toolName)), ("input", input),
            ("content", .array(content.map { $0.protocolJSONValue() })), ("details", details),
            ("usage", usage?.protocolJSONValue()), ("timestamp", .number(JSONNumber(timestamp))),
            ("status", .string(status)), ("isError", .bool(isError)),
        ])
    }
}

public enum TranscriptItem: Sendable, Equatable, ProtocolJSONConvertible {
    case user(UserTranscriptItem)
    case assistant(AssistantTranscriptItem)
    case tool(ToolTranscriptItem)

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .user(value): value.protocolJSONValue()
        case let .assistant(value): value.protocolJSONValue()
        case let .tool(value): value.protocolJSONValue()
        }
    }

    static func decode(_ value: JSONValue, path: String) throws -> TranscriptItem {
        guard case let .object(object) = value, let roleValue = object["role"] else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Transcript item must contain a role")
        }
        switch try StrictValue.string(roleValue, path: "\(path).role") {
        case "user": return .user(try TranscriptDecoding.user(value, path: path))
        case "assistant": return .assistant(try TranscriptDecoding.assistant(value, path: path))
        case "tool": return .tool(try TranscriptDecoding.tool(value, path: path))
        default: throw ValidationIssue(code: .invalidValue, path: "\(path).role", message: "Unknown transcript role")
        }
    }
}

public enum AssistantDeltaKind: String, Sendable, Codable { case text, thinking, toolCall }

public enum UpdatableTranscriptItem: Sendable, Equatable, ProtocolJSONConvertible {
    case assistant(AssistantTranscriptItem)
    case tool(ToolTranscriptItem)
    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .assistant(value): value.protocolJSONValue()
        case let .tool(value): value.protocolJSONValue()
        }
    }
}

public enum FinishedTranscriptItem: Sendable, Equatable, ProtocolJSONConvertible {
    case assistant(AssistantTranscriptItem)
    case tool(ToolTranscriptItem)

    public init(assistant: AssistantTranscriptItem) throws {
        guard assistant.isTerminal else { throw ProtocolModelError.invalid("Finished assistant item must be terminal") }
        self = .assistant(assistant)
    }

    public init(tool: ToolTranscriptItem) throws {
        guard tool.isTerminal else { throw ProtocolModelError.invalid("Finished tool item must be terminal") }
        self = .tool(tool)
    }

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .assistant(value): value.protocolJSONValue()
        case let .tool(value): value.protocolJSONValue()
        }
    }
}

public enum TranscriptProgress: Sendable, Equatable, ProtocolJSONConvertible {
    case itemStarted(TranscriptItem)
    case assistantDelta(messageID: String, contentIndex: Int64, kind: AssistantDeltaKind, delta: String)
    case itemUpdated(UpdatableTranscriptItem)
    case itemFinished(FinishedTranscriptItem)

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .itemStarted(item): return ["type": "item_started", "item": item.protocolJSONValue()]
        case let .assistantDelta(messageID, contentIndex, kind, delta):
            return [
                "type": "assistant_delta", "messageId": .string(messageID),
                "contentIndex": .number(JSONNumber(contentIndex)), "kind": .string(kind.rawValue),
                "delta": .string(delta),
            ]
        case let .itemUpdated(item): return ["type": "item_updated", "item": item.protocolJSONValue()]
        case let .itemFinished(item): return ["type": "item_finished", "item": item.protocolJSONValue()]
        }
    }

    static func decode(_ value: JSONValue, path: String) throws -> TranscriptProgress {
        guard case let .object(raw) = value, let typeValue = raw["type"] else {
            throw ValidationIssue(code: .typeMismatch, path: path, message: "Progress must contain a type")
        }
        let type = try StrictValue.string(typeValue, path: "\(path).type")
        var object = try StrictObjectReader(value, path: path)
        try ProtocolDecoding.literal(type, object.required("type"), path: object.childPath("type"))
        switch type {
        case "item_started":
            let item = try TranscriptItem.decode(object.required("item"), path: object.childPath("item"))
            try object.finish()
            return .itemStarted(item)
        case "assistant_delta":
            let messageID = try ProtocolDecoding.nonemptyString(
                object.required("messageId"), path: object.childPath("messageId"))
            let index = try StrictValue.safeInteger(
                object.required("contentIndex"), path: object.childPath("contentIndex"), minimum: 0)
            let kind = try ProtocolDecoding.rawEnum(
                AssistantDeltaKind.self, value: object.required("kind"), path: object.childPath("kind"))
            let delta = try StrictValue.string(object.required("delta"), path: object.childPath("delta"))
            try object.finish()
            return .assistantDelta(messageID: messageID, contentIndex: index, kind: kind, delta: delta)
        case "item_updated":
            let item = try TranscriptItem.decode(object.required("item"), path: object.childPath("item"))
            try object.finish()
            switch item {
            case let .assistant(value): return .itemUpdated(.assistant(value))
            case let .tool(value): return .itemUpdated(.tool(value))
            case .user:
                throw ValidationIssue(
                    code: .invalidValue, path: object.childPath("item"), message: "User items cannot be updated")
            }
        case "item_finished":
            let item = try TranscriptItem.decode(object.required("item"), path: object.childPath("item"))
            try object.finish()
            switch item {
            case let .assistant(value): return .itemFinished(try .init(assistant: value))
            case let .tool(value): return .itemFinished(try .init(tool: value))
            case .user:
                throw ValidationIssue(
                    code: .invalidValue, path: object.childPath("item"), message: "User items cannot be finished")
            }
        default:
            throw ValidationIssue(code: .invalidValue, path: "\(path).type", message: "Unknown progress type")
        }
    }
}

private enum TranscriptDecoding {
    static func user(_ value: JSONValue, path: String) throws -> UserTranscriptItem {
        var object = try StrictObjectReader(value, path: path)
        let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: object.childPath("id"))
        try ProtocolDecoding.literal("user", object.required("role"), path: object.childPath("role"))
        let content = try ProtocolDecoding.array(
            object.required("content"), path: object.childPath("content"), decode: decodeUserContent)
        let timestamp = try StrictValue.safeInteger(
            object.required("timestamp"), path: object.childPath("timestamp"), minimum: 0)
        try object.finish()
        return try UserTranscriptItem(id: id, content: content, timestamp: timestamp)
    }

    static func assistant(_ value: JSONValue, path: String) throws -> AssistantTranscriptItem {
        var object = try StrictObjectReader(value, path: path)
        let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: object.childPath("id"))
        try ProtocolDecoding.literal("assistant", object.required("role"), path: object.childPath("role"))
        let content = try ProtocolDecoding.array(
            object.required("content"), path: object.childPath("content"), decode: decodeAssistantContent)
        let model = try ModelReference.decode(object.required("model"), path: object.childPath("model"))
        let responseModel = try object.optional("responseModel").map {
            try ProtocolDecoding.nonemptyString($0, path: object.childPath("responseModel"))
        }
        let usage = try object.optional("usage").map { try decodeUsage($0, path: object.childPath("usage")) }
        let timestamp = try StrictValue.safeInteger(
            object.required("timestamp"), path: object.childPath("timestamp"), minimum: 0)
        let status = try StrictValue.string(object.required("status"), path: object.childPath("status"))
        let state: AssistantTranscriptState
        switch status {
        case "streaming": state = .streaming
        case "complete":
            state = .complete(
                try ProtocolDecoding.rawEnum(
                    AssistantStopReason.self, value: object.required("stopReason"), path: object.childPath("stopReason")
                ))
        case "error":
            try ProtocolDecoding.literal("error", object.required("stopReason"), path: object.childPath("stopReason"))
            state = .error(
                message: try object.optional("errorMessage").map {
                    try ProtocolDecoding.nonemptyString($0, path: object.childPath("errorMessage"))
                })
        case "aborted":
            try ProtocolDecoding.literal("aborted", object.required("stopReason"), path: object.childPath("stopReason"))
            state = .aborted(
                message: try object.optional("errorMessage").map {
                    try StrictValue.string($0, path: object.childPath("errorMessage"))
                })
        default:
            throw ValidationIssue(
                code: .invalidValue, path: object.childPath("status"), message: "Unknown assistant status")
        }
        try object.finish()
        return try AssistantTranscriptItem(
            id: id, content: content, model: model, responseModel: responseModel, usage: usage,
            timestamp: timestamp, state: state
        )
    }

    static func tool(_ value: JSONValue, path: String) throws -> ToolTranscriptItem {
        var object = try StrictObjectReader(value, path: path)
        let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: object.childPath("id"))
        try ProtocolDecoding.literal("tool", object.required("role"), path: object.childPath("role"))
        let callID = try ProtocolDecoding.nonemptyString(
            object.required("toolCallId"), path: object.childPath("toolCallId"))
        let name = try ProtocolDecoding.nonemptyString(object.required("toolName"), path: object.childPath("toolName"))
        let input = try object.required("input")
        try ProtocolDecoding.validateJSONValue(input, path: object.childPath("input"))
        let content = try ProtocolDecoding.array(
            object.required("content"), path: object.childPath("content"), decode: decodeToolContent)
        let details = object.optional("details")
        if let details { try ProtocolDecoding.validateJSONValue(details, path: object.childPath("details")) }
        let usage = try object.optional("usage").map { try decodeUsage($0, path: object.childPath("usage")) }
        let timestamp = try StrictValue.safeInteger(
            object.required("timestamp"), path: object.childPath("timestamp"), minimum: 0)
        let status = try StrictValue.string(object.required("status"), path: object.childPath("status"))
        let isError = try StrictValue.boolean(object.required("isError"), path: object.childPath("isError"))
        let state: ToolTranscriptState
        switch (status, isError) {
        case ("running", false): state = .running
        case ("complete", false): state = .complete
        case ("error", true): state = .error
        default:
            throw ValidationIssue(
                code: .invalidValue, path: object.childPath("status"), message: "Inconsistent tool status")
        }
        try object.finish()
        return try ToolTranscriptItem(
            id: id, toolCallID: callID, toolName: name, input: input, content: content,
            details: details, usage: usage, timestamp: timestamp, state: state
        )
    }

    static func decodeUserContent(_ value: JSONValue, _ path: String) throws -> UserContent {
        switch try contentType(value, path: path) {
        case "text": return .text(try decodeText(value, path: path))
        case "image": return .image(try decodeImage(value, path: path))
        default: throw ValidationIssue(code: .invalidValue, path: "\(path).type", message: "Invalid user content")
        }
    }

    static func decodeAssistantContent(_ value: JSONValue, _ path: String) throws -> AssistantContent {
        switch try contentType(value, path: path) {
        case "text": return .text(try decodeText(value, path: path))
        case "thinking":
            var object = try StrictObjectReader(value, path: path)
            try ProtocolDecoding.literal("thinking", object.required("type"), path: object.childPath("type"))
            let thinking = try StrictValue.string(object.required("thinking"), path: object.childPath("thinking"))
            let redacted = try object.optional("redacted").map {
                try StrictValue.boolean($0, path: object.childPath("redacted"))
            }
            try object.finish()
            return .thinking(.init(thinking: thinking, redacted: redacted))
        case "toolCall":
            var object = try StrictObjectReader(value, path: path)
            try ProtocolDecoding.literal("toolCall", object.required("type"), path: object.childPath("type"))
            let id = try ProtocolDecoding.nonemptyString(
                object.required("toolCallId"), path: object.childPath("toolCallId"))
            let name = try ProtocolDecoding.nonemptyString(
                object.required("toolName"), path: object.childPath("toolName"))
            let input = try object.required("input")
            try ProtocolDecoding.validateJSONValue(input, path: object.childPath("input"))
            try object.finish()
            return .toolCall(try .init(toolCallID: id, toolName: name, input: input))
        default: throw ValidationIssue(code: .invalidValue, path: "\(path).type", message: "Invalid assistant content")
        }
    }

    static func decodeToolContent(_ value: JSONValue, _ path: String) throws -> ToolContent {
        switch try contentType(value, path: path) {
        case "text": return .text(try decodeText(value, path: path))
        case "image": return .image(try decodeImage(value, path: path))
        default: throw ValidationIssue(code: .invalidValue, path: "\(path).type", message: "Invalid tool content")
        }
    }

    static func contentType(_ value: JSONValue, path: String) throws -> String {
        guard case let .object(object) = value, let type = object["type"] else {
            throw ValidationIssue(code: .missingProperty, path: "\(path).type", message: "Missing content type")
        }
        return try StrictValue.string(type, path: "\(path).type")
    }

    static func decodeText(_ value: JSONValue, path: String) throws -> TextContent {
        var object = try StrictObjectReader(value, path: path)
        try ProtocolDecoding.literal("text", object.required("type"), path: object.childPath("type"))
        let text = try StrictValue.string(object.required("text"), path: object.childPath("text"))
        try object.finish()
        return .init(text: text)
    }

    static func decodeImage(_ value: JSONValue, path: String) throws -> ImageContent {
        var object = try StrictObjectReader(value, path: path)
        try ProtocolDecoding.literal("image", object.required("type"), path: object.childPath("type"))
        let data = try StrictValue.string(object.required("data"), path: object.childPath("data"))
        let mime = try ProtocolDecoding.nonemptyString(object.required("mimeType"), path: object.childPath("mimeType"))
        try object.finish()
        return try .init(data: data, mimeType: mime)
    }

    static func decodeUsage(_ value: JSONValue, path: String) throws -> Usage {
        var object = try StrictObjectReader(value, path: path)
        let input = try StrictValue.safeInteger(object.required("input"), path: object.childPath("input"), minimum: 0)
        let output = try StrictValue.safeInteger(
            object.required("output"), path: object.childPath("output"), minimum: 0)
        let cacheRead = try StrictValue.safeInteger(
            object.required("cacheRead"), path: object.childPath("cacheRead"), minimum: 0)
        let cacheWrite = try StrictValue.safeInteger(
            object.required("cacheWrite"), path: object.childPath("cacheWrite"), minimum: 0)
        let reasoning = try object.optional("reasoning").map {
            try StrictValue.safeInteger($0, path: object.childPath("reasoning"), minimum: 0)
        }
        let total = try StrictValue.safeInteger(
            object.required("totalTokens"), path: object.childPath("totalTokens"), minimum: 0)
        let cost = try decodeUsageCost(object.required("cost"), path: object.childPath("cost"))
        try object.finish()
        return try Usage(
            input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, reasoning: reasoning,
            totalTokens: total, cost: cost)
    }

    static func decodeUsageCost(_ value: JSONValue, path: String) throws -> UsageCost {
        var object = try StrictObjectReader(value, path: path)
        let input = try ProtocolDecoding.nonnegativeNumber(object.required("input"), path: object.childPath("input"))
        let output = try ProtocolDecoding.nonnegativeNumber(object.required("output"), path: object.childPath("output"))
        let read = try ProtocolDecoding.nonnegativeNumber(
            object.required("cacheRead"), path: object.childPath("cacheRead"))
        let write = try ProtocolDecoding.nonnegativeNumber(
            object.required("cacheWrite"), path: object.childPath("cacheWrite"))
        let total = try ProtocolDecoding.nonnegativeNumber(object.required("total"), path: object.childPath("total"))
        try object.finish()
        return try .init(input: input, output: output, cacheRead: read, cacheWrite: write, total: total)
    }
}
