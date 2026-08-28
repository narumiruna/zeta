import Foundation
import ZetaCore

public struct SessionMetadata: Sendable, Equatable, ProtocolJSONConvertible {
    public let id: String
    public let createdAt: Int64
    public let updatedAt: Int64?
    public let parentSessionID: String?
    public let sessionName: String?
    public let cwd: String?

    public init(
        id: String, createdAt: Int64, updatedAt: Int64? = nil,
        parentSessionID: String? = nil, sessionName: String? = nil, cwd: String? = nil
    ) throws {
        guard !id.isEmpty, createdAt >= 0, createdAt <= javaScriptMaximumSafeInteger,
            updatedAt.map({ $0 >= 0 && $0 <= javaScriptMaximumSafeInteger }) ?? true,
            parentSessionID.map({ !$0.isEmpty }) ?? true,
            cwd.map({ !$0.isEmpty }) ?? true
        else { throw ProtocolModelError.invalid("Invalid session metadata") }
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.parentSessionID = parentSessionID
        self.sessionName = sessionName
        self.cwd = cwd
    }

    public func protocolJSONValue() -> JSONValue {
        ProtocolEncoding.object([
            ("id", .string(id)), ("createdAt", .number(JSONNumber(createdAt))),
            ("updatedAt", updatedAt.map { .number(JSONNumber($0)) }),
            ("parentSessionId", parentSessionID.map(JSONValue.string)),
            ("sessionName", sessionName.map(JSONValue.string)), ("cwd", cwd.map(JSONValue.string)),
        ])
    }

    static func decode(_ value: JSONValue, path: String) throws -> SessionMetadata {
        var object = try StrictObjectReader(value, path: path)
        let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: object.childPath("id"))
        let createdAt = try StrictValue.safeInteger(
            object.required("createdAt"), path: object.childPath("createdAt"), minimum: 0)
        let updatedAtValue = object.optional("updatedAt")
        let updatedAt = try updatedAtValue.map {
            try StrictValue.safeInteger($0, path: "\(path).updatedAt", minimum: 0)
        }
        let parentValue = object.optional("parentSessionId")
        let parent = try parentValue.map { try ProtocolDecoding.nonemptyString($0, path: "\(path).parentSessionId") }
        let nameValue = object.optional("sessionName")
        let name = try nameValue.map { try StrictValue.string($0, path: "\(path).sessionName") }
        let cwdValue = object.optional("cwd")
        let cwd = try cwdValue.map { try ProtocolDecoding.nonemptyString($0, path: "\(path).cwd") }
        try object.finish()
        return try SessionMetadata(
            id: id, createdAt: createdAt, updatedAt: updatedAt, parentSessionID: parent, sessionName: name, cwd: cwd)
    }
}

public struct SessionSnapshot: Sendable, Equatable, ProtocolJSONConvertible {
    public let id: String
    public let name: String?
    public let cwd: String
    public let createdAt: Int64
    public let updatedAt: Int64
    public let phase: SessionPhase
    public let model: ModelReference
    public let thinkingLevel: ThinkingLevel
    public let attached: Bool
    public let locked: Bool
    public let revision: Int64
    public let transcript: [TranscriptItem]
    public let queuedSteer: [UserTranscriptItem]
    public let queuedSteerCount: Int64

    public init(
        id: String, name: String? = nil, cwd: String, createdAt: Int64, updatedAt: Int64,
        phase: SessionPhase, model: ModelReference, thinkingLevel: ThinkingLevel,
        attached: Bool, locked: Bool, revision: Int64, transcript: [TranscriptItem],
        queuedSteer: [UserTranscriptItem], queuedSteerCount: Int64
    ) throws {
        guard !id.isEmpty, !cwd.isEmpty,
            [createdAt, updatedAt, revision, queuedSteerCount].allSatisfy({
                $0 >= 0 && $0 <= javaScriptMaximumSafeInteger
            })
        else { throw ProtocolModelError.invalid("Invalid session snapshot") }
        self.id = id
        self.name = name
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.phase = phase
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.attached = attached
        self.locked = locked
        self.revision = revision
        self.transcript = transcript
        self.queuedSteer = queuedSteer
        self.queuedSteerCount = queuedSteerCount
    }

    public func protocolJSONValue() -> JSONValue {
        ProtocolEncoding.object([
            ("id", .string(id)), ("name", name.map(JSONValue.string)), ("cwd", .string(cwd)),
            ("createdAt", .number(JSONNumber(createdAt))), ("updatedAt", .number(JSONNumber(updatedAt))),
            ("phase", .string(phase.rawValue)), ("model", model.protocolJSONValue()),
            ("thinkingLevel", .string(thinkingLevel.rawValue)), ("attached", .bool(attached)),
            ("locked", .bool(locked)), ("revision", .number(JSONNumber(revision))),
            ("transcript", .array(transcript.map { $0.protocolJSONValue() })),
            ("queuedSteer", .array(queuedSteer.map { $0.protocolJSONValue() })),
            ("queuedSteerCount", .number(JSONNumber(queuedSteerCount))),
        ])
    }

    static func decode(_ value: JSONValue, path: String) throws -> SessionSnapshot {
        var object = try StrictObjectReader(value, path: path)
        let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: object.childPath("id"))
        let nameValue = object.optional("name")
        let name = try nameValue.map { try StrictValue.string($0, path: "\(path).name") }
        let cwd = try ProtocolDecoding.nonemptyString(object.required("cwd"), path: object.childPath("cwd"))
        let created = try StrictValue.safeInteger(
            object.required("createdAt"), path: object.childPath("createdAt"), minimum: 0)
        let updated = try StrictValue.safeInteger(
            object.required("updatedAt"), path: object.childPath("updatedAt"), minimum: 0)
        let phase = try ProtocolDecoding.rawEnum(
            SessionPhase.self, value: object.required("phase"), path: object.childPath("phase"))
        let model = try ModelReference.decode(object.required("model"), path: object.childPath("model"))
        let level = try ProtocolDecoding.rawEnum(
            ThinkingLevel.self, value: object.required("thinkingLevel"), path: object.childPath("thinkingLevel"))
        let attached = try StrictValue.boolean(object.required("attached"), path: object.childPath("attached"))
        let locked = try StrictValue.boolean(object.required("locked"), path: object.childPath("locked"))
        let revision = try StrictValue.safeInteger(
            object.required("revision"), path: object.childPath("revision"), minimum: 0)
        let transcript = try ProtocolDecoding.array(
            object.required("transcript"), path: object.childPath("transcript"), decode: TranscriptItem.decode)
        let steer = try ProtocolDecoding.array(
            object.required("queuedSteer"), path: object.childPath("queuedSteer"), decode: TranscriptDecoders.user)
        let steerCount = try StrictValue.safeInteger(
            object.required("queuedSteerCount"), path: object.childPath("queuedSteerCount"), minimum: 0)
        try object.finish()
        return try SessionSnapshot(
            id: id, name: name, cwd: cwd, createdAt: created, updatedAt: updated, phase: phase,
            model: model, thinkingLevel: level, attached: attached, locked: locked, revision: revision,
            transcript: transcript, queuedSteer: steer, queuedSteerCount: steerCount
        )
    }
}

public struct ServerSnapshot: Sendable, Equatable, ProtocolJSONConvertible {
    public let serverID: String
    public let revision: Int64
    public let sessions: [SessionMetadata]
    public let models: [ModelMetadata]

    public init(serverID: String, revision: Int64, sessions: [SessionMetadata], models: [ModelMetadata]) throws {
        guard !serverID.isEmpty, revision >= 0, revision <= javaScriptMaximumSafeInteger else {
            throw ProtocolModelError.invalid("Invalid server snapshot")
        }
        self.serverID = serverID
        self.revision = revision
        self.sessions = sessions
        self.models = models
    }

    public func protocolJSONValue() -> JSONValue {
        [
            "serverId": .string(serverID), "protocolVersion": .number(JSONNumber(Int64(protocolVersion))),
            "revision": .number(JSONNumber(revision)),
            "sessions": .array(sessions.map { $0.protocolJSONValue() }),
            "models": .array(models.map { $0.protocolJSONValue() }),
        ]
    }

    static func decode(_ value: JSONValue, path: String) throws -> ServerSnapshot {
        var object = try StrictObjectReader(value, path: path)
        let id = try ProtocolDecoding.nonemptyString(object.required("serverId"), path: object.childPath("serverId"))
        let version = try StrictValue.safeInteger(
            object.required("protocolVersion"), path: object.childPath("protocolVersion"), minimum: 0)
        guard version == protocolVersion else {
            throw ValidationIssue(
                code: .invalidValue, path: object.childPath("protocolVersion"),
                message: "Unsupported server snapshot protocol version")
        }
        let revision = try StrictValue.safeInteger(
            object.required("revision"), path: object.childPath("revision"), minimum: 0)
        let sessions = try ProtocolDecoding.array(
            object.required("sessions"), path: object.childPath("sessions"), decode: SessionMetadata.decode)
        let models = try ProtocolDecoding.array(
            object.required("models"), path: object.childPath("models"), decode: ModelMetadata.decode)
        try object.finish()
        return try ServerSnapshot(serverID: id, revision: revision, sessions: sessions, models: models)
    }
}

public enum ProtocolErrorCode: String, Sendable, Codable, CaseIterable {
    case version, busy
    case sessionLocked = "session_locked"
    case notFound = "not_found"
    case invalidRequest = "invalid_request"
    case notImplemented = "not_implemented"
    case internalError = "internal_error"
}

public struct ProtocolErrorValue: Sendable, Equatable, ProtocolJSONConvertible {
    public let code: ProtocolErrorCode
    public let message: String
    public let details: JSONValue?

    public init(code: ProtocolErrorCode, message: String, details: JSONValue? = nil) throws {
        if let details { try ProtocolDecoding.validateJSONValue(details) }
        self.code = code
        self.message = message
        self.details = details
    }

    public func protocolJSONValue() -> JSONValue {
        ProtocolEncoding.object([("code", .string(code.rawValue)), ("message", .string(message)), ("details", details)])
    }

    static func decode(_ value: JSONValue, path: String) throws -> ProtocolErrorValue {
        var object = try StrictObjectReader(value, path: path)
        let code = try ProtocolDecoding.rawEnum(
            ProtocolErrorCode.self, value: object.required("code"), path: object.childPath("code"))
        let message = try StrictValue.string(object.required("message"), path: object.childPath("message"))
        let details = object.optional("details")
        if let details { try ProtocolDecoding.validateJSONValue(details, path: "\(path).details") }
        try object.finish()
        return try ProtocolErrorValue(code: code, message: message, details: details)
    }
}

public typealias ProtocolError = ProtocolErrorValue

public struct CreateCommandOptions: Sendable, Equatable {
    public let cwd: String?
    public let name: String?
    public let model: ModelReference?
    public let thinkingLevel: ThinkingLevel?

    public init(
        cwd: String? = nil, name: String? = nil, model: ModelReference? = nil, thinkingLevel: ThinkingLevel? = nil
    ) throws {
        guard cwd.map({ !$0.isEmpty }) ?? true else { throw ProtocolModelError.invalid("Create cwd must not be empty") }
        self.cwd = cwd
        self.name = name
        self.model = model
        self.thinkingLevel = thinkingLevel
    }
}

public enum CommandName: String, Sendable, Codable, CaseIterable {
    case list, create, attach, detach, prompt, steer, abort
    case setModel = "set_model"
    case setThinking = "set_thinking"
}

public enum Command: Sendable, Equatable, ProtocolJSONConvertible {
    case list
    case create(CreateCommandOptions)
    case attach(sessionID: String)
    case detach(sessionID: String)
    case prompt(sessionID: String, text: String)
    case steer(sessionID: String, text: String)
    case abort(sessionID: String)
    case setModel(sessionID: String, model: ModelReference)
    case setThinking(sessionID: String, thinkingLevel: ThinkingLevel)

    public var name: CommandName {
        switch self {
        case .list: .list
        case .create: .create
        case .attach: .attach
        case .detach: .detach
        case .prompt: .prompt
        case .steer: .steer
        case .abort: .abort
        case .setModel: .setModel
        case .setThinking: .setThinking
        }
    }

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case .list: return ["command": "list"]
        case let .create(options):
            return ProtocolEncoding.object([
                ("command", "create"), ("cwd", options.cwd.map(JSONValue.string)),
                ("name", options.name.map(JSONValue.string)), ("model", options.model?.protocolJSONValue()),
                ("thinkingLevel", options.thinkingLevel.map { .string($0.rawValue) }),
            ])
        case let .attach(id): return ["command": "attach", "sessionId": .string(id)]
        case let .detach(id): return ["command": "detach", "sessionId": .string(id)]
        case let .prompt(id, text): return ["command": "prompt", "sessionId": .string(id), "text": .string(text)]
        case let .steer(id, text): return ["command": "steer", "sessionId": .string(id), "text": .string(text)]
        case let .abort(id): return ["command": "abort", "sessionId": .string(id)]
        case let .setModel(id, model):
            return ["command": "set_model", "sessionId": .string(id), "model": model.protocolJSONValue()]
        case let .setThinking(id, level):
            return ["command": "set_thinking", "sessionId": .string(id), "thinkingLevel": .string(level.rawValue)]
        }
    }

    static func decode(_ value: JSONValue, path: String) throws -> Command {
        guard case let .object(raw) = value, let commandValue = raw["command"] else {
            throw ValidationIssue(code: .missingProperty, path: "\(path).command", message: "Missing command")
        }
        let name = try ProtocolDecoding.rawEnum(CommandName.self, value: commandValue, path: "\(path).command")
        var object = try StrictObjectReader(value, path: path)
        _ = try object.required("command")
        func sessionID(_ object: inout StrictObjectReader) throws -> String {
            try ProtocolDecoding.nonemptyString(object.required("sessionId"), path: "\(path).sessionId")
        }
        let result: Command
        switch name {
        case .list: result = .list
        case .create:
            let cwdValue = object.optional("cwd")
            let cwd = try cwdValue.map { try ProtocolDecoding.nonemptyString($0, path: "\(path).cwd") }
            let nameValue = object.optional("name")
            let sessionName = try nameValue.map { try StrictValue.string($0, path: "\(path).name") }
            let modelValue = object.optional("model")
            let model = try modelValue.map { try ModelReference.decode($0, path: "\(path).model") }
            let levelValue = object.optional("thinkingLevel")
            let level = try levelValue.map {
                try ProtocolDecoding.rawEnum(ThinkingLevel.self, value: $0, path: "\(path).thinkingLevel")
            }
            result = .create(try .init(cwd: cwd, name: sessionName, model: model, thinkingLevel: level))
        case .attach: result = .attach(sessionID: try sessionID(&object))
        case .detach: result = .detach(sessionID: try sessionID(&object))
        case .prompt:
            let id = try sessionID(&object)
            result = .prompt(sessionID: id, text: try StrictValue.string(object.required("text"), path: "\(path).text"))
        case .steer:
            let id = try sessionID(&object)
            result = .steer(sessionID: id, text: try StrictValue.string(object.required("text"), path: "\(path).text"))
        case .abort: result = .abort(sessionID: try sessionID(&object))
        case .setModel:
            let id = try sessionID(&object)
            result = .setModel(
                sessionID: id, model: try ModelReference.decode(object.required("model"), path: "\(path).model"))
        case .setThinking:
            let id = try sessionID(&object)
            result = .setThinking(
                sessionID: id,
                thinkingLevel: try ProtocolDecoding.rawEnum(
                    ThinkingLevel.self, value: object.required("thinkingLevel"), path: "\(path).thinkingLevel")
            )
        }
        try object.finish()
        return result
    }
}

public enum CommandResult: Sendable, Equatable, ProtocolJSONConvertible {
    case list([SessionMetadata])
    case create(SessionSnapshot)
    case attach(SessionSnapshot)
    case detach(sessionID: String)
    case prompt(SessionSnapshot)
    case steer(SessionSnapshot)
    case abort(SessionSnapshot)
    case setModel(SessionSnapshot)
    case setThinking(SessionSnapshot)

    public var name: CommandName {
        switch self {
        case .list: .list
        case .create: .create
        case .attach: .attach
        case .detach: .detach
        case .prompt: .prompt
        case .steer: .steer
        case .abort: .abort
        case .setModel: .setModel
        case .setThinking: .setThinking
        }
    }

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .list(sessions):
            return ["command": "list", "sessions": .array(sessions.map { $0.protocolJSONValue() })]
        case let .detach(id): return ["command": "detach", "sessionId": .string(id)]
        case let .create(snapshot): return ["command": "create", "session": snapshot.protocolJSONValue()]
        case let .attach(snapshot): return ["command": "attach", "session": snapshot.protocolJSONValue()]
        case let .prompt(snapshot): return ["command": "prompt", "session": snapshot.protocolJSONValue()]
        case let .steer(snapshot): return ["command": "steer", "session": snapshot.protocolJSONValue()]
        case let .abort(snapshot): return ["command": "abort", "session": snapshot.protocolJSONValue()]
        case let .setModel(snapshot): return ["command": "set_model", "session": snapshot.protocolJSONValue()]
        case let .setThinking(snapshot): return ["command": "set_thinking", "session": snapshot.protocolJSONValue()]
        }
    }

    static func decode(_ value: JSONValue, path: String) throws -> CommandResult {
        guard case let .object(raw) = value, let commandValue = raw["command"] else {
            throw ValidationIssue(code: .missingProperty, path: "\(path).command", message: "Missing result command")
        }
        let name = try ProtocolDecoding.rawEnum(CommandName.self, value: commandValue, path: "\(path).command")
        var object = try StrictObjectReader(value, path: path)
        _ = try object.required("command")
        let result: CommandResult
        switch name {
        case .list:
            result = .list(
                try ProtocolDecoding.array(
                    object.required("sessions"), path: "\(path).sessions", decode: SessionMetadata.decode))
        case .detach:
            result = .detach(
                sessionID: try ProtocolDecoding.nonemptyString(object.required("sessionId"), path: "\(path).sessionId"))
        default:
            let snapshot = try SessionSnapshot.decode(object.required("session"), path: "\(path).session")
            switch name {
            case .create: result = .create(snapshot)
            case .attach: result = .attach(snapshot)
            case .prompt: result = .prompt(snapshot)
            case .steer: result = .steer(snapshot)
            case .abort: result = .abort(snapshot)
            case .setModel: result = .setModel(snapshot)
            case .setThinking: result = .setThinking(snapshot)
            case .list, .detach:
                throw ValidationIssue(
                    code: .invalidValue, path: "\(path).command", message: "Invalid snapshot result command")
            }
        }
        try object.finish()
        return result
    }
}

private enum TranscriptDecoders {
    static func user(_ value: JSONValue, _ path: String) throws -> UserTranscriptItem {
        guard case let .user(item) = try TranscriptItem.decode(value, path: path) else {
            throw ValidationIssue(code: .invalidValue, path: path, message: "Expected user transcript item")
        }
        return item
    }
}
