import XCTest
import ZetaAI
import ZetaAgent
import ZetaAuth
import ZetaConfig
import ZetaCore
import ZetaModes

@testable import ZetaCLI

final class ZetaCLITests: XCTestCase {
    func testImageMagicDetection() {
        XCTAssertEqual(
            ZetaCLI.imageMIME(Data([0x89, 0x50, 0x4E, 0x47, 0x00])),
            "image/png"
        )
        XCTAssertEqual(
            ZetaCLI.imageMIME(Data("RIFFxxxxWEBP".utf8)),
            "image/webp"
        )
        XCTAssertNil(ZetaCLI.imageMIME(Data("plain".utf8)))
    }

    func testArgumentConflictsAndExtensionFlags() throws {
        let args = try CLIArguments.parse(["--custom=value", "-p", "hello"])
        XCTAssertEqual(args.extensionFlags["custom"]!, "value")
        XCTAssertTrue(args.print)
        XCTAssertEqual(args.messages, ["hello"])
        XCTAssertThrowsError(try CLIArguments.parse(["--fork", "a", "--session", "b"]))
        XCTAssertThrowsError(try CLIArguments.parse(["--session-id", "-invalid-"]))
        let model = try CLIArguments.parse(["--model", "openai/gpt:high", "hello"])
        XCTAssertEqual(model.model, "openai/gpt")
        XCTAssertEqual(model.thinking, .high)
        XCTAssertTrue(model.thinkingSpecified)
    }

    func testJSONUpdateIsDeltaOnly() throws {
        let partial = AssistantMessage(
            content: [.text(text: "hello")],
            api: "faux",
            provider: "faux",
            model: "faux"
        )
        let event = AgentEvent.messageUpdate(
            partial,
            .textDelta(index: 0, delta: "o", partial: partial)
        )
        let value = try OrderedJSON.decode(
            JSONEncoder().encode(JSONAgentEvent(event))
        )
        guard case .object(let object) = value,
            case .object(let update)? = object["assistantMessageEvent"]
        else {
            return XCTFail("Expected JSON update")
        }
        XCTAssertNil(object["message"])
        XCTAssertNil(update["partial"])
        XCTAssertEqual(update["delta"], "o")
        XCTAssertEqual(update["contentIndex"], 0)
    }

    func testRPCRuntimeAcceptsPromptAndStateCommands() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "ok")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
        )
        let agent = Agent(
            state: AgentState(systemPrompt: "", model: model)
        ) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let prompt = try StrictRPCRequest.decode(
            Data(
                #"{"id":"1","type":"prompt","message":"hello"}"#.utf8
            )
        )
        let accepted = await runtime.handle(prompt)
        XCTAssertTrue(accepted.success)
        await runtime.waitForIdle()
        let state = await runtime.handle(
            StrictRPCRequest(
                id: "2",
                command: .getState,
                fields: [:]
            )
        )
        XCTAssertTrue(state.success)
        guard case .object(let stateData)? = state.data else {
            return XCTFail("Expected state")
        }
        XCTAssertEqual(stateData["messageCount"], 2)
    }

    func testBuiltInToolSchemasAreStrictAndMatchRequiredArguments() {
        let required: [String: JSONValue] = [
            "read": ["path": "file"],
            "write": ["path": "file", "content": "text"],
            "edit": ["path": "file", "edits": [["oldText": "a", "newText": "b"]]],
            "bash": ["command": "true"],
            "grep": ["pattern": "needle"],
            "find": ["pattern": "*.swift"],
            "ls": [:],
        ]
        XCTAssertEqual(Set(BuiltinToolSchemas.values.keys), Set(required.keys))
        for (name, arguments) in required {
            let schema = BuiltinToolSchemas.schema(for: name)
            XCTAssertTrue(schema.accepts(arguments), "\(name) should accept handler arguments")
            XCTAssertFalse(
                schema.accepts(["unexpected": true]),
                "\(name) should reject unknown or missing arguments"
            )
            guard case .object(let definition) = BuiltinToolSchemas.definitionParameters(for: name) else {
                return XCTFail("Expected object schema for \(name)")
            }
            XCTAssertEqual(definition["additionalProperties"], false)
        }
        XCTAssertFalse(BuiltinToolSchemas.schema(for: "ls").accepts(["path": 1]))
        XCTAssertFalse(BuiltinToolSchemas.schema(for: "edit").accepts(["path": "file", "edits": []]))
    }

    func testMigrationDefaultsToRuntimeAgentDirectory() {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let locations = ZetaCLI.migrationLocations(
            arguments: ["migrate"],
            home: home,
            workingDirectory: home,
            environment: [:]
        )
        XCTAssertEqual(locations.destination, home.appendingPathComponent(".pi/agent"))
        let overridden = ZetaCLI.migrationLocations(
            arguments: ["migrate", "--destination", "/tmp/custom-zeta-agent"],
            home: home,
            workingDirectory: home,
            environment: [:]
        )
        XCTAssertEqual(overridden.destination.path, "/tmp/custom-zeta-agent")
    }

    func testConcurrentRPCPromptsStartThenQueueWithoutDropping() async throws {
        let provider = HeldRPCProvider()
        let model = provider.model
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let first = await runtime.handle(
            StrictRPCRequest(id: "1", command: .prompt, fields: ["message": "first"])
        )
        XCTAssertTrue(first.success)
        await provider.waitUntilFirstCallStarts()
        let second = await runtime.handle(
            StrictRPCRequest(id: "2", command: .prompt, fields: ["message": "second"])
        )
        XCTAssertTrue(second.success)
        guard case .object(let secondData)? = second.data else {
            return XCTFail("Expected queued response")
        }
        XCTAssertEqual(secondData["queued"], true)
        await provider.finishFirstCall()
        await runtime.waitForIdle()
        let messages = await agent.state().messages
        let userText = messages.compactMap { message -> String? in
            guard case .user(let user) = message else { return nil }
            return user.content.compactMap { block in
                if case .text(let text, _) = block { text } else { nil }
            }.joined()
        }
        XCTAssertEqual(userText, ["first", "second"])
    }

    func testAbortBashWaitsForActiveCommandCancellation() async throws {
        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let running = Task {
            await runtime.handle(
                StrictRPCRequest(
                    id: "bash",
                    command: .bash,
                    fields: ["command": "sleep 30"]
                )
            )
        }
        try await Task.sleep(for: .milliseconds(150))
        let start = ContinuousClock.now
        let aborted = await runtime.handle(
            StrictRPCRequest(id: "abort", command: .abortBash)
        )
        let elapsed = start.duration(to: .now)
        XCTAssertTrue(aborted.success)
        guard case .object(let data)? = aborted.data else {
            return XCTFail("Expected abort response")
        }
        XCTAssertEqual(data["aborted"], true)
        XCTAssertLessThan(elapsed, .seconds(2))
        let bashResponse = await running.value
        if bashResponse.success {
            guard case .object(let data)? = bashResponse.data else {
                return XCTFail("Expected terminated bash result")
            }
            XCTAssertNotEqual(data["exitCode"], 0)
        } else {
            XCTAssertNotNil(bashResponse.error)
        }
    }

    func testNewSessionSwapsPersistentFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let arguments = try CLIArguments.parse([])
        let opened = try await PersistentSessionController.open(
            arguments: arguments,
            workingDirectory: cwd,
            defaultRoot: root.appendingPathComponent("sessions")
        )
        let session = try XCTUnwrap(opened)
        let originalFile = await session.currentFile()
        let original = try XCTUnwrap(originalFile)
        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: cwd,
            session: session
        )
        let response = await runtime.handle(StrictRPCRequest(command: .newSession))
        XCTAssertTrue(response.success)
        let replacementFile = await session.currentFile()
        let replacement = try XCTUnwrap(replacementFile)
        XCTAssertNotEqual(original, replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testInteractiveNewSessionRotatesPersistentFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let opened = try await PersistentSessionController.open(
            arguments: CLIArguments.parse([]),
            workingDirectory: cwd,
            defaultRoot: root.appendingPathComponent("sessions")
        )
        let session = try XCTUnwrap(opened)
        let originalFile = await session.currentFile()
        let original = try XCTUnwrap(originalFile)
        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }

        try await InteractiveSessionCommands.newSession(agent: agent, session: session)

        let replacementFile = await session.currentFile()
        let replacement = try XCTUnwrap(replacementFile)
        XCTAssertNotEqual(original, replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testThinkingCommandsPersistToSessionTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let opened = try await PersistentSessionController.open(
            arguments: CLIArguments.parse([]),
            workingDirectory: cwd,
            defaultRoot: root.appendingPathComponent("sessions")
        )
        let session = try XCTUnwrap(opened)
        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }

        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: cwd,
            session: session
        )
        let rpc = await runtime.handle(
            StrictRPCRequest(
                command: .setThinkingLevel,
                fields: ["level": "medium"]
            )
        )
        XCTAssertTrue(rpc.success)
        let rpcRestore = try await session.restore(models: [model])
        XCTAssertEqual(rpcRestore.thinking, .medium)
        let cycled = await runtime.handle(
            StrictRPCRequest(command: .cycleThinkingLevel)
        )
        XCTAssertTrue(cycled.success)
        let cycleRestore = try await session.restore(models: [model])
        XCTAssertEqual(cycleRestore.thinking, .high)

        try await InteractiveSessionCommands.setThinkingLevel(
            .xhigh,
            agent: agent,
            session: session
        )
        let interactiveRestore = try await session.restore(models: [model])
        XCTAssertEqual(interactiveRestore.thinking, .xhigh)
        let currentFile = await session.currentFile()
        let file = try XCTUnwrap(currentFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let contents = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(contents.contains(#""thinkingLevel":"xhigh""#))
    }

    func testSessionMutationsRejectBeforeChangingManagerWhileBusy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let opened = try await PersistentSessionController.open(
            arguments: CLIArguments.parse([]),
            workingDirectory: cwd,
            defaultRoot: root.appendingPathComponent("sessions")
        )
        let session = try XCTUnwrap(opened)
        _ = try await session.newSession()
        let originalFile = await session.currentFile()
        let original = try XCTUnwrap(originalFile)
        let alternateOpened = try await PersistentSessionController.open(
            arguments: CLIArguments.parse([]),
            workingDirectory: cwd,
            defaultRoot: root.appendingPathComponent("alternate-sessions")
        )
        let alternate = try XCTUnwrap(alternateOpened)
        _ = try await alternate.newSession()
        let alternateFile = await alternate.currentFile()
        let alternatePath = try XCTUnwrap(alternateFile).path
        let provider = HeldRPCProvider()
        let model = provider.model
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: cwd,
            session: session
        )
        let prompt = await runtime.handle(
            StrictRPCRequest(command: .prompt, fields: ["message": "hold"])
        )
        XCTAssertTrue(prompt.success)
        await provider.waitUntilFirstCallStarts()

        let switched = await runtime.handle(
            StrictRPCRequest(
                command: .switchSession,
                fields: ["sessionPath": .string(alternatePath)]
            )
        )
        let forked = await runtime.handle(
            StrictRPCRequest(command: .fork, fields: ["entryId": "missing"])
        )
        let cloned = await runtime.handle(StrictRPCRequest(command: .clone))
        XCTAssertFalse(switched.success)
        XCTAssertFalse(forked.success)
        XCTAssertFalse(cloned.success)
        let unchangedFile = await session.currentFile()
        XCTAssertEqual(unchangedFile, original)

        await provider.finishFirstCall()
        await runtime.waitForIdle()
    }

    func testModelDispatcherUsesEachRequestModelAndTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AuthStore(url: directory.appendingPathComponent("auth.json"))
        try await store.set(
            provider: "two",
            credential: .apiKey(key: "two-key", environment: nil)
        )
        let dispatcher = CLIModelStreamDispatcher(
            authStore: store,
            explicitAPIKeys: ["one": "one-key"],
            transportPreference: .auto,
            environment: { ["ZETA_FAUX_RESPONSE": "ok"] }
        )
        let first = Model(
            id: "first", name: "First", api: "openai-responses", provider: "one",
            baseURL: URL(string: "https://one.invalid")!, contextWindow: 1_000,
            maximumTokens: 100
        )
        let second = Model(
            id: "second", name: "Second", api: "anthropic-messages", provider: "two",
            baseURL: URL(string: "https://two.invalid")!, contextWindow: 1_000,
            maximumTokens: 100
        )

        let firstAuthentication = try await dispatcher.resolveAuthentication(
            for: first,
            environment: [:]
        )
        let secondAuthentication = try await dispatcher.resolveAuthentication(
            for: second,
            environment: [:]
        )
        XCTAssertEqual(firstAuthentication.apiKey, "one-key")
        XCTAssertEqual(secondAuthentication.apiKey, "two-key")

        for model in [first, second] {
            let stream = await dispatcher.stream(
                model: model,
                context: Context(),
                options: StreamOptions()
            )
            for try await _ in stream {}
            let result = await stream.result()
            XCTAssertEqual(result.provider, model.provider)
            XCTAssertEqual(result.model, model.id)
        }

        var codex = first
        codex.api = "openai-codex-responses"
        var bedrock = first
        bedrock.api = "bedrock-converse-stream"
        XCTAssertEqual(CLIProviderTransport.select(for: first, preference: .auto), .http)
        XCTAssertEqual(CLIProviderTransport.select(for: codex, preference: .auto), .codexWebSocket)
        XCTAssertEqual(CLIProviderTransport.select(for: codex, preference: .sse), .http)
        XCTAssertEqual(CLIProviderTransport.select(for: bedrock, preference: .auto), .bedrock)
    }

    func testVertexBearerUsesAuthorizationAndAPIKeyUsesGoogleHeader() async throws {
        let model = Model(
            id: "gemini", name: "Gemini", api: "google-vertex", provider: "google-vertex",
            baseURL: URL(string: "https://aiplatform.googleapis.com")!,
            contextWindow: 1_000, maximumTokens: 100
        )
        let bearer = CLIResolvedProviderAuthentication(
            bearerToken: "adc-token",
            headers: [:],
            environment: [:]
        ).applying(to: StreamOptions(), for: model)
        let bearerHeaders = try await bearer.transformHeaders?([
            "x-goog-api-key": "must-be-removed"
        ])
        XCTAssertNil(bearerHeaders?["x-goog-api-key"] ?? nil)
        XCTAssertEqual(bearerHeaders?["Authorization"] ?? nil, "Bearer adc-token")

        let apiKey = CLIResolvedProviderAuthentication(
            apiKey: "vertex-key",
            headers: [:],
            environment: [:]
        ).applying(to: StreamOptions(), for: model)
        let apiKeyHeaders = try await apiKey.transformHeaders?([
            "Authorization": "Bearer must-be-removed"
        ])
        XCTAssertNil(apiKeyHeaders?["Authorization"] ?? nil)
        XCTAssertEqual(apiKeyHeaders?["x-goog-api-key"] ?? nil, "vertex-key")
    }

    func testAuthReadinessUsesRuntimeCredentialResolution() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AuthStore(url: directory.appendingPathComponent("auth.json"))
        try await store.set(
            provider: "openai",
            credential: .oauth(
                access: "expired",
                refresh: "refresh",
                expires: 1,
                extras: [:]
            )
        )
        let expiredReady = await CLIProviderAuthenticationResolver.isReady(
            provider: "openai",
            store: store,
            environment: [:]
        )
        let environmentReady = await CLIProviderAuthenticationResolver.isReady(
            provider: "openai",
            store: store,
            environment: ["OPENAI_API_KEY": "environment-key"]
        )
        XCTAssertFalse(expiredReady)
        XCTAssertTrue(environmentReady)
    }

    func testStartupSettingsConfigureAgentQueueModes() async {
        let provider = FauxProvider()
        let model = await provider.models[0]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        var settings = Settings()
        settings.steeringMode = .all
        settings.followUpMode = .all

        await ZetaCLI.configure(agent: agent, from: settings)

        let steeringMode = await agent.steeringMode
        let followUpMode = await agent.followUpMode
        XCTAssertEqual(steeringMode, .all)
        XCTAssertEqual(followUpMode, .all)
    }

    func testRPCAutoCompactionRunsAfterThresholdCrossing() async throws {
        var model = Model(
            id: "compact", name: "Compact", api: "faux", provider: "faux",
            baseURL: URL(string: "https://example.invalid")!, contextWindow: 50_000,
            maximumTokens: 1_000
        )
        model.contextWindow = 50_000
        let provider = FauxProvider(models: [model])
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "summary")], api: model.api, provider: model.provider,
                model: model.id, stopReason: .stop
            )
        )
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "answer")], api: model.api, provider: model.provider,
                model: model.id, stopReason: .stop
            )
        )
        let large = String(repeating: "x", count: 100_000)
        let seeded: [Message] = [
            .user(UserMessage(large)),
            .assistant(
                AssistantMessage(
                    content: [.text(text: large)], api: model.api, provider: model.provider,
                    model: model.id, stopReason: .stop
                )
            ),
            .user(UserMessage(large)),
        ]
        let agent = Agent(state: AgentState(systemPrompt: "", model: model, messages: seeded)) {
            model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: [model],
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let accepted = await runtime.handle(
            StrictRPCRequest(command: .prompt, fields: ["message": "continue"])
        )
        XCTAssertTrue(accepted.success)
        await runtime.waitForIdle()
        let state = await agent.state()
        XCTAssertLessThan(state.messages.count, seeded.count + 2)
        let callCount = await provider.callCount()
        XCTAssertEqual(callCount, 2)
        guard case .user(let summary)? = state.messages.first else {
            return XCTFail("Expected compacted summary context")
        }
        XCTAssertTrue(
            summary.content.contains { block in
                if case .text(let text, _) = block { return text.contains("summary") }
                return false
            }
        )
    }

    func testPluginRuntimeRejectsUnsupportedRegistrationKinds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let plugin = root.appendingPathComponent("agent/plugins/sample")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        let script = plugin.appendingPathComponent("plugin.py")
        let source = #"""
            #!/usr/bin/env python3
            import base64,json,sys
            for line in sys.stdin:
                request=json.loads(line)
                registrations=[{"kind":"command","name":"hello","callback":"command.hello"}]
                payload=base64.b64encode(json.dumps(registrations,separators=(',',':')).encode()).decode()
                response={"id":request.get("id"),"type":"response","generation":request["generation"],"payload":payload}
                print(json.dumps(response,separators=(',',':')),flush=True)
            """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let manifest = #"""
            {"name":"sample","version":"1","protocolVersion":1,"executable":"plugin.py","capabilities":["commands"]}
            """#
        try Data(manifest.utf8).write(to: plugin.appendingPathComponent("zeta-plugin.json"))
        let runtime = CLIPluginRuntime()
        let diagnostics = await runtime.load(
            agentDirectory: root.appendingPathComponent("agent"),
            workingDirectory: root.appendingPathComponent("project"),
            projectTrusted: false
        )
        let tools = await runtime.tools()
        XCTAssertEqual(tools.count, 0)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].contains("Unsupported registration kinds: command"))
        XCTAssertTrue(diagnostics[0].contains("only tool registrations"))
        await runtime.stop()
    }

    func testModeResolution() throws {
        XCTAssertEqual(try CLIArguments.parse([]).effectiveMode(stdinIsTTY: true, stdoutIsTTY: true), .interactive)
        XCTAssertEqual(try CLIArguments.parse([]).effectiveMode(stdinIsTTY: false, stdoutIsTTY: true), .print)
        XCTAssertEqual(
            try CLIArguments.parse(["--mode", "rpc"]).effectiveMode(stdinIsTTY: false, stdoutIsTTY: false), .rpc)
    }
}

private actor HeldRPCProvider {
    let model = Model(
        id: "held", name: "Held", api: "faux", provider: "held",
        baseURL: URL(string: "https://example.invalid")!, contextWindow: 128_000,
        maximumTokens: 1_000
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
            let response = AssistantMessage(
                content: [.text(text: "response \(calls)")],
                api: model.api,
                provider: model.provider,
                model: model.id,
                stopReason: .stop
            )
            await stream.emit(.done(reason: .stop, message: response))
        }
        return stream
    }

    func waitUntilFirstCallStarts() async {
        while firstStream == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func finishFirstCall() async {
        guard let firstStream else { return }
        let response = AssistantMessage(
            content: [.text(text: "response 1")],
            api: model.api,
            provider: model.provider,
            model: model.id,
            stopReason: .stop
        )
        await firstStream.emit(.done(reason: .stop, message: response))
    }
}
