import Foundation
import XCTest
import ZetaAI
import ZetaAgent
import ZetaCompaction
import ZetaConfig
import ZetaModes
import ZetaSessions

@testable import ZetaCLI

final class NewestCLISessionFeedbackTests: XCTestCase {
    func testDeferredPersistenceFailuresDrainAtSharedModeAndRPCBoundaries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await fauxModel()

        let sharedSession = try session(
            root: root.appendingPathComponent("shared"),
            injectFailure: { operation in
                if operation == .recordMessage { throw InjectedFailure.recordMessage }
            }
        )
        let sharedProvider = FauxProvider(models: [model])
        await sharedProvider.enqueue(assistant("shared", model: model))
        let sharedAgent = agent(model: model, provider: sharedProvider)
        await sharedAgent.subscribe { event in await sharedSession.record(event) }

        do {
            try await CLISessionBoundary.prompt(
                UserMessage("prompt"), agent: sharedAgent, session: sharedSession
            )
            XCTFail("Expected the shared print/json/interactive boundary to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("recordMessage"))
        }
        try await sharedSession.drainPersistenceErrors()

        let rpcSession = try session(
            root: root.appendingPathComponent("rpc"),
            injectFailure: { operation in
                if operation == .recordMessage { throw InjectedFailure.recordMessage }
            }
        )
        let rpcProvider = FauxProvider(models: [model])
        await rpcProvider.enqueue(assistant("rpc", model: model))
        let rpcAgent = agent(model: model, provider: rpcProvider)
        await rpcAgent.subscribe { event in await rpcSession.record(event) }
        let runtime = CLIRPCRuntime(
            agent: rpcAgent,
            models: [model],
            workingDirectory: root,
            session: rpcSession
        )

        let accepted = await runtime.handle(
            StrictRPCRequest(command: .prompt, fields: ["message": "prompt"])
        )
        XCTAssertTrue(accepted.success)
        await runtime.waitForIdle()
        do {
            try await runtime.drainErrors()
            XCTFail("Expected RPC completion to surface persistence failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("recordMessage"))
        }
        try await runtime.drainErrors()
        try await rpcSession.drainPersistenceErrors()
    }

    func testCycleModelPersistsBeforeUpdatingOrAcknowledging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = model(id: "first")
        let second = model(id: "second")
        let failedSession = try session(
            root: root.appendingPathComponent("failed"),
            injectFailure: { operation in
                if operation == .recordModel { throw InjectedFailure.recordModel }
            }
        )
        let failedAgent = agent(model: first, provider: FauxProvider(models: [first]))
        let failedRuntime = CLIRPCRuntime(
            agent: failedAgent,
            models: [first, second],
            workingDirectory: root,
            session: failedSession
        )

        let failed = await failedRuntime.handle(StrictRPCRequest(command: .cycleModel))
        XCTAssertFalse(failed.success)
        let failedModel = await failedAgent.state().model
        XCTAssertEqual(failedModel.id, first.id)

        let durableSession = try session(root: root.appendingPathComponent("durable"))
        let durableAgent = agent(model: first, provider: FauxProvider(models: [first]))
        let durableRuntime = CLIRPCRuntime(
            agent: durableAgent,
            models: [first, second],
            workingDirectory: root,
            session: durableSession
        )
        let changed = await durableRuntime.handle(StrictRPCRequest(command: .cycleModel))
        XCTAssertTrue(changed.success)
        let changedModel = await durableAgent.state().model
        let restoredModel = try await durableSession.restore(models: [first, second]).model
        XCTAssertEqual(changedModel.id, second.id)
        XCTAssertEqual(restoredModel?.id, second.id)
    }

    func testSetSessionNameMaterializesBeforeAcknowledging() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(id: "name")
        let failedSession = try session(
            root: root.appendingPathComponent("failed"),
            injectFailure: { operation in
                if operation == .materializeName { throw InjectedFailure.materializeName }
            }
        )
        let failedRuntime = CLIRPCRuntime(
            agent: agent(model: model, provider: FauxProvider(models: [model])),
            models: [model],
            workingDirectory: root,
            session: failedSession
        )

        let failed = await failedRuntime.handle(
            StrictRPCRequest(command: .setSessionName, fields: ["name": "not-durable"])
        )
        XCTAssertFalse(failed.success)
        let stats = await failedRuntime.handle(StrictRPCRequest(command: .getSessionStats))
        guard case .object(let failedStats)? = stats.data else {
            return XCTFail("Expected session stats")
        }
        XCTAssertEqual(failedStats["name"], .null)

        let durableSession = try session(root: root.appendingPathComponent("durable"))
        let durableRuntime = CLIRPCRuntime(
            agent: agent(model: model, provider: FauxProvider(models: [model])),
            models: [model],
            workingDirectory: root,
            session: durableSession
        )
        let named = await durableRuntime.handle(
            StrictRPCRequest(command: .setSessionName, fields: ["name": "durable"])
        )
        XCTAssertTrue(named.success)
        let durableFile = await durableSession.currentFile()
        let file = try XCTUnwrap(durableFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(#""name":"durable""#))
    }

    func testRPCRetryStateAndTogglesPreserveConfiguredPolicy() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(id: "retry")
        let agent = agent(model: model, provider: FauxProvider(models: [model]))
        var retry = Settings().retry
        retry.enabled = false
        retry.maxRetries = 7
        retry.baseDelayMs = 123
        retry.maxRetryDelayMs = 456
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: root,
            retrySettings: retry
        )

        let initial = await runtime.handle(StrictRPCRequest(command: .getState))
        guard case .object(let initialState)? = initial.data else {
            return XCTFail("Expected RPC state")
        }
        XCTAssertEqual(initialState["autoRetry"], false)
        var values = await retryValues(agent)
        XCTAssertEqual(values.0, 0)
        XCTAssertEqual(values.1, 123)
        XCTAssertEqual(values.2, 456)

        let enabled = await runtime.handle(
            StrictRPCRequest(command: .setAutoRetry, fields: ["enabled": true])
        )
        XCTAssertTrue(enabled.success)
        values = await retryValues(agent)
        XCTAssertEqual(values.0, 7)
        XCTAssertEqual(values.1, 123)
        XCTAssertEqual(values.2, 456)

        let disabled = await runtime.handle(
            StrictRPCRequest(command: .setAutoRetry, fields: ["enabled": false])
        )
        XCTAssertTrue(disabled.success)
        values = await retryValues(agent)
        XCTAssertEqual(values.0, 0)
        XCTAssertEqual(values.1, 123)
        XCTAssertEqual(values.2, 456)
    }

    func testManualCompactionPersistenceFailureRestoresAgentMessages() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(id: "manual-compaction")
        let original = messages(model: model)
        let provider = FauxProvider(models: [model])
        await provider.enqueue(assistant("summary", model: model))
        let agent = agent(model: model, messages: original, provider: provider)
        let session = try session(
            root: root,
            injectFailure: { operation in
                if operation == .recordCompaction { throw InjectedFailure.recordCompaction }
            }
        )
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: root,
            session: session
        )

        let response = await runtime.handle(StrictRPCRequest(command: .compact))
        XCTAssertFalse(response.success)
        let restored = await agent.state().messages
        XCTAssertEqual(restored, original)
    }

    func testAutoCompactionPersistenceFailureRestoresAgentMessagesAndFailsRun() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var model = model(id: "auto-compaction")
        model.contextWindow = 100
        let original: [Message] = [
            .user(UserMessage(String(repeating: "a", count: 400))),
            .user(UserMessage(String(repeating: "b", count: 400))),
            .user(UserMessage("tail")),
        ]
        let provider = FauxProvider(models: [model])
        await provider.enqueue(assistant("summary", model: model))
        let agent = agent(model: model, messages: original, provider: provider)
        let session = try session(
            root: root,
            injectFailure: { operation in
                if operation == .recordCompaction { throw InjectedFailure.recordCompaction }
            }
        )
        var compaction = Settings().compaction
        compaction.enabled = true
        compaction.reserveTokens = 50
        compaction.keepRecentTokens = 1
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: root,
            session: session,
            compactionSettings: compaction
        )

        let accepted = await runtime.handle(
            StrictRPCRequest(command: .prompt, fields: ["message": "must-not-run"])
        )
        XCTAssertTrue(accepted.success)
        await runtime.waitForIdle()
        let restored = await agent.state().messages
        XCTAssertEqual(restored, original)
        do {
            try await runtime.drainErrors()
            XCTFail("Expected auto-compaction persistence failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("recordCompaction"))
        }
    }

    func testNewSessionWritesRequestedParentSessionToHeader() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(id: "new-session")
        let session = try self.session(root: root)
        let runtime = CLIRPCRuntime(
            agent: agent(model: model, provider: FauxProvider(models: [model])),
            models: [model],
            workingDirectory: root,
            session: session
        )

        let response = await runtime.handle(
            StrictRPCRequest(
                command: .newSession,
                fields: ["parentSession": "/synthetic/parent.jsonl"]
            )
        )
        XCTAssertTrue(response.success)
        let snapshot = await session.exportSnapshot()
        XCTAssertEqual(snapshot.header.parentSession, "/synthetic/parent.jsonl")
        let currentFile = await session.currentFile()
        let file = try XCTUnwrap(currentFile)
        let loaded = try SessionManager.load(file: file)
        let loadedParent = await loaded.header.parentSession
        XCTAssertEqual(loadedParent, "/synthetic/parent.jsonl")
    }

    func testExportHTMLWritesRequestedPathAndRetainsInlineResponse() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(id: "export")
        let runtime = CLIRPCRuntime(
            agent: agent(model: model, messages: messages(model: model), provider: FauxProvider(models: [model])),
            models: [model],
            workingDirectory: root
        )
        let output = root.appendingPathComponent("requested.html")
        try Data("old".utf8).write(to: output)

        let written = await runtime.handle(
            StrictRPCRequest(command: .exportHTML, fields: ["outputPath": .string(output.path)])
        )
        XCTAssertTrue(written.success)
        guard case .object(let writtenData)? = written.data else {
            return XCTFail("Expected export response")
        }
        XCTAssertEqual(writtenData["path"], .string(output.path))
        XCTAssertNil(writtenData["html"])
        let html = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(html.contains("<!doctype html>"))

        let inline = await runtime.handle(StrictRPCRequest(command: .exportHTML))
        XCTAssertTrue(inline.success)
        guard case .object(let inlineData)? = inline.data,
            case .string(let inlineHTML)? = inlineData["html"]
        else {
            return XCTFail("Expected inline HTML")
        }
        XCTAssertTrue(inlineHTML.contains("<!doctype html>"))
        XCTAssertNil(inlineData["path"])
    }

    func testInteractiveAssistantFallbackRendersErrorMessagesWithoutText() {
        let model = model(id: "interactive")
        let failed = AssistantMessage(
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .error,
            errorMessage: "provider failed"
        )
        let aborted = AssistantMessage(
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .aborted,
            errorMessage: "request aborted"
        )
        let textWins = AssistantMessage(
            content: [.text(text: "partial")],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .error,
            errorMessage: "provider failed"
        )

        XCTAssertEqual(InteractiveTranscript.assistantText(failed), "provider failed")
        XCTAssertEqual(InteractiveTranscript.assistantText(aborted), "request aborted")
        XCTAssertEqual(InteractiveTranscript.assistantText(textWins), "partial")
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func session(
        root: URL,
        injectFailure: @escaping PersistentSessionController.FailureInjector = { _ in }
    ) throws -> PersistentSessionController {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = try SessionManager(
            header: SessionHeader(
                id: "session-\(UUID().uuidString.lowercased())",
                timestamp: "2026-01-01T00:00:00Z",
                cwd: root.path
            ),
            file: root.appendingPathComponent("session.jsonl")
        )
        return PersistentSessionController(manager: manager, injectFailure: injectFailure)
    }

    private func fauxModel() async throws -> Model {
        let provider = FauxProvider()
        return await provider.models[0]
    }

    private func model(id: String) -> Model {
        Model(
            id: id,
            name: id,
            api: "faux",
            provider: "faux",
            baseURL: URL(string: "https://example.invalid")!,
            contextWindow: 128_000,
            maximumTokens: 1_000
        )
    }

    private func agent(
        model: Model,
        messages: [Message] = [],
        provider: FauxProvider
    ) -> Agent {
        Agent(state: AgentState(systemPrompt: "", model: model, messages: messages)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
    }

    private func retryValues(_ agent: Agent) async -> (Int, Int, Int) {
        let maximum = await agent.maximumRetries
        let base = await agent.retryBaseDelayMilliseconds
        let maximumDelay = await agent.retryMaximumDelayMilliseconds
        return (maximum, base, maximumDelay)
    }

    private func assistant(_ text: String, model: Model) -> AssistantMessage {
        AssistantMessage(
            content: [.text(text: text)],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .stop
        )
    }

    private func messages(model: Model) -> [Message] {
        [
            .user(UserMessage("first")),
            .assistant(assistant("second", model: model)),
            .user(UserMessage("third")),
        ]
    }
}

private enum InjectedFailure: Error, LocalizedError {
    case recordMessage
    case recordModel
    case materializeName
    case recordCompaction

    var errorDescription: String? {
        switch self {
        case .recordMessage: "injected recordMessage failure"
        case .recordModel: "injected recordModel failure"
        case .materializeName: "injected materializeName failure"
        case .recordCompaction: "injected recordCompaction failure"
        }
    }
}
