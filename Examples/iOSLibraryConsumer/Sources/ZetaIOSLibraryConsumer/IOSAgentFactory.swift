import ZetaAI
import ZetaAgent

public enum IOSAgentFactoryError: Error {
    case unavailableOpenAIModel
}

public enum IOSAgentFactory {
    public static func makeOpenAIAgent(apiKey: String) throws -> Agent {
        let catalog = try BuiltinModelCatalog.bundled()
        guard
            let model = catalog.model(provider: "openai", id: "gpt-4o-mini"),
            let provider = BuiltinProviderFactory.providers(catalog: catalog)
                .first(where: { $0.id == model.provider })
        else {
            throw IOSAgentFactoryError.unavailableOpenAIModel
        }
        return makeAgent(model: model, provider: provider, apiKey: apiKey)
    }

    public static func makeAgent(
        model: Model,
        provider: any AIProvider,
        apiKey: String
    ) -> Agent {
        let echo = AgentTool(
            definition: ToolDefinition(
                name: "echo",
                description: "Return the supplied arguments",
                parameters: [
                    "type": "object",
                    "additionalProperties": true,
                ]
            ),
            label: "Echo"
        ) { _, arguments, _ in
            AgentToolResult(
                content: [.text(text: "Echoed by the iOS application")],
                details: arguments
            )
        }
        return Agent(
            state: AgentState(
                systemPrompt: "You are an assistant embedded in an iOS application.",
                model: model,
                tools: [echo]
            )
        ) { model, context, options in
            var requestOptions = options
            requestOptions.apiKey = apiKey
            return await provider.stream(
                model: model,
                context: context,
                options: requestOptions
            )
        }
    }
}
