import Foundation
import ZetaCore

public let protocolVersion = 1

public protocol ProtocolJSONConvertible: Sendable {
    func protocolJSONValue() -> JSONValue
}

public enum ProtocolModelError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

public enum ThinkingLevel: String, CaseIterable, Codable, Sendable {
    case off, minimal, low, medium, high, xhigh, max
}

public enum SessionPhase: String, CaseIterable, Codable, Sendable {
    case idle, turn, compaction
    case branchSummary = "branch_summary"
    case retry
}

public struct ModelReference: Sendable, Equatable, Codable, ProtocolJSONConvertible {
    public let provider: String
    public let id: String

    public init(provider: String, id: String) throws {
        guard !provider.isEmpty, !id.isEmpty else {
            throw ProtocolModelError.invalid("Model provider and id must not be empty")
        }
        self.provider = provider
        self.id = id
    }

    public func protocolJSONValue() -> JSONValue {
        ["provider": .string(provider), "id": .string(id)]
    }

    static func decode(_ value: JSONValue, path: String) throws -> ModelReference {
        var object = try StrictObjectReader(value, path: path)
        let provider = try ProtocolDecoding.nonemptyString(
            object.required("provider"), path: object.childPath("provider"))
        let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: object.childPath("id"))
        try object.finish()
        return try ModelReference(provider: provider, id: id)
    }
}

public typealias ModelRef = ModelReference

public struct ModelCost: Sendable, Equatable, Codable, ProtocolJSONConvertible {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) throws {
        guard [input, output, cacheRead, cacheWrite].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ProtocolModelError.invalid("Model costs must be finite and nonnegative")
        }
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public func protocolJSONValue() -> JSONValue {
        [
            "input": ProtocolEncoding.number(input), "output": ProtocolEncoding.number(output),
            "cacheRead": ProtocolEncoding.number(cacheRead), "cacheWrite": ProtocolEncoding.number(cacheWrite),
        ]
    }

    static func decode(_ value: JSONValue, path: String) throws -> ModelCost {
        var object = try StrictObjectReader(value, path: path)
        let input = try ProtocolDecoding.nonnegativeNumber(object.required("input"), path: object.childPath("input"))
        let output = try ProtocolDecoding.nonnegativeNumber(object.required("output"), path: object.childPath("output"))
        let cacheRead = try ProtocolDecoding.nonnegativeNumber(
            object.required("cacheRead"), path: object.childPath("cacheRead"))
        let cacheWrite = try ProtocolDecoding.nonnegativeNumber(
            object.required("cacheWrite"), path: object.childPath("cacheWrite"))
        try object.finish()
        return try ModelCost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
    }
}

public enum ModelInput: String, Codable, Sendable { case text, image }

public struct ModelMetadata: Sendable, Equatable, ProtocolJSONConvertible {
    public let provider: String
    public let id: String
    public let name: String
    public let api: String
    public let reasoning: Bool
    public let input: [ModelInput]
    public let contextWindow: Int64
    public let maxTokens: Int64
    public let cost: ModelCost
    public let supportedThinkingLevels: [ThinkingLevel]
    public let authenticated: Bool

    public init(
        provider: String,
        id: String,
        name: String,
        api: String,
        reasoning: Bool,
        input: [ModelInput],
        contextWindow: Int64,
        maxTokens: Int64,
        cost: ModelCost,
        supportedThinkingLevels: [ThinkingLevel],
        authenticated: Bool
    ) throws {
        guard !provider.isEmpty, !id.isEmpty, !name.isEmpty, !api.isEmpty,
            contextWindow >= 1, contextWindow <= javaScriptMaximumSafeInteger,
            maxTokens >= 1, maxTokens <= javaScriptMaximumSafeInteger,
            !supportedThinkingLevels.isEmpty
        else { throw ProtocolModelError.invalid("Invalid model metadata") }
        self.provider = provider
        self.id = id
        self.name = name
        self.api = api
        self.reasoning = reasoning
        self.input = input
        self.contextWindow = contextWindow
        self.maxTokens = maxTokens
        self.cost = cost
        self.supportedThinkingLevels = supportedThinkingLevels
        self.authenticated = authenticated
    }

    public func protocolJSONValue() -> JSONValue {
        [
            "provider": .string(provider), "id": .string(id), "name": .string(name), "api": .string(api),
            "reasoning": .bool(reasoning), "input": .array(input.map { .string($0.rawValue) }),
            "contextWindow": .number(JSONNumber(contextWindow)), "maxTokens": .number(JSONNumber(maxTokens)),
            "cost": cost.protocolJSONValue(),
            "supportedThinkingLevels": .array(supportedThinkingLevels.map { .string($0.rawValue) }),
            "authenticated": .bool(authenticated),
        ]
    }

    static func decode(_ value: JSONValue, path: String) throws -> ModelMetadata {
        var object = try StrictObjectReader(value, path: path)
        let provider = try ProtocolDecoding.nonemptyString(
            object.required("provider"), path: object.childPath("provider"))
        let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: object.childPath("id"))
        let name = try ProtocolDecoding.nonemptyString(object.required("name"), path: object.childPath("name"))
        let api = try ProtocolDecoding.nonemptyString(object.required("api"), path: object.childPath("api"))
        let reasoning = try StrictValue.boolean(object.required("reasoning"), path: object.childPath("reasoning"))
        let inputs = try ProtocolDecoding.array(object.required("input"), path: object.childPath("input")) {
            value, path in
            try ProtocolDecoding.rawEnum(ModelInput.self, value: value, path: path)
        }
        let contextWindow = try StrictValue.safeInteger(
            object.required("contextWindow"), path: object.childPath("contextWindow"), minimum: 1)
        let maxTokens = try StrictValue.safeInteger(
            object.required("maxTokens"), path: object.childPath("maxTokens"), minimum: 1)
        let cost = try ModelCost.decode(object.required("cost"), path: object.childPath("cost"))
        let levels = try ProtocolDecoding.array(
            object.required("supportedThinkingLevels"), path: object.childPath("supportedThinkingLevels"),
            minimumCount: 1
        ) { value, path in try ProtocolDecoding.rawEnum(ThinkingLevel.self, value: value, path: path) }
        let authenticated = try StrictValue.boolean(
            object.required("authenticated"), path: object.childPath("authenticated"))
        try object.finish()
        return try ModelMetadata(
            provider: provider, id: id, name: name, api: api, reasoning: reasoning, input: inputs,
            contextWindow: contextWindow, maxTokens: maxTokens, cost: cost,
            supportedThinkingLevels: levels, authenticated: authenticated
        )
    }
}

public struct TextContent: Sendable, Equatable, ProtocolJSONConvertible {
    public let text: String
    public init(text: String) { self.text = text }
    public func protocolJSONValue() -> JSONValue { ["type": "text", "text": .string(text)] }
}

public struct ThinkingContent: Sendable, Equatable, ProtocolJSONConvertible {
    public let thinking: String
    public let redacted: Bool?
    public init(thinking: String, redacted: Bool? = nil) {
        self.thinking = thinking
        self.redacted = redacted
    }
    public func protocolJSONValue() -> JSONValue {
        ProtocolEncoding.object([
            ("type", "thinking"), ("thinking", .string(thinking)), ("redacted", redacted.map(JSONValue.bool)),
        ])
    }
}

public struct ImageContent: Sendable, Equatable, ProtocolJSONConvertible {
    public let data: String
    public let mimeType: String
    public init(data: String, mimeType: String) throws {
        guard !mimeType.isEmpty else { throw ProtocolModelError.invalid("Image MIME type must not be empty") }
        self.data = data
        self.mimeType = mimeType
    }
    public func protocolJSONValue() -> JSONValue {
        ["type": "image", "data": .string(data), "mimeType": .string(mimeType)]
    }
}

public struct ToolCallContent: Sendable, Equatable, ProtocolJSONConvertible {
    public let toolCallID: String
    public let toolName: String
    public let input: JSONValue

    public init(toolCallID: String, toolName: String, input: JSONValue) throws {
        guard !toolCallID.isEmpty, !toolName.isEmpty else {
            throw ProtocolModelError.invalid("Tool call identifiers must not be empty")
        }
        try ProtocolDecoding.validateJSONValue(input)
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.input = input
    }

    public func protocolJSONValue() -> JSONValue {
        ["type": "toolCall", "toolCallId": .string(toolCallID), "toolName": .string(toolName), "input": input]
    }
}

public enum UserContent: Sendable, Equatable, ProtocolJSONConvertible {
    case text(TextContent)
    case image(ImageContent)
    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .text(value): value.protocolJSONValue()
        case let .image(value): value.protocolJSONValue()
        }
    }
}

public enum AssistantContent: Sendable, Equatable, ProtocolJSONConvertible {
    case text(TextContent)
    case thinking(ThinkingContent)
    case toolCall(ToolCallContent)
    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .text(value): value.protocolJSONValue()
        case let .thinking(value): value.protocolJSONValue()
        case let .toolCall(value): value.protocolJSONValue()
        }
    }
}

public enum ToolContent: Sendable, Equatable, ProtocolJSONConvertible {
    case text(TextContent)
    case image(ImageContent)
    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .text(value): value.protocolJSONValue()
        case let .image(value): value.protocolJSONValue()
        }
    }
}

public struct UsageCost: Sendable, Equatable, ProtocolJSONConvertible {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public let total: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double, total: Double) throws {
        guard [input, output, cacheRead, cacheWrite, total].allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw ProtocolModelError.invalid("Usage costs must be finite and nonnegative")
        }
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.total = total
    }

    public func protocolJSONValue() -> JSONValue {
        [
            "input": ProtocolEncoding.number(input), "output": ProtocolEncoding.number(output),
            "cacheRead": ProtocolEncoding.number(cacheRead), "cacheWrite": ProtocolEncoding.number(cacheWrite),
            "total": ProtocolEncoding.number(total),
        ]
    }
}

public struct Usage: Sendable, Equatable, ProtocolJSONConvertible {
    public let input: Int64
    public let output: Int64
    public let cacheRead: Int64
    public let cacheWrite: Int64
    public let reasoning: Int64?
    public let totalTokens: Int64
    public let cost: UsageCost

    public init(
        input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64,
        reasoning: Int64? = nil, totalTokens: Int64, cost: UsageCost
    ) throws {
        guard
            [input, output, cacheRead, cacheWrite, totalTokens].allSatisfy({
                $0 >= 0 && $0 <= javaScriptMaximumSafeInteger
            }),
            reasoning.map({ $0 >= 0 && $0 <= javaScriptMaximumSafeInteger }) ?? true
        else { throw ProtocolModelError.invalid("Usage token counts must be nonnegative safe integers") }
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.reasoning = reasoning
        self.totalTokens = totalTokens
        self.cost = cost
    }

    public func protocolJSONValue() -> JSONValue {
        ProtocolEncoding.object([
            ("input", .number(JSONNumber(input))), ("output", .number(JSONNumber(output))),
            ("cacheRead", .number(JSONNumber(cacheRead))), ("cacheWrite", .number(JSONNumber(cacheWrite))),
            ("reasoning", reasoning.map { .number(JSONNumber($0)) }),
            ("totalTokens", .number(JSONNumber(totalTokens))), ("cost", cost.protocolJSONValue()),
        ])
    }
}

internal enum ProtocolEncoding {
    static func object(_ fields: [(String, JSONValue?)]) -> JSONValue {
        var object = OrderedJSONObject()
        for (key, value) in fields { if let value { object[key] = value } }
        return .object(object)
    }

    static func number(_ value: Double) -> JSONValue { .number(try! JSONNumber(value)) }
}

internal enum ProtocolDecoding {
    static func literal(_ expected: String, _ value: JSONValue, path: String) throws {
        let actual = try StrictValue.string(value, path: path)
        guard actual == expected else {
            throw ValidationIssue(code: .invalidValue, path: path, message: "Expected \"\(expected)\"")
        }
    }

    static func nonemptyString(_ value: JSONValue, path: String) throws -> String {
        try StrictValue.string(value, path: path, nonempty: true)
    }

    static func nonnegativeNumber(_ value: JSONValue, path: String) throws -> Double {
        let number = try StrictValue.finiteNumber(value, path: path)
        guard number >= 0 else {
            throw ValidationIssue(code: .outOfRange, path: path, message: "Number must be nonnegative")
        }
        return number
    }

    static func rawEnum<Value: RawRepresentable>(
        _ type: Value.Type,
        value: JSONValue,
        path: String
    ) throws -> Value where Value.RawValue == String {
        let raw = try StrictValue.string(value, path: path)
        guard let result = Value(rawValue: raw) else {
            throw ValidationIssue(code: .invalidValue, path: path, message: "Unknown value \"\(raw)\"")
        }
        return result
    }

    static func array<Value>(
        _ value: JSONValue,
        path: String,
        minimumCount: Int = 0,
        decode: (JSONValue, String) throws -> Value
    ) throws -> [Value] {
        let values = try StrictValue.array(value, path: path)
        guard values.count >= minimumCount else {
            throw ValidationIssue(code: .outOfRange, path: path, message: "Array is too short")
        }
        return try values.enumerated().map { try decode($0.element, "\(path)[\($0.offset)]") }
    }

    static func validateJSONValue(_ value: JSONValue, path: String = "$") throws {
        switch value {
        case .null, .bool, .string: break
        case let .number(number):
            guard number.doubleValue.isFinite, !number.isInteger || number.isJavaScriptSafeInteger else {
                throw ValidationIssue(code: .outOfRange, path: path, message: "JSON number is not protocol-safe")
            }
        case let .array(values):
            for (index, value) in values.enumerated() { try validateJSONValue(value, path: "\(path)[\(index)]") }
        case let .object(object):
            for entry in object { try validateJSONValue(entry.value, path: "\(path).\(entry.key)") }
        }
    }
}
