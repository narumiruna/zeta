import Foundation
import ZetaAI
import ZetaAgent
import ZetaCompaction
import ZetaConfig
import ZetaCore
import ZetaExport
import ZetaModes
import ZetaSessions
import ZetaTools

public actor CLIRPCRuntime {
    private let agent: Agent
    private let models: [Model]
    private let shell: ShellTool
    private let workingDirectory: URL
    private var autoCompaction: Bool
    private let compactionPolicy: ZetaCompaction.CompactionSettings
    private let retryPolicy: RetrySettings
    private var autoRetry: Bool
    private var retryPolicyInitialized = false
    private var sessionName: String?
    private let session: PersistentSessionController?
    private var promptTask: Task<Void, Never>?
    private var promptRunID: UUID?
    private var queuedPrompts: [UserMessage] = []
    private var activeBash: (id: UUID, task: Task<ShellResult, Error>)?
    private var sessionMutationInProgress = false
    private var compactionInProgress = false
    private var deferredErrors: [String] = []

    init(
        agent: Agent,
        models: [Model],
        workingDirectory: URL,
        session: PersistentSessionController? = nil,
        compactionSettings: ZetaConfig.CompactionSettings? = nil,
        retrySettings: RetrySettings? = nil
    ) {
        let defaults = Settings()
        let compactionSettings = compactionSettings ?? defaults.compaction
        let retrySettings = retrySettings ?? defaults.retry
        self.agent = agent
        self.models = models
        self.session = session
        self.workingDirectory = workingDirectory
        autoCompaction = compactionSettings.enabled
        retryPolicy = retrySettings
        autoRetry = retrySettings.enabled
        compactionPolicy = ZetaCompaction.CompactionSettings(
            reserveTokens: compactionSettings.reserveTokens,
            keepRecentTokens: compactionSettings.keepRecentTokens
        )
        shell = ShellTool(workingDirectory: workingDirectory)
    }

    func admit(
        _ request: StrictRPCRequest
    ) async -> Task<StrictRPCResponse, Never> {
        guard request.command == .bash else {
            let response = await handle(request)
            return Task { response }
        }
        do {
            let command = try requiredString("command", request.fields)
            guard activeBash == nil else {
                throw AgentError.blocked("A bash command is already running")
            }
            let id = UUID()
            let task = Task { try await shell.run(command: command) }
            activeBash = (id, task)
            return Task {
                await self.finishAdmittedBash(
                    request: request,
                    id: id,
                    task: task
                )
            }
        } catch {
            let response = StrictRPCResponse(
                id: request.id,
                command: request.command,
                success: false,
                error: String(describing: error)
            )
            return Task { response }
        }
    }

    public func handle(_ request: StrictRPCRequest) async -> StrictRPCResponse {
        do {
            let data = try await execute(request)
            return StrictRPCResponse(
                id: request.id,
                command: request.command,
                success: true,
                data: data
            )
        } catch {
            return StrictRPCResponse(
                id: request.id,
                command: request.command,
                success: false,
                error: String(describing: error)
            )
        }
    }

    private func execute(_ request: StrictRPCRequest) async throws -> JSONValue? {
        try surfaceDeferredErrors()
        try await session?.drainPersistenceErrors()
        await initializeRetryPolicy()
        switch request.command {
        case .prompt:
            guard !sessionMutationInProgress, !compactionInProgress else {
                throw AgentError.blocked("An agent operation is in progress")
            }
            let message = try userMessage(request.fields)
            if promptTask != nil {
                queuedPrompts.append(message)
                return ["queued": true]
            }
            if (await agent.state()).isStreaming {
                let behavior = optionalString("streamingBehavior", request.fields) ?? "steer"
                if behavior == "followUp" {
                    await agent.followUp(message)
                } else {
                    await agent.steer(message)
                }
                return ["queued": true]
            }
            let id = UUID()
            promptRunID = id
            promptTask = Task { await self.runPrompt(message, id: id) }
            return ["accepted": true]
        case .steer:
            await agent.steer(try userMessage(request.fields))
            return ["queued": true]
        case .followUp:
            await agent.followUp(try userMessage(request.fields))
            return ["queued": true]
        case .abort:
            await agent.abort()
            return ["aborted": true]
        case .clearQueue:
            queuedPrompts.removeAll()
            await agent.clearQueues()
            return ["cleared": true]
        case .newSession:
            guard !compactionInProgress else {
                throw AgentError.blocked("Agent is busy")
            }
            queuedPrompts.removeAll()
            promptTask?.cancel()
            await agent.abort()
            await agent.waitForIdle()
            if let promptTask { await promptTask.value }
            try await agent.reset()
            let file = try await session?.newSession(
                parentSession: optionalString("parentSession", request.fields)
            )
            sessionName = nil
            return [
                "created": true,
                "path": file.map { .string($0.path) } ?? .null,
            ]
        case .getState:
            return try await stateJSON()
        case .setModel:
            let provider = try requiredString("provider", request.fields)
            let id = try requiredString("modelId", request.fields)
            guard
                let model = models.first(where: {
                    $0.provider == provider && $0.id == id
                })
            else {
                throw ProviderError.unknownModel("\(provider)/\(id)")
            }
            try await session?.recordModel(model)
            await agent.setModel(model)
            return ["model": .string("\(provider)/\(id)")]
        case .cycleModel:
            let state = await agent.state()
            let current =
                models.firstIndex(where: {
                    $0.provider == state.model.provider && $0.id == state.model.id
                }) ?? 0
            let direction =
                optionalString("direction", request.fields) == "previous"
                ? -1 : 1
            let index = (current + direction + models.count) % models.count
            try await session?.recordModel(models[index])
            await agent.setModel(models[index])
            return [
                "provider": .string(models[index].provider),
                "modelId": .string(models[index].id),
            ]
        case .getAvailableModels:
            return .array(try models.map(encoded))
        case .setThinkingLevel:
            let raw = try requiredString("level", request.fields)
            guard let level = ThinkingLevel(rawValue: raw) else {
                throw RPCProtocolError.invalidType
            }
            try await session?.recordThinkingLevel(level)
            await agent.setThinkingLevel(level)
            return ["level": .string(raw)]
        case .cycleThinkingLevel:
            let state = await agent.state()
            let values = ThinkingLevel.allCases
            let current = values.firstIndex(of: state.thinkingLevel) ?? 0
            let next = values[(current + 1) % values.count]
            try await session?.recordThinkingLevel(next)
            await agent.setThinkingLevel(next)
            return ["level": .string(next.rawValue)]
        case .getAvailableThinkingLevels:
            return .array(ThinkingLevel.allCases.map { .string($0.rawValue) })
        case .setSteeringMode:
            let mode = try requiredString("mode", request.fields)
            await agent.setSteeringMode(mode == "all" ? .all : .oneAtATime)
            return ["mode": .string(mode)]
        case .setFollowUpMode:
            let mode = try requiredString("mode", request.fields)
            await agent.setFollowUpMode(mode == "all" ? .all : .oneAtATime)
            return ["mode": .string(mode)]
        case .compact:
            guard !sessionMutationInProgress, !compactionInProgress else {
                throw AgentError.blocked("Agent is busy")
            }
            compactionInProgress = true
            defer { compactionInProgress = false }
            let state = await agent.state()
            guard
                let preparation = Compaction.prepare(
                    messages: state.messages,
                    settings: compactionPolicy
                )
            else {
                return ["compacted": false]
            }
            _ = try await CLISessionBoundary.compact(
                agent: agent,
                session: session,
                preparation: preparation,
                summaryPrompt: Compaction.summaryPrompt(
                    preparation: preparation,
                    customInstructions: optionalString("customInstructions", request.fields)
                )
            )
            return [
                "compacted": true,
                "tokensBefore": .number(JSONNumber(preparation.estimatedTokensBefore)),
                "firstRetainedIndex": .number(JSONNumber(preparation.firstRetainedMessageIndex)),
            ]
        case .setAutoCompaction:
            autoCompaction = try requiredBool("enabled", request.fields)
            return ["enabled": .bool(autoCompaction)]
        case .setAutoRetry:
            autoRetry = try requiredBool("enabled", request.fields)
            await agent.configureRetry(
                maximumRetries: autoRetry ? retryPolicy.maxRetries : 0,
                baseDelayMilliseconds: retryPolicy.baseDelayMs,
                maximumDelayMilliseconds: retryPolicy.maxRetryDelayMs
            )
            return ["enabled": .bool(autoRetry)]
        case .abortRetry:
            await agent.abortRetry()
            return ["aborted": true]
        case .bash:
            let command = try requiredString("command", request.fields)
            guard activeBash == nil else {
                throw AgentError.blocked("A bash command is already running")
            }
            let id = UUID()
            let task = Task { try await shell.run(command: command) }
            activeBash = (id, task)
            defer {
                if activeBash?.id == id { activeBash = nil }
            }
            let result = try await task.value
            return [
                "output": .string(result.output),
                "exitCode": .number(JSONNumber(Int(result.exitCode))),
                "truncated": .bool(result.truncated),
            ]
        case .abortBash:
            guard let activeBash else { return ["aborted": false] }
            activeBash.task.cancel()
            _ = await activeBash.task.result
            if self.activeBash?.id == activeBash.id { self.activeBash = nil }
            return ["aborted": true]
        case .getSessionStats:
            let state = await agent.state()
            return [
                "messages": .number(JSONNumber(state.messages.count)),
                "tokens": .number(
                    JSONNumber(
                        MessageTransforms.estimateContextTokens(
                            Context(messages: state.messages)
                        ))),
                "name": sessionName.map(JSONValue.string) ?? .null,
            ]
        case .exportHTML:
            let state = await agent.state()
            let exported = try await exportJSONL(messages: state.messages)
            let html = SessionExporter.standaloneHTML(
                title: sessionName ?? "Zeta Session",
                sessionJSONL: exported.data,
                renderedTranscript: state.messages.map(String.init(describing:))
                    .joined(separator: "\n\n"),
                leafID: exported.leafID
            )
            if let outputPath = optionalString("outputPath", request.fields) {
                let output = URL(fileURLWithPath: outputPath).standardizedFileURL
                try Data(html.utf8).write(to: output, options: .atomic)
                return ["path": .string(output.path)]
            }
            return ["html": .string(html)]
        case .switchSession:
            guard let session else { return ["switched": false, "reason": "No persistent session selected"] }
            try await beginSessionMutation()
            defer { sessionMutationInProgress = false }
            let path = try requiredString("sessionPath", request.fields)
            let messages = try await session.switchTo(path: path)
            try await agent.setMessages(messages)
            return ["switched": true, "path": .string(path)]
        case .fork:
            guard let session else { return ["forked": false, "reason": "No persistent session selected"] }
            try await beginSessionMutation()
            defer { sessionMutationInProgress = false }
            let manager = try await session.fork(
                at: try requiredString("entryId", request.fields)
            )
            let messages = try await manager.context().messages
            try await agent.setMessages(messages)
            return ["forked": true, "entries": .number(JSONNumber((await manager.allEntries()).count))]
        case .clone:
            guard let session else { return ["cloned": false, "reason": "No persistent session selected"] }
            try await beginSessionMutation()
            defer { sessionMutationInProgress = false }
            let manager = try await session.clone()
            let messages = try await manager.context().messages
            try await agent.setMessages(messages)
            return ["cloned": true, "entries": .number(JSONNumber((await manager.allEntries()).count))]
        case .getForkMessages:
            return .array(
                try await agent.state().messages.compactMap { message in
                    if case .user = message { return try encoded(message) }
                    return nil
                })
        case .getEntries:
            var entries = await rpcEntries()
            if let since = optionalString("since", request.fields) {
                guard let index = entries.firstIndex(where: { $0.base.id == since }) else {
                    throw SessionError.missingEntry(since)
                }
                entries = Array(entries.dropFirst(index + 1))
            }
            let leafID = await rpcLeafID()
            return [
                "entries": .array(try entries.map(encoded)),
                "leafId": leafID.map(JSONValue.string) ?? .null,
            ]
        case .getTree:
            let tree =
                if let session {
                    await session.currentTree()
                } else {
                    Self.tree(from: await rpcEntries())
                }
            let leafID = await rpcLeafID()
            return [
                "tree": try encodedTree(tree),
                "leafId": leafID.map(JSONValue.string) ?? .null,
            ]
        case .getMessages:
            return .array(try await agent.state().messages.map(encoded))
        case .getLastAssistantText:
            let state = await agent.state()
            let value = state.messages.reversed().compactMap { message -> String? in
                guard case .assistant(let assistant) = message else { return nil }
                return assistant.content.compactMap { block in
                    if case .text(let text, _) = block { text } else { nil }
                }.joined()
            }.first
            return ["text": value.map(JSONValue.string) ?? .null]
        case .setSessionName:
            let name = try requiredString("name", request.fields)
            try await session?.setName(name)
            sessionName = name
            return ["name": .string(name)]
        case .getCommands:
            return .array(RPCCommandName.allCases.map { .string($0.rawValue) })
        }
    }

    func waitForIdle() async {
        if let promptTask { await promptTask.value }
    }

    func drainErrors() throws {
        try surfaceDeferredErrors()
    }

    private func finishAdmittedBash(
        request: StrictRPCRequest,
        id: UUID,
        task: Task<ShellResult, Error>
    ) async -> StrictRPCResponse {
        defer {
            if activeBash?.id == id { activeBash = nil }
        }
        do {
            let result = try await task.value
            return StrictRPCResponse(
                id: request.id,
                command: request.command,
                success: true,
                data: [
                    "output": .string(result.output),
                    "exitCode": .number(JSONNumber(Int(result.exitCode))),
                    "truncated": .bool(result.truncated),
                ]
            )
        } catch {
            return StrictRPCResponse(
                id: request.id,
                command: request.command,
                success: false,
                error: String(describing: error)
            )
        }
    }

    private func beginSessionMutation() async throws {
        guard !sessionMutationInProgress, !compactionInProgress, promptTask == nil else {
            throw AgentError.blocked("Agent is busy")
        }
        sessionMutationInProgress = true
        guard !(await agent.state()).isStreaming else {
            sessionMutationInProgress = false
            throw AgentError.blocked("Agent is busy")
        }
    }

    private func runPrompt(_ message: UserMessage, id: UUID) async {
        var next: UserMessage? = message
        do {
            while let current = next, !Task.isCancelled {
                try await compactIfNeeded()
                try await agent.prompt(current)
                try await session?.drainPersistenceErrors()
                if !Task.isCancelled {
                    try await compactIfNeeded()
                }
                next = queuedPrompts.isEmpty ? nil : queuedPrompts.removeFirst()
            }
        } catch {
            deferredErrors.append(error.localizedDescription)
            queuedPrompts.removeAll()
        }
        if promptRunID == id {
            promptRunID = nil
            promptTask = nil
        }
    }

    private func compactIfNeeded() async throws {
        guard autoCompaction else { return }
        let state = await agent.state()
        guard
            Compaction.shouldCompact(
                messages: state.messages,
                contextWindow: state.model.contextWindow,
                reserveTokens: compactionPolicy.reserveTokens
            ),
            let preparation = Compaction.prepare(
                messages: state.messages,
                settings: compactionPolicy
            )
        else {
            return
        }
        _ = try await CLISessionBoundary.compact(
            agent: agent,
            session: session,
            preparation: preparation,
            summaryPrompt: Compaction.summaryPrompt(preparation: preparation)
        )
    }

    private func surfaceDeferredErrors() throws {
        guard !deferredErrors.isEmpty else { return }
        let failures = deferredErrors
        deferredErrors.removeAll()
        throw DeferredPersistenceError(failures: failures)
    }

    private func initializeRetryPolicy() async {
        guard !retryPolicyInitialized else { return }
        retryPolicyInitialized = true
        await agent.configureRetry(
            maximumRetries: autoRetry ? retryPolicy.maxRetries : 0,
            baseDelayMilliseconds: retryPolicy.baseDelayMs,
            maximumDelayMilliseconds: retryPolicy.maxRetryDelayMs
        )
    }

    private func rpcEntries() async -> [SessionEntry] {
        if let session { return await session.currentEntries() }
        var parentID: String?
        return await agent.state().messages.enumerated().map { index, message in
            let id = String(format: "%08x", index + 1)
            defer { parentID = id }
            return .message(
                SessionEntryBase(
                    id: id,
                    parentId: parentID,
                    timestamp: Self.timestamp(for: message)
                ),
                message
            )
        }
    }

    private func rpcLeafID() async -> String? {
        if let session { return await session.currentLeafID() }
        let entries = await rpcEntries()
        return entries.last?.base.id
    }

    private static func tree(from entries: [SessionEntry]) -> [SessionTreeNode] {
        let nodes = entries.reduce(into: [String: SessionTreeNode]()) {
            $0[$1.base.id] = SessionTreeNode(entry: $1)
        }
        var roots: [SessionTreeNode] = []
        for entry in entries {
            guard let node = nodes[entry.base.id] else { continue }
            if let parentID = entry.base.parentId, let parent = nodes[parentID] {
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }
        return roots
    }

    private func encodedTree(_ nodes: [SessionTreeNode]) throws -> JSONValue {
        .array(
            try nodes.map { node in
                [
                    "entry": try encoded(node.entry),
                    "children": try encodedTree(node.children),
                ]
            }
        )
    }

    private func userMessage(_ fields: OrderedJSONObject) throws -> UserMessage {
        var content: [ContentBlock] = [.text(text: try requiredString("message", fields))]
        guard let value = fields["images"] else {
            return UserMessage(content: content, timestamp: timestamp())
        }
        guard case .array(let images) = value else {
            throw RPCProtocolError.invalidType
        }
        for image in images {
            guard case .object(let object) = image,
                object.count == 3,
                case .string("image")? = object["type"],
                case .string(let data)? = object["data"],
                case .string(let mimeType)? = object["mimeType"],
                !data.isEmpty,
                let base64 = try? Base64Content(rawValue: data),
                !base64.data.isEmpty,
                let detectedMIME = ZetaCLI.imageMIME(base64.data),
                Self.mimeTypesMatch(declared: mimeType, detected: detectedMIME)
            else {
                throw RPCProtocolError.invalidType
            }
            content.append(.image(data: data, mimeType: mimeType))
        }
        return UserMessage(content: content, timestamp: timestamp())
    }

    private func exportJSONL(messages: [Message]) async throws -> (data: Data, leafID: String?) {
        let header: SessionHeader
        let entries: [SessionEntry]
        let leafID: String?
        if let session {
            let snapshot = await session.exportSnapshot()
            header = snapshot.header
            entries = snapshot.entries
            leafID = snapshot.leafID
        } else {
            header = SessionHeader(
                id: UUID().uuidString.lowercased(),
                timestamp: ISO8601DateFormatter().string(from: Date()),
                cwd: workingDirectory.path
            )
            var parentID: String?
            entries = messages.enumerated().map { index, message in
                let id = String(format: "%08x", index + 1)
                defer { parentID = id }
                return .message(
                    SessionEntryBase(
                        id: id,
                        parentId: parentID,
                        timestamp: Self.timestamp(for: message)
                    ),
                    message
                )
            }
            leafID = entries.last?.base.id
        }
        var data = try SessionExporter.jsonLines([header])
        data.append(try SessionExporter.jsonLines(entries))
        return (data, leafID)
    }

    private static func mimeTypesMatch(declared: String, detected: String) -> Bool {
        let declared = declared.lowercased()
        return declared == detected || (declared == "image/jpg" && detected == "image/jpeg")
    }

    private func timestamp() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    private static func timestamp(for message: Message) -> String {
        let milliseconds: Int64 =
            switch message {
            case .user(let value): value.timestamp
            case .assistant(let value): value.timestamp
            case .toolResult(let value): value.timestamp
            case .custom(let value): value.timestamp
            }
        return ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        )
    }

    private func stateJSON() async throws -> JSONValue {
        let state = await agent.state()
        return [
            "model": [
                "provider": .string(state.model.provider),
                "id": .string(state.model.id),
            ],
            "thinkingLevel": .string(state.thinkingLevel.rawValue),
            "isStreaming": .bool(state.isStreaming),
            "messageCount": .number(JSONNumber(state.messages.count)),
            "autoCompaction": .bool(autoCompaction),
            "autoRetry": .bool(autoRetry),
        ]
    }

    private func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try OrderedJSON.decode(JSONEncoder().encode(value))
    }

    private func requiredString(
        _ key: String,
        _ fields: OrderedJSONObject
    ) throws -> String {
        guard case .string(let value)? = fields[key] else {
            throw RPCProtocolError.invalidType
        }
        return value
    }

    private func optionalString(
        _ key: String,
        _ fields: OrderedJSONObject
    ) -> String? {
        guard case .string(let value)? = fields[key] else { return nil }
        return value
    }

    private func requiredBool(
        _ key: String,
        _ fields: OrderedJSONObject
    ) throws -> Bool {
        guard case .bool(let value)? = fields[key] else {
            throw RPCProtocolError.invalidType
        }
        return value
    }
}
