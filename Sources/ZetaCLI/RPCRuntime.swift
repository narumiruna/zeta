import Foundation
import ZetaAI
import ZetaAgent
import ZetaCompaction
import ZetaCore
import ZetaExport
import ZetaModes
import ZetaTools

public actor CLIRPCRuntime {
    private let agent: Agent
    private let models: [Model]
    private let shell: ShellTool
    private var autoCompaction = true
    private var autoRetry = true
    private var sessionName: String?
    private let session: PersistentSessionController?

    init(
        agent: Agent,
        models: [Model],
        workingDirectory: URL,
        session: PersistentSessionController? = nil
    ) {
        self.agent = agent
        self.models = models
        self.session = session
        shell = ShellTool(workingDirectory: workingDirectory)
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
        switch request.command {
        case .prompt:
            let message = try requiredString("message", request.fields)
            let state = await agent.state()
            if state.isStreaming {
                let behavior = optionalString("streamingBehavior", request.fields) ?? "steer"
                if behavior == "followUp" {
                    await agent.followUp(UserMessage(message))
                } else {
                    await agent.steer(UserMessage(message))
                }
                return ["queued": true]
            }
            return ["accepted": true]
        case .steer:
            await agent.steer(UserMessage(try requiredString("message", request.fields)))
            return ["queued": true]
        case .followUp:
            await agent.followUp(UserMessage(try requiredString("message", request.fields)))
            return ["queued": true]
        case .abort:
            await agent.abort()
            return ["aborted": true]
        case .clearQueue:
            await agent.clearQueues()
            return ["cleared": true]
        case .newSession:
            await agent.abort()
            await agent.waitForIdle()
            try await agent.reset()
            return ["created": true]
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
            await agent.setThinkingLevel(level)
            return ["level": .string(raw)]
        case .cycleThinkingLevel:
            let state = await agent.state()
            let values = ThinkingLevel.allCases
            let current = values.firstIndex(of: state.thinkingLevel) ?? 0
            let next = values[(current + 1) % values.count]
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
            let state = await agent.state()
            guard let preparation = Compaction.prepare(messages: state.messages) else {
                return ["compacted": false]
            }
            let summary = try await agent.compact(
                summaryPrompt: Compaction.summaryPrompt(preparation: preparation),
                retainedTail: preparation.retainedTail
            )
            try await session?.recordCompaction(
                summary: summary,
                preparation: preparation
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
                maximumRetries: autoRetry ? 3 : 0,
                baseDelayMilliseconds: 2_000
            )
            return ["enabled": .bool(autoRetry)]
        case .abortRetry:
            await agent.abortRetry()
            return ["aborted": true]
        case .bash:
            let command = try requiredString("command", request.fields)
            let result = try await shell.run(command: command)
            return [
                "output": .string(result.output),
                "exitCode": .number(JSONNumber(Int(result.exitCode))),
                "truncated": .bool(result.truncated),
            ]
        case .abortBash:
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
            let data = try state.messages.map(encoded)
            var lines = Data()
            for value in data {
                lines.append(OrderedJSON.encode(value))
                lines.append(0x0A)
            }
            let html = SessionExporter.standaloneHTML(
                title: sessionName ?? "Zeta Session",
                sessionJSONL: lines,
                renderedTranscript: state.messages.map(String.init(describing:))
                    .joined(separator: "\n\n")
            )
            return ["html": .string(html)]
        case .switchSession:
            guard let session else { return ["switched": false, "reason": "No persistent session selected"] }
            let path = try requiredString("path", request.fields)
            let messages = try await session.switchTo(path: path)
            try await agent.setMessages(messages)
            return ["switched": true, "path": .string(path)]
        case .fork:
            guard let session else { return ["forked": false, "reason": "No persistent session selected"] }
            let manager = try await session.fork(at: optionalString("entryId", request.fields))
            let messages = try await manager.context().messages
            try await agent.setMessages(messages)
            return ["forked": true, "entries": .number(JSONNumber((await manager.allEntries()).count))]
        case .clone:
            guard let session else { return ["cloned": false, "reason": "No persistent session selected"] }
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
        case .getEntries, .getTree:
            if let session {
                return .array(try await session.currentEntries().map(encoded))
            }
            return .array(try await agent.state().messages.map(encoded))
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
            sessionName = optionalString("name", request.fields)
            try await session?.setName(sessionName)
            return ["name": sessionName.map(JSONValue.string) ?? .null]
        case .getCommands:
            return .array(RPCCommandName.allCases.map { .string($0.rawValue) })
        }
    }

    func afterResponse(_ request: StrictRPCRequest) async {
        guard request.command == .prompt,
            let message = try? requiredString("message", request.fields),
            !(await agent.state().isStreaming)
        else {
            return
        }
        try? await agent.prompt(UserMessage(message))
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
