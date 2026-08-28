import Foundation

public struct SearchMatch: Sendable, Equatable {
    public var path: String
    public var line: Int
    public var text: String
}

public struct SearchTools: Sendable {
    public let workingDirectory: URL

    public init(workingDirectory: URL) {
        self.workingDirectory = workingDirectory.standardizedFileURL
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
            let relative = String(url.path.dropFirst(root.path.count + 1))
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
