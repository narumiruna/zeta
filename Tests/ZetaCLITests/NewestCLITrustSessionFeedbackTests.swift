import Foundation
import XCTest
import ZetaAI
import ZetaAgent
import ZetaConfig
import ZetaModes
import ZetaSessions

@testable import ZetaCLI

final class NewestCLITrustSessionFeedbackTests: XCTestCase {
    func testRPCLoadsAndSwitchesLatestDurableSessionNameIncludingTombstone() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = model(id: "session-name")
        let initial = try session(root: root.appendingPathComponent("initial"))
        try await initial.setName("Restored title")
        let runtime = runtime(model: model, session: initial, workingDirectory: root)

        let restoredName = try await sessionName(from: runtime)
        XCTAssertEqual(restoredName, "Restored title")
        let restoredHTML = try await exportedHTML(from: runtime)
        XCTAssertTrue(restoredHTML.contains("<title>Restored title</title>"))

        let alternate = try session(root: root.appendingPathComponent("alternate"))
        try await alternate.setName("Switched title")
        let currentAlternateFile = await alternate.currentFile()
        let alternateFile = try XCTUnwrap(currentAlternateFile)
        let switched = await runtime.handle(
            StrictRPCRequest(
                command: .switchSession,
                fields: ["sessionPath": .string(alternateFile.path)]
            )
        )
        XCTAssertTrue(switched.success)
        let switchedName = try await sessionName(from: runtime)
        XCTAssertEqual(switchedName, "Switched title")

        try await alternate.setName(nil)
        let tombstoneSwitch = await runtime.handle(
            StrictRPCRequest(
                command: .switchSession,
                fields: ["sessionPath": .string(alternateFile.path)]
            )
        )
        XCTAssertTrue(tombstoneSwitch.success)
        let tombstonedName = try await sessionName(from: runtime)
        XCTAssertNil(tombstonedName)
        let tombstoneHTML = try await exportedHTML(from: runtime)
        XCTAssertTrue(tombstoneHTML.contains("<title>Zeta Session</title>"))
        XCTAssertFalse(tombstoneHTML.contains("<title>Switched title</title>"))
    }

    func testJSONModeEmitsAllPromptEventsAndFailsForFinalAbortedAssistant() async throws {
        let model = model(id: "json-status")
        let provider = FauxProvider(models: [model])
        await provider.enqueue(
            AssistantMessage(
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .error,
                errorMessage: "first failed"
            )
        )
        await provider.enqueue(
            AssistantMessage(
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .aborted,
                errorMessage: "second aborted"
            )
        )
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let output = EventOutput()

        let status = await ZetaCLI.runJSONMode(
            agent: agent,
            prompt: UserMessage("first"),
            remaining: ["second"],
            session: nil,
            writeEvent: { data in await output.append(data) }
        )

        XCTAssertEqual(status, 1)
        let messages = await agent.state().messages
        XCTAssertEqual(messages.compactMap(userText), ["first", "second"])
        let lines = await output.lines()
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: line))
        }
    }

    func testJSONModeFailsForFinalAssistantErrorWhileKeepingEvents() async throws {
        let model = model(id: "json-error-status")
        let provider = FauxProvider(models: [model])
        await provider.enqueue(
            AssistantMessage(
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .error,
                errorMessage: "provider failed"
            )
        )
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let output = EventOutput()

        let status = await ZetaCLI.runJSONMode(
            agent: agent,
            prompt: UserMessage("fail"),
            remaining: [],
            session: nil,
            writeEvent: { data in await output.append(data) }
        )

        XCTAssertEqual(status, 1)
        let outputIsEmpty = await output.isEmpty()
        XCTAssertFalse(outputIsEmpty)
    }

    func testAskTrustSelectsAndRecordsWhileNoninteractiveAskDeniesActionably() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrustStore(url: root.appendingPathComponent("agent/trust.json"))
        let interactiveProject = try projectWithSettings(root.appendingPathComponent("interactive"))
        let selections = TrustSelections(.trusted)

        let selected = try await CLIProjectTrust.resolve(
            directory: interactiveProject,
            store: store,
            override: nil,
            default: .ask,
            projectResourcesPresent: true,
            supportsInteractiveSelection: true,
            selector: { directory in await selections.select(directory) }
        )

        XCTAssertTrue(selected.trusted)
        XCTAssertNil(selected.diagnostic)
        let recordedInteractiveDecision = await store.decision(for: interactiveProject)
        let selectedDirectories = await selections.selectedDirectories()
        XCTAssertEqual(recordedInteractiveDecision, .trusted)
        XCTAssertEqual(selectedDirectories, [interactiveProject.standardizedFileURL])

        let noninteractiveProject = try projectWithSettings(root.appendingPathComponent("noninteractive"))
        let denied = try await CLIProjectTrust.resolve(
            directory: noninteractiveProject,
            store: store,
            override: nil,
            default: .ask,
            projectResourcesPresent: true,
            supportsInteractiveSelection: false,
            selector: { directory in await selections.select(directory) }
        )

        XCTAssertFalse(denied.trusted)
        XCTAssertTrue(denied.diagnostic?.contains("--approve") == true)
        XCTAssertTrue(denied.diagnostic?.contains("defaultProjectTrust") == true)
        let recordedNoninteractiveDecision = await store.decision(for: noninteractiveProject)
        let finalSelectedDirectories = await selections.selectedDirectories()
        XCTAssertNil(recordedNoninteractiveDecision)
        XCTAssertEqual(finalSelectedDirectories.count, 1)
    }

    func testTrustNeverAndApprovalOverridesBypassAskSelection() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try TrustStore(url: root.appendingPathComponent("agent/trust.json"))
        let selections = TrustSelections(.denied)
        let neverProject = try projectWithSettings(root.appendingPathComponent("never"))

        let never = try await CLIProjectTrust.resolve(
            directory: neverProject,
            store: store,
            override: nil,
            default: .never,
            projectResourcesPresent: true,
            supportsInteractiveSelection: true,
            selector: { directory in await selections.select(directory) }
        )
        XCTAssertFalse(never.trusted)
        XCTAssertNil(never.diagnostic)
        let recordedNeverDecision = await store.decision(for: neverProject)
        XCTAssertNil(recordedNeverDecision)

        let approvedProject = try projectWithSettings(root.appendingPathComponent("approved"))
        let approved = try await CLIProjectTrust.resolve(
            directory: approvedProject,
            store: store,
            override: true,
            default: .ask,
            projectResourcesPresent: true,
            supportsInteractiveSelection: false,
            selector: { directory in await selections.select(directory) }
        )
        XCTAssertTrue(approved.trusted)
        let recordedApproval = await store.decision(for: approvedProject)
        let overrideSelections = await selections.selectedDirectories()
        XCTAssertEqual(recordedApproval, .trusted)
        XCTAssertTrue(overrideSelections.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func projectWithSettings(_ directory: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".pi"),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: directory.appendingPathComponent(".pi/settings.json"))
        XCTAssertTrue(CLIProjectTrust.hasTrustRequiringResources(in: directory))
        return directory
    }

    private func session(root: URL) throws -> PersistentSessionController {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = try SessionManager(
            header: SessionHeader(
                id: "session-\(UUID().uuidString.lowercased())",
                timestamp: "2026-01-01T00:00:00Z",
                cwd: root.path
            ),
            file: root.appendingPathComponent("session.jsonl")
        )
        return PersistentSessionController(manager: manager)
    }

    private func runtime(
        model: Model,
        session: PersistentSessionController,
        workingDirectory: URL
    ) -> CLIRPCRuntime {
        let provider = FauxProvider(models: [model])
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        return CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: workingDirectory,
            session: session
        )
    }

    private func sessionName(from runtime: CLIRPCRuntime) async throws -> String? {
        let response = await runtime.handle(StrictRPCRequest(command: .getSessionStats))
        XCTAssertTrue(response.success)
        guard case .object(let data)? = response.data else {
            throw TestFailure.missingData
        }
        guard case .string(let name)? = data["name"] else { return nil }
        return name
    }

    private func exportedHTML(from runtime: CLIRPCRuntime) async throws -> String {
        let response = await runtime.handle(StrictRPCRequest(command: .exportHTML))
        XCTAssertTrue(response.success)
        guard case .object(let data)? = response.data,
            case .string(let html)? = data["html"]
        else {
            throw TestFailure.missingData
        }
        return html
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

    private func userText(_ message: Message) -> String? {
        guard case .user(let user) = message else { return nil }
        return user.content.compactMap { block in
            if case .text(let text, _) = block { text } else { nil }
        }.joined()
    }
}

private actor EventOutput {
    private var records: [Data] = []

    func append(_ data: Data) {
        records.append(Data(data.dropLast()))
    }

    func lines() -> [Data] { records }
    func isEmpty() -> Bool { records.isEmpty }
}

private actor TrustSelections {
    private let decision: TrustDecision
    private var directories: [URL] = []

    init(_ decision: TrustDecision) {
        self.decision = decision
    }

    func select(_ directory: URL) -> TrustDecision {
        directories.append(directory.standardizedFileURL)
        return decision
    }

    func selectedDirectories() -> [URL] { directories }
}

private enum TestFailure: Error {
    case missingData
}
