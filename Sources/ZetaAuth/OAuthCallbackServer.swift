import Foundation
import Network

public struct OAuthCallback: Sendable, Equatable {
    public var code: String
    public var state: String
}

public final class OAuthCallbackServer: @unchecked Sendable {
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
        if let listener, let port = listener.port {
            return URL(string: "http://127.0.0.1:\(port.rawValue)/callback")!
        }
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
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
                (listenerReady, listenerFailure, listener.port?.rawValue)
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
        guard listener != nil || pendingResult != nil else {
            throw OAuthError.invalidCallback
        }
        if let pending = lock.withLock({ () -> Result<OAuthCallback, Error>? in
            defer { pendingResult = nil }
            return pendingResult
        }) {
            return try pending.get()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    public func stop() {
        finish(.failure(CancellationError()))
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1_024
        ) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.respond(connection, status: "400 Bad Request", message: "Authorization failed")
                self.finish(.failure(error))
                return
            }
            guard let data,
                let request = String(data: data, encoding: .utf8),
                let firstLine = request.split(separator: "\n").first,
                let target = firstLine.split(separator: " ").dropFirst().first,
                let components = URLComponents(string: String(target)),
                let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
                let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
                state == self.expectedState
            else {
                self.respond(connection, status: "400 Bad Request", message: "Invalid authorization callback")
                self.finish(.failure(OAuthError.invalidCallback))
                return
            }
            self.respond(connection, status: "200 OK", message: "Authorization complete. You may close this window.")
            self.finish(.success(OAuthCallback(code: code, state: state)))
        }
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
        let continuation: CheckedContinuation<OAuthCallback, Error>? = lock.withLock {
            guard !settled else { return nil }
            settled = true
            let value = self.continuation
            self.continuation = nil
            if value == nil { pendingResult = result }
            return value
        }
        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
    }
}
