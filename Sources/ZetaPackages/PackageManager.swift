import CryptoKit
import Darwin
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
        let (urlPart, reference) = Self.splitGitReference(value)
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

    private static func splitGitReference(_ value: String) -> (String, String?) {
        let repositoryPathStart: String.Index?
        if let scheme = value.range(of: "://") {
            repositoryPathStart = value[scheme.upperBound...].firstIndex(of: "/").map {
                value.index(after: $0)
            }
        } else if value.hasPrefix("git@"), let colon = value.firstIndex(of: ":") {
            repositoryPathStart = value.index(after: colon)
        } else if let slash = value.firstIndex(of: "/") {
            repositoryPathStart = value.index(after: slash)
        } else {
            repositoryPathStart = nil
        }
        guard let repositoryPathStart,
            let separator = value[repositoryPathStart...].lastIndex(of: "@"),
            separator > repositoryPathStart,
            value.index(after: separator) < value.endIndex
        else {
            return (value, nil)
        }
        return (
            String(value[..<separator]),
            String(value[value.index(after: separator)...])
        )
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
        case .unsafeArchive: "Package archive contains unsafe paths or metadata"
        case .missingManifest: "Package does not contain a package.json manifest"
        case .unsupportedExtensionPackage:
            "TypeScript extension packages are unsupported; migrate extensions to ZetaPluginSDK"
        }
    }
}

enum PackageInternalError: Error, LocalizedError, Sendable {
    case unsafeRegistryDirectory(String)
    case duplicateRegistryDirectory(String)
    case destinationCollision
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsafeRegistryDirectory(let value):
            "Package registry contains an unsafe directory: \(value)"
        case .duplicateRegistryDirectory(let value):
            "Multiple package records own the same directory: \(value)"
        case .destinationCollision:
            "Package install destination is already owned or occupied"
        case .rollbackFailed(let value):
            "Package rollback failed: \(value)"
        }
    }
}

public actor ResourcePackageManager {
    private static let defaultMaximumCompressedArchiveBytes: Int64 = 100 * 1_024 * 1_024
    private static let defaultMaximumExpandedArchiveBytes: Int64 = 1_024 * 1_024 * 1_024
    private static let defaultMaximumArchiveFileBytes: Int64 = 256 * 1_024 * 1_024
    private static let defaultMaximumArchiveMembers = 10_000
    private static let maximumArchiveMetadataBytes = 16 * 1_024 * 1_024

    private let root: URL
    private let session: URLSession
    private let maximumCompressedArchiveBytes: Int64
    private let maximumExpandedArchiveBytes: Int64
    private let maximumArchiveFileBytes: Int64
    private let maximumArchiveMembers: Int
    private var installed: [String: InstalledPackage] = [:]

    public init(root: URL, session: URLSession = .shared) throws {
        try self.init(
            root: root,
            session: session,
            maximumCompressedArchiveBytes: Self.defaultMaximumCompressedArchiveBytes,
            maximumExpandedArchiveBytes: Self.defaultMaximumExpandedArchiveBytes,
            maximumArchiveFileBytes: Self.defaultMaximumArchiveFileBytes,
            maximumArchiveMembers: Self.defaultMaximumArchiveMembers
        )
    }

    init(
        root: URL,
        session: URLSession,
        maximumCompressedArchiveBytes: Int64,
        maximumExpandedArchiveBytes: Int64 = 1_024 * 1_024 * 1_024,
        maximumArchiveFileBytes: Int64 = 256 * 1_024 * 1_024,
        maximumArchiveMembers: Int = 10_000
    ) throws {
        precondition(
            maximumCompressedArchiveBytes > 0 && maximumExpandedArchiveBytes > 0
                && maximumArchiveFileBytes > 0 && maximumArchiveMembers > 0
        )
        let standardizedRoot = root.standardizedFileURL
        self.root = standardizedRoot
        self.session = session
        self.maximumCompressedArchiveBytes = maximumCompressedArchiveBytes
        self.maximumExpandedArchiveBytes = maximumExpandedArchiveBytes
        self.maximumArchiveFileBytes = maximumArchiveFileBytes
        self.maximumArchiveMembers = maximumArchiveMembers
        try FileManager.default.createDirectory(
            at: standardizedRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let indexURL = standardizedRoot.appendingPathComponent("packages.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let records = try JSONDecoder().decode(
                [String: InstalledPackage].self,
                from: Data(contentsOf: indexURL)
            )
            try Self.validateRegistry(records)
            installed = records
        }
    }

    public func list() -> [InstalledPackage] {
        installed.values.sorted { $0.source < $1.source }
    }

    public func install(_ source: PackageSource, trusted: Bool = true) async throws {
        guard trusted else { throw PackageManagerError.untrusted }
        let identifier = source.identifier
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        switch source {
        case .git(let url, let reference):
            var arguments = ["clone", "--quiet", "--depth", "1"]
            if let reference { arguments += ["--branch", reference] }
            arguments += [url, staging.path]
            try await Self.run("git", arguments)
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
        installed = try withRegistryLock {
            var current = try loadIndex()
            let directory = try destinationDirectory(for: identifier, in: current)
            let destination = try installedPackageURL(directory: directory)
            if current[identifier] == nil,
                FileManager.default.fileExists(atPath: destination.path)
            {
                throw PackageInternalError.destinationCollision
            }
            let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)")
            current[identifier] = InstalledPackage(
                source: identifier,
                directory: directory,
                pinned: source.pinned,
                installedAt: ISO8601DateFormatter().string(from: Date())
            )
            var movedPreviousPackage = false
            var publishedNewPackage = false
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.moveItem(at: destination, to: backup)
                    movedPreviousPackage = true
                }
                try FileManager.default.moveItem(at: staging, to: destination)
                publishedNewPackage = true
                try persistIndex(current)
            } catch {
                let operationError = error
                do {
                    if publishedNewPackage {
                        try FileManager.default.removeItem(at: destination)
                    }
                    if movedPreviousPackage {
                        try FileManager.default.moveItem(at: backup, to: destination)
                    }
                } catch {
                    throw PackageInternalError.rollbackFailed(
                        "\(operationError.localizedDescription); \(error.localizedDescription)"
                    )
                }
                throw operationError
            }
            if movedPreviousPackage {
                try? FileManager.default.removeItem(at: backup)
            }
            return current
        }
    }

    public func remove(_ identifier: String, trusted: Bool = true) throws {
        guard trusted else { throw PackageManagerError.untrusted }
        if let cached = installed[identifier] {
            _ = try installedPackageURL(directory: cached.directory)
        }
        installed = try withRegistryLock {
            var current = try loadIndex()
            guard let value = current[identifier] else { return current }
            try requireExclusiveOwnership(of: value.directory, by: identifier, in: current)
            let destination = try installedPackageURL(directory: value.directory)
            let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)")
            current[identifier] = nil
            var movedPackage = false
            do {
                try FileManager.default.moveItem(at: destination, to: backup)
                movedPackage = true
                try persistIndex(current)
            } catch {
                let operationError = error
                if movedPackage {
                    do {
                        try FileManager.default.moveItem(at: backup, to: destination)
                    } catch {
                        throw PackageInternalError.rollbackFailed(
                            "\(operationError.localizedDescription); \(error.localizedDescription)"
                        )
                    }
                }
                throw operationError
            }
            try? FileManager.default.removeItem(at: backup)
            return current
        }
    }

    public func updateAll(trusted: Bool = true) async throws {
        guard trusted else { throw PackageManagerError.untrusted }
        installed = try withRegistryLock { try loadIndex() }
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
        let temporary = root.appendingPathComponent(".archive-\(UUID().uuidString).tgz")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await downloadArchive(from: tarballURL, to: temporary, packageName: name)
        try await validateArchiveMetadata(temporary)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try await Self.run(
            "/usr/bin/tar",
            [
                "-xzf", temporary.path, "--strip-components", "1",
                "--no-xattrs", "--no-acls", "--no-fflags", "--no-same-owner", "--safe-writes",
                "-C", staging.path,
            ]
        )
    }

    private func validateArchiveMetadata(_ archive: URL) async throws {
        // Mtree exposes escaped paths, types, and declared sizes without materializing members.
        let metadataData = try await Self.run(
            "/usr/bin/tar",
            ["-cf", "-", "--format=mtree", "@\(archive.path)"],
            maximumOutputBytes: Self.maximumArchiveMetadataBytes
        )
        let listingData = try await Self.run(
            "/usr/bin/tar",
            ["-tzf", archive.path],
            maximumOutputBytes: Self.maximumArchiveMetadataBytes
        )
        let verboseData = try await Self.run(
            "/usr/bin/tar",
            ["-tvzf", archive.path],
            maximumOutputBytes: Self.maximumArchiveMetadataBytes
        )
        guard let metadata = String(data: metadataData, encoding: .utf8),
            let listing = String(data: listingData, encoding: .utf8),
            let verbose = String(data: verboseData, encoding: .utf8)
        else {
            throw PackageManagerError.unsafeArchive
        }
        let metadataLines = Self.nonemptyLines(metadata)
        let listingLines = Self.nonemptyLines(listing)
        let verboseLines = Self.nonemptyLines(verbose)
        guard metadataLines.first == "#mtree" else {
            throw PackageManagerError.unsafeArchive
        }
        let records = Array(metadataLines.dropFirst())
        guard records.count == listingLines.count, records.count == verboseLines.count,
            records.count <= maximumArchiveMembers
        else {
            throw PackageManagerError.unsafeArchive
        }

        for rawPath in listingLines {
            let path = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : String(rawPath)
            guard Self.isSafeArchivePath(path) else {
                throw PackageManagerError.unsafeArchive
            }
        }
        guard verboseLines.allSatisfy({ $0.first == "-" || $0.first == "d" }) else {
            throw PackageManagerError.unsafeArchive
        }

        var expandedBytes: Int64 = 0
        for record in records {
            let fields = record.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2,
                let path = Self.decodeMTreePath(fields[0]),
                Self.isSafeArchivePath(path)
            else {
                throw PackageManagerError.unsafeArchive
            }
            var attributes: [Substring: Substring] = [:]
            for field in fields.dropFirst() {
                guard let separator = field.firstIndex(of: "="), separator != field.startIndex else {
                    throw PackageManagerError.unsafeArchive
                }
                let key = field[..<separator]
                let value = field[field.index(after: separator)...]
                guard attributes.updateValue(value, forKey: key) == nil else {
                    throw PackageManagerError.unsafeArchive
                }
            }
            guard let type = attributes["type"] else {
                throw PackageManagerError.unsafeArchive
            }
            switch type {
            case "dir":
                if let size = attributes["size"], size != "0" {
                    throw PackageManagerError.unsafeArchive
                }
            case "file":
                guard let rawSize = attributes["size"],
                    rawSize.allSatisfy({ $0.isASCII && $0.isNumber }),
                    let size = Int64(rawSize),
                    size <= maximumArchiveFileBytes
                else {
                    throw PackageManagerError.unsafeArchive
                }
                let (nextTotal, overflow) = expandedBytes.addingReportingOverflow(size)
                guard !overflow, nextTotal <= maximumExpandedArchiveBytes else {
                    throw PackageManagerError.unsafeArchive
                }
                expandedBytes = nextTotal
            default:
                throw PackageManagerError.unsafeArchive
            }
        }
    }

    private nonisolated static func nonemptyLines(_ value: String) -> [Substring] {
        value.split(separator: "\n", omittingEmptySubsequences: true)
    }

    private nonisolated static func decodeMTreePath(_ encoded: Substring) -> String? {
        let source = Array(encoded.utf8)
        var decoded: [UInt8] = []
        var index = 0
        while index < source.count {
            guard source[index] == 0x5C else {
                decoded.append(source[index])
                index += 1
                continue
            }
            guard index + 3 < source.count else { return nil }
            let digits = source[(index + 1)...(index + 3)]
            guard digits.allSatisfy({ (0x30...0x37).contains($0) }) else { return nil }
            let byte =
                (digits[digits.startIndex] - 0x30) * 64
                + (digits[digits.index(after: digits.startIndex)] - 0x30) * 8
                + (digits[digits.index(digits.startIndex, offsetBy: 2)] - 0x30)
            decoded.append(byte)
            index += 4
        }
        guard let rendered = String(bytes: decoded, encoding: .utf8), rendered.hasPrefix("./") else {
            return nil
        }
        return String(rendered.dropFirst(2))
    }

    private nonisolated static func isSafeArchivePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && path.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
            && components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private func downloadArchive(
        from url: URL,
        to destination: URL,
        packageName: String
    ) async throws {
        let delegate = BoundedDownloadDelegate(maximumBytes: maximumCompressedArchiveBytes)
        let downloaded: URL
        let response: URLResponse
        do {
            (downloaded, response) = try await session.download(
                for: URLRequest(url: url),
                delegate: delegate
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if delegate.exceededLimit { throw PackageManagerError.unsafeArchive }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        try Task.checkCancellation()
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PackageManagerError.invalidSource("npm:\(packageName)")
        }
        let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) <= maximumCompressedArchiveBytes else {
            throw PackageManagerError.unsafeArchive
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)
    }

    private func validatePackageTree(_ directory: URL) throws {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]
        let rootValues = try directory.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys)
            )
        else {
            throw PackageManagerError.unsafeArchive
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true,
                values.isRegularFile == true || values.isDirectory == true
            else {
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
    private nonisolated static func run(
        _ executable: String,
        _ arguments: [String],
        maximumOutputBytes: Int? = nil
    ) async throws -> Data {
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

        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try process.run()
                _ = setpgid(process.processIdentifier, process.processIdentifier)
                try Task.checkCancellation()
                var data = Data()
                for try await byte in pipe.fileHandleForReading.bytes {
                    if let maximumOutputBytes, data.count >= maximumOutputBytes {
                        terminateProcessTree(process)
                        throw PackageManagerError.unsafeArchive
                    }
                    data.append(byte)
                }
                let status = try await waitForExit(process)
                guard status == 0 else {
                    throw PackageManagerError.processFailed(
                        String(decoding: data, as: UTF8.self)
                    )
                }
                return data
            } catch {
                if Task.isCancelled {
                    terminateProcessTree(process)
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            terminateProcessTree(process)
        }
    }

    private nonisolated static func waitForExit(_ process: Process) async throws -> Int32 {
        while process.isRunning {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        return process.terminationStatus
    }

    private nonisolated static func terminateProcessTree(_ process: Process) {
        guard process.isRunning else { return }
        let identifier = process.processIdentifier
        if kill(-identifier, SIGTERM) != 0 {
            process.terminate()
        }
        if process.isRunning, kill(-identifier, SIGKILL) != 0 {
            _ = kill(identifier, SIGKILL)
        }
    }

    private func destinationDirectory(
        for identifier: String,
        in records: [String: InstalledPackage]
    ) throws -> String {
        if let record = records[identifier] {
            try requireExclusiveOwnership(
                of: record.directory,
                by: identifier,
                in: records
            )
            return record.directory
        }
        let readable = identifier.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? String(scalar) : "-"
        }.joined().prefix(80)
        let digest = SHA256.hash(data: Data(identifier.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = "\(readable)-\(digest)"
        try requireExclusiveOwnership(
            of: directory,
            by: identifier,
            in: records
        )
        return directory
    }

    private func requireExclusiveOwnership(
        of directory: String,
        by identifier: String,
        in records: [String: InstalledPackage]
    ) throws {
        let key = Self.directoryKey(directory)
        guard
            !records.contains(where: {
                $0.key != identifier && Self.directoryKey($0.value.directory) == key
            })
        else {
            throw PackageInternalError.destinationCollision
        }
    }

    private static func validateRegistry(
        _ records: [String: InstalledPackage]
    ) throws {
        var directories: Set<String> = []
        for record in records.values {
            let directory = record.directory
            guard directories.insert(directoryKey(directory)).inserted else {
                throw PackageInternalError.duplicateRegistryDirectory(directory)
            }
        }
    }

    private static func directoryKey(_ directory: String) -> String {
        directory.precomposedStringWithCanonicalMapping.lowercased()
    }

    private func installedPackageURL(directory: String) throws -> URL {
        guard !directory.isEmpty, directory != ".", directory != "..",
            !directory.contains("/"), !directory.contains("\\")
        else {
            throw PackageInternalError.unsafeRegistryDirectory(directory)
        }
        let destination = root.appendingPathComponent(directory).standardizedFileURL
        guard destination.deletingLastPathComponent().path == root.path else {
            throw PackageInternalError.unsafeRegistryDirectory(directory)
        }
        return destination
    }

    private var indexURL: URL { root.appendingPathComponent("packages.json") }

    private func loadIndex() throws -> [String: InstalledPackage] {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [:] }
        let records = try JSONDecoder().decode(
            [String: InstalledPackage].self,
            from: Data(contentsOf: indexURL)
        )
        try Self.validateRegistry(records)
        return records
    }

    private func withRegistryLock<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        let lockURL = root.appendingPathComponent(".packages.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func persistIndex(_ packages: [String: InstalledPackage]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(packages).write(to: indexURL, options: .atomic)
    }
}

private final class BoundedDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let lock = NSLock()
    private var exceeded = false

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    var exceededLimit: Bool {
        lock.withLock { exceeded }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > maximumBytes else { return }
        lock.withLock { exceeded = true }
        downloadTask.cancel()
    }
}
