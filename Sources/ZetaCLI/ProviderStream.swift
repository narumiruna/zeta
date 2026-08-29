import Foundation
import ZetaAI
import ZetaAuth
import ZetaBedrock
import ZetaConfig

struct CLIResolvedProviderAuthentication: Sendable, Equatable {
    var apiKey: String?
    var bearerToken: String?
    var headers: [String: String]
    var environment: [String: String]

    var isConfigured: Bool {
        apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            || !headers.isEmpty
    }

    func applying(to original: StreamOptions, for model: Model) -> StreamOptions {
        var options = original
        for (name, value) in headers {
            options.headers[name] = value
        }
        guard model.api == "google-vertex" else {
            options.apiKey = apiKey ?? bearerToken ?? options.apiKey
            return options
        }

        let previousTransform = options.transformHeaders
        let apiKey = apiKey
        let bearerToken = bearerToken
        let authenticationHeaders = headers
        options.apiKey = apiKey ?? bearerToken ?? (headers.isEmpty ? options.apiKey : "<authenticated>")
        options.transformHeaders = { headers in
            var result = try await previousTransform?(headers) ?? headers
            if let apiKey {
                result["Authorization"] = nil
                result["x-goog-api-key"] = apiKey
            } else {
                result["x-goog-api-key"] = nil
                if let bearerToken {
                    result["Authorization"] = "Bearer \(bearerToken)"
                }
                for (name, value) in authenticationHeaders {
                    result[name] = value
                }
            }
            return result
        }
        return options
    }
}

enum CLIProviderAuthenticationResolver {
    static func resolve(
        provider: String,
        api: String,
        explicitAPIKey: String? = nil,
        store: AuthStore,
        environment: [String: String]
    ) async throws -> CLIResolvedProviderAuthentication {
        let stored = try await store.resolveCredential(
            provider: provider,
            environment: environment,
            fallbackVariables: BuiltinProviderFactory.environmentVariables[provider] ?? []
        )
        let selectedAPIKey =
            explicitAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? explicitAPIKey : stored.apiKey

        if api == "google-vertex" || provider == "google-vertex" {
            if let bearerToken = stored.bearerToken {
                return CLIResolvedProviderAuthentication(
                    bearerToken: bearerToken,
                    headers: [:],
                    environment: stored.environment
                )
            }
            var vertexEnvironment = stored.environment
            if vertexEnvironment["GOOGLE_CLOUD_API_KEY"]?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            {
                vertexEnvironment["GOOGLE_CLOUD_API_KEY"] = nil
            }
            let vertex = try await CredentialResolver.vertexAccessAuthentication(
                explicitAPIKey: selectedAPIKey,
                environment: vertexEnvironment
            )
            return CLIResolvedProviderAuthentication(
                apiKey: vertex?.apiKey,
                bearerToken: vertex?.bearerToken,
                headers: vertex?.headers ?? [:],
                environment: stored.environment
            )
        }

        if api == "bedrock-converse-stream" {
            var resolvedEnvironment = stored.environment
            if CredentialResolver.aws(environment: resolvedEnvironment) == nil,
                let selectedAPIKey
            {
                resolvedEnvironment["AWS_BEARER_TOKEN_BEDROCK"] = selectedAPIKey
            }
            return CLIResolvedProviderAuthentication(
                apiKey: selectedAPIKey,
                bearerToken: stored.bearerToken,
                headers: [:],
                environment: resolvedEnvironment
            )
        }

        return CLIResolvedProviderAuthentication(
            apiKey: selectedAPIKey,
            bearerToken: stored.bearerToken,
            headers: [:],
            environment: stored.environment
        )
    }

    static func isReady(
        provider: String,
        store: AuthStore,
        environment: [String: String]
    ) async -> Bool {
        guard BuiltinProviderFactory.environmentVariables[provider] != nil else {
            return false
        }
        do {
            let api =
                provider == "google-vertex"
                ? "google-vertex"
                : provider == "amazon-bedrock"
                    ? "bedrock-converse-stream"
                    : "http"
            let resolved = try await resolve(
                provider: provider,
                api: api,
                store: store,
                environment: environment
            )
            if api == "bedrock-converse-stream" {
                return CredentialResolver.aws(environment: resolved.environment) != nil
            }
            return resolved.isConfigured
        } catch {
            return false
        }
    }
}

enum CLIProviderTransport: Sendable, Equatable {
    case http
    case codexWebSocket
    case bedrock

    static func select(for model: Model, preference: TransportPreference) -> CLIProviderTransport {
        if model.api == "openai-codex-responses", preference != .sse {
            return .codexWebSocket
        }
        if model.api == "bedrock-converse-stream" {
            return .bedrock
        }
        return .http
    }
}

actor CLIModelStreamDispatcher {
    private let authStore: AuthStore
    private let explicitAPIKeys: [String: String]
    private let transportPreference: TransportPreference
    private let environment: @Sendable () -> [String: String]
    private let codexPool = CodexWebSocketPool(factory: CodexWebSocket.defaultFactory())
    private var fauxProviders: [String: FauxProvider] = [:]

    init(
        authStore: AuthStore,
        explicitAPIKeys: [String: String],
        transportPreference: TransportPreference,
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.authStore = authStore
        self.explicitAPIKeys = explicitAPIKeys
        self.transportPreference = transportPreference
        self.environment = environment
    }

    func stream(
        model: Model,
        context: Context,
        options: StreamOptions
    ) async -> AssistantEventStream {
        let currentEnvironment = environment()
        if currentEnvironment["ZETA_FAUX_RESPONSE"] != nil
            || currentEnvironment["ZETA_FAUX_TOOL"] != nil
        {
            return await fauxStream(
                model: model,
                context: context,
                options: options,
                environment: currentEnvironment
            )
        }

        do {
            let authentication = try await resolveAuthentication(
                for: model,
                requestAPIKey: options.apiKey,
                environment: currentEnvironment
            )
            let resolvedOptions = authentication.applying(to: options, for: model)
            switch CLIProviderTransport.select(for: model, preference: transportPreference) {
            case .codexWebSocket:
                let provider = CodexWebSocketProvider(
                    models: [model],
                    pool: codexPool,
                    environment: { authentication.environment }
                )
                return await provider.stream(
                    model: model,
                    context: context,
                    options: resolvedOptions
                )
            case .bedrock:
                let credential = CredentialResolver.aws(environment: authentication.environment)
                let provider = BedrockProvider(
                    models: [model],
                    region: authentication.environment["AWS_REGION"]
                        ?? authentication.environment["AWS_DEFAULT_REGION"]
                        ?? "us-east-1"
                ) {
                    guard let credential else {
                        throw ProviderError.missingCredential(model.provider)
                    }
                    return credential
                }
                return await provider.stream(
                    model: model,
                    context: context,
                    options: resolvedOptions
                )
            case .http:
                let provider = HTTPProvider(
                    configuration: ProviderConfiguration(
                        id: model.provider,
                        api: model.api,
                        baseURL: model.baseURL,
                        models: [model],
                        apiKeyEnvironmentVariables: BuiltinProviderFactory.environmentVariables[model.provider] ?? []
                    ),
                    environment: { authentication.environment }
                )
                return await provider.stream(
                    model: model,
                    context: context,
                    options: resolvedOptions
                )
            }
        } catch {
            let stream = AssistantEventStream()
            await stream.failBeforeStart(
                api: model.api,
                provider: model.provider,
                model: model.id,
                error: error
            )
            return stream
        }
    }

    func resolveAuthentication(
        for model: Model,
        requestAPIKey: String? = nil,
        environment: [String: String]? = nil
    ) async throws -> CLIResolvedProviderAuthentication {
        try await CLIProviderAuthenticationResolver.resolve(
            provider: model.provider,
            api: model.api,
            explicitAPIKey: explicitAPIKeys[model.provider] ?? requestAPIKey,
            store: authStore,
            environment: environment ?? self.environment()
        )
    }

    private func fauxStream(
        model: Model,
        context: Context,
        options: StreamOptions,
        environment: [String: String]
    ) async -> AssistantEventStream {
        let key = "\(model.provider)/\(model.id)"
        let provider: FauxProvider
        if let existing = fauxProviders[key] {
            provider = existing
        } else {
            let created = FauxProvider(models: [model], tokensPerSecond: 10_000)
            if let tool = environment["ZETA_FAUX_TOOL"] {
                await created.enqueue(
                    AssistantMessage(
                        content: [
                            .toolCall(
                                ToolCall(
                                    id: "faux-tool-1",
                                    name: tool,
                                    arguments: ["text": "plugin smoke"]
                                )
                            )
                        ],
                        api: model.api,
                        provider: model.provider,
                        model: model.id,
                        stopReason: .toolUse
                    )
                )
            }
            await created.enqueue(
                AssistantMessage(
                    content: [.text(text: environment["ZETA_FAUX_RESPONSE"] ?? "faux-ok")],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .stop
                )
            )
            fauxProviders[key] = created
            provider = created
        }
        return await provider.stream(model: model, context: context, options: options)
    }
}
