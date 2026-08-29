import Foundation
import ZetaAI
import ZetaAgent
import ZetaCompaction
import ZetaTUI
import ZetaTools

protocol InteractiveTUI: Sendable {
    func addInputListener(_ listener: @escaping @Sendable (String) -> Bool)
    func setFocus(_ component: (Component & Focusable)?)
    func start() throws
    func stop()
    func requestRender(force: Bool)
}

extension InteractiveTUI {
    func requestRender() { requestRender(force: false) }
}

extension TUI: InteractiveTUI {}
extension AltScreenTUI: InteractiveTUI {}

actor InteractiveRunner {
    let agent: Agent
    let transcript: Container
    let tui: any InteractiveTUI
    private let shell: ShellTool
    private let session: PersistentSessionController?
    private var activeShell: (id: UUID, task: Task<ShellResult, Error>)?
    private var cancelledShells: Set<UUID> = []
    private var exitRequested = false
    private var failed = false

    init(
        agent: Agent,
        transcript: Container,
        tui: any InteractiveTUI,
        session: PersistentSessionController?,
        shell: ShellTool? = nil
    ) {
        self.agent = agent
        self.transcript = transcript
        self.tui = tui
        self.session = session
        self.shell =
            shell
            ?? ShellTool(
                workingDirectory: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath
                )
            )
    }

    func submit(_ message: UserMessage) async {
        do {
            try await submitMessage(message)
        } catch {
            report(error)
        }
    }

    func submit(_ text: String) async {
        guard !text.isEmpty else { return }
        do {
            if try await command(text) { return }
            try await submitMessage(UserMessage(text))
        } catch {
            report(error)
        }
    }

    func requestExit() async {
        guard !exitRequested else { return }
        exitRequested = true
        await cancelDirectShell()
        await InteractiveSessionCommands.exit(agent: agent)
    }

    func shouldExit() -> Bool { exitRequested }
    func hadFailure() -> Bool { failed }

    func report(_ error: Error) {
        failed = true
        transcript.add(Text(error.localizedDescription))
        tui.requestRender()
    }

    private func submitMessage(_ message: UserMessage) async throws {
        let state = await agent.state()
        if state.isStreaming {
            await agent.steer(message)
        } else {
            try await CLISessionBoundary.prompt(
                message, agent: agent, session: session
            )
        }
    }

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
            transcript.add(Markdown(InteractiveTranscript.assistantText(message)))
        case .toolExecutionStart(_, let name, _):
            transcript.add(Text("[\(name)]"))
        default:
            break
        }
        tui.requestRender()
    }

    private func command(_ text: String) async throws -> Bool {
        if text == "/quit" || text == "/exit" {
            await requestExit()
            return true
        }
        if text == "/abort" {
            await cancelDirectShell()
            await agent.abort()
            return true
        }
        if text == "/new" {
            await cancelDirectShell()
            try await InteractiveSessionCommands.newSession(
                agent: agent,
                session: session
            )
            transcript.clear()
            tui.requestRender()
            return true
        }
        if text.hasPrefix("/thinking ") {
            let raw = String(text.dropFirst("/thinking ".count))
            guard let level = ThinkingLevel(rawValue: raw) else {
                throw CLIArgumentError.invalidValue("/thinking")
            }
            try await InteractiveSessionCommands.setThinkingLevel(
                level,
                agent: agent,
                session: session
            )
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
            _ = try await CLISessionBoundary.compact(
                agent: agent,
                session: session,
                preparation: preparation,
                summaryPrompt: Compaction.summaryPrompt(preparation: preparation)
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
            guard activeShell == nil else {
                throw CLIArgumentError.invalidValue("shell command already running")
            }
            let id = UUID()
            let task = Task {
                try await shell.run(command: String(text.dropFirst()))
            }
            activeShell = (id, task)
            do {
                let result = try await task.value
                cancelledShells.remove(id)
                if activeShell?.id == id { activeShell = nil }
                transcript.add(Text(result.output))
                tui.requestRender()
                return true
            } catch {
                let deliberatelyCancelled = cancelledShells.remove(id) != nil
                if activeShell?.id == id { activeShell = nil }
                if deliberatelyCancelled, error is CancellationError {
                    return true
                }
                throw error
            }
        }
        return false
    }

    private func cancelDirectShell() async {
        guard let activeShell else { return }
        cancelledShells.insert(activeShell.id)
        activeShell.task.cancel()
        _ = try? await activeShell.task.value
        if self.activeShell?.id == activeShell.id {
            self.activeShell = nil
        }
    }
}
