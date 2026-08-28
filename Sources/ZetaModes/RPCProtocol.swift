import Foundation
import ZetaCore

public enum RPCCommandName: String, CaseIterable, Sendable {
    case prompt
    case steer
    case followUp = "follow_up"
    case abort
    case clearQueue = "clear_queue"
    case newSession = "new_session"
    case getState = "get_state"
    case setModel = "set_model"
    case cycleModel = "cycle_model"
    case getAvailableModels = "get_available_models"
    case setThinkingLevel = "set_thinking_level"
    case cycleThinkingLevel = "cycle_thinking_level"
    case getAvailableThinkingLevels = "get_available_thinking_levels"
    case setSteeringMode = "set_steering_mode"
    case setFollowUpMode = "set_follow_up_mode"
    case compact
    case setAutoCompaction = "set_auto_compaction"
    case setAutoRetry = "set_auto_retry"
    case abortRetry = "abort_retry"
    case bash
    case abortBash = "abort_bash"
    case getSessionStats = "get_session_stats"
    case exportHTML = "export_html"
    case switchSession = "switch_session"
    case fork
    case clone
    case getForkMessages = "get_fork_messages"
    case getEntries = "get_entries"
    case getTree = "get_tree"
    case getLastAssistantText = "get_last_assistant_text"
    case setSessionName = "set_session_name"
    case getMessages = "get_messages"
    case getCommands = "get_commands"
}

public struct StrictRPCRequest: Sendable, Equatable {
    public var id: String?
    public var command: RPCCommandName
    public var fields: OrderedJSONObject

    public init(
        id: String? = nil,
        command: RPCCommandName,
        fields: OrderedJSONObject = [:]
    ) {
        self.id = id
        self.command = command
        self.fields = fields
    }

    public static func decode(_ data: Data) throws -> StrictRPCRequest {
        let value = try OrderedJSON.decode(data)
        var reader = try StrictObjectReader(value)
        let id = try reader.optional("id").map {
            try StrictValue.string($0, nonempty: true)
        }
        let raw = try StrictValue.string(reader.required("type"))
        guard let command = RPCCommandName(rawValue: raw) else {
            throw RPCProtocolError.unknownCommand(raw)
        }
        var fields = OrderedJSONObject()
        for key in reader.remainingKeys {
            if let value = reader.optional(key) { fields[key] = value }
        }
        try reader.finish()
        return StrictRPCRequest(id: id, command: command, fields: fields)
    }

    public func encoded() -> Data {
        var object = fields
        object["type"] = .string(command.rawValue)
        if let id { object["id"] = .string(id) }
        return OrderedJSON.encode(.object(object))
    }
}

public struct StrictRPCResponse: Sendable, Equatable {
    public var id: String?
    public var command: RPCCommandName
    public var success: Bool
    public var data: JSONValue?
    public var error: String?

    public init(
        id: String?,
        command: RPCCommandName,
        success: Bool,
        data: JSONValue? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.command = command
        self.success = success
        self.data = data
        self.error = error
    }

    public func encodedLine() -> Data {
        var object: OrderedJSONObject = [
            "type": "response",
            "command": .string(command.rawValue),
            "success": .bool(success),
        ]
        if let id { object["id"] = .string(id) }
        if let data { object["data"] = data }
        if let error { object["error"] = .string(error) }
        var output = OrderedJSON.encode(.object(object))
        output.append(0x0A)
        return output
    }
}

public enum RPCUIRequest: Sendable, Equatable {
    case select(id: String, title: String, options: [String])
    case confirm(id: String, title: String, message: String)
    case input(id: String, title: String, placeholder: String?)
    case editor(id: String, title: String, text: String)
    case notify(message: String, level: String)
    case setStatus(key: String, value: String?)
    case setWidget(key: String, lines: [String]?)
    case setTitle(String)
    case setEditorText(String)
}

public enum RPCProtocolError: Error, LocalizedError, Sendable {
    case invalidType
    case unknownCommand(String)

    public var errorDescription: String? {
        switch self {
        case .invalidType: "RPC record is not a request"
        case .unknownCommand(let command): "Unknown RPC command: \(command)"
        }
    }
}
