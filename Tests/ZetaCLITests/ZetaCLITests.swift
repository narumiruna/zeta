import XCTest
import ZetaAI
import ZetaAgent
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
        XCTAssertTrue(bashResponse.success)
        guard case .object(let bashData)? = bashResponse.data else {
            return XCTFail("Expected cancelled bash result")
        }
        XCTAssertNotEqual(bashData["exitCode"], 0)
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

    func testRPCAutoCompactionRunsAfterThresholdCrossing() async throws {
        var model = Model(
            id: "compact", name: "Compact", api: "faux", provider: "faux",
            baseURL: URL(string: "https://example.invalid")!, contextWindow: 100_000,
            maximumTokens: 1_000
        )
        model.contextWindow = 100_000
        let provider = FauxProvider(models: [model])
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "answer")], api: model.api, provider: model.provider,
                model: model.id, stopReason: .stop
            )
        )
        await provider.enqueue(
            AssistantMessage(
                content: [.text(text: "summary")], api: model.api, provider: model.provider,
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
