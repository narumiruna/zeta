import Foundation
import XCTest
import ZetaAI
import ZetaAgent
import ZetaConfig
import ZetaCore
import ZetaModes
import ZetaSessions

@testable import ZetaCLI

final class LatestSettingsFeedbackTests: XCTestCase {
    func testExplicitVertexKeysOverrideStoredBearerTokens() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuthStore(url: root.appendingPathComponent("auth.json"))
        try await store.set(
            provider: "google-vertex",
            credential: .oauth(
                access: "stored-bearer",
                refresh: "refresh",
                expires: Int64.max,
                extras: [:]
            )
        )
        let model = vertexModel()

        let flagDispatcher = CLIModelStreamDispatcher(
            authStore: store,
            explicitAPIKeys: ["google-vertex": "flag-key"],
            transportPreference: .auto,
            environment: { [:] }
        )
        let flag = try await flagDispatcher.resolveAuthentication(for: model)
        XCTAssertEqual(flag.apiKey, "flag-key")
        XCTAssertNil(flag.bearerToken)

        let requestDispatcher = CLIModelStreamDispatcher(
            authStore: store,
            explicitAPIKeys: [:],
            transportPreference: .auto,
            environment: { [:] }
        )
        let request = try await requestDispatcher.resolveAuthentication(
            for: model,
            requestAPIKey: "request-key"
        )
        XCTAssertEqual(request.apiKey, "request-key")
        XCTAssertNil(request.bearerToken)
    }

    func testMinimumExpiryArithmeticRejectsMultiplicationAndDeadlineOverflow() throws {
        XCTAssertEqual(try ZetaCLI.durationMilliseconds("25ms"), 25)
        XCTAssertEqual(try ZetaCLI.durationMilliseconds("2h"), 7_200_000)
        XCTAssertThrowsError(try ZetaCLI.durationMilliseconds("9223372036854776s"))
        XCTAssertThrowsError(
            try ZetaCLI.minimumExpiryDeadline(
                nowMilliseconds: Int64.max - 4,
                minimumMilliseconds: 5
            )
        )
        XCTAssertEqual(
            try ZetaCLI.minimumExpiryDeadline(
                nowMilliseconds: Int64.max - 5,
                minimumMilliseconds: 5
            ),
            Int64.max
        )
    }

    func testRPCAdmissionPreservesPromptRecordOrder() async throws {
        let provider = AdmissionHeldProvider()
        let model = provider.model
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        let first = await runtime.admit(
            StrictRPCRequest(id: "first", command: .prompt, fields: ["message": "first"])
        )
        let second = await runtime.admit(
            StrictRPCRequest(id: "second", command: .prompt, fields: ["message": "second"])
        )
        let firstResponse = await first.value
        XCTAssertTrue(firstResponse.success)
        let secondResponse = await second.value
        XCTAssertTrue(secondResponse.success)
        guard case .object(let secondData)? = secondResponse.data else {
            return XCTFail("Expected queued response")
        }
        XCTAssertEqual(secondData["queued"], true)

        await provider.waitUntilFirstCallStarts()
        await provider.finishFirstCall()
        await runtime.waitForIdle()
        let text = await agent.state().messages.compactMap(userText)
        XCTAssertEqual(text, ["first", "second"])
    }

    func testRPCAdmissionAllowsAcceptedBashToBeAbortedConcurrently() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )

        let bash = await runtime.admit(
            StrictRPCRequest(command: .bash, fields: ["command": "sleep 30"])
        )
        try await Task.sleep(for: .milliseconds(100))
        let abort = await runtime.admit(StrictRPCRequest(command: .abortBash))
        let abortResponse = await abort.value
        XCTAssertTrue(abortResponse.success)
        guard case .object(let data)? = abortResponse.data else {
            return XCTFail("Expected abort response")
        }
        XCTAssertEqual(data["aborted"], true)
        _ = await bash.value
    }

    func testDispatcherAppliesSettingsTimeoutUnlessRequestOverrides() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuthStore(url: root.appendingPathComponent("auth.json"))
        let dispatcher = CLIModelStreamDispatcher(
            authStore: store,
            explicitAPIKeys: [:],
            transportPreference: .auto,
            httpIdleTimeoutMilliseconds: 12_345,
            environment: { [:] }
        )
        let defaulted = await dispatcher.applyingDefaultTimeout(to: StreamOptions())
        XCTAssertEqual(defaulted.timeout, .milliseconds(12_345))

        let explicit = StreamOptions(timeout: .seconds(7))
        let preserved = await dispatcher.applyingDefaultTimeout(to: explicit)
        XCTAssertEqual(preserved.timeout, .seconds(7))

        let disabledDispatcher = CLIModelStreamDispatcher(
            authStore: store,
            explicitAPIKeys: [:],
            transportPreference: .auto,
            httpIdleTimeoutMilliseconds: 0,
            environment: { [:] }
        )
        let disabled = await disabledDispatcher.applyingDefaultTimeout(
            to: StreamOptions()
        )
        XCTAssertEqual(disabled.timeout, .milliseconds(Int(Int32.max)))
    }

    func testRPCAutoCompactionUsesEnabledReserveAndKeepRecentSettings() async throws {
        let model = Model(
            id: "compact", name: "Compact", api: "faux", provider: "faux",
            baseURL: URL(string: "https://example.invalid")!,
            contextWindow: 100, maximumTokens: 20
        )
        let messages: [Message] = [
            .user(UserMessage(String(repeating: "a", count: 120))),
            .user(UserMessage(String(repeating: "b", count: 120))),
            .user(UserMessage("tail")),
        ]
        let disabledProvider = FauxProvider(models: [model])
        await disabledProvider.enqueue(assistant("answer", model: model))
        let disabledAgent = Agent(
            state: AgentState(systemPrompt: "", model: model, messages: messages)
        ) { model, context, options in
            await disabledProvider.stream(model: model, context: context, options: options)
        }
        var disabledSettings = Settings().compaction
        disabledSettings.enabled = false
        disabledSettings.reserveTokens = 50
        disabledSettings.keepRecentTokens = 1
        let disabledRuntime = CLIRPCRuntime(
            agent: disabledAgent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory,
            compactionSettings: disabledSettings
        )
        let disabledState = await disabledRuntime.handle(StrictRPCRequest(command: .getState))
        guard case .object(let state)? = disabledState.data else {
            return XCTFail("Expected state")
        }
        XCTAssertEqual(state["autoCompaction"], false)
        _ = await disabledRuntime.handle(
            StrictRPCRequest(command: .prompt, fields: ["message": "continue"])
        )
        await disabledRuntime.waitForIdle()
        let disabledCallCount = await disabledProvider.callCount()
        XCTAssertEqual(disabledCallCount, 1)

        let enabledProvider = FauxProvider(models: [model])
        await enabledProvider.enqueue(assistant("summary", model: model))
        await enabledProvider.enqueue(assistant("answer", model: model))
        let enabledAgent = Agent(
            state: AgentState(systemPrompt: "", model: model, messages: messages)
        ) { model, context, options in
            await enabledProvider.stream(model: model, context: context, options: options)
        }
        disabledSettings.enabled = true
        let enabledRuntime = CLIRPCRuntime(
            agent: enabledAgent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory,
            compactionSettings: disabledSettings
        )
        _ = await enabledRuntime.handle(
            StrictRPCRequest(command: .prompt, fields: ["message": "continue"])
        )
        await enabledRuntime.waitForIdle()
        let enabledCallCount = await enabledProvider.callCount()
        XCTAssertEqual(enabledCallCount, 2)
        let compacted = await enabledAgent.state().messages
        XCTAssertFalse(compacted.contains { userText($0) == String(repeating: "b", count: 120) })
    }

    func testRPCEntriesCursorAndTreeReturnSessionHierarchy() async throws {
        XCTAssertThrowsError(
            try StrictRPCRequest.decode(Data(#"{"type":"get_entries","since":""}"#.utf8))
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = "2026-01-01T00:00:00Z"
        let entries: [SessionEntry] = [
            .message(
                SessionEntryBase(id: "root", parentId: nil, timestamp: timestamp),
                .user(UserMessage("root"))
            ),
            .message(
                SessionEntryBase(id: "left", parentId: "root", timestamp: timestamp),
                .user(UserMessage("left"))
            ),
            .message(
                SessionEntryBase(id: "right", parentId: "root", timestamp: timestamp),
                .user(UserMessage("right"))
            ),
        ]
        let manager = try SessionManager(
            header: SessionHeader(id: "tree-session", timestamp: timestamp, cwd: root.path),
            entries: entries,
            file: root.appendingPathComponent("tree.jsonl")
        )
        let runtime = try await makeRuntime(
            model: vertexModel(),
            messages: entries.compactMap(entryMessage),
            session: PersistentSessionController(manager: manager)
        )

        let filtered = await runtime.handle(
            StrictRPCRequest(command: .getEntries, fields: ["since": "root"])
        )
        XCTAssertTrue(filtered.success)
        guard case .object(let filteredData)? = filtered.data,
            case .array(let filteredEntries)? = filteredData["entries"]
        else {
            return XCTFail("Expected entries response")
        }
        XCTAssertEqual(filteredEntries.compactMap(entryID), ["left", "right"])
        XCTAssertEqual(filteredData["leafId"], "right")

        let missing = await runtime.handle(
            StrictRPCRequest(command: .getEntries, fields: ["since": "missing"])
        )
        XCTAssertFalse(missing.success)

        let tree = await runtime.handle(StrictRPCRequest(command: .getTree))
        XCTAssertTrue(tree.success)
        guard case .object(let treeData)? = tree.data,
            case .array(let roots)? = treeData["tree"],
            case .object(let rootNode)? = roots.first,
            case .array(let children)? = rootNode["children"]
        else {
            return XCTFail("Expected hierarchical tree")
        }
        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(children.count, 2)
    }

    func testRPCSetModelPersistsBeforeUpdatingAgent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = vertexModel(id: "first")
        let second = vertexModel(id: "second")
        let file = root.appendingPathComponent("session.jsonl")
        let manager = try SessionManager(
            header: SessionHeader(
                id: "model-session",
                timestamp: "2026-01-01T00:00:00Z",
                cwd: root.path
            ),
            file: file
        )
        let session = PersistentSessionController(manager: manager)
        let runtime = try await makeRuntime(model: first, session: session, models: [first, second])
        let changed = await runtime.handle(
            StrictRPCRequest(
                command: .setModel,
                fields: ["provider": .string(second.provider), "modelId": .string(second.id)]
            )
        )
        XCTAssertTrue(changed.success)
        let changedModel = await runtimeModel(runtime)
        let restored = try await session.restore(models: [first, second])
        XCTAssertEqual(changedModel.id, second.id)
        XCTAssertEqual(restored.model?.id, second.id)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains(#""type":"model_change""#))

        let unwritableManager = try SessionManager(
            header: SessionHeader(
                id: "failed-model-session",
                timestamp: "2026-01-01T00:00:00Z",
                cwd: root.path
            ),
            file: root
        )
        let failedRuntime = try await makeRuntime(
            model: first,
            session: PersistentSessionController(manager: unwritableManager),
            models: [first, second]
        )
        let failed = await failedRuntime.handle(
            StrictRPCRequest(
                command: .setModel,
                fields: ["provider": .string(second.provider), "modelId": .string(second.id)]
            )
        )
        XCTAssertFalse(failed.success)
        let unchangedModel = await runtimeModel(failedRuntime)
        XCTAssertEqual(unchangedModel.id, first.id)
    }

    func testSessionArgumentResolvesHeaderIDInsteadOfFilenameSubstring() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project")
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let largeSession = sessions.appendingPathComponent("target-header-in-filename.jsonl")
        try await writeSession(
            id: "different-id",
            to: largeSession,
            cwd: cwd
        )
        let largeHandle = try FileHandle(forWritingTo: largeSession)
        try largeHandle.truncate(atOffset: 512 * 1_024 * 1_024)
        try largeHandle.close()
        let expected = sessions.appendingPathComponent("opaque.jsonl")
        try await writeSession(id: "target-header-id", to: expected, cwd: cwd)
        let arguments = try CLIArguments.parse([
            "--session", "target-header-id",
            "--session-dir", sessions.path,
        ])

        let start = ContinuousClock.now
        let opened = try await PersistentSessionController.open(
            arguments: arguments,
            workingDirectory: cwd,
            defaultRoot: sessions
        )
        let session = try XCTUnwrap(opened)
        let snapshot = await session.exportSnapshot()
        let currentFile = await session.currentFile()
        XCTAssertEqual(snapshot.header.id, "target-header-id")
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertEqual(
            currentFile?.resolvingSymlinksInPath(),
            expected.resolvingSymlinksInPath()
        )
    }

    func testLongAndShortLocalPackageFlagsUseTrustedProjectRootOnlyWhenApproved() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project/../project")
        let home = root.appendingPathComponent("home")
        let expectedProjectRoot = project.standardizedFileURL.appendingPathComponent(".pi/packages")

        for flag in ["-l", "--local"] {
            let trailingArguments = ["install", "npm:test", flag]
            let leadingArguments = ["install", flag, "npm:test"]
            XCTAssertEqual(ZetaCLI.packageCommandSource(trailingArguments), "npm:test")
            XCTAssertEqual(ZetaCLI.packageCommandSource(leadingArguments), "npm:test")
            let untrusted = ZetaCLI.packageCommandLocation(
                arguments: trailingArguments,
                workingDirectory: project,
                home: home
            )
            XCTAssertEqual(untrusted.root, expectedProjectRoot)
            XCTAssertFalse(untrusted.trusted)

            let approved = ZetaCLI.packageCommandLocation(
                arguments: ["install", "npm:test", flag, "--approve"],
                workingDirectory: project,
                home: home
            )
            XCTAssertEqual(approved.root, expectedProjectRoot)
            XCTAssertTrue(approved.trusted)
        }

        let global = ZetaCLI.packageCommandLocation(
            arguments: ["install", "npm:test"],
            workingDirectory: project,
            home: home
        )
        XCTAssertEqual(
            global.root,
            home.standardizedFileURL.appendingPathComponent(".pi/agent/packages")
        )
        XCTAssertTrue(global.trusted)
    }

    func testPluginToolCollisionsAreRejectedPerHostBeforePublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugins = root.appendingPathComponent("agent/plugins")
        try makeRegistrationPlugin(
            in: plugins,
            directory: "a-first",
            registrations: [
                ["kind": "tool", "name": "echo", "callback": "tool.echo"]
            ]
        )
        try makeRegistrationPlugin(
            in: plugins,
            directory: "b-duplicate",
            registrations: [
                ["kind": "tool", "name": "echo", "callback": "tool.echo"],
                ["kind": "tool", "name": "unreachable", "callback": "tool.unreachable"],
            ]
        )
        try makeRegistrationPlugin(
            in: plugins,
            directory: "c-builtin",
            registrations: [
                ["kind": "tool", "name": "read", "callback": "tool.read"]
            ]
        )
        let runtime = CLIPluginRuntime()

        let diagnostics = await runtime.load(
            agentDirectory: root.appendingPathComponent("agent"),
            workingDirectory: root.appendingPathComponent("project"),
            projectTrusted: false
        )
        let names = await runtime.tools().map(\.definition.name)

        XCTAssertEqual(names, ["echo"])
        XCTAssertEqual(diagnostics.count, 2)
        XCTAssertTrue(diagnostics.contains { $0.contains("collides") && $0.contains("echo") })
        XCTAssertTrue(diagnostics.contains { $0.contains("collides") && $0.contains("read") })
        XCTAssertFalse(names.contains("unreachable"))
        await runtime.stop()
    }

    private func vertexModel(id: String = "gemini") -> Model {
        Model(
            id: id, name: id, api: "google-vertex", provider: "google-vertex",
            baseURL: URL(string: "https://aiplatform.googleapis.com")!,
            contextWindow: 1_000, maximumTokens: 100
        )
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

    private func makeRuntime(
        model: Model,
        messages: [Message] = [],
        session: PersistentSessionController? = nil,
        models: [Model]? = nil
    ) async throws -> CLIRPCRuntime {
        let provider = FauxProvider(models: [model])
        let agent = Agent(state: AgentState(systemPrompt: "", model: model, messages: messages)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        return CLIRPCRuntime(
            agent: agent,
            models: models ?? [model],
            workingDirectory: FileManager.default.temporaryDirectory,
            session: session
        )
    }

    private func runtimeModel(_ runtime: CLIRPCRuntime) async -> Model {
        let response = await runtime.handle(StrictRPCRequest(command: .getState))
        guard case .object(let data)? = response.data,
            case .object(let model)? = data["model"],
            case .string(let id)? = model["id"]
        else {
            return vertexModel(id: "missing")
        }
        return vertexModel(id: id)
    }

    private func writeSession(id: String, to file: URL, cwd: URL) async throws {
        let manager = try SessionManager(
            header: SessionHeader(
                id: id,
                timestamp: "2026-01-01T00:00:00Z",
                cwd: cwd.path
            ),
            file: file
        )
        try await manager.materialize()
    }
}

private actor AdmissionHeldProvider {
    let model = Model(
        id: "held", name: "Held", api: "faux", provider: "held",
        baseURL: URL(string: "https://example.invalid")!,
        contextWindow: 128_000, maximumTokens: 100
    )
    private var calls = 0
    private var firstStream: AssistantEventStream?

    func stream(
        model: Model,
        context: Context,
        options: StreamOptions
    ) async -> AssistantEventStream {
        calls += 1
        let stream = AssistantEventStream()
        await stream.emit(
            .start(
                AssistantMessage(
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                )
            )
        )
        if calls == 1 {
            firstStream = stream
        } else {
            await stream.emit(
                .done(
                    reason: .stop,
                    message: AssistantMessage(
                        content: [.text(text: "response \(calls)")],
                        api: model.api,
                        provider: model.provider,
                        model: model.id,
                        stopReason: .stop
                    )
                )
            )
        }
        return stream
    }

    func waitUntilFirstCallStarts() async {
        while firstStream == nil {
            await Task.yield()
        }
    }

    func finishFirstCall() async {
        guard let firstStream else { return }
        await firstStream.emit(
            .done(
                reason: .stop,
                message: AssistantMessage(
                    content: [.text(text: "response 1")],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .stop
                )
            )
        )
    }
}

private func makeRegistrationPlugin(
    in plugins: URL,
    directory: String,
    registrations: [[String: String]]
) throws {
    let plugin = plugins.appendingPathComponent(directory)
    try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
    let registrationData = try JSONSerialization.data(
        withJSONObject: registrations,
        options: [.sortedKeys]
    )
    let registrationJSON = String(decoding: registrationData, as: UTF8.self)
    let script = plugin.appendingPathComponent("plugin.py")
    let source = #"""
        #!/usr/bin/env python3
        import base64,json,sys
        registrations=json.loads('\#(registrationJSON)')
        for line in sys.stdin:
            request=json.loads(line)
            payload=base64.b64encode(json.dumps(registrations,separators=(',',':')).encode()).decode()
            response={"id":request.get("id"),"type":"response","generation":request["generation"],"payload":payload}
            print(json.dumps(response,separators=(',',':')),flush=True)
        """#
    try Data(source.utf8).write(to: script)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o700],
        ofItemAtPath: script.path
    )
    let manifest = #"""
        {"name":"\#(directory)","version":"1","protocolVersion":1,"executable":"plugin.py","capabilities":["tools"]}
        """#
    try Data(manifest.utf8).write(
        to: plugin.appendingPathComponent("zeta-plugin.json")
    )
}

private func userText(_ message: Message) -> String? {
    guard case .user(let user) = message else { return nil }
    return user.content.compactMap { block in
        if case .text(let text, _) = block { text } else { nil }
    }.joined()
}

private func entryMessage(_ entry: SessionEntry) -> Message? {
    guard case .message(_, let message) = entry else { return nil }
    return message
}

private func entryID(_ value: JSONValue) -> String? {
    guard case .object(let object) = value,
        case .string(let id)? = object["id"]
    else {
        return nil
    }
    return id
}
