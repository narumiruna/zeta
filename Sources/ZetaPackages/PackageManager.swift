import Foundation

public enum PackageSource: Sendable, Equatable {
    case npm(name: String, version: String?)
    case git(url: String, reference: String?)

    public init(_ raw: String) throws {
        if raw.hasPrefix("npm:") {
            let value = String(raw.dropFirst(4))
            let separator = value.lastIndex(of: "@").flatMap { index in
                index == value.startIndex ? nil : index
            }
            if let separator {
                self = .npm(
                    name: String(value[..<separator]),
                    version: String(value[value.index(after: separator)...])
                )
            } else {
                self = .npm(name: value, version: nil)
            }
            return
        }
        var value = raw
        if value.hasPrefix("git:") { value = String(value.dropFirst(4)) }
        let referenceSeparator = value.lastIndex(of: "@").flatMap { index in
            value[value.startIndex..<index].contains("/") ? index : nil
        }
        let reference = referenceSeparator.map {
            String(value[value.index(after: $0)...])
        }
        let urlPart = referenceSeparator.map { String(value[..<$0]) } ?? value
        let normalized: String
        if urlPart.hasPrefix("http://") || urlPart.hasPrefix("https://")
            || urlPart.hasPrefix("ssh://") || urlPart.hasPrefix("git@")
        {
            normalized = urlPart
        } else if urlPart.hasPrefix("github.com/") {
            normalized = "https://" + urlPart
        } else {
            normalized = "https://github.com/" + urlPart
        }
        guard !normalized.isEmpty else { throw PackageManagerError.invalidSource(raw) }
        self = .git(url: normalized, reference: reference)
    }

    public var identifier: String {
        switch self {
        case .npm(let name, _): "npm:" + name
        case .git(let url, _): "git:" + url
        }
    }

    public var pinned: Bool {
        switch self {
        case .npm(_, let version), .git(_, let version): version != nil
        }
    }
}

public struct InstalledPackage: Codable, Sendable, Equatable {
    public var source: String
    public var directory: String
    public var pinned: Bool
    public var installedAt: String
}

public struct ResourcePackageManifest: Codable, Sendable, Equatable {
    public struct Resources: Codable, Sendable, Equatable {
        public var extensions: [String]?
        public var skills: [String]?
        public var prompts: [String]?
        public var themes: [String]?
    }

    public var name: String
    public var pi: Resources?
}

public enum PackageManagerError: Error, LocalizedError, Sendable {
    case invalidSource(String)
    case untrusted
    case processFailed(String)
    case unsafeArchive
    case missingManifest
    case unsupportedExtensionPackage

    public var errorDescription: String? {
        switch self {
        case .invalidSource(let value): "Invalid package source: \(value)"
        case .untrusted: "Project-local package operations require trust"
        case .processFailed(let value): value
        case .unsafeArchive: "Package archive contains an unsafe path"
        case .missingManifest: "Package does not contain a package.json manifest"
        case .unsupportedExtensionPackage:
            "TypeScript extension packages are unsupported; migrate extensions to ZetaPluginSDK"
        }
    }
}

public actor ResourcePackageManager {
    private let root: URL
    private let session: URLSession
    private var installed: [String: InstalledPackage] = [:]

    public init(root: URL, session: URLSession = .shared) throws {
        self.root = root
        self.session = session
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let indexURL = root.appendingPathComponent("packages.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            installed = try JSONDecoder().decode(
                [String: InstalledPackage].self,
                from: Data(contentsOf: indexURL)
            )
        }
    }

    public func list() -> [InstalledPackage] {
        installed.values.sorted { $0.source < $1.source }
    }

    public func install(_ source: PackageSource, trusted: Bool = true) async throws {
        guard trusted else { throw PackageManagerError.untrusted }
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        switch source {
        case .git(let url, let reference):
            var arguments = ["clone", "--quiet", "--depth", "1"]
            if let reference { arguments += ["--branch", reference] }
            arguments += [url, staging.path]
            try run("git", arguments)
        case .npm(let name, let version):
            try await installNPM(name: name, version: version, staging: staging)
        }
        try validatePackageTree(staging)
        let manifestURL = staging.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PackageManagerError.missingManifest
        }
        let manifest = try JSONDecoder().decode(
            ResourcePackageManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.pi?.extensions?.isEmpty != false else {
            throw PackageManagerError.unsupportedExtensionPackage
        }
        try validateResourcePaths(manifest, root: staging)
        let destination = root.appendingPathComponent(safeName(source.identifier))
        let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)")
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.moveItem(at: destination, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.removeItem(at: backup)
            installed[source.identifier] = InstalledPackage(
                source: source.identifier,
                directory: destination.lastPathComponent,
                pinned: source.pinned,
                installedAt: ISO8601DateFormatter().string(from: Date())
            )
            try persistIndex()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    public func remove(_ identifier: String, trusted: Bool = true) throws {
        guard trusted else { throw PackageManagerError.untrusted }
        guard let value = installed.removeValue(forKey: identifier) else { return }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent(value.directory)
        )
        try persistIndex()
    }

    public func updateAll(trusted: Bool = true) async throws {
        guard trusted else { throw PackageManagerError.untrusted }
        let sources = installed.values.filter { !$0.pinned }.map(\.source)
        for raw in sources {
            try await install(PackageSource(raw), trusted: trusted)
        }
    }

    private func installNPM(
        name: String,
        version: String?,
        staging: URL
    ) async throws {
        let encodedName =
            name.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed
            ) ?? name
        let metadataURL = URL(string: "https://registry.npmjs.org/\(encodedName)")!
        let (data, response) = try await session.data(from: metadataURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let versions = object["versions"] as? [String: Any],
            let selectedVersion = version
                ?? (object["dist-tags"] as? [String: String])?["latest"],
            let selected = versions[selectedVersion] as? [String: Any],
            let distribution = selected["dist"] as? [String: Any],
            let tarball = distribution["tarball"] as? String,
            let tarballURL = URL(string: tarball)
        else {
            throw PackageManagerError.invalidSource("npm:\(name)")
        }
        let (archive, archiveResponse) = try await session.data(from: tarballURL)
        guard (archiveResponse as? HTTPURLResponse)?.statusCode == 200 else {
            throw PackageManagerError.invalidSource("npm:\(name)")
        }
        let temporary = root.appendingPathComponent(".archive-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try archive.write(to: temporary, options: .atomic)
        let listing = String(
            decoding: try run("/usr/bin/tar", ["-tzf", temporary.path]),
            as: UTF8.self
        )
        for raw in listing.split(separator: "\n") {
            let path = String(raw)
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !components.contains(".."), !path.contains("\\") else {
                throw PackageManagerError.unsafeArchive
            }
        }
        let verbose = String(
            decoding: try run("/usr/bin/tar", ["-tvzf", temporary.path]),
            as: UTF8.self
        )
        guard
            !verbose.split(separator: "\n").contains(where: { line in
                line.first == "l" || line.contains(" -> ") || line.contains(" link to ")
            })
        else {
            throw PackageManagerError.unsafeArchive
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run(
            "/usr/bin/tar",
            ["-xzf", temporary.path, "--strip-components", "1", "-C", staging.path]
        )
    }

    private func validatePackageTree(_ directory: URL) throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isSymbolicLinkKey]
            )
        else { return }
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw PackageManagerError.unsafeArchive
            }
        }
    }

    private func validateResourcePaths(
        _ manifest: ResourcePackageManifest,
        root: URL
    ) throws {
        let resources = manifest.pi
        let paths =
            (resources?.skills ?? []) + (resources?.prompts ?? [])
            + (resources?.themes ?? [])
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !components.contains(".."), !path.contains("\\") else {
                throw PackageManagerError.unsafeArchive
            }
            let resolved = root.appendingPathComponent(path).standardizedFileURL
            guard
                resolved.path == root.standardizedFileURL.path
                    || resolved.path.hasPrefix(root.standardizedFileURL.path + "/")
            else {
                throw PackageManagerError.unsafeArchive
            }
        }
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL =
            executable.hasPrefix("/")
            ? URL(fileURLWithPath: executable)
            : URL(fileURLWithPath: "/usr/bin/env")
        process.arguments =
            executable.hasPrefix("/")
            ? arguments
            : [executable] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PackageManagerError.processFailed(
                String(decoding: data, as: UTF8.self)
            )
        }
        return data
    }

    private func safeName(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    private var indexURL: URL { root.appendingPathComponent("packages.json") }

    private func persistIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(installed).write(to: indexURL, options: .atomic)
    }
}
