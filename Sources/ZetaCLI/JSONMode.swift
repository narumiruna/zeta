import Foundation
import ZetaAI
import ZetaAgent

extension ZetaCLI {
    static func runJSONMode(
        agent: Agent,
        prompt: UserMessage,
        remaining: [String],
        session: PersistentSessionController?,
        writeEvent: @escaping @Sendable (Data) async -> Void
    ) async -> Int32 {
        let subscription = await agent.subscribe { event in
            if let data = try? JSONEncoder().encode(JSONAgentEvent(event)) {
                var line = data
                line.append(0x0A)
                await writeEvent(line)
            }
        }
        let result: Int32
        do {
            try await CLISessionBoundary.prompt(prompt, agent: agent, session: session)
            for message in remaining {
                try await CLISessionBoundary.prompt(
                    UserMessage(message), agent: agent, session: session
                )
            }
            let state = await agent.state()
            guard case .assistant(let assistant)? = state.messages.last else {
                await agent.unsubscribe(subscription)
                return 1
            }
            result = [.error, .aborted].contains(assistant.stopReason) ? 1 : 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            result = 1
        }
        await agent.unsubscribe(subscription)
        return result
    }
}
