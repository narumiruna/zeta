import CryptoKit
import Foundation
import ZetaCore

public struct CodexWebSocketProvider: AIProvider {
    public let id: String
    public let modelDefinitions: [Model]
    private let pool: CodexWebSocketPool
    private let environment: @Sendable () -> [String: String]

    public init(
        id: String = "openai-codex",
        models: [Model],
        pool: CodexWebSocketPool,
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.id = id
        modelDefinitions = models
        self.pool = pool
        self.environment = environment
    }

    public var models: [Model] { get async { modelDefinitions } }

    public func stream(
        model: Model,
        context: Context,
        options: StreamOptions
    ) async -> AssistantEventStream {
        let output = AssistantEventStream()
        let producer = Task {
            do {
                guard
                    let credential = options.apiKey
                        ?? options.environment["OPENAI_CODEX_TOKEN"]
                        ?? options.environment["COPILOT_GITHUB_TOKEN"]
                        ?? environment()["OPENAI_CODEX_TOKEN"]
                        ?? environment()["COPILOT_GITHUB_TOKEN"]
                else { throw ProviderError.missingCredential(id) }
                let sessionID = options.sessionID ?? UUID().uuidString
                let url = try websocketURL(model.baseURL)
                var headers = CaseInsensitiveHeaders([
                    "Authorization": "Bearer \(credential)",
                    "OpenAI-Beta": "responses_websockets=2026-02-06",
                ])
                headers.merge(options.headers)
                let payload = try ProviderPayloadBuilder.build(
                    model: model,
                    context: context,
                    options: options
                )
                var request: OrderedJSONObject = [
                    "type": "response.create",
                    "response": payload,
                ]
                request["session_id"] = .string(sessionID)
                let requestData = OrderedJSON.encode(.object(request))
                try await pool.withConnection(
                    key: .init(
                        account: connectionFingerprint(
                            credential: credential,
                            url: url,
                            headers: headers
                        ),
                        sessionID: sessionID
                    ),
                    url: url,
                    headers: headers.dictionary
                ) { connection in
                    var reducer = ProviderEventReducer(model: model)
                    do {
                        try await withTaskCancellationHandler {
                            try await connection.send(requestData)
                            await output.emit(.start(reducer.partial))
                            var terminal = false
                            while !terminal {
                                try Task.checkCancellation()
                                let frame = try await connection.receive()
                                let value = try OrderedJSON.decode(frame)
                                for event in try reducer.consume(value) {
                                    await output.emit(event)
                                }
                                if case .object(let object) = value,
                                    case .string(let type)? = object["type"]
                                {
                                    if let message = try terminalMessage(
                                        type: type,
                                        object: object,
                                        partial: reducer.partial
                                    ) {
                                        await output.emit(
                                            .done(reason: message.stopReason, message: message)
                                        )
                                        terminal = true
                                    } else if type.contains("error") {
                                        throw ProviderError.invalidResponse(
                                            OrderedJSON.string(value)
                                        )
                                    }
                                }
                            }
                        } onCancel: {
                            Task { await connection.close() }
                        }
                    } catch {
                        await output.fail(
                            error,
                            preserving: reducer.partial,
                            aborted: error is CancellationError
                        )
                        throw error
                    }
                }
            } catch is CancellationError {
                await output.failBeforeStart(
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    error: CancellationError(),
                    aborted: true
                )
            } catch {
                await output.failBeforeStart(
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    error: error
                )
            }
        }
        output.attachProducer(producer)
        return output
    }

    private func terminalMessage(
        type: String,
        object: OrderedJSONObject,
        partial: AssistantMessage
    ) throws -> AssistantMessage? {
        let status = object.codexString(at: ["response", "status"])
        if type == "response.failed" || status == "failed" || status == "cancelled" {
            let message =
                object.codexString(at: ["response", "error", "message"])
                ?? object.codexString(at: ["response", "incomplete_details", "reason"])
                ?? "Codex response failed"
            throw ProviderError.invalidResponse(message)
        }
        guard
            type == "response.completed"
                || type == "response.done"
                || type == "response.incomplete"
        else {
            return nil
        }

        var message = partial
        if type == "response.incomplete" || status == "incomplete" {
            let reason = object.codexString(at: [
                "response", "incomplete_details", "reason",
            ])
            message.rawStopReason =
                reason.map { "incomplete.\($0)" }
                ?? "incomplete"
            guard reason == "max_output_tokens" else {
                throw ProviderError.invalidResponse(
                    reason.map { "Codex response incomplete: \($0)" }
                        ?? "Codex response incomplete without a provider reason"
                )
            }
            message.stopReason = .length
        } else if message.stopReason == .pending {
            message.stopReason = .stop
        }
        return message
    }

    private func connectionFingerprint(
        credential: String,
        url: URL,
        headers: CaseInsensitiveHeaders
    ) -> String {
        let normalizedHeaders: [(String, String)] = headers.dictionary.map {
            ($0.key.lowercased(), $0.value)
        }
        let sortedHeaders = normalizedHeaders.sorted {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
        }
        var components = [id, url.absoluteString, credential]
        for (name, value) in sortedHeaders {
            components.append(name)
            components.append(value)
        }
        let material = components.map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "codex-\(digest)"
    }

    private func websocketURL(_ base: URL) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ProviderError.invalidResponse("Invalid Codex base URL")
        }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        let path = components.path.hasSuffix("/") ? components.path : components.path + "/"
        components.path = path + "responses"
        guard let url = components.url else {
            throw ProviderError.invalidResponse("Invalid Codex WebSocket URL")
        }
        return url
    }
}

private extension OrderedJSONObject {
    func codexString(at path: [String]) -> String? {
        var current: JSONValue = .object(self)
        for key in path {
            guard case .object(let object) = current, let next = object[key] else {
                return nil
            }
            current = next
        }
        if case .string(let string) = current { return string }
        return nil
    }
}
