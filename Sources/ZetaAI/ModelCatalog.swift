import Foundation

public enum ModelCatalogError: Error, LocalizedError, Sendable {
    case missingResource
    case invalidModel(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource:
            "Bundled model catalog is missing"
        case .invalidModel(let model):
            "Bundled model catalog contains an invalid model: \(model)"
        }
    }
}

public struct BuiltinModelCatalog: Sendable {
    public let modelsByProvider: [String: [Model]]

    public init(data: Data) throws {
        let decoded = try JSONDecoder().decode(
            [String: [String: GeneratedModel]].self,
            from: data
        )
        var result: [String: [Model]] = [:]
        for (provider, values) in decoded {
            result[provider] = try values.values.map { generated in
                guard generated.contextWindow > 0,
                    generated.maximumTokens > 0
                else {
                    throw ModelCatalogError.invalidModel("\(provider)/\(generated.id)")
                }
                let baseURL =
                    URL(string: generated.baseURL).flatMap { url in
                        url.scheme == nil ? nil : url
                    } ?? URL(string: "https://configuration-required.invalid")!
                return Model(
                    id: generated.id,
                    name: generated.name,
                    api: generated.api,
                    provider: generated.provider,
                    baseURL: baseURL,
                    reasoning: generated.reasoning,
                    input: Set(generated.input),
                    cost: generated.cost,
                    contextWindow: generated.contextWindow,
                    maximumTokens: generated.maximumTokens
                )
            }.sorted { $0.id < $1.id }
        }
        modelsByProvider = result
    }

    public static func bundled() throws -> BuiltinModelCatalog {
        guard
            let url = Bundle.module.url(
                forResource: "model-catalog",
                withExtension: "json"
            )
        else {
            throw ModelCatalogError.missingResource
        }
        return try BuiltinModelCatalog(data: Data(contentsOf: url))
    }

    public var providers: [String] {
        modelsByProvider.keys.sorted()
    }

    public var models: [Model] {
        providers.flatMap { modelsByProvider[$0] ?? [] }
    }

    public func model(provider: String, id: String) -> Model? {
        modelsByProvider[provider]?.first { $0.id == id }
    }
}

private struct GeneratedModel: Decodable {
    let id: String
    let name: String
    let api: String
    let provider: String
    let baseURL: String
    let reasoning: Bool
    let input: [String]
    let cost: ModelCost
    let contextWindow: Int
    let maximumTokens: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case api
        case provider
        case baseURL = "baseUrl"
        case reasoning
        case input
        case cost
        case contextWindow
        case maximumTokens = "maxTokens"
    }
}

public enum BuiltinProviderFactory {
    public static let environmentVariables: [String: [String]] = [
        "amazon-bedrock": ["AWS_BEARER_TOKEN_BEDROCK", "AWS_ACCESS_KEY_ID"],
        "ant-ling": ["ANT_LING_API_KEY"],
        "anthropic": ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_OAUTH_TOKEN", "ANTHROPIC_API_KEY"],
        "azure-openai-responses": ["AZURE_OPENAI_API_KEY"],
        "baseten": ["BASETEN_API_KEY"],
        "cerebras": ["CEREBRAS_API_KEY"],
        "cloudflare-ai-gateway": ["CLOUDFLARE_API_KEY"],
        "cloudflare-workers-ai": ["CLOUDFLARE_API_KEY"],
        "deepseek": ["DEEPSEEK_API_KEY"],
        "fireworks": ["FIREWORKS_API_KEY"],
        "github-copilot": ["COPILOT_GITHUB_TOKEN"],
        "google": ["GEMINI_API_KEY"],
        "google-vertex": ["GOOGLE_CLOUD_API_KEY"],
        "groq": ["GROQ_API_KEY"],
        "huggingface": ["HF_TOKEN"],
        "kimi-coding": ["KIMI_API_KEY"],
        "minimax": ["MINIMAX_API_KEY"],
        "minimax-cn": ["MINIMAX_CN_API_KEY"],
        "mistral": ["MISTRAL_API_KEY"],
        "moonshotai": ["MOONSHOT_API_KEY"],
        "moonshotai-cn": ["MOONSHOT_API_KEY"],
        "nvidia": ["NVIDIA_API_KEY"],
        "openai": ["OPENAI_API_KEY"],
        "openai-codex": [],
        "opencode": ["OPENCODE_API_KEY"],
        "opencode-go": ["OPENCODE_API_KEY"],
        "openrouter": ["OPENROUTER_API_KEY"],
        "qwen-token-plan": ["QWEN_TOKEN_PLAN_API_KEY"],
        "qwen-token-plan-cn": ["QWEN_TOKEN_PLAN_CN_API_KEY"],
        "qwen-token-plan-individual": ["QWEN_TOKEN_PLAN_API_KEY"],
        "together": ["TOGETHER_API_KEY"],
        "vercel-ai-gateway": ["AI_GATEWAY_API_KEY"],
        "xai": ["XAI_API_KEY"],
        "xiaomi": ["XIAOMI_API_KEY"],
        "xiaomi-token-plan-ams": ["XIAOMI_TOKEN_PLAN_AMS_API_KEY"],
        "xiaomi-token-plan-cn": ["XIAOMI_TOKEN_PLAN_CN_API_KEY"],
        "xiaomi-token-plan-sgp": ["XIAOMI_TOKEN_PLAN_SGP_API_KEY"],
        "zai": ["ZAI_API_KEY"],
        "zai-coding-cn": ["ZAI_CODING_CN_API_KEY"],
    ]

    public static func providers(
        catalog: BuiltinModelCatalog,
        session: URLSession = .shared
    ) -> [HTTPProvider] {
        catalog.providers.compactMap { id in
            guard let models = catalog.modelsByProvider[id],
                let first = models.first
            else {
                return nil
            }
            return HTTPProvider(
                configuration: ProviderConfiguration(
                    id: id,
                    api: first.api,
                    baseURL: first.baseURL,
                    models: models,
                    apiKeyEnvironmentVariables: environmentVariables[id] ?? []
                ),
                session: session
            )
        }
    }
}
