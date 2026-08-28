import Foundation
import ZetaCore

public enum MessageTransforms {
    public static func forModel(
        _ messages: [Message],
        target: Model,
        knownTools: [ToolDefinition] = []
    ) -> [Message] {
        let toolNames = Set(knownTools.map(\.name))
        var output: [Message] = []
        var pendingCalls: [String: String] = [:]
        for message in messages {
            switch message {
            case .assistant(var assistant):
                guard assistant.stopReason != .error,
                    assistant.stopReason != .deferred
                else {
                    continue
                }
                assistant.content = assistant.content.compactMap { block in
                    switch block {
                    case .thinking(let text, _, let redacted):
                        if assistant.provider == target.provider,
                            assistant.api == target.api
                        {
                            return block
                        }
                        guard !redacted, !text.isEmpty else { return nil }
                        return .text(text: "<thinking>\(text)</thinking>")
                    case .toolCall(var call):
                        call.id = normalizeToolCallID(call.id)
                        if !toolNames.isEmpty, !toolNames.contains(call.name) {
                            // Preserve calls to no-longer-active tools for transcript
                            // continuity; providers still require a paired result.
                        }
                        pendingCalls[call.id] = call.name
                        return .toolCall(call)
                    default:
                        return block
                    }
                }
                output.append(.assistant(assistant))
            case .toolResult(var result):
                result.toolCallId = normalizeToolCallID(result.toolCallId)
                pendingCalls[result.toolCallId] = nil
                output.append(.toolResult(result))
            case .user:
                appendMissingToolResults(&output, pending: &pendingCalls)
                output.append(message)
            case .custom:
                appendMissingToolResults(&output, pending: &pendingCalls)
                output.append(message)
            }
        }
        appendMissingToolResults(&output, pending: &pendingCalls)
        return output
    }

    public static func normalizeToolCallID(_ value: String) -> String {
        let allowed = value.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
                || $0 == "_" || $0 == "-"
        }
        var normalized = String(String.UnicodeScalarView(allowed))
        if normalized.isEmpty { normalized = "call" }
        if normalized.count > 64 { normalized = String(normalized.prefix(64)) }
        return normalized
    }

    public static func estimateContextTokens(_ context: Context) -> Int {
        var characters = context.systemPrompt?.utf8.count ?? 0
        characters += context.messages.reduce(0) { total, message in
            total + estimate(message)
        }
        characters += (context.tools ?? []).reduce(0) { total, tool in
            total + tool.name.utf8.count + tool.description.utf8.count
                + OrderedJSON.string(tool.parameters).utf8.count
        }
        return max(1, (characters + 3) / 4)
    }

    public static func classifyOverflow(
        status: Int?,
        message: String
    ) -> Bool {
        let text = message.lowercased()
        return status == 413
            || text.contains("context length")
            || text.contains("context window")
            || text.contains("too many tokens")
            || text.contains("maximum context")
    }

    public static func retryDelay(
        attempt: Int,
        baseMilliseconds: Int = 2_000,
        requestedMilliseconds: Int? = nil,
        maximumRequestedMilliseconds: Int = 60_000
    ) -> Int? {
        if let requestedMilliseconds {
            guard requestedMilliseconds <= maximumRequestedMilliseconds else {
                return nil
            }
            return max(0, requestedMilliseconds)
        }
        let exponent = min(20, max(0, attempt - 1))
        return baseMilliseconds.multipliedReportingOverflow(
            by: 1 << exponent
        ).overflow ? Int.max : baseMilliseconds * (1 << exponent)
    }

    private static func appendMissingToolResults(
        _ output: inout [Message],
        pending: inout [String: String]
    ) {
        for (id, name) in pending.sorted(by: { $0.key < $1.key }) {
            output.append(
                .toolResult(
                    ToolResultMessage(
                        toolCallId: id,
                        toolName: name,
                        content: [.text(text: "Tool call did not produce a result")],
                        isError: true
                    )
                )
            )
        }
        pending.removeAll()
    }

    private static func estimate(_ message: Message) -> Int {
        let blocks: [ContentBlock]
        switch message {
        case .user(let value): blocks = value.content
        case .assistant(let value): blocks = value.content
        case .toolResult(let value): blocks = value.content
        case .custom(let value):
            return OrderedJSON.string(value.content).utf8.count
        }
        return blocks.reduce(0) { total, block in
            switch block {
            case .text(let text, _): total + text.utf8.count
            case .thinking(let text, _, _): total + text.utf8.count
            case .image: total + 4_800
            case .toolCall(let call):
                total + call.name.utf8.count
                    + OrderedJSON.string(call.arguments).utf8.count
            }
        }
    }
}
