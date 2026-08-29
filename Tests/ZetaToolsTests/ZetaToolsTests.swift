import Darwin
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

    func testReadBoundsDefaultsAndPreservesOffsetLimitSemantics() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = (1...2_500).map { "line-\($0)" }.joined(separator: "\n")
        try Data(content.utf8).write(to: directory.appendingPathComponent("lines.txt"))
        let tools = FileTools(workingDirectory: directory)

        let bounded = try tools.read(path: "lines.txt")

        XCTAssertEqual(bounded.split(separator: "\n").count, defaultMaximumLines)
        XCTAssertTrue(bounded.hasSuffix("line-2000"))
        XCTAssertLessThanOrEqual(bounded.utf8.count, defaultMaximumBytes)
        XCTAssertEqual(
            try tools.read(path: "lines.txt", offset: 2_000, limit: 2),
            "line-2000\nline-2001"
        )
        XCTAssertEqual(try tools.read(path: "lines.txt", offset: 3_000), "")
        XCTAssertEqual(try tools.read(path: "lines.txt", limit: 0), "")
    }

    func testReadStopsAtByteLimitWithoutAllocatingLargeSparseFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sparse.txt")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 8 * 1_024 * 1_024 * 1_024)
        try handle.close()
        let tools = FileTools(workingDirectory: directory)
        let start = ContinuousClock.now

        let content = try tools.read(path: "sparse.txt")

        XCTAssertEqual(content, "")
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }

    func testReadRejectsFIFOWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appendingPathComponent("input.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let tools = FileTools(workingDirectory: directory)
        let start = ContinuousClock.now

        XCTAssertThrowsError(try tools.read(path: "input.txt"))

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testReadContentDetectsImagesBeforeTextDecoding() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        try data.write(to: directory.appendingPathComponent("image.png"))
        let tools = FileTools(workingDirectory: directory)

        guard case .image(let loaded, let mimeType) = try tools.readContent(path: "image.png") else {
            return XCTFail("Expected image content")
        }
        XCTAssertEqual(loaded, data)
        XCTAssertEqual(mimeType, "image/png")
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

    func testFindPlacesDashPrefixedPatternAfterOptionDelimiter() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fd")
        let argumentsFile = directory.appendingPathComponent("arguments")
        let source = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(argumentsFile.path)'
            printf '%s\\n' 'sub/-result.txt'
            """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let search = SearchTools(
            workingDirectory: directory,
            useExternalCommands: true,
            executableDirectory: directory
        )

        let result = try await search.find(pattern: "--dash-*.txt", path: "sub")

        XCTAssertEqual(result, ["sub/-result.txt"])
        let arguments = try String(contentsOf: argumentsFile, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            arguments,
            [
                "--glob", "--hidden", "--exclude", ".git", "--color", "never",
                "--", "--dash-*.txt", "sub",
            ]
        )
    }

    func testGrepTerminatesProducerAtMaximumMatches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("rg")
        let source = """
            #!/bin/sh
            sleep 30 &
            child=$!
            echo $$ > rg-parent.pid
            echo $child > rg-child.pid
            line=1
            while :; do
                printf 'file.txt:%s:needle-%s\\n' "$line" "$line"
                line=$((line + 1))
            done
            """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let search = SearchTools(
            workingDirectory: directory,
            useExternalCommands: true,
            executableDirectory: directory
        )
        let parentFile = directory.appendingPathComponent("rg-parent.pid")
        let childFile = directory.appendingPathComponent("rg-child.pid")

        let matches = try await search.grep(pattern: "needle", maximumMatches: 3)

        XCTAssertEqual(matches.map(\.text), ["needle-1", "needle-2", "needle-3"])
        let parent = try readProcessID(parentFile)
        let child = try readProcessID(childFile)
        try await waitForCondition {
            !processIsRunning(parent) && !processIsRunning(child)
        }
    }

    func testGrepTerminatesProducerAtByteLimitWithoutReturningPartialLine() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("rg")
        let source = """
            #!/bin/sh
            echo $$ > rg-parent.pid
            printf 'file.txt:1:'
            while :; do
                printf '0123456789abcdef0123456789abcdef'
            done
            """
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let search = SearchTools(
            workingDirectory: directory,
            useExternalCommands: true,
            executableDirectory: directory
        )
        let parentFile = directory.appendingPathComponent("rg-parent.pid")

        let matches = try await search.grep(pattern: "needle")

        XCTAssertTrue(matches.isEmpty)
        let parent = try readProcessID(parentFile)
        try await waitForCondition {
            !processIsRunning(parent)
        }
    }

    func testSearchCancellationTerminatesExternalProcessTrees() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for executable in ["rg", "fd"] {
            let script = directory.appendingPathComponent(executable)
            let source = """
                #!/bin/sh
                sleep 30 &
                child=$!
                echo $$ > \(executable)-parent.pid
                echo $child > \(executable)-child.pid
                if [ '\(executable)' = rg ]; then
                    printf '%s\\n' 'file:1:needle'
                else
                    printf '%s\\n' 'file'
                fi
                touch \(executable)-output-ready
                wait
                """
            try Data(source.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            let search = SearchTools(
                workingDirectory: directory,
                useExternalCommands: true,
                executableDirectory: directory
            )
            let task = Task {
                if executable == "rg" {
                    _ = try await search.grep(pattern: "needle")
                } else {
                    _ = try await search.find(pattern: "*")
                }
            }
            let parentFile = directory.appendingPathComponent("\(executable)-parent.pid")
            let childFile = directory.appendingPathComponent("\(executable)-child.pid")
            let outputMarker = directory.appendingPathComponent("\(executable)-output-ready")
            try await waitForCondition(timeout: .seconds(5)) {
                FileManager.default.fileExists(atPath: parentFile.path)
                    && FileManager.default.fileExists(atPath: childFile.path)
                    && FileManager.default.fileExists(atPath: outputMarker.path)
            }
            let parent = try readProcessID(parentFile)
            let child = try readProcessID(childFile)

            task.cancel()
            do {
                try await task.value
                XCTFail("Expected search cancellation")
            } catch is CancellationError {}
            try await waitForCondition {
                !processIsRunning(parent) && !processIsRunning(child)
            }
        }
    }

    func testShellSpoolsLargeOutputAndBoundsProgressSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let updates = ShellUpdateRecorder()
        let result = try await ShellTool(workingDirectory: directory).run(
            command: "yes '0123456789abcdef' | head -c 262144",
            onUpdate: { updates.record($0) }
        )

        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.output.utf8.count, defaultMaximumBytes)
        let outputFile = try XCTUnwrap(result.fullOutputFile)
        defer { try? FileManager.default.removeItem(at: outputFile) }
        let fullOutput = try Data(contentsOf: outputFile)
        XCTAssertEqual(fullOutput.count, 262_144)
        XCTAssertTrue(fullOutput.starts(with: Data("0123456789abcdef\n".utf8)))
        XCTAssertFalse(updates.sizes.isEmpty)
        XCTAssertTrue(updates.sizes.allSatisfy { $0 <= defaultMaximumBytes })
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

    func testEditPreservesMixedLineEndingsAndBOMByteExactly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed.txt")
        let original = Data([0xEF, 0xBB, 0xBF]) + Data("keep-lf\nold-one\r\nold-two\nkeep-crlf\r\ntail\n".utf8)
        try original.write(to: file)
        let tools = FileTools(workingDirectory: directory)

        _ = try await tools.edit(
            path: "mixed.txt",
            replacements: [
                TextReplacement(
                    oldText: "old-one\nold-two\n",
                    newText: "new-one\nnew-two\n"
                )
            ]
        )

        let expected = Data([0xEF, 0xBB, 0xBF]) + Data("keep-lf\nnew-one\r\nnew-two\nkeep-crlf\r\ntail\n".utf8)
        XCTAssertEqual(try Data(contentsOf: file), expected)
    }

    func testMultipleEditsLeaveEveryMixedLineSeparatorByteExact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("mixed.txt")
        try Data("first\r\nsecond\nthird\r\nfourth\n".utf8).write(to: file)
        let tools = FileTools(workingDirectory: directory)

        _ = try await tools.edit(
            path: "mixed.txt",
            replacements: [
                TextReplacement(oldText: "first", newText: "FIRST"),
                TextReplacement(oldText: "fourth", newText: "FOURTH"),
            ]
        )

        XCTAssertEqual(
            try Data(contentsOf: file),
            Data("FIRST\r\nsecond\nthird\r\nFOURTH\n".utf8)
        )
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

private final class ShellUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSizes: [Int] = []

    var sizes: [Int] { lock.withLock { recordedSizes } }

    func record(_ value: String) {
        lock.withLock { recordedSizes.append(value.utf8.count) }
    }
}

private func readProcessID(_ url: URL) throws -> pid_t {
    pid_t(
        try XCTUnwrap(
            Int32(String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )
    )
}

private func processIsRunning(_ identifier: pid_t) -> Bool {
    kill(identifier, 0) == 0 || errno == EPERM
}

private func waitForCondition(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw ToolTestError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum ToolTestError: Error {
    case timedOut
}

private func assertThrowsErrorAsync(_ expression: () async throws -> Void) async {
    do {
        try await expression()
        XCTFail("Expected error")
    } catch {}
}
