import Foundation

public struct SearchMatch: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var text: String
}

public struct SearchTools: Sendable {
    public let workingDirectory: URL
    private let useExternalCommands: Bool
    private let executableDirectory: URL?

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        useExternalCommands = true
        executableDirectory = nil
    }

    init(
        workingDirectory: URL,
        useExternalCommands: Bool,
        executableDirectory: URL? = nil
    ) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.useExternalCommands = useExternalCommands
        self.executableDirectory = executableDirectory
    }

    public func grep(
        pattern: String,
        path: String = ".",
        filePattern: String? = nil,
        maximumMatches: Int = 100
    ) async throws -> [SearchMatch] {
        guard maximumMatches > 0 else { return [] }
        var arguments = [
            "--line-number", "--no-heading", "--color", "never", "--hidden",
            "--glob", "!.git/**",
        ]
        if let filePattern { arguments += ["--glob", filePattern] }
        arguments += ["--regexp", pattern, path]
        let result = try await command(
            "rg",
            arguments: arguments,
            maximumLines: maximumMatches,
            maximumBytes: defaultMaximumBytes
        )
        if result.status == 127 {
            return try fallbackGrep(
                pattern: pattern,
                path: path,
                filePattern: filePattern,
                maximumMatches: maximumMatches
            )
        }
        if result.status != 0 && result.status != 1 {
            throw FileToolError.processFailed(result.output)
        }
        return result.output.split(separator: "\n").prefix(maximumMatches).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let number = Int(parts[1]) else { return nil }
            return SearchMatch(
                path: String(parts[0]),
                line: number,
                text: Truncation.line(String(parts[2])).0
            )
        }
    }

    public func find(
        pattern: String,
        path: String = ".",
        maximumResults: Int = 1_000
    ) async throws -> [String] {
        guard maximumResults > 0 else { return [] }
        let result = try await command(
            "fd",
            arguments: [
                "--glob", "--hidden", "--exclude", ".git", "--color", "never",
                "--", pattern, path,
            ],
            maximumLines: maximumResults,
            maximumBytes: defaultMaximumBytes
        )
        guard result.status == 0 else {
            if result.status == 127 {
                return try fallbackFind(pattern: pattern, path: path, maximumResults: maximumResults)
            }
            throw FileToolError.processFailed(result.output)
        }
        return result.output.split(separator: "\n").prefix(maximumResults).map(String.init)
    }

    private func fallbackGrep(
        pattern: String,
        path: String,
        filePattern: String?,
        maximumMatches: Int
    ) throws -> [SearchMatch] {
        let root = workingDirectory.appendingPathComponent(path).standardizedFileURL
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsPackageDescendants]
            )
        else {
            return []
        }
        let expression = try NSRegularExpression(pattern: pattern)
        let fileExpression = try filePattern.map {
            try NSRegularExpression(pattern: globRegex($0), options: [.caseInsensitive])
        }
        var matches: [SearchMatch] = []
        var outputBytes = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if url.pathComponents.contains(".git") {
                enumerator.skipDescendants()
                continue
            }
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                continue
            }
            let relative = String(
                url.standardizedFileURL.path.dropFirst(root.path.count + 1)
            )
            if let fileExpression {
                let range = NSRange(relative.startIndex..<relative.endIndex, in: relative)
                guard fileExpression.firstMatch(in: relative, range: range) != nil else { continue }
            }
            guard
                let result = try fallbackMatches(
                    in: url,
                    relativePath: relative,
                    expression: expression,
                    maximumMatches: maximumMatches - matches.count,
                    maximumOutputBytes: defaultMaximumBytes - outputBytes
                )
            else {
                continue
            }
            matches += result.matches
            outputBytes += result.outputBytes
            if matches.count == maximumMatches || result.reachedByteLimit { return matches }
        }
        return matches
    }

    private func fallbackMatches(
        in url: URL,
        relativePath: String,
        expression: NSRegularExpression,
        maximumMatches: Int,
        maximumOutputBytes: Int
    ) throws -> FallbackFileMatches? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var validator = StreamingUTF8Validator()
        var line = Data()
        var lineIsTooLong = false
        var lineNumber = 1
        var matches: [SearchMatch] = []
        var outputBytes = 0
        var reachedByteLimit = false

        func matchCurrentLine() -> (SearchMatch, Int)? {
            guard !lineIsTooLong,
                let value = String(data: line, encoding: .utf8)
            else {
                return nil
            }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard expression.firstMatch(in: value, range: range) != nil else { return nil }
            let rawOutputBytes =
                relativePath.utf8.count + String(lineNumber).utf8.count + line.count + 3
            return (
                SearchMatch(
                    path: relativePath,
                    line: lineNumber,
                    text: Truncation.line(value).0
                ),
                rawOutputBytes
            )
        }

        func appendCurrentMatch() {
            guard matches.count < maximumMatches, !reachedByteLimit,
                let (match, byteCount) = matchCurrentLine()
            else {
                return
            }
            guard outputBytes + byteCount <= maximumOutputBytes else {
                reachedByteLimit = true
                return
            }
            matches.append(match)
            outputBytes += byteCount
        }

        do {
            while let chunk = try handle.read(upToCount: 16 * 1_024), !chunk.isEmpty {
                try Task.checkCancellation()
                for byte in chunk {
                    guard validator.consume(byte) else { return nil }
                    if byte == 0x0A {
                        appendCurrentMatch()
                        line.removeAll(keepingCapacity: true)
                        lineIsTooLong = false
                        lineNumber += 1
                    } else if line.count < defaultMaximumBytes {
                        line.append(byte)
                    } else {
                        lineIsTooLong = true
                    }
                }
            }
            guard validator.isComplete else { return nil }
            appendCurrentMatch()
            return FallbackFileMatches(
                matches: matches,
                outputBytes: outputBytes,
                reachedByteLimit: reachedByteLimit
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    private func fallbackFind(
        pattern: String,
        path: String,
        maximumResults: Int
    ) throws -> [String] {
        let root = workingDirectory.appendingPathComponent(path).standardizedFileURL
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
        else {
            return []
        }
        let regex = try NSRegularExpression(
            pattern: globRegex(pattern),
            options: [.caseInsensitive]
        )
        var result: [String] = []
        for case let url as URL in enumerator {
            if url.pathComponents.contains(".git") {
                enumerator.skipDescendants()
                continue
            }
            let relative = String(
                url.standardizedFileURL.path.dropFirst(root.path.count + 1)
            )
            let range = NSRange(relative.startIndex..<relative.endIndex, in: relative)
            if regex.firstMatch(in: relative, range: range) != nil {
                let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                result.append(relative + (directory ? "/" : ""))
                if result.count == maximumResults { break }
            }
        }
        return result
    }

    private func command(
        _ executable: String,
        arguments: [String],
        maximumLines: Int,
        maximumBytes: Int
    ) async throws -> (status: Int32, output: String) {
        guard useExternalCommands else { return (127, "External search command disabled") }
        let process = Process()
        if let executableDirectory {
            process.executableURL = executableDirectory.appendingPathComponent(executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, String(describing: error))
        }
        ToolProcessLifecycle.prepare(process)
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                var data = Data()
                data.reserveCapacity(min(maximumBytes, 8 * 1_024))
                var lineCount = 0
                var reachedLimit = false
                for try await byte in pipe.fileHandleForReading.bytes {
                    data.append(byte)
                    if byte == 0x0A { lineCount += 1 }
                    if lineCount >= maximumLines || data.count >= maximumBytes {
                        reachedLimit = true
                        ToolProcessLifecycle.terminate(
                            process,
                            closing: [pipe.fileHandleForReading]
                        )
                        break
                    }
                }
                if data.count >= maximumBytes, data.last != 0x0A {
                    if let newline = data.lastIndex(of: 0x0A) {
                        data.removeSubrange(data.index(after: newline)..<data.endIndex)
                    } else {
                        data.removeAll(keepingCapacity: true)
                    }
                }
                while process.isRunning {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(10))
                }
                try Task.checkCancellation()
                let status = reachedLimit ? 0 : process.terminationStatus
                return (status, String(decoding: data, as: UTF8.self))
            } catch {
                ToolProcessLifecycle.terminate(process, closing: [pipe.fileHandleForReading])
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            ToolProcessLifecycle.terminate(process, closing: [pipe.fileHandleForReading])
        }
    }

    private func globRegex(_ pattern: String) -> String {
        var output = "^"
        for character in pattern {
            switch character {
            case "*": output += ".*"
            case "?": output += "."
            case ".", "+", "(", ")", "[", "]", "{", "}", "^", "$", "|", "\\":
                output += "\\\(character)"
            default: output.append(character)
            }
        }
        return output + "$"
    }
}

private struct FallbackFileMatches {
    let matches: [SearchMatch]
    let outputBytes: Int
    let reachedByteLimit: Bool
}

private struct StreamingUTF8Validator {
    private var remainingContinuationBytes = 0
    private var nextContinuationRange: ClosedRange<UInt8> = 0x80...0xBF

    var isComplete: Bool { remainingContinuationBytes == 0 }

    mutating func consume(_ byte: UInt8) -> Bool {
        if remainingContinuationBytes > 0 {
            guard nextContinuationRange.contains(byte) else { return false }
            remainingContinuationBytes -= 1
            nextContinuationRange = 0x80...0xBF
            return true
        }

        switch byte {
        case 0x00...0x7F:
            return true
        case 0xC2...0xDF:
            remainingContinuationBytes = 1
        case 0xE0:
            remainingContinuationBytes = 2
            nextContinuationRange = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF:
            remainingContinuationBytes = 2
        case 0xED:
            remainingContinuationBytes = 2
            nextContinuationRange = 0x80...0x9F
        case 0xF0:
            remainingContinuationBytes = 3
            nextContinuationRange = 0x90...0xBF
        case 0xF1...0xF3:
            remainingContinuationBytes = 3
        case 0xF4:
            remainingContinuationBytes = 3
            nextContinuationRange = 0x80...0x8F
        default:
            return false
        }
        return true
    }
}
