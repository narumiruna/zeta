import Foundation

public enum FileToolError: Error, LocalizedError, Equatable {
    case invalidPath(String)
    case unreadable(String)
    case invalidEdit(String)
    case noMatch(String)
    case multipleMatches(String)
    case overlappingEdits
    case processFailed(String)
    case timedOut
    case aborted

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let value): "Invalid path: \(value)"
        case .unreadable(let value): "Could not read file: \(value)"
        case .invalidEdit(let value): "Invalid edit: \(value)"
        case .noMatch(let value): "oldText did not match in \(value)"
        case .multipleMatches(let value): "oldText matched multiple locations in \(value)"
        case .overlappingEdits: "Edits overlap in the original file"
        case .processFailed(let value): value
        case .timedOut: "Command timed out"
        case .aborted: "Operation aborted"
        }
    }
}

public struct TextReplacement: Sendable, Codable, Equatable {
    public let oldText: String
    public let newText: String

    public init(oldText: String, newText: String) {
        self.oldText = oldText
        self.newText = newText
    }
}

public struct EditResult: Sendable, Equatable {
    public let replacements: Int
    public let firstChangedLine: Int?
    public let original: String
    public let updated: String
}

public actor FileMutationCoordinator {
    public static let shared = FileMutationCoordinator()
    private var active: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public func perform<T: Sendable>(at path: String, operation: @escaping @Sendable () async throws -> T) async throws
        -> T
    {
        await acquire(path)
        do {
            let value = try await operation()
            release(path)
            return value
        } catch {
            release(path)
            throw error
        }
    }

    private func acquire(_ path: String) async {
        if active.insert(path).inserted { return }
        await withCheckedContinuation { waiters[path, default: []].append($0) }
    }

    private func release(_ path: String) {
        if var queued = waiters[path], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[path] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            active.remove(path)
        }
    }
}

public struct FileTools: @unchecked Sendable {
    public let workingDirectory: URL
    private let fileManager: FileManager

    public init(workingDirectory: URL, fileManager: FileManager = .default) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func resolve(_ path: String) throws -> URL {
        let stripped = path.hasPrefix("@") ? String(path.dropFirst()) : path
        guard !stripped.isEmpty else { throw FileToolError.invalidPath(path) }
        let expanded = (stripped as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : workingDirectory.appendingPathComponent(expanded)
        return url.standardizedFileURL
    }

    public func read(path: String, offset: Int = 1, limit: Int? = nil) throws -> String {
        guard offset >= 1 else { throw FileToolError.invalidPath("offset must be at least 1") }
        let url = try resolve(path)
        guard let data = fileManager.contents(atPath: url.path) else {
            throw FileToolError.unreadable(path)
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")
        let start = min(offset - 1, lines.count)
        let end = min(lines.count, start + (limit ?? lines.count))
        return lines[start..<end].joined(separator: "\n")
    }

    public func write(path: String, content: String) throws {
        let url = try resolve(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    public func edit(path: String, replacements: [TextReplacement]) async throws -> EditResult {
        guard !replacements.isEmpty else {
            throw FileToolError.invalidEdit("edits must contain at least one replacement")
        }
        let url = try resolve(path)
        return try await FileMutationCoordinator.shared.perform(at: url.path) {
            guard let data = self.fileManager.contents(atPath: url.path) else {
                throw FileToolError.unreadable(path)
            }
            try Task.checkCancellation()
            let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
            let contentBytes = hasBOM ? data.dropFirst(3) : data[...]
            guard let raw = String(bytes: contentBytes, encoding: .utf8) else {
                throw FileToolError.unreadable(path)
            }
            let bom = hasBOM ? "\u{FEFF}" : ""
            let newline = raw.contains("\r\n") ? "\r\n" : "\n"
            let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            var ranges: [(Range<String.Index>, String)] = []
            for replacement in replacements {
                guard !replacement.oldText.isEmpty else { throw FileToolError.invalidEdit("oldText must not be empty") }
                let needle = replacement.oldText.replacingOccurrences(of: "\r\n", with: "\n")
                let matches = normalized.ranges(of: needle)
                guard !matches.isEmpty else { throw FileToolError.noMatch(path) }
                guard matches.count == 1 else { throw FileToolError.multipleMatches(path) }
                ranges.append((matches[0], replacement.newText.replacingOccurrences(of: "\r\n", with: "\n")))
            }
            let sorted = ranges.sorted { $0.0.lowerBound < $1.0.lowerBound }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.0.upperBound > pair.1.0.lowerBound {
                throw FileToolError.overlappingEdits
            }
            var updated = normalized
            for (range, replacement) in sorted.reversed() {
                updated.replaceSubrange(range, with: replacement)
            }
            let firstIndex = sorted.first?.0.lowerBound
            let firstLine = firstIndex.map { normalized[..<$0].reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
            let restored = bom + (newline == "\r\n" ? updated.replacingOccurrences(of: "\n", with: "\r\n") : updated)
            try Task.checkCancellation()
            try Data(restored.utf8).write(to: url, options: .atomic)
            return EditResult(
                replacements: replacements.count, firstChangedLine: firstLine, original: bom + raw, updated: restored)
        }
    }

    public func list(path: String = ".", limit: Int = 500) throws -> [String] {
        let url = try resolve(path)
        let values = try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        return try values.compactMap { value in
            let isDirectory = try value.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            return value.lastPathComponent + (isDirectory ? "/" : "")
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(limit).map { $0 }
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var output: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex, let range = range(of: needle, range: start..<endIndex) {
            output.append(range)
            start = range.upperBound
        }
        return output
    }
}
