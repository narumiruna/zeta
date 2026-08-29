import XCTest

@testable import ZetaCLI

final class CLIArgumentsFeedbackTests: XCTestCase {
    func testThinkingOptionsUseTheirOriginalOrder() throws {
        let modelLast = try CLIArguments.parse([
            "--thinking", "high", "--model", "openai/gpt:low",
        ])
        XCTAssertEqual(modelLast.model, "openai/gpt")
        XCTAssertEqual(modelLast.thinking, .low)

        let thinkingLast = try CLIArguments.parse([
            "--model=openai/gpt:low", "--thinking=high",
        ])
        XCTAssertEqual(thinkingLast.model, "openai/gpt")
        XCTAssertEqual(thinkingLast.thinking, .high)
    }

    func testApprovalAliasesRejectAttachedValues() {
        for value in ["-a=false", "-na=true"] {
            XCTAssertThrowsError(try CLIArguments.parse([value])) { error in
                XCTAssertEqual(error.localizedDescription, "Unknown short flag: \(value.split(separator: "=")[0])")
            }
        }
    }

    func testStringOptionsAcceptDashPrefixedValues() throws {
        let arguments = try CLIArguments.parse([
            "--provider", "-provider",
            "--model", "-model",
            "--api-key", "-secret",
            "--session", "-session",
            "--session-dir", "-cache",
            "-n", "-draft",
            "-t", "-read,-write",
            "-xt", "-bash",
        ])

        XCTAssertEqual(arguments.provider, "-provider")
        XCTAssertEqual(arguments.model, "-model")
        XCTAssertEqual(arguments.apiKey, "-secret")
        XCTAssertEqual(arguments.session, "-session")
        XCTAssertEqual(arguments.sessionDirectory, "-cache")
        XCTAssertEqual(try CLIArguments.parse(["--fork", "-fork"]).fork, "-fork")
        XCTAssertEqual(arguments.name, "-draft")
        XCTAssertEqual(arguments.tools, ["-read", "-write"])
        XCTAssertEqual(arguments.excludedTools, ["-bash"])
    }
}
