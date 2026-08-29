import Foundation
import ZetaAI
import ZetaAgent
import ZetaCompaction
import ZetaSessions

enum PersistentSessionOperation: Sendable, Equatable {
    case recordMessage
    case recordCompaction
    case recordModel
    case recordThinkingLevel
    case setName
    case materializeName
    case materializeNewSession
}

struct DeferredPersistenceError: LocalizedError, Sendable, Equatable {
    let failures: [String]

    var errorDescription: String? {
        "Session persistence failed: " + failures.joined(separator: "; ")
    }
}

struct PreparedSessionReplacement: Sendable {
    fileprivate let manager: SessionManager
    let file: URL?
}

actor PersistentSessionController {
    typealias FailureInjector = @Sendable (PersistentSessionOperation) throws -> Void

    private var manager: SessionManager
    private var errors: [String] = []
    private let injectFailure: FailureInjector

    init(
        manager: SessionManager,
        injectFailure: @escaping FailureInjector = { _ in }
    ) {
        self.manager = manager
        self.injectFailure = injectFailure
    }

    static func open(
        arguments: CLIArguments,
        workingDirectory: URL,
        defaultRoot: URL
    ) async throws -> PersistentSessionController? {
        guard !arguments.noSession else { return nil }
        let root =
            arguments.sessionDirectory.map(URL.init(fileURLWithPath:))
            ?? defaultRoot.appendingPathComponent(encodedDirectory(workingDirectory.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        if let requested = arguments.session {
            return try PersistentSessionController(manager: resolve(requested, root: root))
        }
        if arguments.continueSession || arguments.resume {
            if let latest = latestSession(in: root) {
                return try PersistentSessionController(manager: SessionManager.load(file: latest))
            }
        }
        if let source = arguments.fork {
            let original = try resolve(source, root: root)
            guard let leaf = await original.leaf() else {
                return try PersistentSessionController(manager: create(root: root, cwd: workingDirectory.path))
            }
            let destination = sessionFile(root: root)
            let header = SessionHeader(
                id: UUID().uuidString.lowercased(),
                timestamp: ISO8601DateFormatter().string(from: Date()),
                cwd: workingDirectory.path,
                parentSession: await original.file?.path
            )
            let fork = try await original.fork(
                header: header,
                file: destination,
                at: leaf.base.id,
                includeTarget: false
            )
            return PersistentSessionController(manager: fork)
        }
        return try PersistentSessionController(
            manager: create(
                root: root,
                cwd: workingDirectory.path,
                id: arguments.sessionID
            )
        )
    }

    func restore(models: [Model]) async throws -> (messages: [Message], model: Model?, thinking: ThinkingLevel) {
        let context = try await manager.context()
        let model = context.model.flatMap { selected in
            models.first { $0.provider == selected.provider && $0.id == selected.modelID }
        }
        return (context.messages, model, context.thinkingLevel)
    }

    func record(_ event: AgentEvent) async {
        guard case .messageEnd(let message) = event else { return }
        do {
            try injectFailure(.recordMessage)
            let parent = await manager.leaf()?.base.id
            let base = SessionEntryBase(
                id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
                parentId: parent,
                timestamp: Self.timestamp(for: message)
            )
            try await manager.append(.message(base, message))
        } catch {
            errors.append(error.localizedDescription)
        }
    }

    func currentEntries() async -> [SessionEntry] { await manager.allEntries() }
    func currentTree() async -> [SessionTreeNode] { await manager.tree() }
    func currentLeafID() async -> String? { await manager.leaf()?.base.id }
    func currentMessages() async throws -> [Message] { try await manager.context().messages }
    func currentFile() async -> URL? { await manager.file }
    func currentName() async -> String? { Self.sessionName(in: await manager.allEntries()) }
    func exportSnapshot() async -> (header: SessionHeader, entries: [SessionEntry], leafID: String?) {
        await (manager.header, manager.allEntries(), manager.leaf()?.base.id)
    }

    func drainPersistenceErrors() throws {
        guard !errors.isEmpty else { return }
        let failures = errors
        errors.removeAll()
        throw DeferredPersistenceError(failures: failures)
    }

    func prepareNewSession(parentSession: String? = nil) async throws -> PreparedSessionReplacement {
        try drainPersistenceErrors()
        let currentFile = await manager.file
        let root =
            currentFile?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        let replacement = try Self.create(
            root: root,
            cwd: await manager.header.cwd,
            parentSession: parentSession
        )
        try injectFailure(.materializeNewSession)
        try await replacement.materialize()
        return PreparedSessionReplacement(
            manager: replacement,
            file: await replacement.file
        )
    }

    func publishNewSession(_ replacement: PreparedSessionReplacement) {
        manager = replacement.manager
        errors = []
    }

    @discardableResult
    func newSession(parentSession: String? = nil) async throws -> URL? {
        let replacement = try await prepareNewSession(parentSession: parentSession)
        publishNewSession(replacement)
        return replacement.file
    }

    func recordCompaction(
        summary: String,
        preparation: CompactionPreparation
    ) async throws {
        try injectFailure(.recordCompaction)
        let branch = try await manager.branch()
        let contextEntries = Self.projectedContextEntries(branch)
        guard contextEntries.indices.contains(preparation.firstRetainedMessageIndex) else {
            throw AgentError.blocked("Compaction context does not match the persistent session")
        }
        let firstKeptEntryID = contextEntries[preparation.firstRetainedMessageIndex].base.id
        let base = SessionEntryBase(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            parentId: await manager.leaf()?.base.id,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        try await manager.append(
            .compaction(
                base,
                summary: summary,
                firstKeptEntryID: firstKeptEntryID,
                tokensBefore: preparation.estimatedTokensBefore,
                details: nil,
                usage: nil,
                fromHook: false
            )
        )
    }

    func recordModel(_ model: Model) async throws {
        try injectFailure(.recordModel)
        let base = SessionEntryBase(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            parentId: await manager.leaf()?.base.id,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        try await manager.append(
            .modelChange(base, provider: model.provider, modelID: model.id)
        )
        try await manager.materialize()
    }

    func recordThinkingLevel(_ level: ThinkingLevel) async throws {
        try injectFailure(.recordThinkingLevel)
        if try await manager.context().thinkingLevel == level {
            return
        }
        let base = SessionEntryBase(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            parentId: await manager.leaf()?.base.id,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        try await manager.append(.thinkingLevelChange(base, level))
        try await manager.materialize()
    }

    func setName(_ name: String?) async throws {
        try injectFailure(.setName)
        let base = SessionEntryBase(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            parentId: await manager.leaf()?.base.id,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        try await manager.append(.sessionInfo(base, name: name))
        try injectFailure(.materializeName)
        try await manager.materialize()
    }

    func clone() async throws -> SessionManager {
        let sourceFile = await manager.file
        let root = sourceFile?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let file = Self.sessionFile(root: root)
        let header = SessionHeader(
            id: UUID().uuidString.lowercased(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            cwd: await manager.header.cwd,
            parentSession: sourceFile?.path
        )
        let clone = try await manager.clone(header: header, file: file)
        try await clone.materialize()
        manager = clone
        return clone
    }

    func fork(at entryID: String?) async throws -> SessionManager {
        let currentLeaf = await manager.leaf()?.base.id
        guard let target = entryID ?? currentLeaf else { return try await clone() }
        let sourceFile = await manager.file
        let root = sourceFile?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
        let file = Self.sessionFile(root: root)
        let header = SessionHeader(
            id: UUID().uuidString.lowercased(),
            timestamp: ISO8601DateFormatter().string(from: Date()),
            cwd: await manager.header.cwd,
            parentSession: sourceFile?.path
        )
        let fork = try await manager.fork(header: header, file: file, at: target)
        try await fork.materialize()
        manager = fork
        return fork
    }

    func switchTo(path: String) async throws -> (messages: [Message], name: String?) {
        let loaded = try SessionManager.load(file: URL(fileURLWithPath: path))
        let messages = try await loaded.context().messages
        let name = Self.sessionName(in: await loaded.allEntries())
        manager = loaded
        return (messages, name)
    }

    private static func sessionName(in entries: [SessionEntry]) -> String? {
        for entry in entries.reversed() {
            guard case .sessionInfo(_, let name) = entry else { continue }
            let normalized = name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized?.isEmpty == false ? normalized : nil
        }
        return nil
    }

    private static func projectedContextEntries(_ branch: [SessionEntry]) -> [SessionEntry] {
        let projected: [SessionEntry]
        if let compactionIndex = branch.lastIndex(where: { entry in
            if case .compaction = entry { true } else { false }
        }), case .compaction(_, _, let firstKept, _, _, _, _) = branch[compactionIndex] {
            var compacted = [branch[compactionIndex]]
            if let keptIndex = branch[..<compactionIndex].firstIndex(where: { $0.base.id == firstKept }) {
                compacted += branch[keptIndex..<compactionIndex]
            }
            compacted += branch.dropFirst(compactionIndex + 1)
            projected = compacted
        } else {
            projected = branch
        }
        return projected.filter { entry in
            switch entry {
            case .message, .customMessage, .compaction, .branchSummary:
                true
            default:
                false
            }
        }
    }

    private static func resolve(_ value: String, root: URL) throws -> SessionManager {
        let direct = URL(fileURLWithPath: value)
        if FileManager.default.fileExists(atPath: direct.path) {
            return try SessionManager.load(file: direct)
        }
        let sessions =
            ((try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        let identified = sessions.compactMap { file in
            sessionID(in: file).map { (file: file, id: $0) }
        }
        guard
            let selected = identified.first(where: { $0.id == value })
                ?? identified.first(where: { $0.id.hasPrefix(value) })
        else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try SessionManager.load(file: selected.file)
    }

    private static func sessionID(in file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        var decoder = StrictJSONLDecoder()
        for record in decoder.push(data) + decoder.finish() {
            guard
                let object = try? JSONSerialization.jsonObject(with: record) as? [String: Any],
                object["type"] as? String == "session",
                let id = object["id"] as? String
            else {
                continue
            }
            return id
        }
        return nil
    }

    private static func latestSession(in root: URL) -> URL? {
        ((try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [])
        .filter { $0.pathExtension == "jsonl" }
        .max { lhs, rhs in
            let left =
                (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let right =
                (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return left < right
        }
    }

    private static func create(
        root: URL,
        cwd: String,
        id: String? = nil,
        parentSession: String? = nil
    ) throws -> SessionManager {
        try SessionManager(
            header: SessionHeader(
                id: id ?? UUID().uuidString.lowercased(),
                timestamp: ISO8601DateFormatter().string(from: Date()),
                cwd: cwd,
                parentSession: parentSession
            ),
            file: sessionFile(root: root)
        )
    }

    private static func sessionFile(root: URL) -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent("\(timestamp)_\(UUID().uuidString.lowercased()).jsonl")
    }

    private static func encodedDirectory(_ path: String) -> String {
        "--"
            + path.drop(while: { $0 == "/" || $0 == "\\" })
            .map { $0 == "/" || $0 == "\\" || $0 == ":" ? "-" : $0 }
            + "--"
    }

    private static func timestamp(for message: Message) -> String {
        let milliseconds: Int64 =
            switch message {
            case .user(let value): value.timestamp
            case .assistant(let value): value.timestamp
            case .toolResult(let value): value.timestamp
            case .custom(let value): value.timestamp
            }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(milliseconds) / 1_000))
    }
}
