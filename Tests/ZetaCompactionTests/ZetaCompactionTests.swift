import Foundation
import XCTest
import ZetaAI

@testable import ZetaCompaction

final class ZetaCompactionTests: XCTestCase {
    func testThresholdAndSafeCutAvoidOrphanToolResults() {
        let messages: [Message] = [
            .user(UserMessage(String(repeating: "a", count: 400), timestamp: 1)),
            .assistant(
                AssistantMessage(
                    content: [.toolCall(ToolCall(id: "c", name: "read"))],
                    api: "test",
                    provider: "test",
                    model: "test",
                    stopReason: .toolUse,
                    timestamp: 2
                )
            ),
            .toolResult(
                ToolResultMessage(
                    toolCallId: "c",
                    toolName: "read",
                    content: [.text(text: "result")],
                    isError: false,
                    timestamp: 3
                )
            ),
            .assistant(
                AssistantMessage(
                    content: [.text(text: "done")],
                    api: "test",
                    provider: "test",
                    model: "test",
                    stopReason: .stop,
                    timestamp: 4
                )
            ),
        ]
        XCTAssertTrue(
            Compaction.shouldCompact(
                messages: messages,
                contextWindow: 100,
                reserveTokens: 10
            )
        )
        let prepared = Compaction.prepare(
            messages: messages,
            settings: CompactionSettings(keepRecentTokens: 1)
        )
        XCTAssertNotNil(prepared)
        if let first = prepared?.retainedTail.first {
            if case .toolResult = first {
                XCTFail("Retained tail must not begin with an orphan tool result")
            }
        }
    }

    func testAssistantEstimatesDoNotSumCumulativeRequestUsage() {
        let messages: [Message] = [
            .assistant(
                AssistantMessage(
                    content: [.text(text: "one")],
                    api: "test",
                    provider: "test",
                    model: "test",
                    usage: Usage(input: 1_000, output: 4, totalTokens: 1_004),
                    stopReason: .stop
                )
            ),
            .assistant(
                AssistantMessage(
                    content: [.text(text: "two")],
                    api: "test",
                    provider: "test",
                    model: "test",
                    usage: Usage(input: 2_000, output: 5, totalTokens: 2_005),
                    stopReason: .stop
                )
            ),
        ]
        XCTAssertEqual(Compaction.estimateTokens(messages), 9)
    }

    func testImagesAndToolResultsHaveBoundedSummaryRepresentation() {
        let tool = ToolResultMessage(
            toolCallId: "c",
            toolName: "read",
            content: [.text(text: String(repeating: "x", count: 3_000))],
            isError: false,
            timestamp: 1
        )
        let preparation = CompactionPreparation(
            messagesToSummarize: [.toolResult(tool)],
            retainedTail: [.user(UserMessage(content: [.image(data: "", mimeType: "image/png")], timestamp: 2))],
            estimatedTokensBefore: 2_000,
            firstRetainedMessageIndex: 1
        )
        let prompt = Compaction.summaryPrompt(preparation: preparation)
        XCTAssertLessThan(prompt.count, 2_500)
        XCTAssertGreaterThan(Compaction.estimateTokens(preparation.retainedTail), 1_000)
    }
}
