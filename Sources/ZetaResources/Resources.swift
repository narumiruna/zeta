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
            loadTopLevel(root, into: &snapshot)
        }
        let packageRoots =
            [agentDirectory.appendingPathComponent("packages")]
            + (trusted ? [workingDirectory.appendingPathComponent(".pi/packages")] : [])
        for packageRoot in packageRoots {
            for installedRoot in installedPackageRoots(packageRoot, diagnostics: &snapshot.diagnostics) {
                loadPackage(installedRoot, into: &snapshot)
            }
        }
        for value in snapshot.unsupportedExtensions {
            snapshot.diagnostics.append(
                ResourceDiagnostic(
                    severity: .warning, path: value.path,
                    message: "TypeScript extensions are not executed by Zeta; migrate this extension to ZetaPluginSDK"))
        }
        return snapshot
    }

    private func loadTopLevel(_ root: URL, into snapshot: inout ResourceSnapshot) {
        snapshot.prompts += loadPrompts(root.appendingPathComponent("prompts"), diagnostics: &snapshot.diagnostics)
        snapshot.skills += loadSkills(root.appendingPathComponent("skills"), diagnostics: &snapshot.diagnostics)
        snapshot.themes += files(root.appendingPathComponent("themes"), extensions: ["json"])
        snapshot.unsupportedExtensions += files(
            root.appendingPathComponent("extensions"), extensions: ["ts", "js", "mts", "mjs"])
    }

    private func installedPackageRoots(
        _ root: URL,
        diagnostics: inout [ResourceDiagnostic]
    ) -> [URL] {
        let registry = root.appendingPathComponent("packages.json")
        guard FileManager.default.fileExists(atPath: registry.path) else { return [] }
        guard isDirectory(root), isRegularFile(registry) else {
            diagnostics.append(
                ResourceDiagnostic(
                    severity: .error,
                    path: registry.path,
                    message: "Package registry must contain only regular files and directories"
                )
            )
            return []
        }
        let records: [String: InstalledPackageRecord]
        do {
            records = try JSONDecoder().decode(
                [String: InstalledPackageRecord].self,
                from: Data(contentsOf: registry)
            )
        } catch {
            diagnostics.append(
                ResourceDiagnostic(
                    severity: .error,
                    path: registry.path,
                    message: "Invalid package registry: \(error.localizedDescription)"
                )
            )
            return []
        }
        return records.keys.sorted().compactMap { key in
            let directory = records[key]!.directory
            guard isSafePackageDirectory(directory) else {
                diagnostics.append(
                    ResourceDiagnostic(
                        severity: .error,
                        path: registry.path,
                        message: "Package \(key) has an unsafe registry directory"
                    )
                )
                return nil
            }
            let package = root.appendingPathComponent(directory).standardizedFileURL
            guard isContained(package, in: root), isValidatedPackageTree(package) else {
                diagnostics.append(
                    ResourceDiagnostic(
                        severity: .error,
                        path: package.path,
                        message: "Package \(key) is missing or contains an unsafe symbolic link or file type"
                    )
                )
                return nil
            }
            return package
        }
    }

    private func loadPackage(_ root: URL, into snapshot: inout ResourceSnapshot) {
        let manifestURL = root.appendingPathComponent("package.json")
        guard isRegularFile(manifestURL) else {
            snapshot.diagnostics.append(
                ResourceDiagnostic(
                    severity: .error,
                    path: manifestURL.path,
                    message: "Installed package manifest is not a regular file"
                )
            )
            return
        }
        let manifest: InstalledResourceManifest
        do {
            manifest = try JSONDecoder().decode(
                InstalledResourceManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            snapshot.diagnostics.append(
                ResourceDiagnostic(
                    severity: .error,
                    path: manifestURL.path,
                    message: "Invalid installed package manifest: \(error.localizedDescription)"
                )
            )
            return
        }
        guard !manifest.name.isEmpty else {
            snapshot.diagnostics.append(
                ResourceDiagnostic(
                    severity: .error,
                    path: manifestURL.path,
                    message: "Installed package manifest has an empty name"
                )
            )
            return
        }
        guard let resources = manifest.pi else {
            loadTopLevel(root, into: &snapshot)
            return
        }
        loadPackageEntries(
            resources.prompts ?? [], root: root, kind: .prompt, into: &snapshot)
        loadPackageEntries(
            resources.skills ?? [], root: root, kind: .skill, into: &snapshot)
        loadPackageEntries(
            resources.themes ?? [], root: root, kind: .theme, into: &snapshot)
        loadPackageEntries(
            resources.extensions ?? [], root: root, kind: .extension, into: &snapshot)
    }

    private func loadPackageEntries(
        _ entries: [String],
        root: URL,
        kind: PackageResourceKind,
        into snapshot: inout ResourceSnapshot
    ) {
        for entry in entries {
            guard let path = validatedResourcePath(entry, root: root) else {
                snapshot.diagnostics.append(
                    ResourceDiagnostic(
                        severity: .error,
                        path: root.appendingPathComponent(entry).path,
                        message: "Installed package resource path is unsafe or missing"
                    )
                )
                continue
            }
            switch kind {
            case .prompt:
                snapshot.prompts += loadPromptPath(path, diagnostics: &snapshot.diagnostics)
            case .skill:
                snapshot.skills += loadSkillPath(path, diagnostics: &snapshot.diagnostics)
            case .theme:
                snapshot.themes += resourceFiles(path, extensions: ["json"])
            case .extension:
                snapshot.unsupportedExtensions += resourceFiles(
                    path, extensions: ["ts", "js", "mts", "mjs"])
            }
        }
    }

    private func loadContext() -> [String] {
        var output: [String] = []
        let global = agentDirectory.appendingPathComponent("AGENTS.md")
        if isRegularFile(global), let text = try? String(contentsOf: global, encoding: .utf8) {
            output.append(text)
        }
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
                isRegularFile(override)
                ? override : isRegularFile(agents) ? agents : claude
            if isRegularFile(selected), let text = try? String(contentsOf: selected, encoding: .utf8) {
                output.append(text)
            }
        }
        return output
    }

    private func loadPrompts(_ directory: URL, diagnostics: inout [ResourceDiagnostic]) -> [PromptTemplate] {
        files(directory, extensions: ["md"]).compactMap { loadPrompt($0, diagnostics: &diagnostics) }
    }

    private func loadPromptPath(_ path: URL, diagnostics: inout [ResourceDiagnostic]) -> [PromptTemplate] {
        resourceFiles(path, extensions: ["md"]).compactMap { loadPrompt($0, diagnostics: &diagnostics) }
    }

    private func loadPrompt(_ url: URL, diagnostics: inout [ResourceDiagnostic]) -> PromptTemplate? {
        guard isRegularFile(url) else { return nil }
        do {
            let parsed = frontmatter(try String(contentsOf: url, encoding: .utf8))
            return PromptTemplate(
                name: url.deletingPathExtension().lastPathComponent,
                description: parsed.metadata["description"],
                body: parsed.body
            )
        } catch {
            diagnostics.append(
                ResourceDiagnostic(severity: .error, path: url.path, message: String(describing: error)))
            return nil
        }
    }

    private func loadSkills(_ directory: URL, diagnostics: inout [ResourceDiagnostic]) -> [Skill] {
        skillFiles(directory).compactMap { loadSkill($0, diagnostics: &diagnostics) }
    }

    private func loadSkillPath(_ path: URL, diagnostics: inout [ResourceDiagnostic]) -> [Skill] {
        skillFiles(path).compactMap { loadSkill($0, diagnostics: &diagnostics) }
    }

    private func loadSkill(_ url: URL, diagnostics: inout [ResourceDiagnostic]) -> Skill? {
        guard isRegularFile(url) else { return nil }
        do {
            let parsed = frontmatter(try String(contentsOf: url, encoding: .utf8))
            let name = parsed.metadata["name"] ?? url.deletingLastPathComponent().lastPathComponent
            guard let description = parsed.metadata["description"], !description.isEmpty else {
                throw ResourceError.missingDescription
            }
            return Skill(
                name: name,
                description: description,
                body: parsed.body,
                directory: url.deletingLastPathComponent()
            )
        } catch {
            diagnostics.append(
                ResourceDiagnostic(severity: .error, path: url.path, message: String(describing: error)))
            return nil
        }
    }

    private func skillFiles(_ path: URL) -> [URL] {
        if isRegularFile(path) { return path.lastPathComponent == "SKILL.md" ? [path] : [] }
        guard isDirectory(path),
            let enumerator = FileManager.default.enumerator(
                at: path,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "SKILL.md" && isRegularFile($0) }
            .sorted { $0.path < $1.path }
    }

    private func resourceFiles(_ path: URL, extensions: Set<String>) -> [URL] {
        if isDirectory(path) { return files(path, extensions: extensions) }
        return isRegularFile(path) && extensions.contains(path.pathExtension.lowercased()) ? [path] : []
    }

    private func files(_ directory: URL, extensions: Set<String>) -> [URL] {
        guard isDirectory(directory),
            let values = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return values.filter {
            isRegularFile($0) && extensions.contains($0.pathExtension.lowercased())
        }.sorted { $0.path < $1.path }
    }

    private func validatedResourcePath(_ entry: String, root: URL) -> URL? {
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.contains("\\"), !components.contains("..") else {
            return nil
        }
        let path = root.appendingPathComponent(entry).standardizedFileURL
        guard isContained(path, in: root), isRegularFile(path) || isDirectory(path) else { return nil }
        return path
    }

    private func isSafePackageDirectory(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }

    private func isContained(_ path: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let pathValue = path.standardizedFileURL.path
        return pathValue.hasPrefix(rootPath + "/")
    }

    private func isValidatedPackageTree(_ root: URL) -> Bool {
        guard isDirectory(root),
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ]
            )
        else {
            return false
        }
        for case let url as URL in enumerator {
            guard isRegularFile(url) || isDirectory(url) else { return false }
        }
        return true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private func frontmatter(_ value: String) -> (metadata: [String: String], body: String) {
        let lineEnding: String
        if value.hasPrefix("---\r\n") {
            lineEnding = "\r\n"
        } else if value.hasPrefix("---\n") {
            lineEnding = "\n"
        } else {
            return ([:], value)
        }
        let headerStart = value.index(value.startIndex, offsetBy: 3 + lineEnding.count)
        let closingDelimiter = lineEnding + "---" + lineEnding
        guard let end = value.range(of: closingDelimiter, range: headerStart..<value.endIndex) else {
            return ([:], value)
        }
        let header = value[headerStart..<end.lowerBound]
        let metadata = header.components(separatedBy: lineEnding).reduce(into: [String: String]()) { result, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            result[String(line[..<colon]).trimmingCharacters(in: .whitespaces)] = String(
                line[line.index(after: colon)...]
            ).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        }
        return (metadata, String(value[end.upperBound...]))
    }
}

private struct InstalledPackageRecord: Decodable {
    var directory: String
}

private struct InstalledResourceManifest: Decodable {
    struct Resources: Decodable {
        var extensions: [String]?
        var skills: [String]?
        var prompts: [String]?
        var themes: [String]?
    }

    var name: String
    var pi: Resources?
}

private enum PackageResourceKind {
    case prompt
    case skill
    case theme
    case `extension`
}

public enum ResourceError: Error, Sendable { case missingDescription }
