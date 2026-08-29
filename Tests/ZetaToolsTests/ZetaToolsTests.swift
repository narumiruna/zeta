import XCTest

@testable import ZetaTools

final class ZetaToolsTests: XCTestCase {
    func testHeadTruncationNeverReturnsPartialLine() {
        let result = Truncation.head("abcdef\nsecond", maximumLines: 10, maximumBytes: 3)
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.firstLineExceedsLimit)
        XCTAssertEqual(result.content, "")
    }

    func testTailTruncationUsesUTF8Boundary() {
        let result = Truncation.tail("🙂🙂🙂", maximumLines: 10, maximumBytes: 5)
        XCTAssertEqual(result.content, "🙂")
        XCTAssertTrue(result.partialBoundaryLine)
    }

    func testEditMatchesOriginalAndRejectsOverlap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = FileTools(workingDirectory: directory)
        try tools.write(path: "file.txt", content: "alpha beta gamma")
        await assertThrowsErrorAsync {
            _ = try await tools.edit(
                path: "file.txt",
                replacements: [
                    TextReplacement(oldText: "alpha beta", newText: "x"),
                    TextReplacement(oldText: "beta gamma", newText: "y"),
                ])
        }
        XCTAssertEqual(try tools.read(path: "file.txt"), "alpha beta gamma")
    }

    func testSearchListShellAndTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try Data("needle\n".utf8)
            .write(to: directory.appendingPathComponent("sub/file.txt"))
        let search = SearchTools(workingDirectory: directory)
        let matches = try await search.grep(pattern: "needle")
        XCTAssertEqual(matches.first?.line, 1)
        let found = try await search.find(pattern: "*.txt")
        XCTAssertTrue(found.contains { $0.contains("file.txt") })
        let files = FileTools(workingDirectory: directory)
        XCTAssertEqual(try files.list(), ["sub/"])
        let shell = ShellTool(workingDirectory: directory)
        let result = try await shell.run(command: "printf ok")
        XCTAssertEqual(result.output, "ok")
        XCTAssertEqual(result.exitCode, 0)
        do {
            _ = try await shell.run(command: "sleep 2", timeout: 0.01)
            XCTFail("Expected timeout")
        } catch FileToolError.timedOut {}
    }

    func testSearchTreatsDashPrefixedPatternAsExpression() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("--zeta-dash-pattern\nother\n".utf8)
            .write(to: directory.appendingPathComponent("file.txt"))

        for useExternalCommands in [true, false] {
            let search = SearchTools(
                workingDirectory: directory,
                useExternalCommands: useExternalCommands
            )
            let matches = try await search.grep(pattern: "--zeta-dash-pattern")
            XCTAssertEqual(matches.count, 1)
            XCTAssertTrue(matches[0].path.hasSuffix("file.txt"))
            XCTAssertEqual(matches[0].line, 1)
            XCTAssertEqual(matches[0].text, "--zeta-dash-pattern")
        }
    }

    func testSearchFallbackWorksWithoutExternalCommands() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("first\nneedle 42\n".utf8)
            .write(to: directory.appendingPathComponent("sub/file.txt"))
        try Data("needle ignored\n".utf8)
            .write(to: directory.appendingPathComponent("sub/file.md"))
        let search = SearchTools(
            workingDirectory: directory,
            useExternalCommands: false
        )
        let matches = try await search.grep(
            pattern: #"needle \d+"#,
            filePattern: "*.txt"
        )
        XCTAssertEqual(
            matches,
            [SearchMatch(path: "sub/file.txt", line: 2, text: "needle 42")]
        )
        let found = try await search.find(pattern: "*.txt")
        XCTAssertEqual(found, ["sub/file.txt"])
    }

    func testEditPreservesBOMAndCRLF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = FileTools(workingDirectory: directory)
        try tools.write(path: "file.txt", content: "\u{FEFF}a\r\nb\r\n")
        _ = try await tools.edit(path: "file.txt", replacements: [TextReplacement(oldText: "a\nb", newText: "x\ny")])
        XCTAssertEqual(try tools.read(path: "file.txt"), "\u{FEFF}x\r\ny\r\n")
    }

    func testEditRejectsInvalidUTF8WithoutChangingBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invalid.txt")
        let original = Data([0x61, 0x6C, 0x70, 0x68, 0x61, 0x0A, 0xFF, 0x0A])
        try original.write(to: file)
        let tools = FileTools(workingDirectory: directory)

        do {
            _ = try await tools.edit(
                path: "invalid.txt",
                replacements: [TextReplacement(oldText: "alpha", newText: "beta")]
            )
            XCTFail("Expected invalid UTF-8 to be rejected")
        } catch FileToolError.unreadable(let path) {
            XCTAssertEqual(path, "invalid.txt")
        } catch {
            XCTFail("Expected unreadable error, got \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}

private func assertThrowsErrorAsync(_ expression: () async throws -> Void) async {
    do {
        try await expression()
        XCTFail("Expected error")
    } catch {}
}
