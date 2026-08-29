import Foundation

public protocol WebSocketConnection: Sendable {
    var identifier: UUID { get }
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

public typealias WebSocketFactory =
    @Sendable (
        _ url: URL,
        _ headers: [String: String]
    ) async throws -> any WebSocketConnection

public struct URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    public let identifier = UUID()
    private let task: URLSessionWebSocketTask

    public init(task: URLSessionWebSocketTask) { self.task = task }

    public func send(_ data: Data) async throws {
        try await task.send(.data(data))
    }

    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data): data
        case .string(let string): Data(string.utf8)
        @unknown default: throw ProviderError.invalidResponse("Unknown WebSocket message")
        }
    }

    public func close() async {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

public actor CodexWebSocketPool {
    public struct Key: Hashable, Sendable {
        public var account: String
        public var sessionID: String
        public init(account: String, sessionID: String) {
            self.account = account
            self.sessionID = sessionID
        }
    }

    private struct Entry {
        var connection: any WebSocketConnection
        var lastUsed: ContinuousClock.Instant
        var inUse: Bool
    }

    private let factory: WebSocketFactory
    private let idleTimeout: Duration
    private var entries: [Key: Entry] = [:]

    public init(
        idleTimeout: Duration = .seconds(300),
        factory: @escaping WebSocketFactory
    ) {
        self.idleTimeout = idleTimeout
        self.factory = factory
    }

    public func withConnection<Result: Sendable>(
        key: Key,
        url: URL,
        headers: [String: String],
        operation: @Sendable (any WebSocketConnection) async throws -> Result
    ) async throws -> Result {
        await evictIdle()
        let connection: any WebSocketConnection
        if var entry = entries[key], !entry.inUse {
            entry.inUse = true
            entry.lastUsed = .now
            entries[key] = entry
            connection = entry.connection
        } else if entries[key] != nil {
            connection = try await factory(url, headers)
        } else {
            connection = try await factory(url, headers)
            entries[key] = Entry(
                connection: connection,
                lastUsed: .now,
                inUse: true
            )
        }
        do {
            let value = try await operation(connection)
            release(key: key, connection: connection)
            return value
        } catch {
            await discard(key: key, connection: connection)
            throw error
        }
    }

    public func evictIdle(now: ContinuousClock.Instant = .now) async {
        let expired = entries.filter { now - $0.value.lastUsed >= idleTimeout }
        for (key, entry) in expired where !entry.inUse {
            entries[key] = nil
            await entry.connection.close()
        }
    }

    public func closeAll() async {
        let values = entries.values.map(\.connection)
        entries.removeAll()
        for value in values { await value.close() }
    }

    public func count() -> Int { entries.count }

    private func release(key: Key, connection: any WebSocketConnection) {
        guard var entry = entries[key],
            entry.connection.identifier == connection.identifier
        else {
            Task { await connection.close() }
            return
        }
        entry.inUse = false
        entry.lastUsed = .now
        entries[key] = entry
    }

    private func discard(
        key: Key,
        connection: any WebSocketConnection
    ) async {
        if entries[key]?.connection.identifier == connection.identifier {
            entries[key] = nil
        }
        await connection.close()
    }
}

public enum CodexWebSocket {
    public static func defaultFactory(
        session: URLSession = .shared
    ) -> WebSocketFactory {
        { url, headers in
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let task = session.webSocketTask(with: request)
            task.resume()
            return URLSessionWebSocketConnection(task: task)
        }
    }
}
