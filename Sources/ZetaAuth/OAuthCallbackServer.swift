import Foundation
import Network

public struct OAuthCallback: Sendable, Equatable {
    public var code: String
    public var state: String
}

public final class OAuthCallbackServer: @unchecked Sendable {
    private static let maximumRequestLineBytes = 16 * 1_024

    private let expectedState: String
    private let queue = DispatchQueue(label: "zeta.oauth.callback")
    private var listener: NWListener?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OAuthCallback, Error>?
    private var listenerReady = false
    private var listenerFailure: Error?
    private var pendingResult: Result<OAuthCallback, Error>?
    private var settled = false

    public init(expectedState: String) {
        self.expectedState = expectedState
    }

    public func start() async throws -> URL {
        if let listener = lock.withLock({ self.listener }), let port = listener.port {
            return URL(string: "http://127.0.0.1:\(port.rawValue)/callback")!
        }
        let listener = try NWListener(using: .tcp, on: .any)
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.lock.withLock {
                switch state {
                case .ready:
                    self.listenerReady = true
                case .failed(let error):
                    self.listenerFailure = error
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        while true {
            try Task.checkCancellation()
            let state = lock.withLock {
                (listenerReady, listenerFailure, self.listener?.port?.rawValue)
            }
            if let failure = state.1 { throw failure }
            if state.0, let port = state.2, port != 0 {
                return URL(
                    string: "http://127.0.0.1:\(port)/callback"
                )!
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    public func waitForCallback() async throws -> OAuthCallback {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback in
                let immediate: Result<OAuthCallback, Error>? = lock.withLock {
                    if let pendingResult {
                        self.pendingResult = nil
                        return pendingResult
                    }
                    guard listener != nil, continuation == nil else {
                        return .failure(OAuthError.invalidCallback)
                    }
                    continuation = callback
                    return nil
                }
                if let immediate { callback.resume(with: immediate) }
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    var isWaitingForCallback: Bool {
        lock.withLock { continuation != nil }
    }

    public func stop() {
        finish(.failure(CancellationError()))
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequestLine(from: connection, buffer: Data())
    }

    private func receiveRequestLine(from connection: NWConnection, buffer: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maximumRequestLineBytes - buffer.count
        ) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                self.respond(connection, status: "400 Bad Request", message: "Authorization failed")
                return
            }
            var received = buffer
            if let data { received.append(data) }
            if let lineFeed = received.firstIndex(of: 0x0A) {
                let lineLength = received.distance(from: received.startIndex, to: received.index(after: lineFeed))
                guard lineLength < Self.maximumRequestLineBytes else {
                    self.respond(connection, status: "400 Bad Request", message: "Invalid authorization callback")
                    return
                }
                self.handleRequestLine(received[..<lineFeed], from: connection)
                return
            }
            guard !isComplete, received.count < Self.maximumRequestLineBytes else {
                self.respond(connection, status: "400 Bad Request", message: "Invalid authorization callback")
                return
            }
            self.receiveRequestLine(from: connection, buffer: received)
        }
    }

    private func handleRequestLine(_ bytes: Data.SubSequence, from connection: NWConnection) {
        var line = bytes
        if line.last == 0x0D { line.removeLast() }
        guard let requestLine = String(data: line, encoding: .utf8),
            let target = requestLine.split(separator: " ").dropFirst().first,
            let components = URLComponents(string: String(target)),
            let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
            state == expectedState
        else {
            respond(connection, status: "400 Bad Request", message: "Invalid authorization callback")
            return
        }
        respond(connection, status: "200 OK", message: "Authorization complete. You may close this window.")
        finish(.success(OAuthCallback(code: code, state: state)))
    }

    private func respond(
        _ connection: NWConnection,
        status: String,
        message: String
    ) {
        let body = "<!doctype html><meta charset=utf-8><title>Zeta</title><p>\(message)</p>"
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func finish(_ result: Result<OAuthCallback, Error>) {
        let transition: (CheckedContinuation<OAuthCallback, Error>?, NWListener?)? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            let callback = continuation
            continuation = nil
            if callback == nil { pendingResult = result }
            let activeListener = listener
            listener = nil
            return (callback, activeListener)
        }
        guard let transition else { return }
        transition.1?.cancel()
        transition.0?.resume(with: result)
    }
}
