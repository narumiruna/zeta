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
        var discriminator = try StrictObjectReader(value)
        let raw = try StrictValue.string(discriminator.required("type"))
        guard let command = RPCCommandName(rawValue: raw) else {
            throw RPCProtocolError.unknownCommand(raw)
        }
        guard case .object(let object) = try schema(for: command).validate(value) else {
            throw RPCProtocolError.invalidType
        }
        let id: String?
        if let value = object["id"] {
            id = try StrictValue.string(value, path: "$.id", nonempty: true)
        } else {
            id = nil
        }
        var fields = OrderedJSONObject()
        for entry in object where entry.key != "id" && entry.key != "type" {
            try fields.append(key: entry.key, value: entry.value)
        }
        return StrictRPCRequest(id: id, command: command, fields: fields)
    }

    private static func schema(for command: RPCCommandName) -> JSONSchema {
        var properties = [
            JSONSchemaProperty("id", .string(minLength: 1), required: false),
            JSONSchemaProperty("type", .enumeration([.string(command.rawValue)])),
        ]
        func field(
            _ name: String,
            _ schema: JSONSchema,
            required: Bool = true
        ) -> JSONSchemaProperty {
            JSONSchemaProperty(name, schema, required: required)
        }
        let imageSchema = JSONSchema.object(
            properties: [
                field("type", .enumeration(["image"])),
                field("data", .string(minLength: 1)),
                field("mimeType", .string(minLength: 1)),
            ],
            additionalProperties: .forbidden
        )
        switch command {
        case .prompt:
            properties += [
                field("message", .string()),
                field("images", .array(items: imageSchema), required: false),
                field(
                    "streamingBehavior",
                    .enumeration(["steer", "followUp"]),
                    required: false
                ),
            ]
        case .steer, .followUp:
            properties += [
                field("message", .string()),
                field("images", .array(items: imageSchema), required: false),
            ]
        case .newSession:
            properties.append(field("parentSession", .string(), required: false))
        case .setModel:
            properties += [field("provider", .string()), field("modelId", .string())]
        case .setThinkingLevel:
            properties.append(
                field(
                    "level",
                    .enumeration(
                        ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
                    )
                )
            )
        case .setSteeringMode, .setFollowUpMode:
            properties.append(
                field("mode", .enumeration(["all", "one-at-a-time"]))
            )
        case .compact:
            properties.append(field("customInstructions", .string(), required: false))
        case .setAutoCompaction, .setAutoRetry:
            properties.append(field("enabled", .boolean))
        case .bash:
            properties += [
                field("command", .string()),
                field("excludeFromContext", .boolean, required: false),
            ]
        case .exportHTML:
            properties.append(field("outputPath", .string(), required: false))
        case .switchSession:
            properties.append(field("sessionPath", .string()))
        case .fork:
            properties.append(field("entryId", .string()))
        case .getEntries:
            properties.append(field("since", .string(), required: false))
        case .setSessionName:
            properties.append(field("name", .string()))
        case .abort, .clearQueue, .getState, .cycleModel,
            .getAvailableModels, .cycleThinkingLevel,
            .getAvailableThinkingLevels, .abortRetry, .abortBash,
            .getSessionStats, .clone, .getForkMessages, .getTree,
            .getLastAssistantText, .getMessages, .getCommands:
            break
        }
        return .object(properties: properties, additionalProperties: .forbidden)
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
