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
                    key: .init(account: id, sessionID: sessionID),
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
                                    case .string(let type)? = object["type"],
                                    type == "response.completed"
                                {
                                    var message = reducer.partial
                                    if message.stopReason == .pending { message.stopReason = .stop }
                                    await output.emit(.done(reason: message.stopReason, message: message))
                                    terminal = true
                                }
                                if case .object(let object) = value,
                                    case .string(let type)? = object["type"],
                                    type.contains("error")
                                {
                                    throw ProviderError.invalidResponse(OrderedJSON.string(value))
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
