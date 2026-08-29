import Foundation
import ZetaAI

public enum SessionError: Error, LocalizedError, Sendable {
    case invalidHeader
    case unsupportedVersion(Int)
    case duplicateID(String)
    case missingParent(String)
    case missingEntry(String)
    case invalidSessionID

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "Session file does not contain a valid header"
        case .unsupportedVersion(let value): "Unsupported coding-agent session version: \(value)"
        case .duplicateID(let value): "Duplicate session entry id: \(value)"
        case .missingParent(let value): "Missing parent session entry: \(value)"
        case .missingEntry(let value): "Missing session entry: \(value)"
        case .invalidSessionID:
            "Session id must use alphanumeric characters, '.', '_', or '-', and start and end alphanumerically"
        }
    }
}

public actor SessionManager {
    public let header: SessionHeader
    public let file: URL?
    private var entries: [SessionEntry]
    private var byID: [String: SessionEntry]
    private var leafID: String?
    private var physicallyCreated: Bool

    public init(header: SessionHeader, entries: [SessionEntry] = [], file: URL? = nil) throws {
        guard Self.validSessionID(header.id) else { throw SessionError.invalidSessionID }
        guard (header.version ?? 1) <= currentCodingSessionVersion else {
            throw SessionError.unsupportedVersion(header.version ?? 1)
        }
        var index: [String: SessionEntry] = [:]
        for entry in entries {
            guard index[entry.base.id] == nil else { throw SessionError.duplicateID(entry.base.id) }
            if let parent = entry.base.parentId, index[parent] == nil { throw SessionError.missingParent(parent) }
            index[entry.base.id] = entry
        }
        self.header = header
        self.file = file
        self.entries = entries
        self.byID = index
        self.leafID = entries.last?.base.id
        self.physicallyCreated = file.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public static func load(file: URL) throws -> SessionManager {
        var data = try Data(contentsOf: file)
        let needsNewlineRepair = !data.isEmpty && data.last != 0x0A
        var decoder = StrictJSONLDecoder()
        let records = decoder.push(data) + decoder.finish()
        var objects: [[String: Any]] = records.compactMap { record in
            try? JSONSerialization.jsonObject(with: record) as? [String: Any]
        }
        guard
            let headerIndex = objects.firstIndex(where: {
                $0["type"] as? String == "session"
            })
        else {
            throw SessionError.invalidHeader
        }
        let version = objects[headerIndex]["version"] as? Int ?? 1
        guard version <= currentCodingSessionVersion else {
            throw SessionError.unsupportedVersion(version)
        }
        objects[headerIndex]["version"] = currentCodingSessionVersion
        let entryIndices = objects.indices.filter {
            $0 != headerIndex && objects[$0]["type"] as? String != "session"
        }
        if version < 2 {
            var previous: String?
            var generatedIDs: [String] = []
            for index in entryIndices {
                let id =
                    objects[index]["id"] as? String
                    ?? UUID().uuidString.lowercased().prefix(8).description
                objects[index]["id"] = id
                objects[index]["parentId"] = previous ?? NSNull()
                generatedIDs.append(id)
                previous = id
            }
            for index in entryIndices where objects[index]["type"] as? String == "compaction" {
                if let old = objects[index].removeValue(forKey: "firstKeptEntryIndex") as? Int,
                    entryIndices.indices.contains(old),
                    generatedIDs.indices.contains(old)
                {
                    objects[index]["firstKeptEntryId"] = generatedIDs[old]
                }
            }
        }
        if version < 3 {
            for index in entryIndices where objects[index]["type"] as? String == "message" {
                guard var message = objects[index]["message"] as? [String: Any],
                    message["role"] as? String == "hookMessage"
                else {
                    continue
                }
                message["role"] = "custom"
                objects[index]["message"] = message
            }
        }
        let jsonDecoder = JSONDecoder()
        let headerData = try JSONSerialization.data(withJSONObject: objects[headerIndex])
        let header = try jsonDecoder.decode(SessionHeader.self, from: headerData)
        var entries: [SessionEntry] = []
        for index in entryIndices {
            let record = try JSONSerialization.data(withJSONObject: objects[index])
            if let entry = try? jsonDecoder.decode(SessionEntry.self, from: record) {
                entries.append(entry)
            }
        }
        if version < currentCodingSessionVersion {
            var migrated = Data()
            for index in [headerIndex] + entryIndices {
                migrated.append(try Self.line(objects[index]))
            }
            try migrated.write(to: file, options: .atomic)
        } else if needsNewlineRepair {
            data.append(0x0A)
            try data.write(to: file, options: .atomic)
        }
        return try SessionManager(header: header, entries: entries, file: file)
    }

    public func allEntries() -> [SessionEntry] { entries }
    public func leaf() -> SessionEntry? { leafID.flatMap { byID[$0] } }
    public func setLeaf(_ id: String?) throws {
        if let id, byID[id] == nil { throw SessionError.missingEntry(id) }
        leafID = id
    }

    @discardableResult
    public func append(_ entry: SessionEntry) throws -> SessionEntry {
        guard byID[entry.base.id] == nil else { throw SessionError.duplicateID(entry.base.id) }
        if let parent = entry.base.parentId, byID[parent] == nil { throw SessionError.missingParent(parent) }

        let materialized: Bool
        if physicallyCreated {
            try appendRecord(entry)
            materialized = false
        } else if case .message(_, .assistant) = entry {
            materialized = try ensureFileAndAppendPending(entry)
        } else {
            materialized = false
        }

        entries.append(entry)
        byID[entry.base.id] = entry
        leafID = entry.base.id
        if materialized { physicallyCreated = true }
        return entry
    }

    public func branch(to id: String? = nil) throws -> [SessionEntry] {
        let target = id ?? leafID
        guard let target else { return [] }
        var output: [SessionEntry] = []
        var current: SessionEntry? = byID[target]
        guard current != nil else { throw SessionError.missingEntry(target) }
        var seen = Set<String>()
        while let entry = current {
            guard seen.insert(entry.base.id).inserted else { throw SessionError.missingParent(entry.base.id) }
            output.append(entry)
            current = entry.base.parentId.flatMap { byID[$0] }
        }
        return output.reversed()
    }

    public func fork(
        header newHeader: SessionHeader,
        file newFile: URL?,
        at entryID: String,
        includeTarget: Bool = false
    ) throws -> SessionManager {
        var selected = try branch(to: entryID)
        if !includeTarget, !selected.isEmpty { selected.removeLast() }
        return try SessionManager(
            header: newHeader,
            entries: selected,
            file: newFile
        )
    }

    public func clone(
        header newHeader: SessionHeader,
        file newFile: URL?
    ) throws -> SessionManager {
        try SessionManager(
            header: newHeader,
            entries: branch(),
            file: newFile
        )
    }

    public func materialize() throws {
        guard file != nil, !physicallyCreated else { return }
        try rewriteAll()
        physicallyCreated = true
    }

    public func context(to id: String? = nil) throws -> SessionContext {
        let branch = try branch(to: id)
        var thinking: ThinkingLevel = .off
        var model: (provider: String, modelID: String)?
        for entry in branch {
            switch entry {
            case .thinkingLevelChange(_, let value): thinking = value
            case .modelChange(_, let provider, let modelID): model = (provider, modelID)
            case .message(_, .assistant(let assistant)): model = (assistant.provider, assistant.model)
            default: break
            }
        }
        let projected = projectCompaction(branch).flatMap { entry -> [Message] in
            switch entry {
            case .message(_, let message): return [message]
            case .customMessage(let base, _, let content, _, _):
                return [.user(UserMessage(content: content, timestamp: Self.milliseconds(base.timestamp)))]
            case .compaction(let base, let summary, _, let tokens, _, _, _):
                return [
                    .user(
                        UserMessage(
                            "Summary of previous conversation (\(tokens) tokens):\n\(summary)",
                            timestamp: Self.milliseconds(base.timestamp)))
                ]
            case .branchSummary(let base, _, let summary, _, _, _):
                return [
                    .user(
                        UserMessage(
                            "Summary of abandoned branch:\n\(summary)", timestamp: Self.milliseconds(base.timestamp)))
                ]
            default: return []
            }
        }
        return SessionContext(messages: projected, thinkingLevel: thinking, model: model)
    }

    public func tree() -> [SessionTreeNode] {
        let nodes: [String: SessionTreeNode] = entries.reduce(into: [:]) { $0[$1.base.id] = SessionTreeNode(entry: $1) }
        var roots: [SessionTreeNode] = []
        for entry in entries {
            guard let node = nodes[entry.base.id] else { continue }
            if let parent = entry.base.parentId, let parentNode = nodes[parent] {
                parentNode.children.append(node)
            } else {
                roots.append(node)
            }
        }
        return roots
    }

    private func projectCompaction(_ branch: [SessionEntry]) -> [SessionEntry] {
        guard let compactionIndex = branch.lastIndex(where: { if case .compaction = $0 { true } else { false } }),
            case .compaction(_, _, let firstKept, _, _, _, _) = branch[compactionIndex]
        else { return branch }
        var output: [SessionEntry] = [branch[compactionIndex]]
        if let keptIndex = branch[..<compactionIndex].firstIndex(where: { $0.base.id == firstKept }) {
            output += branch[keptIndex..<compactionIndex]
        }
        output += branch.dropFirst(compactionIndex + 1)
        return output
    }

    private func ensureFileAndAppendPending(_ pendingEntry: SessionEntry) throws -> Bool {
        guard let file, !physicallyCreated else { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rewriteAll(appending: pendingEntry)
        return true
    }

    private func rewriteAll(appending pendingEntry: SessionEntry? = nil) throws {
        guard let file else { return }
        var data = try Self.line(header)
        for entry in entries { data.append(try Self.line(entry)) }
        if let pendingEntry { data.append(try Self.line(pendingEntry)) }
        try data.write(to: file, options: .atomic)
    }

    private func appendRecord(_ entry: SessionEntry) throws {
        guard let file else { return }
        let record = try Self.line(entry)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let originalLength = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: record)
            try handle.synchronize()
        } catch {
            try? handle.truncate(atOffset: originalLength)
            try? handle.synchronize()
            throw error
        }
    }

    private static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private static func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    public static func validSessionID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil
    }

    private static func milliseconds(_ iso: String) -> Int64 {
        Int64((ISO8601DateFormatter().date(from: iso)?.timeIntervalSince1970 ?? 0) * 1_000)
    }
}

public final class SessionTreeNode: @unchecked Sendable {
    public let entry: SessionEntry
    public var children: [SessionTreeNode] = []
    public init(entry: SessionEntry) { self.entry = entry }
}

public struct StrictJSONLDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        return drain()
    }
    public mutating func finish() -> [Data] {
        guard !buffer.isEmpty else { return [] }
        defer { buffer.removeAll() }
        return [stripCR(buffer)]
    }
    private mutating func drain() -> [Data] {
        var output: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            output.append(stripCR(buffer[..<newline]))
            buffer.removeSubrange(...newline)
        }
        return output
    }
    private func stripCR<D: DataProtocol>(_ data: D) -> Data {
        var result = Data(data)
        if result.last == 0x0D { result.removeLast() }
        return result
    }
}
