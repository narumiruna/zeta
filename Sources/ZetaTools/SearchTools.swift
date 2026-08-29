import Foundation

public struct SearchMatch: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var text: String
}

public struct SearchTools: Sendable {
    public let workingDirectory: URL
    private let useExternalCommands: Bool

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        useExternalCommands = true
    }

    init(workingDirectory: URL, useExternalCommands: Bool) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.useExternalCommands = useExternalCommands
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
        arguments += [pattern, path]
        let result = try await command("rg", arguments: arguments)
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
                pattern, path,
            ]
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
        for case let url as URL in enumerator {
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
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let value = String(line)
                let range = NSRange(value.startIndex..<value.endIndex, in: value)
                guard expression.firstMatch(in: value, range: range) != nil else { continue }
                matches.append(
                    SearchMatch(
                        path: relative,
                        line: offset + 1,
                        text: Truncation.line(value).0
                    )
                )
                if matches.count == maximumMatches { return matches }
            }
        }
        return matches
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
        arguments: [String]
    ) async throws -> (status: Int32, output: String) {
        guard useExternalCommands else { return (127, "External search command disabled") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = workingDirectory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, String(describing: error))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
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
