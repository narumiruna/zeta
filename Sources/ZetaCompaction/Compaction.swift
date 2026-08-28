import Foundation
import ZetaAI

public struct CompactionSettings: Sendable, Equatable {
    public var reserveTokens: Int
    public var keepRecentTokens: Int
    public var toolResultMaximumCharacters: Int

    public init(
        reserveTokens: Int = 16_384,
        keepRecentTokens: Int = 20_000,
        toolResultMaximumCharacters: Int = 2_000
    ) {
        self.reserveTokens = reserveTokens
        self.keepRecentTokens = keepRecentTokens
        self.toolResultMaximumCharacters = toolResultMaximumCharacters
    }
}

public struct CompactionPreparation: Sendable, Equatable {
    public var messagesToSummarize: [Message]
    public var retainedTail: [Message]
    public var estimatedTokensBefore: Int
    public var firstRetainedMessageIndex: Int
}

public enum Compaction {
    public static func estimateTokens(_ message: Message) -> Int {
        switch message {
        case .user(let value):
            estimate(value.content)
        case .assistant(let value):
            max(value.usage.totalTokens, estimate(value.content))
        case .toolResult(let value):
            estimate(value.content)
        case .custom(let value):
            max(1, String(describing: value.content).utf8.count / 4)
        }
    }

    public static func estimateTokens(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1) }
    }

    public static func shouldCompact(
        messages: [Message],
        contextWindow: Int,
        reserveTokens: Int
    ) -> Bool {
        estimateTokens(messages) > max(0, contextWindow - reserveTokens)
    }

    public static func prepare(
        messages: [Message],
        settings: CompactionSettings = CompactionSettings()
    ) -> CompactionPreparation? {
        guard messages.count > 1 else { return nil }
        let total = estimateTokens(messages)
        var retainedTokens = 0
        var cut = messages.count
        while cut > 1, retainedTokens < settings.keepRecentTokens {
            cut -= 1
            retainedTokens += estimateTokens(messages[cut])
        }
        cut = safeCutIndex(messages: messages, proposed: cut)
        guard cut > 0, cut < messages.count else { return nil }
        return CompactionPreparation(
            messagesToSummarize: Array(messages[..<cut]),
            retainedTail: Array(messages[cut...]),
            estimatedTokensBefore: total,
            firstRetainedMessageIndex: cut
        )
    }

    public static func summaryPrompt(
        preparation: CompactionPreparation,
        customInstructions: String? = nil,
        toolResultMaximumCharacters: Int = 2_000
    ) -> String {
        let transcript = preparation.messagesToSummarize.map { message in
            switch message {
            case .user(let value):
                return "USER:\n" + text(value.content)
            case .assistant(let value):
                return "ASSISTANT:\n" + text(value.content)
            case .toolResult(let value):
                let result = text(value.content)
                return "TOOL \(value.toolName):\n" + String(result.prefix(toolResultMaximumCharacters))
            case .custom(let value):
                return "CUSTOM \(value.role):\n" + String(describing: value.content)
            }
        }.joined(separator: "\n\n")
        let instructions =
            customInstructions
            ?? "Summarize the conversation for continuation. Preserve decisions, unfinished work, errors, and file changes."
        return "\(instructions)\n\n<conversation>\n\(transcript)\n</conversation>"
    }

    public static func branchSummaryPrompt(
        abandonedMessages: [Message],
        tokenBudget: Int
    ) -> String {
        var selected: [Message] = []
        var tokens = 0
        for message in abandonedMessages.reversed() {
            if case .toolResult = message { continue }
            let next = estimateTokens(message)
            if tokens + next > tokenBudget { break }
            selected.insert(message, at: 0)
            tokens += next
        }
        return "Summarize this abandoned branch and preserve useful discoveries:\n\n"
            + selected.map { message in
                switch message {
                case .user(let value): "USER: " + text(value.content)
                case .assistant(let value): "ASSISTANT: " + text(value.content)
                case .toolResult: ""
                case .custom(let value):
                    "CUSTOM \(value.role): " + String(describing: value.content)
                }
            }.joined(separator: "\n")
    }

    private static func safeCutIndex(messages: [Message], proposed: Int) -> Int {
        var cut = proposed
        while cut > 0, cut < messages.count {
            if case .toolResult = messages[cut] {
                cut -= 1
                continue
            }
            if case .assistant(let assistant) = messages[cut - 1],
                assistant.stopReason == .toolUse
            {
                cut -= 1
                continue
            }
            break
        }
        return cut
    }

    private static func estimate(_ blocks: [ContentBlock]) -> Int {
        let characters = blocks.reduce(0) { result, block in
            switch block {
            case .text(let text, _): result + text.utf8.count
            case .thinking(let text, _, _): result + text.utf8.count
            case .toolCall(let call):
                result + call.name.utf8.count + String(describing: call.arguments).utf8.count
            case .image: result + 4_800
            }
        }
        return max(1, (characters + 3) / 4)
    }

    private static func text(_ blocks: [ContentBlock]) -> String {
        blocks.compactMap { block in
            switch block {
            case .text(let text, _): text
            case .thinking(let text, _, _): "<thinking>\(text)</thinking>"
            case .toolCall(let call): "<tool name=\"\(call.name)\">\(call.arguments)</tool>"
            case .image(_, let mime): "<image mime=\"\(mime)\">"
            }
        }.joined(separator: "\n")
    }
}
