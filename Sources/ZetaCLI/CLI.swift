import Darwin
import Foundation
import ZetaAI
import ZetaAgent
import ZetaAuth
import ZetaBedrock
import ZetaCompaction
import ZetaConfig
import ZetaCore
import ZetaModes
import ZetaResources
import ZetaTUI
import ZetaTerminal
import ZetaTools

public enum ZetaCLI {
    public static let version = BuildVersion.current

    public static func runWithSignals(
        arguments: [String] = Array(CommandLine.arguments.dropFirst())
    ) async -> Int32 {
        guard let monitor = try? TerminationSignalMonitor() else {
            return await run(arguments: arguments)
        }
        return await withTaskGroup(of: Int32.self) { group in
            group.addTask { await run(arguments: arguments) }
            group.addTask { await monitor.wait() }
            let result = await group.next() ?? 1
            group.cancelAll()
            monitor.cancel()
            return result
        }
    }

    public static func run(arguments: [String] = Array(CommandLine.arguments.dropFirst())) async -> Int32 {
        setenv("PI_CODING_AGENT", "true", 1)
        setenv("AI_AGENT", "pi", 1)
        do {
            if let result = await runManagementCommand(arguments) {
                return result
            }
            let parsed = try CLIArguments.parse(arguments)
            if parsed.offline { setenv("PI_OFFLINE", "1", 1) }
            if parsed.help {
                FileHandle.standardOutput.write(Data(help.utf8))
                return 0
            }
            if parsed.version {
                print(version)
                return 0
            }
            let models = builtInModels()
            if parsed.listModels != nil {
                let query = parsed.listModels?.lowercased() ?? ""
                for model in models
                where query.isEmpty || model.id.lowercased().contains(query)
                    || model.provider.lowercased().contains(query)
                { print("\(model.provider)/\(model.id)\t\(model.name)") }
                return 0
            }
            let workingDirectory = URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ).standardizedFileURL
            let paths = ZetaPaths(workingDirectory: workingDirectory)
            let stdinIsTTY = isatty(STDIN_FILENO) == 1
            let stdoutIsTTY = isatty(STDOUT_FILENO) == 1
            let mode = parsed.effectiveMode(
                stdinIsTTY: stdinIsTTY,
                stdoutIsTTY: stdoutIsTTY
            )
            let globalSettingsStore = try SettingsStore(paths: paths, includeProject: false)
            let globalSettings = await globalSettingsStore.current()
            let trustStore = try TrustStore(url: paths.trust)
            let trust = try await CLIProjectTrust.resolve(
                directory: workingDirectory,
                store: trustStore,
                override: parsed.approve,
                default: globalSettings.defaultProjectTrust,
                projectResourcesPresent: CLIProjectTrust.hasTrustRequiringResources(
                    in: workingDirectory
                ),
                supportsInteractiveSelection: mode == .interactive && stdinIsTTY && stdoutIsTTY,
                selector: { CLITrustPrompt.select(directory: $0) }
            )
            if let diagnostic = trust.diagnostic {
                FileHandle.standardError.write(Data("warning: \(diagnostic)\n".utf8))
            }
            let trusted = trust.trusted
            let settingsStore =
                trusted
                ? try SettingsStore(paths: paths, includeProject: true)
                : globalSettingsStore
            let settings = await settingsStore.current()
            let resources = ResourceLoader(
                workingDirectory: workingDirectory,
                agentDirectory: paths.agentDirectory,
                trusted: trusted
            ).load()
            for diagnostic in resources.diagnostics {
                FileHandle.standardError.write(
                    Data("\(diagnostic.severity.rawValue): \(diagnostic.path): \(diagnostic.message)\n".utf8)
                )
            }
            let initial =
                mode == .rpc
                ? nil
                : try buildInitialPrompt(
                    parsed: parsed,
                    includeStdin: !stdinIsTTY
                )
            guard initial?.isEmpty == false || mode == .interactive || mode == .rpc else {
                throw CLIArgumentError.missingValue("prompt")
            }
            let persistentSession = try await PersistentSessionController.open(
                arguments: parsed,
                workingDirectory: workingDirectory,
                defaultRoot: paths.sessions
            )
            let restored = try await persistentSession?.restore(models: models)
            var model = try selectModel(parsed, from: models)
            if parsed.model == nil, parsed.provider == nil, let restoredModel = restored?.model {
                model = restoredModel
            }
            let authStore = try AuthStore(url: paths.auth)
            let stream = makeStream(
                initialModel: model,
                explicitAPIKey: parsed.apiKey,
                authStore: authStore,
                transport: settings.transport,
                httpIdleTimeoutMilliseconds: settings.httpIdleTimeoutMs
            )
            let pluginRuntime = CLIPluginRuntime()
            for diagnostic in await pluginRuntime.load(
                agentDirectory: paths.agentDirectory,
                workingDirectory: workingDirectory,
                projectTrusted: trusted
            ) {
                FileHandle.standardError.write(Data("warning: \(diagnostic)\n".utf8))
            }
            var tools = makeTools(
                cwd: workingDirectory, allow: parsed.tools,
                exclude: parsed.excludedTools, disabled: parsed.noTools || parsed.noBuiltinTools)
            if !parsed.noTools {
                tools += await pluginRuntime.tools().filter {
                    (parsed.tools == nil || parsed.tools!.contains($0.definition.name))
                        && !parsed.excludedTools.contains($0.definition.name)
                }
            }
            let agent = Agent(
                state: AgentState(
                    systemPrompt: systemPrompt(resources: resources),
                    model: model,
                    thinkingLevel: parsed.thinkingSpecified
                        ? parsed.thinking : (restored?.thinking ?? parsed.thinking),
                    tools: tools,
                    messages: restored?.messages ?? []
                ),
                stream: stream
            )
            await configure(agent: agent, from: settings)
            if let persistentSession {
                await agent.subscribe { event in await persistentSession.record(event) }
                if let name = parsed.name { try await persistentSession.setName(name) }
            }
            let result: Int32
            switch mode {
            case .print:
                result = await runPrint(
                    agent: agent,
                    prompt: initial!.message,
                    remaining: Array(parsed.messages.dropFirst()),
                    session: persistentSession
                )
            case .json:
                result = await runJSONMode(
                    agent: agent,
                    prompt: initial!.message,
                    remaining: Array(parsed.messages.dropFirst()),
                    session: persistentSession,
                    writeEvent: { data in
                        try? FileHandle.standardOutput.write(contentsOf: data)
                    }
                )
            case .interactive:
                result = await runInteractive(
                    agent: agent,
                    initial: initial?.message,
                    session: persistentSession,
                    settings: settings
                )
            case .rpc:
                result = await runRPC(
                    agent: agent,
                    models: models,
                    session: persistentSession,
                    compactionSettings: settings.compaction,
                    retrySettings: settings.retry
                )
            }
            await pluginRuntime.stop()
            return result
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func runPrint(
        agent: Agent,
        prompt: UserMessage,
        remaining: [String],
        session: PersistentSessionController?
    ) async -> Int32 {
        do {
            try await CLISessionBoundary.prompt(prompt, agent: agent, session: session)
            for message in remaining {
                try await CLISessionBoundary.prompt(
                    UserMessage(message), agent: agent, session: session
                )
            }
            let state = await agent.state()
            guard case .assistant(let assistant)? = state.messages.last else { return 1 }
            for block in assistant.content { if case .text(let text, _) = block { print(text, terminator: "") } }
            if assistant.content.contains(where: { if case .text = $0 { true } else { false } }) { print() }
            if [.error, .aborted].contains(assistant.stopReason) {
                if let error = assistant.errorMessage { FileHandle.standardError.write(Data("\(error)\n".utf8)) }
                return 1
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func runInteractive(
        agent: Agent,
        initial: UserMessage?,
        session: PersistentSessionController?,
        settings: Settings
    ) async -> Int32 {
        let terminal = ProcessTerminal()
        let transcript = Container()
        let input = Editor()
        let tui = makeInteractiveTUI(
            settings: settings,
            terminal: terminal,
            root: Container([transcript, input])
        )
        let runner = InteractiveRunner(
            agent: agent,
            transcript: transcript,
            tui: tui,
            session: session
        )
        input.onSubmit = { value in Task { await runner.submit(value) } }
        await agent.subscribe { event in await runner.receive(event) }
        tui.addInputListener { data in
            if data == "\u{1B}" {
                Task { await agent.abort() }
                return true
            }
            if data == "\u{03}" {
                Task { await runner.requestExit() }
                return true
            }
            return false
        }
        tui.setFocus(input)
        do { try tui.start() } catch { return 1 }
        let result = await withTaskCancellationHandler {
            if let initial { await runner.submit(initial) }
            while !(await runner.shouldExit()), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(25))
            }
            if Task.isCancelled { await runner.requestExit() }
            do {
                try await session?.drainPersistenceErrors()
            } catch {
                await runner.report(error)
            }
            return await runner.hadFailure() ? Int32(1) : Int32(0)
        } onCancel: {
            tui.stop()
            Task.detached { await runner.requestExit() }
        }
        tui.stop()
        return result
    }

    static func makeInteractiveTUI(
        settings: Settings,
        terminal: Terminal,
        root: Container
    ) -> any InteractiveTUI {
        if settings.tuiMode == "fullscreen" {
            return AltScreenTUI(
                terminal: terminal,
                root: root,
                transcriptOnExit: settings.fullscreenExit == "transcript"
            )
        }
        return TUI(terminal: terminal, root: root)
    }

    private static func runRPC(
        agent: Agent,
        models: [Model],
        session: PersistentSessionController?,
        compactionSettings: ZetaConfig.CompactionSettings,
        retrySettings: RetrySettings
    ) async -> Int32 {
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: models,
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ),
            session: session,
            compactionSettings: compactionSettings,
            retrySettings: retrySettings
        )
        let writer = RPCOutputWriter()
        await agent.subscribe { event in
            let envelope: JSONValue = [
                "type": "agent_event",
                "event": JSONAgentEvent(event).value,
            ]
            var line = OrderedJSON.encode(envelope)
            line.append(0x0A)
            await writer.write(line)
        }
        var decoder = LFJSONLDecoder()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for try await byte in FileHandle.standardInput.bytes {
                    for record in try decoder.push(Data([byte])) {
                        let request = try StrictRPCRequest.decode(record)
                        let operation = await runtime.admit(request)
                        group.addTask {
                            let response = await operation.value
                            await writer.write(response.encodedLine())
                        }
                    }
                }
                for record in try decoder.finish() {
                    let request = try StrictRPCRequest.decode(record)
                    let operation = await runtime.admit(request)
                    group.addTask {
                        let response = await operation.value
                        await writer.write(response.encodedLine())
                    }
                }
                try await group.waitForAll()
            }
            await runtime.waitForIdle()
            await agent.waitForIdle()
            try await session?.drainPersistenceErrors()
            try await runtime.drainErrors()
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    static func selectModel(_ args: CLIArguments, from models: [Model]) throws -> Model {
        if let requested = args.model {
            let pieces = requested.split(separator: "/", maxSplits: 1).map(String.init)
            if pieces.count == 2, let value = models.first(where: { $0.provider == pieces[0] && $0.id == pieces[1] }) {
                return value
            }
            if let value = models.first(where: {
                $0.id == requested && (args.provider == nil || $0.provider == args.provider)
            }) {
                return value
            }
            throw ProviderError.unknownModel(requested)
        }
        if let provider = args.provider {
            guard let value = models.first(where: { $0.provider == provider }) else {
                throw ProviderError.unknownModel(provider)
            }
            return value
        }
        return models[0]
    }

    private static func makeStream(
        initialModel: Model,
        explicitAPIKey: String?,
        authStore: AuthStore,
        transport: TransportPreference,
        httpIdleTimeoutMilliseconds: Int
    ) -> Agent.StreamFunction {
        let explicitAPIKeys = explicitAPIKey.map { [initialModel.provider: $0] } ?? [:]
        let dispatcher = CLIModelStreamDispatcher(
            authStore: authStore,
            explicitAPIKeys: explicitAPIKeys,
            transportPreference: transport,
            httpIdleTimeoutMilliseconds: httpIdleTimeoutMilliseconds
        )
        return { model, context, options in
            await dispatcher.stream(model: model, context: context, options: options)
        }
    }

    static func configure(agent: Agent, from settings: Settings) async {
        await agent.setSteeringMode(
            settings.steeringMode == .all ? .all : .oneAtATime
        )
        await agent.setFollowUpMode(
            settings.followUpMode == .all ? .all : .oneAtATime
        )
        await agent.configureRetry(
            maximumRetries: settings.retry.enabled ? settings.retry.maxRetries : 0,
            baseDelayMilliseconds: settings.retry.baseDelayMs,
            maximumDelayMilliseconds: settings.retry.maxRetryDelayMs
        )
    }

    private static func builtInModels() -> [Model] {
        if let catalog = try? BuiltinModelCatalog.bundled(),
            !catalog.models.isEmpty
        {
            return catalog.models
        }
        return [
            Model(
                id: "gpt-4o-mini", name: "GPT-4o mini", api: "openai-responses", provider: "openai",
                baseURL: URL(string: "https://api.openai.com/v1")!, contextWindow: 128_000, maximumTokens: 16_384),
            Model(
                id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", api: "anthropic-messages", provider: "anthropic",
                baseURL: URL(string: "https://api.anthropic.com")!, reasoning: true, contextWindow: 200_000,
                maximumTokens: 64_000),
            Model(
                id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", api: "google-generative-ai", provider: "google",
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!, reasoning: true,
                contextWindow: 1_000_000, maximumTokens: 65_536),
        ]
    }

    private static func makeTools(cwd: URL, allow: Set<String>?, exclude: Set<String>, disabled: Bool) -> [AgentTool] {
        guard !disabled else { return [] }
        let files = FileTools(workingDirectory: cwd)
        let searches = SearchTools(workingDirectory: cwd)
        let shell = ShellTool(workingDirectory: cwd)
        var values: [AgentTool] = [
            AgentTool(
                definition: ToolDefinition(
                    name: "read", description: "Read a file",
                    parameters: BuiltinToolSchemas.definitionParameters(for: "read")
                ),
                label: "read",
                parameterSchema: BuiltinToolSchemas.schema(for: "read")
            ) { _, arguments, _ in
                guard case .object(let object) = arguments, case .string(let path)? = object["path"] else {
                    throw FileToolError.invalidPath("path")
                }
                let offset = try integerArgument(object["offset"], name: "offset", minimum: 1) ?? 1
                let limit = try integerArgument(object["limit"], name: "limit", minimum: 0)
                switch try files.readContent(path: path, offset: offset, limit: limit) {
                case .text(let text):
                    return AgentToolResult(content: [.text(text: text)])
                case .image(let data, let mimeType):
                    return AgentToolResult(content: [
                        .text(text: "Read image file [\(mimeType)]"),
                        .image(data: data.base64EncodedString(), mimeType: mimeType),
                    ])
                }
            },
            AgentTool(
                definition: ToolDefinition(
                    name: "write", description: "Write a file",
                    parameters: BuiltinToolSchemas.definitionParameters(for: "write")
                ),
                label: "write",
                executionMode: .sequential,
                parameterSchema: BuiltinToolSchemas.schema(for: "write")
            ) { _, arguments, _ in
                guard case .object(let object) = arguments, case .string(let path)? = object["path"],
                    case .string(let content)? = object["content"]
                else { throw FileToolError.invalidPath("path/content") }
                try files.write(path: path, content: content)
                return AgentToolResult(content: [.text(text: "Successfully wrote to \(path).")])
            },
            AgentTool(
                definition: ToolDefinition(
                    name: "edit", description: "Edit a file",
                    parameters: BuiltinToolSchemas.definitionParameters(for: "edit")
                ),
                label: "edit",
                executionMode: .sequential,
                parameterSchema: BuiltinToolSchemas.schema(for: "edit")
            ) { _, arguments, _ in
                guard case .object(let object) = arguments,
                    case .string(let path)? = object["path"],
                    case .array(let rawEdits)? = object["edits"]
                else {
                    throw FileToolError.invalidEdit("path/edits")
                }
                let edits = try rawEdits.map { value -> TextReplacement in
                    guard case .object(let edit) = value,
                        case .string(let oldText)? = edit["oldText"],
                        case .string(let newText)? = edit["newText"]
                    else {
                        throw FileToolError.invalidEdit("oldText/newText")
                    }
                    return TextReplacement(oldText: oldText, newText: newText)
                }
                let result = try await files.edit(path: path, replacements: edits)
                return AgentToolResult(
                    content: [
                        .text(text: "Successfully replaced \(result.replacements) block(s) in \(path).")
                    ],
                    details: result.firstChangedLine.map {
                        ["firstChangedLine": .number(JSONNumber($0))]
                    }
                )
            },
            AgentTool(
                definition: ToolDefinition(
                    name: "bash", description: "Run a shell command",
                    parameters: BuiltinToolSchemas.definitionParameters(for: "bash")
                ),
                label: "bash",
                parameterSchema: BuiltinToolSchemas.schema(for: "bash")
            ) { _, arguments, update in
                guard case .object(let object) = arguments, case .string(let command)? = object["command"] else {
                    throw FileToolError.invalidEdit("command")
                }
                let result = try await shell.run(command: command) { value in
                    Task { await update(AgentToolResult(content: [.text(text: value)])) }
                }
                return AgentToolResult(
                    content: [.text(text: result.output)],
                    details: ["exitCode": .number(JSONNumber(Int(result.exitCode)))])
            },
        ]
        if allow?.contains("grep") == true {
            values.append(
                AgentTool(
                    definition: ToolDefinition(
                        name: "grep", description: "Search file contents",
                        parameters: BuiltinToolSchemas.definitionParameters(for: "grep")
                    ),
                    label: "grep",
                    parameterSchema: BuiltinToolSchemas.schema(for: "grep")
                ) { _, arguments, _ in
                    guard case .object(let object) = arguments,
                        case .string(let pattern)? = object["pattern"]
                    else {
                        throw FileToolError.invalidEdit("pattern")
                    }
                    let matches = try await searches.grep(pattern: pattern)
                    let text = matches.map { "\($0.path):\($0.line): \($0.text)" }
                        .joined(separator: "\n")
                    return AgentToolResult(content: [.text(text: text)])
                }
            )
        }
        if allow?.contains("find") == true {
            values.append(
                AgentTool(
                    definition: ToolDefinition(
                        name: "find", description: "Find paths",
                        parameters: BuiltinToolSchemas.definitionParameters(for: "find")
                    ),
                    label: "find",
                    parameterSchema: BuiltinToolSchemas.schema(for: "find")
                ) { _, arguments, _ in
                    guard case .object(let object) = arguments,
                        case .string(let pattern)? = object["pattern"]
                    else {
                        throw FileToolError.invalidEdit("pattern")
                    }
                    return AgentToolResult(
                        content: [.text(text: try await searches.find(pattern: pattern).joined(separator: "\n"))]
                    )
                }
            )
        }
        if allow?.contains("ls") == true {
            values.append(
                AgentTool(
                    definition: ToolDefinition(
                        name: "ls", description: "List a directory",
                        parameters: BuiltinToolSchemas.definitionParameters(for: "ls")
                    ),
                    label: "ls",
                    parameterSchema: BuiltinToolSchemas.schema(for: "ls")
                ) { _, arguments, _ in
                    let path: String
                    if case .object(let object) = arguments,
                        case .string(let value)? = object["path"]
                    {
                        path = value
                    } else {
                        path = "."
                    }
                    return AgentToolResult(
                        content: [.text(text: try files.list(path: path).joined(separator: "\n"))]
                    )
                }
            )
        }
        if let allow { values.removeAll { !allow.contains($0.definition.name) } }
        values.removeAll { exclude.contains($0.definition.name) }
        return values
    }

    private static func buildInitialPrompt(
        parsed: CLIArguments,
        includeStdin: Bool
    ) throws -> InitialPrompt {
        var text = ""
        var images: [ContentBlock] = []
        if includeStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            text += String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fileTools = FileTools(
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        for path in parsed.files {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if case .image(let data, let mimeType)? = try fileTools.readImage(path: url.path) {
                images.append(
                    .image(data: data.base64EncodedString(), mimeType: mimeType)
                )
                text += "<file name=\"\(url.path)\">\n[image attachment]\n</file>"
                continue
            }

            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { continue }
            guard let contents = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text += "<file name=\"\(url.path)\">\n\(contents)\n</file>"
        }
        text += parsed.messages.first ?? ""
        return InitialPrompt(text: text, images: images)
    }

    private static func integerArgument(
        _ value: JSONValue?,
        name: String,
        minimum: Int64
    ) throws -> Int? {
        guard let value else { return nil }
        guard case .number(let number) = value,
            let integer = number.safeIntegerValue,
            integer >= minimum,
            integer <= Int64(Int.max)
        else {
            throw FileToolError.invalidPath("\(name) must be an integer of at least \(minimum)")
        }
        return Int(integer)
    }

    static func imageMIME(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.starts(with: Array("BM".utf8)) { return "image/bmp" }
        if bytes.count >= 12,
            String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
            String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP"
        {
            return "image/webp"
        }
        return nil
    }

    private static func systemPrompt(resources: ResourceSnapshot) -> String {
        (["You are an expert coding assistant operating inside Zeta."] + resources.context).joined(
            separator: "\n\n"
        )
    }

    public static let help = """
        zeta [options] [--] [@files...] [messages...]

        Modes and models:
          -p, --print                 Print response and exit
          --mode <json|rpc>           Emit JSON events or run concurrent JSONL RPC
          --provider <name>           Select provider
          --model <provider/id>       Select model
          --api-key <value>           Override the selected provider credential
          --thinking <level>          off|minimal|low|medium|high|xhigh|max
          --list-models[=search]      List built-in models
          --offline                   Disable mutable network catalog refresh

        Sessions:
          --no-session                Do not persist this conversation
          -c, --continue              Continue the newest project session
          -r, --resume                Resume the newest project session
          --session <path-or-id>      Open a session file or matching session id
          --session-id <id>           Use a validated id for a new session
          --fork <path-or-id>         Fork a prior session before its leaf
          --session-dir <path>        Override the project session directory
          -n, --name <name>           Name the session

        Tools and trust:
          -t, --tools <names>         Enable only comma-separated tool names
          -xt, --exclude-tools <n>    Exclude comma-separated tool names
          -nbt, --no-builtin-tools    Disable built-in tools but retain plugin tools
          -nt, --no-tools             Disable all tools
          -a, --approve               Trust project resources and Swift plugins
          -na, --no-approve           Deny project resources and Swift plugins
          -- <messages>               Stop option parsing

        Management:
          zeta install|remove|update|list [source] [-l] [--approve]
          zeta auth <check|print-api-key|print-bearer-token> --provider <id>
          zeta migrate [--source <path>] --destination <path>

          -h, --help                  Show help
          -v, --version               Show version
        """ + "\n"
}

private struct InitialPrompt {
    var text: String
    var images: [ContentBlock]

    var isEmpty: Bool { text.isEmpty && images.isEmpty }

    var message: UserMessage {
        var content: [ContentBlock] = []
        if !text.isEmpty { content.append(.text(text: text)) }
        content += images
        return UserMessage(
            content: content,
            timestamp: Int64(Date().timeIntervalSince1970 * 1_000)
        )
    }
}

enum CLISessionBoundary {
    static func prompt(
        _ message: UserMessage,
        agent: Agent,
        session: PersistentSessionController?
    ) async throws {
        try await session?.drainPersistenceErrors()
        try await agent.prompt(message)
        try await session?.drainPersistenceErrors()
    }

    static func compact(
        agent: Agent,
        session: PersistentSessionController?,
        preparation: CompactionPreparation,
        summaryPrompt: String
    ) async throws -> String {
        try await session?.drainPersistenceErrors()
        let originalMessages = await agent.state().messages
        let summary = try await agent.compact(
            summaryPrompt: summaryPrompt,
            retainedTail: preparation.retainedTail
        )
        do {
            try await session?.recordCompaction(
                summary: summary,
                preparation: preparation
            )
            return summary
        } catch {
            try? await agent.setMessages(originalMessages)
            throw error
        }
    }
}

enum InteractiveTranscript {
    static func assistantText(_ message: AssistantMessage) -> String {
        let text = message.content.compactMap {
            if case .text(let text, _) = $0 { text } else { nil }
        }.joined()
        if text.isEmpty, [.error, .aborted].contains(message.stopReason) {
            return message.errorMessage ?? text
        }
        return text
    }
}

enum InteractiveSessionCommands {
    static func setThinkingLevel(
        _ level: ThinkingLevel,
        agent: Agent,
        session: PersistentSessionController?
    ) async throws {
        try await session?.recordThinkingLevel(level)
        await agent.setThinkingLevel(level)
    }

    static func newSession(
        agent: Agent,
        session: PersistentSessionController?
    ) async throws {
        let replacement = try await session?.prepareNewSession()
        await agent.abort()
        await agent.waitForIdle()
        try await agent.reset()
        if let replacement {
            await session?.publishNewSession(replacement)
        }
    }

    static func exit(agent: Agent) async {
        await agent.abort()
        await agent.waitForIdle()
    }
}
