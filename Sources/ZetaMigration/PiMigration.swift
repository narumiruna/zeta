import Foundation
import SQLite3

public struct MigrationReport: Codable, Sendable, Equatable {
    public var copied: [String]
    public var skipped: [String]
    public var warnings: [String]
    public var backupDirectory: String
}

public enum PiMigrationError: Error, LocalizedError, Sendable {
    case sourceMissing
    case destinationNotEmpty
    case invalidArtifact(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing: "Pi configuration directory does not exist"
        case .destinationNotEmpty: "Migration destination contains incompatible data"
        case .invalidArtifact(let path): "Migration input is invalid or unsupported: \(path)"
        }
    }
}

public struct PiMigrator: Sendable {
    public let source: URL
    public let destination: URL

    public init(source: URL, destination: URL) {
        self.source = source
        self.destination = destination
    }

    public func migrate() throws -> MigrationReport {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw PiMigrationError.sourceMissing
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let nonce = UUID().uuidString
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).migration-\(nonce)")
        let backup = parent.appendingPathComponent("\(destination.lastPathComponent)-migration-backup-\(nonce)")
        defer { try? FileManager.default.removeItem(at: staging) }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.copyItem(at: destination, to: staging)
        } else {
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var copied: [String] = []
        var skipped: [String] = []
        for path in Self.supportedPaths {
            let input = source.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: input.path) else {
                skipped.append(path)
                continue
            }
            let output = staging.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: output.path), try equivalent(input, output) {
                skipped.append(path)
                continue
            }
            try validate(input, relativePath: path)
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.createDirectory(
                at: output.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.copyItem(at: input, to: output)
            copied.append(path)
        }

        let warnings = extensionWarnings()
        if copied.isEmpty {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            return MigrationReport(
                copied: [], skipped: skipped.sorted(), warnings: warnings,
                backupDirectory: backup.path
            )
        }

        var movedOriginal = false
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
                movedOriginal = true
            } else {
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            }
            try FileManager.default.moveItem(at: staging, to: destination)
            if copied.contains("auth.json") {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.appendingPathComponent("auth.json").path
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            if movedOriginal {
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            throw error
        }
        return MigrationReport(
            copied: copied.sorted(), skipped: skipped.sorted(), warnings: warnings,
            backupDirectory: backup.path
        )
    }

    private static let supportedPaths = [
        "settings.json", "auth.json", "trust.json", "models.json",
        "models-store.json", "sessions", "skills", "prompts", "themes",
        "git", "npm",
    ]

    private func validate(_ url: URL, relativePath: String) throws {
        if ["settings.json", "auth.json", "trust.json", "models.json", "models-store.json"].contains(relativePath) {
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard value is [String: Any] else { throw PiMigrationError.invalidArtifact(relativePath) }
        }
        if relativePath == "sessions" {
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
                return
            }
            for case let file as URL in enumerator {
                if file.pathExtension == "jsonl" {
                    let first = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").first
                    guard let first,
                        let data = String(first).data(using: .utf8),
                        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        object["type"] as? String == "session",
                        (object["version"] as? Int ?? 1) <= 3
                    else {
                        throw PiMigrationError.invalidArtifact(file.path)
                    }
                } else if ["sqlite", "sqlite3", "db"].contains(file.pathExtension.lowercased()) {
                    try validateSQLite(file)
                }
            }
        }
    }

    private func validateSQLite(_ url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
            let database
        else {
            if let database { sqlite3_close(database) }
            throw PiMigrationError.invalidArtifact(url.path)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(entries)", -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw PiMigrationError.invalidArtifact(url.path) }
        defer { sqlite3_finalize(statement) }
        var integerTimestamp = false
        var parentColumn = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let type = sqlite3_column_text(statement, 2).map { String(cString: $0).uppercased() }
            if name == "timestamp" { integerTimestamp = type == "INTEGER" }
            if name == "parent_id" { parentColumn = true }
        }
        guard integerTimestamp, parentColumn else {
            throw PiMigrationError.invalidArtifact(url.path)
        }
    }

    private func extensionWarnings() -> [String] {
        let root = source.appendingPathComponent("extensions")
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return
            files
            .filter { ["ts", "js", "mts", "mjs"].contains($0.pathExtension.lowercased()) }
            .map { "TypeScript extension is not executable in Zeta: \($0.path)" }
            .sorted()
    }

    private func equivalent(_ lhs: URL, _ rhs: URL) throws -> Bool {
        var leftDirectory: ObjCBool = false
        var rightDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: lhs.path, isDirectory: &leftDirectory),
            FileManager.default.fileExists(atPath: rhs.path, isDirectory: &rightDirectory),
            leftDirectory.boolValue == rightDirectory.boolValue
        else {
            return false
        }
        if !leftDirectory.boolValue {
            return try Data(contentsOf: lhs) == Data(contentsOf: rhs)
        }
        let left = try relativeFiles(lhs)
        let right = try relativeFiles(rhs)
        guard left == right else { return false }
        return try left.allSatisfy {
            try Data(contentsOf: lhs.appendingPathComponent($0))
                == Data(contentsOf: rhs.appendingPathComponent($0))
        }
    }

    private func relativeFiles(_ root: URL) throws -> [String] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        else { return [] }
        return try enumerator.compactMap { value -> String? in
            guard let url = value as? URL,
                try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            else { return nil }
            return String(url.path.dropFirst(root.path.count + 1))
        }.sorted()
    }
}
