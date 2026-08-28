import Foundation

public struct LFJSONLDecoder: Sendable {
    private var buffer = Data()
    public let maximumRecordBytes: Int

    public init(maximumRecordBytes: Int = 16 * 1_024 * 1_024) { self.maximumRecordBytes = maximumRecordBytes }

    public mutating func push(_ data: Data) throws -> [Data] {
        buffer.append(data)
        guard buffer.count <= maximumRecordBytes || buffer.contains(0x0A) else {
            throw JSONLFramingError.recordTooLarge
        }
        var output: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var record = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if record.last == 0x0D { record.removeLast() }
            guard record.count <= maximumRecordBytes else { throw JSONLFramingError.recordTooLarge }
            output.append(record)
        }
        return output
    }

    public mutating func finish() throws -> [Data] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        if buffer.last == 0x0D { buffer.removeLast() }
        guard buffer.count <= maximumRecordBytes else { throw JSONLFramingError.recordTooLarge }
        return [buffer]
    }
}

public enum JSONLFramingError: Error, Sendable { case recordTooLarge }

public func serializeJSONLine<T: Encodable>(_ value: T) throws -> Data {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    return data
}

public struct RPCRequest: Codable, Sendable, Equatable {
    public var id: String?
    public var type: String
    public var command: String
    public var arguments: Data?
    public init(id: String? = nil, command: String, arguments: Data? = nil) {
        self.id = id
        self.type = "request"
        self.command = command
        self.arguments = arguments
    }
}

public struct RPCResponse: Codable, Sendable, Equatable {
    public var id: String?
    public var type = "response"
    public var command: String
    public var success: Bool
    public var data: Data?
    public var error: String?
    public init(id: String?, command: String, success: Bool, data: Data? = nil, error: String? = nil) {
        self.id = id
        self.command = command
        self.success = success
        self.data = data
        self.error = error
    }
}

public actor RPCEngine {
    public typealias Handler = @Sendable (RPCRequest) async throws -> Data?
    private var handlers: [String: Handler] = [:]
    private let write: @Sendable (Data) async -> Void

    public init(write: @escaping @Sendable (Data) async -> Void) { self.write = write }
    public func register(_ command: String, handler: @escaping Handler) { handlers[command] = handler }

    public nonisolated func accept(_ request: RPCRequest) {
        Task { await self.handle(request) }
    }

    private func handle(_ request: RPCRequest) async {
        let response: RPCResponse
        do {
            guard request.type == "request", let handler = handlers[request.command] else {
                throw RPCError.unknownCommand(request.command)
            }
            response = RPCResponse(
                id: request.id, command: request.command, success: true, data: try await handler(request))
        } catch {
            response = RPCResponse(
                id: request.id, command: request.command, success: false, error: String(describing: error))
        }
        if let data = try? serializeJSONLine(response) { await write(data) }
    }
}

public enum RPCError: Error, LocalizedError, Sendable {
    case unknownCommand(String)
    public var errorDescription: String? {
        if case .unknownCommand(let value) = self { "Unknown RPC command: \(value)" } else { nil }
    }
}
