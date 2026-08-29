import Foundation
import ZetaAI
import ZetaCore

public let currentCodingSessionVersion = 3

public struct SessionHeader: Codable, Sendable, Equatable {
    public let type = "session"
    public var version: Int?
    public var id: String
    public var timestamp: String
    public var cwd: String
    public var parentSession: String?

    public init(
        version: Int? = currentCodingSessionVersion, id: String, timestamp: String, cwd: String,
        parentSession: String? = nil
    ) {
        self.version = version
        self.id = id
        self.timestamp = timestamp
        self.cwd = cwd
        self.parentSession = parentSession
    }
    private enum CodingKeys: String, CodingKey { case type, version, id, timestamp, cwd, parentSession }
}

public struct SessionEntryBase: Codable, Sendable, Equatable {
    public var id: String
    public var parentId: String?
    public var timestamp: String

    public init(id: String, parentId: String?, timestamp: String) {
        self.id = id
        self.parentId = parentId
        self.timestamp = timestamp
    }
}

public enum SessionEntry: Sendable, Equatable {
    case message(SessionEntryBase, Message)
    case thinkingLevelChange(SessionEntryBase, ThinkingLevel)
    case modelChange(SessionEntryBase, provider: String, modelID: String)
    case compaction(
        SessionEntryBase, summary: String, firstKeptEntryID: String, tokensBefore: Int, details: JSONValue?,
        usage: Usage?, fromHook: Bool?)
    case branchSummary(
        SessionEntryBase, fromID: String, summary: String, details: JSONValue?, usage: Usage?, fromHook: Bool?)
    case custom(SessionEntryBase, customType: String, data: JSONValue?)
    case customMessage(
        SessionEntryBase, customType: String, content: [ContentBlock], details: JSONValue?, display: Bool)
    case label(SessionEntryBase, targetID: String, label: String?)
    case sessionInfo(SessionEntryBase, name: String?)

    public var base: SessionEntryBase {
        switch self {
        case .message(let value, _), .thinkingLevelChange(let value, _), .modelChange(let value, _, _),
            .compaction(let value, _, _, _, _, _, _), .branchSummary(let value, _, _, _, _, _),
            .custom(let value, _, _), .customMessage(let value, _, _, _, _), .label(let value, _, _),
            .sessionInfo(let value, _):
            value
        }
    }

    public var type: String {
        switch self {
        case .message: "message"
        case .thinkingLevelChange: "thinking_level_change"
        case .modelChange: "model_change"
        case .compaction: "compaction"
        case .branchSummary: "branch_summary"
        case .custom: "custom"
        case .customMessage: "custom_message"
        case .label: "label"
        case .sessionInfo: "session_info"
        }
    }
}

extension SessionEntry: Codable {
    private enum Keys: String, CodingKey {
        case type, id, parentId, timestamp, message, thinkingLevel, provider, modelId, summary, firstKeptEntryId,
            tokensBefore, details, usage, fromHook, fromId, customType, data, content, display, targetId, label, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let base = SessionEntryBase(
            id: try c.decode(String.self, forKey: .id), parentId: try c.decodeIfPresent(String.self, forKey: .parentId),
            timestamp: try c.decode(String.self, forKey: .timestamp))
        switch try c.decode(String.self, forKey: .type) {
        case "message": self = .message(base, try c.decode(Message.self, forKey: .message))
        case "thinking_level_change":
            self = .thinkingLevelChange(base, try c.decode(ThinkingLevel.self, forKey: .thinkingLevel))
        case "model_change":
            self = .modelChange(
                base, provider: try c.decode(String.self, forKey: .provider),
                modelID: try c.decode(String.self, forKey: .modelId))
        case "compaction":
            self = .compaction(
                base, summary: try c.decode(String.self, forKey: .summary),
                firstKeptEntryID: try c.decode(String.self, forKey: .firstKeptEntryId),
                tokensBefore: try c.decode(Int.self, forKey: .tokensBefore),
                details: try c.decodeIfPresent(JSONValue.self, forKey: .details),
                usage: try c.decodeIfPresent(Usage.self, forKey: .usage),
                fromHook: try c.decodeIfPresent(Bool.self, forKey: .fromHook))
        case "branch_summary":
            self = .branchSummary(
                base, fromID: try c.decode(String.self, forKey: .fromId),
                summary: try c.decode(String.self, forKey: .summary),
                details: try c.decodeIfPresent(JSONValue.self, forKey: .details),
                usage: try c.decodeIfPresent(Usage.self, forKey: .usage),
                fromHook: try c.decodeIfPresent(Bool.self, forKey: .fromHook))
        case "custom":
            self = .custom(
                base, customType: try c.decode(String.self, forKey: .customType),
                data: try c.decodeIfPresent(JSONValue.self, forKey: .data))
        case "custom_message":
            self = .customMessage(
                base, customType: try c.decode(String.self, forKey: .customType),
                content: try c.decode([ContentBlock].self, forKey: .content),
                details: try c.decodeIfPresent(JSONValue.self, forKey: .details),
                display: try c.decode(Bool.self, forKey: .display))
        case "label":
            self = .label(
                base, targetID: try c.decode(String.self, forKey: .targetId),
                label: try c.decodeIfPresent(String.self, forKey: .label))
        case "session_info": self = .sessionInfo(base, name: try c.decodeIfPresent(String.self, forKey: .name))
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown session entry")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(type, forKey: .type)
        try c.encode(base.id, forKey: .id)
        try c.encodeIfPresent(base.parentId, forKey: .parentId)
        if base.parentId == nil { try c.encodeNil(forKey: .parentId) }
        try c.encode(base.timestamp, forKey: .timestamp)
        switch self {
        case .message(_, let value): try c.encode(value, forKey: .message)
        case .thinkingLevelChange(_, let value): try c.encode(value, forKey: .thinkingLevel)
        case .modelChange(_, let provider, let model):
            try c.encode(provider, forKey: .provider)
            try c.encode(model, forKey: .modelId)
        case .compaction(_, let summary, let kept, let tokens, let details, let usage, let hook):
            try c.encode(summary, forKey: .summary)
            try c.encode(kept, forKey: .firstKeptEntryId)
            try c.encode(tokens, forKey: .tokensBefore)
            try c.encodeIfPresent(details, forKey: .details)
            try c.encodeIfPresent(usage, forKey: .usage)
            try c.encodeIfPresent(hook, forKey: .fromHook)
        case .branchSummary(_, let from, let summary, let details, let usage, let hook):
            try c.encode(from, forKey: .fromId)
            try c.encode(summary, forKey: .summary)
            try c.encodeIfPresent(details, forKey: .details)
            try c.encodeIfPresent(usage, forKey: .usage)
            try c.encodeIfPresent(hook, forKey: .fromHook)
        case .custom(_, let type, let data):
            try c.encode(type, forKey: .customType)
            try c.encodeIfPresent(data, forKey: .data)
        case .customMessage(_, let type, let content, let details, let display):
            try c.encode(type, forKey: .customType)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(details, forKey: .details)
            try c.encode(display, forKey: .display)
        case .label(_, let target, let label):
            try c.encode(target, forKey: .targetId)
            try c.encodeIfPresent(label, forKey: .label)
        case .sessionInfo(_, let name): try c.encodeIfPresent(name, forKey: .name)
        }
    }
}

public struct SessionContext: Sendable, Equatable {
    public var messages: [Message]
    public var thinkingLevel: ThinkingLevel
    public var model: (provider: String, modelID: String)?

    public static func == (lhs: SessionContext, rhs: SessionContext) -> Bool {
        lhs.messages == rhs.messages && lhs.thinkingLevel == rhs.thinkingLevel
            && lhs.model?.provider == rhs.model?.provider && lhs.model?.modelID == rhs.model?.modelID
    }
}
