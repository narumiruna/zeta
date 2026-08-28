import Foundation

public struct ResourceDiagnostic: Sendable, Equatable {
    public enum Severity: String, Sendable { case warning, error }
    public var severity: Severity
    public var path: String
    public var message: String
}

public struct PromptTemplate: Sendable, Equatable {
    public var name: String
    public var description: String?
    public var body: String

    public func expand(arguments: [String]) -> String {
        var result = body
        for (index, value) in arguments.enumerated() {
            result = result.replacingOccurrences(of: "{{\(index + 1)}}", with: value)
        }
        result = result.replacingOccurrences(of: "{{args}}", with: arguments.joined(separator: " "))
        return result
    }
}

public struct Skill: Sendable, Equatable {
    public var name: String
    public var description: String
    public var body: String
    public var directory: URL
}

public struct ResourceSnapshot: Sendable {
    public var context: [String]
    public var prompts: [PromptTemplate]
    public var skills: [Skill]
    public var themes: [URL]
    public var unsupportedExtensions: [URL]
    public var diagnostics: [ResourceDiagnostic]
}

public struct ResourceLoader: Sendable {
    public let home: URL
    public let workingDirectory: URL
    public let agentDirectory: URL
    public let trusted: Bool

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser, workingDirectory: URL, agentDirectory: URL? = nil,
        trusted: Bool
    ) {
        self.home = home
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.agentDirectory = agentDirectory ?? home.appendingPathComponent(".pi/agent")
        self.trusted = trusted
    }

    public func load() -> ResourceSnapshot {
        var snapshot = ResourceSnapshot(
            context: [], prompts: [], skills: [], themes: [], unsupportedExtensions: [], diagnostics: [])
        snapshot.context = loadContext()
        let roots = [agentDirectory] + (trusted ? [workingDirectory.appendingPathComponent(".pi")] : [])
        for root in roots {
            snapshot.prompts += loadPrompts(root.appendingPathComponent("prompts"), diagnostics: &snapshot.diagnostics)
            snapshot.skills += loadSkills(root.appendingPathComponent("skills"), diagnostics: &snapshot.diagnostics)
            snapshot.themes += files(root.appendingPathComponent("themes"), extensions: ["json"])
            snapshot.unsupportedExtensions += files(
                root.appendingPathComponent("extensions"), extensions: ["ts", "js", "mts", "mjs"])
        }
        for value in snapshot.unsupportedExtensions {
            snapshot.diagnostics.append(
                ResourceDiagnostic(
                    severity: .warning, path: value.path,
                    message: "TypeScript extensions are not executed by Zeta; migrate this extension to ZetaPluginSDK"))
        }
        return snapshot
    }

    private func loadContext() -> [String] {
        var output: [String] = []
        let global = agentDirectory.appendingPathComponent("AGENTS.md")
        if let text = try? String(contentsOf: global, encoding: .utf8) { output.append(text) }
        var directories: [URL] = []
        var current = workingDirectory
        while current.path != "/" {
            directories.append(current)
            current.deleteLastPathComponent()
        }
        for directory in directories.reversed() {
            let override = directory.appendingPathComponent("AGENTS.override.md")
            let agents = directory.appendingPathComponent("AGENTS.md")
            let claude = directory.appendingPathComponent("CLAUDE.md")
            let selected =
                FileManager.default.fileExists(atPath: override.path)
                ? override : FileManager.default.fileExists(atPath: agents.path) ? agents : claude
            if let text = try? String(contentsOf: selected, encoding: .utf8) { output.append(text) }
        }
        return output
    }

    private func loadPrompts(_ directory: URL, diagnostics: inout [ResourceDiagnostic]) -> [PromptTemplate] {
        files(directory, extensions: ["md"]).compactMap { url in
            do {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let parsed = frontmatter(raw)
                return PromptTemplate(
                    name: url.deletingPathExtension().lastPathComponent, description: parsed.metadata["description"],
                    body: parsed.body)
            } catch {
                diagnostics.append(
                    ResourceDiagnostic(severity: .error, path: url.path, message: String(describing: error)))
                return nil
            }
        }
    }

    private func loadSkills(_ directory: URL, diagnostics: inout [ResourceDiagnostic]) -> [Skill] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var output: [Skill] = []
        for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
            do {
                let parsed = frontmatter(try String(contentsOf: url, encoding: .utf8))
                let name = parsed.metadata["name"] ?? url.deletingLastPathComponent().lastPathComponent
                guard let description = parsed.metadata["description"], !description.isEmpty else {
                    throw ResourceError.missingDescription
                }
                output.append(
                    Skill(
                        name: name, description: description, body: parsed.body,
                        directory: url.deletingLastPathComponent()))
            } catch {
                diagnostics.append(
                    ResourceDiagnostic(severity: .error, path: url.path, message: String(describing: error)))
            }
        }
        return output
    }

    private func files(_ directory: URL, extensions: Set<String>) -> [URL] {
        guard
            let values = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return values.filter { extensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
    }

    private func frontmatter(_ value: String) -> (metadata: [String: String], body: String) {
        guard value.hasPrefix("---\n"),
            let end = value.range(of: "\n---\n", range: value.index(value.startIndex, offsetBy: 4)..<value.endIndex)
        else { return ([:], value) }
        let header = value[value.index(value.startIndex, offsetBy: 4)..<end.lowerBound]
        let metadata = header.split(separator: "\n").reduce(into: [String: String]()) { result, line in
            let text = String(line)
            guard let colon = text.firstIndex(of: ":") else { return }
            result[String(text[..<colon]).trimmingCharacters(in: .whitespaces)] = String(
                text[text.index(after: colon)...]
            ).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        }
        return (metadata, String(value[end.upperBound...]))
    }
}

public enum ResourceError: Error, Sendable { case missingDescription }
