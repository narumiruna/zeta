import Foundation
import ZetaCore

public struct ClientHello: Sendable, Equatable, ProtocolJSONConvertible {
    public let version: Int64
    public init(version: Int64 = Int64(protocolVersion)) throws {
        guard version >= 0, version <= javaScriptMaximumSafeInteger else {
            throw ProtocolModelError.invalid("Client protocol version must be a nonnegative safe integer")
        }
        self.version = version
    }
    public func protocolJSONValue() -> JSONValue { ["type": "hello", "version": .number(JSONNumber(version))] }
}

public struct RequestEnvelope: Sendable, Equatable, ProtocolJSONConvertible {
    public let id: String
    public let request: Command
    public init(id: String, request: Command) throws {
        guard !id.isEmpty else { throw ProtocolModelError.invalid("Request id must not be empty") }
        self.id = id
        self.request = request
    }
    public func protocolJSONValue() -> JSONValue {
        ["type": "request", "id": .string(id), "request": request.protocolJSONValue()]
    }
}

public enum ClientMessage: Sendable, Equatable, ProtocolJSONConvertible {
    case hello(ClientHello)
    case request(RequestEnvelope)

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .hello(value): value.protocolJSONValue()
        case let .request(value): value.protocolJSONValue()
        }
    }
}

public struct ServerHello: Sendable, Equatable, ProtocolJSONConvertible {
    public let connectionID: String
    public let snapshot: ServerSnapshot
    public init(connectionID: String, snapshot: ServerSnapshot) throws {
        guard !connectionID.isEmpty else { throw ProtocolModelError.invalid("Connection id must not be empty") }
        self.connectionID = connectionID
        self.snapshot = snapshot
    }
    public func protocolJSONValue() -> JSONValue {
        [
            "type": "hello", "version": .number(JSONNumber(Int64(protocolVersion))),
            "connectionId": .string(connectionID), "snapshot": snapshot.protocolJSONValue(),
        ]
    }
}

public enum ServerEvent: Sendable, Equatable, ProtocolJSONConvertible {
    case serverSnapshot(ServerSnapshot)
    case sessionSnapshot(SessionSnapshot)
    case sessionProgress(sessionID: String, progress: TranscriptProgress)
    case sessionRemoved(sessionID: String)

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .serverSnapshot(snapshot):
            return ["type": "server_snapshot", "snapshot": snapshot.protocolJSONValue()]
        case let .sessionSnapshot(snapshot):
            return ["type": "session_snapshot", "snapshot": snapshot.protocolJSONValue()]
        case let .sessionProgress(id, progress):
            return ["type": "session_progress", "sessionId": .string(id), "progress": progress.protocolJSONValue()]
        case let .sessionRemoved(id): return ["type": "session_removed", "sessionId": .string(id)]
        }
    }
}

public enum ResponseEnvelope: Sendable, Equatable, ProtocolJSONConvertible {
    case success(id: String, result: CommandResult)
    case failure(id: String, error: ProtocolErrorValue)

    public var id: String {
        switch self {
        case let .success(id, _), let .failure(id, _): id
        }
    }

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .success(id, result):
            return ["type": "response", "id": .string(id), "ok": true, "result": result.protocolJSONValue()]
        case let .failure(id, error):
            return ["type": "response", "id": .string(id), "ok": false, "error": error.protocolJSONValue()]
        }
    }
}

public enum ServerMessage: Sendable, Equatable, ProtocolJSONConvertible {
    case hello(ServerHello)
    case helloError(ProtocolErrorValue)
    case response(ResponseEnvelope)
    case event(ServerEvent)

    public func protocolJSONValue() -> JSONValue {
        switch self {
        case let .hello(value): value.protocolJSONValue()
        case let .helloError(error): ["type": "hello_error", "error": error.protocolJSONValue()]
        case let .response(value): value.protocolJSONValue()
        case let .event(event): ["type": "event", "event": event.protocolJSONValue()]
        }
    }
}

public struct ProtocolValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public func parseClientMessage(_ value: JSONValue) throws -> ClientMessage {
    do {
        try ProtocolDecoding.validateJSONValue(value)
        guard case let .object(raw) = value, let typeValue = raw["type"] else {
            throw ValidationIssue(code: .missingProperty, path: "$.type", message: "Missing message type")
        }
        switch try StrictValue.string(typeValue, path: "$.type") {
        case "hello":
            var object = try StrictObjectReader(value)
            try ProtocolDecoding.literal("hello", object.required("type"), path: "$.type")
            let version = try StrictValue.safeInteger(object.required("version"), path: "$.version", minimum: 0)
            try object.finish()
            return .hello(try ClientHello(version: version))
        case "request":
            var object = try StrictObjectReader(value)
            try ProtocolDecoding.literal("request", object.required("type"), path: "$.type")
            let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: "$.id")
            let request = try Command.decode(object.required("request"), path: "$.request")
            try object.finish()
            return .request(try RequestEnvelope(id: id, request: request))
        default:
            throw ValidationIssue(code: .invalidValue, path: "$.type", message: "Unknown client message type")
        }
    } catch {
        throw ProtocolValidationError("Invalid client protocol message")
    }
}

public func parseClientMessage(_ value: CBORValue) throws -> ClientMessage {
    do { return try parseClientMessage(value.jsonValue()) } catch let error as ProtocolValidationError {
        throw error
    } catch { throw ProtocolValidationError("Invalid client protocol message") }
}

public func parseServerMessage(_ value: JSONValue) throws -> ServerMessage {
    do {
        try ProtocolDecoding.validateJSONValue(value)
        guard case let .object(raw) = value, let typeValue = raw["type"] else {
            throw ValidationIssue(code: .missingProperty, path: "$.type", message: "Missing message type")
        }
        switch try StrictValue.string(typeValue, path: "$.type") {
        case "hello": return .hello(try decodeServerHello(value))
        case "hello_error":
            var object = try StrictObjectReader(value)
            try ProtocolDecoding.literal("hello_error", object.required("type"), path: "$.type")
            let error = try ProtocolErrorValue.decode(object.required("error"), path: "$.error")
            try object.finish()
            return .helloError(error)
        case "response": return .response(try decodeResponse(value))
        case "event":
            var object = try StrictObjectReader(value)
            try ProtocolDecoding.literal("event", object.required("type"), path: "$.type")
            let event = try decodeEvent(object.required("event"), path: "$.event")
            try object.finish()
            return .event(event)
        default:
            throw ValidationIssue(code: .invalidValue, path: "$.type", message: "Unknown server message type")
        }
    } catch {
        throw ProtocolValidationError("Invalid server protocol message")
    }
}

public func parseServerMessage(_ value: CBORValue) throws -> ServerMessage {
    do { return try parseServerMessage(value.jsonValue()) } catch let error as ProtocolValidationError {
        throw error
    } catch { throw ProtocolValidationError("Invalid server protocol message") }
}

private func decodeServerHello(_ value: JSONValue) throws -> ServerHello {
    var object = try StrictObjectReader(value)
    try ProtocolDecoding.literal("hello", object.required("type"), path: "$.type")
    let version = try StrictValue.safeInteger(object.required("version"), path: "$.version", minimum: 0)
    guard version == protocolVersion else {
        throw ValidationIssue(code: .invalidValue, path: "$.version", message: "Unsupported protocol version")
    }
    let connectionID = try ProtocolDecoding.nonemptyString(object.required("connectionId"), path: "$.connectionId")
    let snapshot = try ServerSnapshot.decode(object.required("snapshot"), path: "$.snapshot")
    try object.finish()
    return try ServerHello(connectionID: connectionID, snapshot: snapshot)
}

private func decodeResponse(_ value: JSONValue) throws -> ResponseEnvelope {
    var object = try StrictObjectReader(value)
    try ProtocolDecoding.literal("response", object.required("type"), path: "$.type")
    let id = try ProtocolDecoding.nonemptyString(object.required("id"), path: "$.id")
    let ok = try StrictValue.boolean(object.required("ok"), path: "$.ok")
    let response: ResponseEnvelope
    if ok {
        response = .success(id: id, result: try CommandResult.decode(object.required("result"), path: "$.result"))
    } else {
        response = .failure(id: id, error: try ProtocolErrorValue.decode(object.required("error"), path: "$.error"))
    }
    try object.finish()
    return response
}

private func decodeEvent(_ value: JSONValue, path: String) throws -> ServerEvent {
    guard case let .object(raw) = value, let typeValue = raw["type"] else {
        throw ValidationIssue(code: .missingProperty, path: "\(path).type", message: "Missing event type")
    }
    let type = try StrictValue.string(typeValue, path: "\(path).type")
    var object = try StrictObjectReader(value, path: path)
    _ = try object.required("type")
    let event: ServerEvent
    switch type {
    case "server_snapshot":
        event = .serverSnapshot(try ServerSnapshot.decode(object.required("snapshot"), path: "\(path).snapshot"))
    case "session_snapshot":
        event = .sessionSnapshot(try SessionSnapshot.decode(object.required("snapshot"), path: "\(path).snapshot"))
    case "session_progress":
        let id = try ProtocolDecoding.nonemptyString(object.required("sessionId"), path: "\(path).sessionId")
        event = .sessionProgress(
            sessionID: id,
            progress: try TranscriptProgress.decode(object.required("progress"), path: "\(path).progress"))
    case "session_removed":
        event = .sessionRemoved(
            sessionID: try ProtocolDecoding.nonemptyString(object.required("sessionId"), path: "\(path).sessionId"))
    default: throw ValidationIssue(code: .invalidValue, path: "\(path).type", message: "Unknown server event type")
    }
    try object.finish()
    return event
}

public func isSupportedProtocolVersion(_ version: Int64) -> Bool {
    version == protocolVersion
}

public final class ClientProtocolSequenceValidator: @unchecked Sendable {
    private let lock = NSLock()
    private var greeted = false

    public init() {}

    public func accept(_ message: ClientMessage) throws {
        lock.lock()
        defer { lock.unlock() }
        switch (greeted, message) {
        case (false, .hello): greeted = true
        case (false, .request): throw ProtocolValidationError("The first client message must be hello")
        case (true, .hello): throw ProtocolValidationError("Client hello must only be sent once")
        case (true, .request): break
        }
    }
}

public final class ServerProtocolSequenceValidator: @unchecked Sendable {
    private enum State { case waiting, active, rejected }
    private let lock = NSLock()
    private var state = State.waiting

    public init() {}

    public func accept(_ message: ServerMessage) throws {
        lock.lock()
        defer { lock.unlock() }
        switch (state, message) {
        case (.waiting, .hello): state = .active
        case (.waiting, .helloError): state = .rejected
        case (.waiting, _): throw ProtocolValidationError("The first server message must be hello or hello_error")
        case (.active, .response), (.active, .event): break
        case (.active, _): throw ProtocolValidationError("Server hello must only be sent once")
        case (.rejected, _): throw ProtocolValidationError("No messages may follow hello_error")
        }
    }
}
