import Foundation
import ZetaCore

public typealias ProviderID = String
public typealias APIID = String

public enum ThinkingLevel: String, Codable, Sendable, CaseIterable {
    case off, minimal, low, medium, high, xhigh, max
}

public enum StopReason: String, Codable, Sendable {
    case pending, stop, length, toolUse, error, aborted, deferred
}

public struct Cost: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var total: Double { input + output + cacheRead + cacheWrite }

    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct Usage: Codable, Sendable, Equatable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var cacheWrite1h: Int?
    public var reasoning: Int?
    public var totalTokens: Int
    public var cost: Cost

    public init(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, cacheWrite1h: Int? = nil,
        reasoning: Int? = nil, totalTokens: Int? = nil, cost: Cost = Cost()
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.reasoning = reasoning
        self.totalTokens = totalTokens ?? input + output + cacheRead + cacheWrite
        self.cost = cost
    }
}

public struct ToolCall: Codable, Sendable, Equatable {
    public let type = "toolCall"
    public var id: String
    public var name: String
    public var arguments: JSONValue
    public var thoughtSignature: String?
    public var namespace: String?

    public init(
        id: String, name: String, arguments: JSONValue = [:], thoughtSignature: String? = nil, namespace: String? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.thoughtSignature = thoughtSignature
        self.namespace = namespace
    }

    private enum CodingKeys: String, CodingKey { case type, id, name, arguments, thoughtSignature, namespace }
}

public enum ContentBlock: Sendable, Equatable {
    case text(text: String, signature: String? = nil)
    case thinking(text: String, signature: String? = nil, redacted: Bool = false)
    case image(data: String, mimeType: String)
    case toolCall(ToolCall)
}

extension ContentBlock: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, text, textSignature, thinking, thinkingSignature, redacted, data, mimeType, id, name, arguments,
            thoughtSignature, namespace
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "text":
            self = .text(
                text: try container.decode(String.self, forKey: .text),
                signature: try container.decodeIfPresent(String.self, forKey: .textSignature))
        case "thinking":
            self = .thinking(
                text: try container.decode(String.self, forKey: .thinking),
                signature: try container.decodeIfPresent(String.self, forKey: .thinkingSignature),
                redacted: try container.decodeIfPresent(Bool.self, forKey: .redacted) ?? false)
        case "image":
            self = .image(
                data: try container.decode(String.self, forKey: .data),
                mimeType: try container.decode(String.self, forKey: .mimeType))
        case "toolCall":
            self = .toolCall(
                ToolCall(
                    id: try container.decode(String.self, forKey: .id),
                    name: try container.decode(String.self, forKey: .name),
                    arguments: try container.decode(JSONValue.self, forKey: .arguments),
                    thoughtSignature: try container.decodeIfPresent(String.self, forKey: .thoughtSignature),
                    namespace: try container.decodeIfPresent(String.self, forKey: .namespace)
                ))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown content type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text, let signature):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(signature, forKey: .textSignature)
        case .thinking(let text, let signature, let redacted):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .thinking)
            try container.encodeIfPresent(signature, forKey: .thinkingSignature)
            if redacted { try container.encode(true, forKey: .redacted) }
        case .image(let data, let mimeType):
            try container.encode("image", forKey: .type)
            try container.encode(data, forKey: .data)
            try container.encode(mimeType, forKey: .mimeType)
        case .toolCall(let call):
            try container.encode("toolCall", forKey: .type)
            try container.encode(call.id, forKey: .id)
            try container.encode(call.name, forKey: .name)
            try container.encode(call.arguments, forKey: .arguments)
            try container.encodeIfPresent(call.thoughtSignature, forKey: .thoughtSignature)
            try container.encodeIfPresent(call.namespace, forKey: .namespace)
        }
    }
}

public struct UserMessage: Codable, Sendable, Equatable {
    public let role = "user"
    public var content: [ContentBlock]
    public var timestamp: Int64

    public init(_ text: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) {
        content = [.text(text: text)]
        self.timestamp = timestamp
    }

    public init(content: [ContentBlock], timestamp: Int64) {
        self.content = content
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey { case role, content, timestamp }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .content) {
            content = [.text(text: text)]
        } else {
            content = try container.decode([ContentBlock].self, forKey: .content)
        }
        timestamp = try container.decode(Int64.self, forKey: .timestamp)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if content.count == 1,
            case .text(let text, nil) = content[0]
        {
            try container.encode(text, forKey: .content)
        } else {
            try container.encode(content, forKey: .content)
        }
        try container.encode(timestamp, forKey: .timestamp)
    }
}

public struct DeferredHandle: Codable, Sendable, Equatable {
    public var provider: String
    public var modelID: String
    public var api: String
    public var id: String
    public var expiresAt: Int64?
    public var pollAfterMilliseconds: Int?
    public var data: JSONValue?

    public init(
        provider: String,
        modelID: String,
        api: String,
        id: String,
        expiresAt: Int64? = nil,
        pollAfterMilliseconds: Int? = nil,
        data: JSONValue? = nil
    ) {
        self.provider = provider
        self.modelID = modelID
        self.api = api
        self.id = id
        self.expiresAt = expiresAt
        self.pollAfterMilliseconds = pollAfterMilliseconds
        self.data = data
    }
}

public struct AssistantMessage: Codable, Sendable, Equatable {
    public let role = "assistant"
    public var content: [ContentBlock]
    public var api: APIID
    public var provider: ProviderID
    public var model: String
    public var responseModel: String?
    public var responseId: String?
    public var usage: Usage
    public var stopReason: StopReason
    public var deferred: DeferredHandle?
    public var errorMessage: String?
    public var rawStopReason: String?
    public var endTurn: Bool?
    public var timestamp: Int64

    public init(
        content: [ContentBlock] = [], api: APIID, provider: ProviderID, model: String, usage: Usage = Usage(),
        stopReason: StopReason = .pending, errorMessage: String? = nil,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.content = content
        self.api = api
        self.provider = provider
        self.model = model
        self.usage = usage
        self.stopReason = stopReason
        self.errorMessage = errorMessage
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case role, content, api, provider, model, responseModel, responseId, usage, stopReason, deferred,
            errorMessage, rawStopReason, endTurn, timestamp
    }
}

public struct ToolResultMessage: Codable, Sendable, Equatable {
    public let role = "toolResult"
    public var toolCallId: String
    public var toolName: String
    public var content: [ContentBlock]
    public var details: JSONValue?
    public var usage: Usage?
    public var addedToolNames: [String]?
    public var isError: Bool
    public var timestamp: Int64

    public init(
        toolCallId: String, toolName: String, content: [ContentBlock], details: JSONValue? = nil, usage: Usage? = nil,
        addedToolNames: [String]? = nil, isError: Bool, timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.content = content
        self.details = details
        self.usage = usage
        self.addedToolNames = addedToolNames
        self.isError = isError
        self.timestamp = timestamp
    }

    private enum CodingKeys: String, CodingKey {
        case role, toolCallId, toolName, content, details, usage, addedToolNames, isError, timestamp
    }
}

public struct CustomAgentMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: JSONValue
    public var timestamp: Int64

    public init(
        role: String,
        content: JSONValue,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
    }
}

public enum Message: Sendable, Equatable {
    case user(UserMessage)
    case assistant(AssistantMessage)
    case toolResult(ToolResultMessage)
    case custom(CustomAgentMessage)
}

extension Message: Codable {
    private enum CodingKeys: String, CodingKey { case role }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .role) {
        case "user": self = .user(try UserMessage(from: decoder))
        case "assistant": self = .assistant(try AssistantMessage(from: decoder))
        case "toolResult": self = .toolResult(try ToolResultMessage(from: decoder))
        default: self = .custom(try CustomAgentMessage(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .user(let value): try value.encode(to: encoder)
        case .assistant(let value): try value.encode(to: encoder)
        case .toolResult(let value): try value.encode(to: encoder)
        case .custom(let value): try value.encode(to: encoder)
        }
    }
}

public struct ModelCost: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public struct Model: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var api: APIID
    public var provider: ProviderID
    public var baseURL: URL
    public var reasoning: Bool
    public var input: Set<String>
    public var cost: ModelCost
    public var contextWindow: Int
    public var maximumTokens: Int
    public var headers: [String: String]?
    public var compat: JSONValue?
    public var thinkingLevelMap: JSONValue?
    public var baseURLTemplate: String?

    public init(
        id: String, name: String, api: APIID, provider: ProviderID, baseURL: URL, reasoning: Bool = false,
        input: Set<String> = ["text"], cost: ModelCost = ModelCost(), contextWindow: Int, maximumTokens: Int
    ) {
        self.init(
            id: id,
            name: name,
            api: api,
            provider: provider,
            baseURL: baseURL,
            reasoning: reasoning,
            input: input,
            cost: cost,
            contextWindow: contextWindow,
            maximumTokens: maximumTokens,
            headers: nil,
            compat: nil,
            thinkingLevelMap: nil,
            baseURLTemplate: nil
        )
    }

    public init(
        id: String, name: String, api: APIID, provider: ProviderID, baseURL: URL, reasoning: Bool = false,
        input: Set<String> = ["text"], cost: ModelCost = ModelCost(), contextWindow: Int, maximumTokens: Int,
        headers: [String: String]? = nil, compat: JSONValue? = nil, thinkingLevelMap: JSONValue? = nil,
        baseURLTemplate: String? = nil
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseURL = baseURL
        self.reasoning = reasoning
        self.input = input
        self.cost = cost
        self.contextWindow = contextWindow
        self.maximumTokens = maximumTokens
        self.headers = headers
        self.compat = compat
        self.thinkingLevelMap = thinkingLevelMap
        self.baseURLTemplate = baseURLTemplate
    }

    public func compatibility(_ key: String) -> JSONValue? {
        guard case .object(let values)? = compat else { return nil }
        return values[key]
    }

    public func compatibilityBool(_ key: String) -> Bool? {
        guard case .bool(let value)? = compatibility(key) else { return nil }
        return value
    }

    public func compatibilityString(_ key: String) -> String? {
        guard case .string(let value)? = compatibility(key) else { return nil }
        return value
    }

    public func resolvedThinkingLevel(_ requested: ThinkingLevel) -> ThinkingLevel {
        let available = ThinkingLevel.allCases.filter { level in
            guard reasoning else { return level == .off }
            guard case .object(let values)? = thinkingLevelMap else {
                return level != .xhigh && level != .max
            }
            if values[level.rawValue] == .null { return false }
            if level == .xhigh || level == .max {
                return values[level.rawValue] != nil
            }
            return true
        }
        if available.contains(requested) { return requested }
        guard let requestedIndex = ThinkingLevel.allCases.firstIndex(of: requested) else {
            return available.first ?? .off
        }
        for index in requestedIndex..<ThinkingLevel.allCases.count {
            let level = ThinkingLevel.allCases[index]
            if available.contains(level) { return level }
        }
        if requestedIndex > 0 {
            for index in stride(from: requestedIndex - 1, through: 0, by: -1) {
                let level = ThinkingLevel.allCases[index]
                if available.contains(level) { return level }
            }
        }
        return available.first ?? .off
    }

    public func thinkingLevelMapValue(_ level: ThinkingLevel) -> JSONValue? {
        guard case .object(let values)? = thinkingLevelMap else { return nil }
        return values[level.rawValue]
    }

    public func requestThinkingValue(_ requested: ThinkingLevel) -> String? {
        let level = resolvedThinkingLevel(requested)
        guard let mapped = thinkingLevelMapValue(level)
        else {
            return level.rawValue
        }
        if case .string(let value) = mapped { return value }
        return mapped == .null ? nil : level.rawValue
    }
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ImageModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var api: String
    public var provider: String
    public var baseURL: URL
    public var input: Set<String>
    public var output: Set<String>
    public var cost: ModelCost

    public init(
        id: String,
        name: String,
        api: String,
        provider: String,
        baseURL: URL,
        input: Set<String>,
        output: Set<String>,
        cost: ModelCost = ModelCost()
    ) {
        self.id = id
        self.name = name
        self.api = api
        self.provider = provider
        self.baseURL = baseURL
        self.input = input
        self.output = output
        self.cost = cost
    }
}

public enum ImageStopReason: String, Codable, Sendable {
    case stop
    case error
    case aborted
}

public struct AssistantImages: Codable, Sendable, Equatable {
    public var api: String
    public var provider: String
    public var model: String
    public var output: [ContentBlock]
    public var responseID: String?
    public var usage: Usage?
    public var stopReason: ImageStopReason
    public var errorMessage: String?
    public var timestamp: Int64
}

public struct Context: Codable, Sendable, Equatable {
    public var systemPrompt: String?
    public var messages: [Message]
    public var tools: [ToolDefinition]?
    public init(systemPrompt: String? = nil, messages: [Message] = [], tools: [ToolDefinition]? = nil) {
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
    }
}
