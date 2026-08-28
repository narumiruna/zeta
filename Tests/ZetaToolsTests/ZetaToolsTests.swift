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

    func testEditPreservesBOMAndCRLF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = FileTools(workingDirectory: directory)
        try tools.write(path: "file.txt", content: "\u{FEFF}a\r\nb\r\n")
        _ = try await tools.edit(path: "file.txt", replacements: [TextReplacement(oldText: "a\nb", newText: "x\ny")])
        XCTAssertEqual(try tools.read(path: "file.txt"), "\u{FEFF}x\r\ny\r\n")
    }
}

private func assertThrowsErrorAsync(_ expression: () async throws -> Void) async {
    do {
        try await expression()
        XCTFail("Expected error")
    } catch {}
}
