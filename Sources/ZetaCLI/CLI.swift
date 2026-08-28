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
            let globalSettingsStore = try SettingsStore(paths: paths, includeProject: false)
            let globalSettings = await globalSettingsStore.current()
            let trustStore = try TrustStore(url: paths.trust)
            if let approved = parsed.approve {
                try await trustStore.set(approved ? .trusted : .denied, for: workingDirectory)
            }
            let trustDecision = await trustStore.decision(for: workingDirectory)
            let trusted =
                parsed.approve
                ?? trustDecision.map { $0 == .trusted }
                ?? (globalSettings.defaultProjectTrust == .always)
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
            let mode = parsed.effectiveMode(
                stdinIsTTY: isatty(STDIN_FILENO) == 1, stdoutIsTTY: isatty(STDOUT_FILENO) == 1)
            let initial =
                mode == .rpc
                ? nil
                : try buildInitialPrompt(
                    parsed: parsed,
                    includeStdin: isatty(STDIN_FILENO) != 1
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
            let apiKey: String?
            if let explicit = parsed.apiKey {
                apiKey = explicit
            } else {
                apiKey = try await authStore.resolveAPIKey(
                    provider: model.provider,
                    environment: ProcessInfo.processInfo.environment,
                    fallbackVariables: BuiltinProviderFactory.environmentVariables[model.provider] ?? []
                )
            }
            let stream = await makeStream(
                model: model,
                apiKey: apiKey,
                transport: settings.transport
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
            await agent.configureRetry(
                maximumRetries: settings.retry.enabled ? settings.retry.maxRetries : 0,
                baseDelayMilliseconds: settings.retry.baseDelayMs
            )
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
                    remaining: Array(parsed.messages.dropFirst())
                )
            case .json:
                result = await runJSON(
                    agent: agent,
                    prompt: initial!.message,
                    remaining: Array(parsed.messages.dropFirst())
                )
            case .interactive:
                result = await runInteractive(
                    agent: agent,
                    initial: initial?.message,
                    session: persistentSession
                )
            case .rpc:
                result = await runRPC(
                    agent: agent,
                    models: models,
                    session: persistentSession
                )
            }
            await pluginRuntime.stop()
            return result
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func runPrint(agent: Agent, prompt: UserMessage, remaining: [String]) async -> Int32 {
        do {
            try await agent.prompt(prompt)
            for message in remaining { try await agent.prompt(UserMessage(message)) }
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

    private static func runJSON(
        agent: Agent,
        prompt: UserMessage,
        remaining: [String]
    ) async -> Int32 {
        await agent.subscribe { event in
            if let data = try? JSONEncoder().encode(JSONAgentEvent(event)), var line = Optional(data) {
                line.append(0x0A)
                try? FileHandle.standardOutput.write(contentsOf: line)
            }
        }
        do {
            try await agent.prompt(prompt)
            for message in remaining { try await agent.prompt(UserMessage(message)) }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func runInteractive(
        agent: Agent,
        initial: UserMessage?,
        session: PersistentSessionController?
    ) async -> Int32 {
        let terminal = ProcessTerminal()
        let transcript = Container()
        let input = Editor()
        let tui = TUI(terminal: terminal, root: Container([transcript, input]))
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
            return Int32(0)
        } onCancel: {
            tui.stop()
            Task.detached { await runner.requestExit() }
        }
        tui.stop()
        return result
    }

    private static func runRPC(
        agent: Agent,
        models: [Model],
        session: PersistentSessionController?
    ) async -> Int32 {
        let runtime = CLIRPCRuntime(
            agent: agent,
            models: models,
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            ),
            session: session
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
                        group.addTask {
                            let response = await runtime.handle(request)
                            await writer.write(response.encodedLine())
                            await runtime.afterResponse(request)
                        }
                    }
                }
                for record in try decoder.finish() {
                    let request = try StrictRPCRequest.decode(record)
                    group.addTask {
                        let response = await runtime.handle(request)
                        await writer.write(response.encodedLine())
                        await runtime.afterResponse(request)
                    }
                }
                try await group.waitForAll()
            }
            await agent.waitForIdle()
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func selectModel(_ args: CLIArguments, from models: [Model]) throws -> Model {
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
        if let provider = args.provider, let value = models.first(where: { $0.provider == provider }) { return value }
        return models[0]
    }

    private static func makeStream(
        model: Model,
        apiKey: String?,
        transport: TransportPreference
    ) async -> Agent.StreamFunction {
        let fauxResponse = ProcessInfo.processInfo.environment["ZETA_FAUX_RESPONSE"]
        let fauxTool = ProcessInfo.processInfo.environment["ZETA_FAUX_TOOL"]
        if fauxResponse != nil || fauxTool != nil {
            let provider = FauxProvider(models: [model], tokensPerSecond: 10_000)
            if let fauxTool {
                await provider.enqueue(
                    AssistantMessage(
                        content: [
                            .toolCall(
                                ToolCall(
                                    id: "faux-tool-1",
                                    name: fauxTool,
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
            await provider.enqueue(
                AssistantMessage(
                    content: [.text(text: fauxResponse ?? "faux-ok")],
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    stopReason: .stop
                )
            )
            return { model, context, options in
                await provider.stream(model: model, context: context, options: options)
            }
        }
        if model.api == "openai-codex-responses", transport != .sse {
            let pool = CodexWebSocketPool(factory: CodexWebSocket.defaultFactory())
            let provider = CodexWebSocketProvider(
                models: [model],
                pool: pool,
                environment: {
                    var values = ProcessInfo.processInfo.environment
                    if let apiKey { values["OPENAI_CODEX_TOKEN"] = apiKey }
                    return values
                }
            )
            return { model, context, options in
                var resolved = options
                if resolved.apiKey == nil { resolved.apiKey = apiKey }
                return await provider.stream(model: model, context: context, options: resolved)
            }
        }
        if model.api == "bedrock-converse-stream" {
            let environment = ProcessInfo.processInfo.environment
            let provider = BedrockProvider(
                models: [model],
                region: environment["AWS_REGION"] ?? environment["AWS_DEFAULT_REGION"] ?? "us-east-1"
            ) {
                guard let credential = CredentialResolver.aws(environment: environment) else {
                    throw ProviderError.missingCredential(model.provider)
                }
                return credential
            }
            return { model, context, options in
                await provider.stream(model: model, context: context, options: options)
            }
        }
        let environmentVariables =
            BuiltinProviderFactory.environmentVariables[model.provider] ?? []
        let provider = HTTPProvider(
            configuration: ProviderConfiguration(
                id: model.provider,
                api: model.api,
                baseURL: model.baseURL,
                models: [model],
                apiKeyEnvironmentVariables: environmentVariables
            ),
            environment: {
                var result = ProcessInfo.processInfo.environment
                if let apiKey, let variable = environmentVariables.first {
                    result[variable] = apiKey
                }
                return result
            }
        )
        return { model, context, options in
            await provider.stream(model: model, context: context, options: options)
        }
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
                definition: ToolDefinition(name: "read", description: "Read a file", parameters: [:]), label: "read"
            ) { _, arguments, _ in
                guard case .object(let object) = arguments, case .string(let path)? = object["path"] else {
                    throw FileToolError.invalidPath("path")
                }
                return AgentToolResult(content: [.text(text: try files.read(path: path))])
            },
            AgentTool(
                definition: ToolDefinition(name: "write", description: "Write a file", parameters: [:]), label: "write",
                executionMode: .sequential
            ) { _, arguments, _ in
                guard case .object(let object) = arguments, case .string(let path)? = object["path"],
                    case .string(let content)? = object["content"]
                else { throw FileToolError.invalidPath("path/content") }
                try files.write(path: path, content: content)
                return AgentToolResult(content: [.text(text: "Successfully wrote to \(path).")])
            },
            AgentTool(
                definition: ToolDefinition(name: "edit", description: "Edit a file", parameters: [:]),
                label: "edit",
                executionMode: .sequential
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
                definition: ToolDefinition(name: "bash", description: "Run a shell command", parameters: [:]),
                label: "bash"
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
                    definition: ToolDefinition(name: "grep", description: "Search file contents", parameters: [:]),
                    label: "grep"
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
                    definition: ToolDefinition(name: "find", description: "Find paths", parameters: [:]),
                    label: "find"
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
                    definition: ToolDefinition(name: "ls", description: "List a directory", parameters: [:]),
                    label: "ls"
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
        for path in parsed.files {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { continue }
            if let mime = imageMIME(data) {
                images.append(
                    .image(data: data.base64EncodedString(), mimeType: mime)
                )
                text += "<file name=\"\(url.path)\">\n[image attachment]\n</file>"
            } else {
                guard let contents = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                text += "<file name=\"\(url.path)\">\n\(contents)\n</file>"
            }
        }
        text += parsed.messages.first ?? ""
        return InitialPrompt(text: text, images: images)
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
          zeta migrate [--source <path>] [--destination <path>]

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

private actor InteractiveRunner {
    let agent: Agent
    let transcript: Container
    let tui: TUI
    private let shell: ShellTool
    private let session: PersistentSessionController?
    private var exitRequested = false

    init(
        agent: Agent,
        transcript: Container,
        tui: TUI,
        session: PersistentSessionController?
    ) {
        self.agent = agent
        self.transcript = transcript
        self.tui = tui
        self.session = session
        shell = ShellTool(
            workingDirectory: URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath
            )
        )
    }

    func submit(_ message: UserMessage) async {
        let state = await agent.state()
        if state.isStreaming {
            await agent.steer(message)
        } else {
            try? await agent.prompt(message)
        }
    }

    func submit(_ text: String) async {
        guard !text.isEmpty else { return }
        do {
            if try await command(text) { return }
            let state = await agent.state()
            if state.isStreaming {
                await agent.steer(UserMessage(text))
            } else {
                try await agent.prompt(UserMessage(text))
            }
        } catch {
            transcript.add(Text(error.localizedDescription))
            tui.requestRender()
        }
    }

    func requestExit() {
        guard !exitRequested else { return }
        exitRequested = true
    }

    func shouldExit() -> Bool { exitRequested }

    func receive(_ event: AgentEvent) {
        switch event {
        case .messageEnd(.user(let message)):
            transcript.add(
                Text(
                    "> "
                        + message.content.compactMap {
                            if case .text(let text, _) = $0 { text } else { nil }
                        }.joined()
                )
            )
        case .messageEnd(.assistant(let message)):
            transcript.add(
                Markdown(
                    message.content.compactMap {
                        if case .text(let text, _) = $0 { text } else { nil }
                    }.joined()
                )
            )
        case .toolExecutionStart(_, let name, _):
            transcript.add(Text("[\(name)]"))
        default:
            break
        }
        tui.requestRender()
    }

    private func command(_ text: String) async throws -> Bool {
        if text == "/quit" || text == "/exit" {
            requestExit()
            return true
        }
        if text == "/abort" {
            await agent.abort()
            return true
        }
        if text == "/new" {
            await agent.abort()
            await agent.waitForIdle()
            try await agent.reset()
            transcript.clear()
            tui.requestRender()
            return true
        }
        if text.hasPrefix("/thinking ") {
            let raw = String(text.dropFirst("/thinking ".count))
            guard let level = ThinkingLevel(rawValue: raw) else {
                throw CLIArgumentError.invalidValue("/thinking")
            }
            await agent.setThinkingLevel(level)
            transcript.add(Text("Thinking level: \(raw)"))
            tui.requestRender()
            return true
        }
        if text == "/session" {
            let state = await agent.state()
            transcript.add(
                Text(
                    "Model: \(state.model.provider)/\(state.model.id), "
                        + "messages: \(state.messages.count)"
                )
            )
            tui.requestRender()
            return true
        }
        if text == "/compact" {
            let state = await agent.state()
            guard let preparation = Compaction.prepare(messages: state.messages) else {
                transcript.add(Text("Nothing to compact"))
                tui.requestRender()
                return true
            }
            let summary = try await agent.compact(
                summaryPrompt: Compaction.summaryPrompt(preparation: preparation),
                retainedTail: preparation.retainedTail
            )
            try await session?.recordCompaction(
                summary: summary,
                preparation: preparation
            )
            transcript.add(Text("Compacted at message \(preparation.firstRetainedMessageIndex)"))
            tui.requestRender()
            return true
        }
        if text == "/help" || text == "/hotkeys" {
            transcript.add(
                Text(
                    "/new /session /thinking <level> /compact /abort /quit; "
                        + "prefix shell commands with !"
                )
            )
            tui.requestRender()
            return true
        }
        if text.hasPrefix("!") {
            let result = try await shell.run(
                command: String(text.dropFirst())
            )
            transcript.add(Text(result.output))
            tui.requestRender()
            return true
        }
        return false
    }
}
