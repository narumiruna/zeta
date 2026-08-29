import XCTest
import ZetaAI
import ZetaAgent

@testable import ZetaIOSLibraryConsumer

final class IOSLibraryConsumerTests: XCTestCase {
    func testBundledCatalogLoadsOnIOS() throws {
        let catalog = try BuiltinModelCatalog.bundled()
        XCTAssertGreaterThan(catalog.models.count, 0)
        XCTAssertNotNil(catalog.model(provider: "openai", id: "gpt-4o-mini"))
        XCTAssertNoThrow(
            try IOSAgentFactory.makeOpenAIAgent(apiKey: "synthetic-ios-api-key")
        )
    }

    func testAgentStreamsEventsInjectsCredentialAndRunsAppTool() async throws {
        let faux = FauxProvider()
        let model = await faux.models[0]
        await faux.enqueue(
            AssistantMessage(
                content: [
                    .toolCall(
                        ToolCall(
                            id: "echo-1",
                            name: "echo",
                            arguments: ["text": "hello"]
                        )
                    )
                ],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .toolUse
            )
        )
        await faux.enqueue(
            AssistantMessage(
                content: [.text(text: "done")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let credentials = CredentialRecorder()
        let provider = RecordingProvider(faux: faux, credentials: credentials)
        let agent = IOSAgentFactory.makeAgent(
            model: model,
            provider: provider,
            apiKey: "synthetic-ios-api-key"
        )
        let events = EventRecorder()
        await agent.subscribe { event in
            await events.append(event)
        }

        try await agent.prompt(UserMessage("Use the echo tool"))

        let state = await agent.state()
        XCTAssertEqual(state.messages.count, 4)
        guard
            state.messages.indices.contains(2),
            case .toolResult(let toolResult) = state.messages[2]
        else {
            return XCTFail("Expected an app-owned tool result")
        }
        XCTAssertEqual(toolResult.toolName, "echo")
        XCTAssertEqual(
            toolResult.content,
            [.text(text: "Echoed by the iOS application")]
        )
        let recordedCredentials = await credentials.values()
        XCTAssertEqual(
            recordedCredentials,
            ["synthetic-ios-api-key", "synthetic-ios-api-key"]
        )
        let recordedEvents = await events.values()
        XCTAssertEqual(recordedEvents.first, .agentStart)
        XCTAssertTrue(
            recordedEvents.contains { event in
                if case .toolExecutionEnd(
                    id: "echo-1",
                    name: "echo",
                    result: _,
                    isError: false
                ) = event {
                    true
                } else {
                    false
                }
            }
        )
        guard case .agentEnd? = recordedEvents.last else {
            return XCTFail("Expected a terminal agentEnd event")
        }
    }
}

private struct RecordingProvider: AIProvider {
    let id: String
    let faux: FauxProvider
    let credentials: CredentialRecorder

    init(faux: FauxProvider, credentials: CredentialRecorder) {
        id = faux.id
        self.faux = faux
        self.credentials = credentials
    }

    var models: [Model] {
        get async { await faux.models }
    }

    func stream(
        model: Model,
        context: Context,
        options: StreamOptions
    ) async -> AssistantEventStream {
        await credentials.append(options.apiKey)
        return await faux.stream(model: model, context: context, options: options)
    }
}

private actor CredentialRecorder {
    private var storage: [String?] = []

    func append(_ credential: String?) {
        storage.append(credential)
    }

    func values() -> [String?] {
        storage
    }
}

private actor EventRecorder {
    private var storage: [AgentEvent] = []

    func append(_ event: AgentEvent) {
        storage.append(event)
    }

    func values() -> [AgentEvent] {
        storage
    }
}
