import Foundation
import ZetaAI
import ZetaAgent
import ZetaCompaction
import ZetaSessions

actor PersistentSessionController {
    private var manager: SessionManager
    private var errors: [String] = []

    init(manager: SessionManager) {
        self.manager = manager
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
    func currentMessages() async throws -> [Message] { try await manager.context().messages }
    func currentFile() async -> URL? { await manager.file }
    func persistenceErrors() -> [String] { errors }

    @discardableResult
    func newSession() async throws -> URL? {
        let currentFile = await manager.file
        let root =
            currentFile?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory
        let replacement = try Self.create(
            root: root,
            cwd: await manager.header.cwd
        )
        try await replacement.materialize()
        manager = replacement
        errors = []
        return await replacement.file
    }

    func recordCompaction(
        summary: String,
        preparation: CompactionPreparation
    ) async throws {
        let branch = try await manager.branch()
        let messageEntries = branch.compactMap { entry -> SessionEntry? in
            if case .message = entry { entry } else { nil }
        }
        guard !messageEntries.isEmpty else { return }
        let retainedIndex = min(
            preparation.firstRetainedMessageIndex,
            messageEntries.count - 1
        )
        let base = SessionEntryBase(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            parentId: await manager.leaf()?.base.id,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        try await manager.append(
            .compaction(
                base,
                summary: summary,
                firstKeptEntryID: messageEntries[retainedIndex].base.id,
                tokensBefore: preparation.estimatedTokensBefore,
                details: nil,
                usage: nil,
                fromHook: false
            )
        )
    }

    func recordThinkingLevel(_ level: ThinkingLevel) async throws {
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
        let base = SessionEntryBase(
            id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased(),
            parentId: await manager.leaf()?.base.id,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        try await manager.append(.sessionInfo(base, name: name))
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

    func switchTo(path: String) async throws -> [Message] {
        let loaded = try SessionManager.load(file: URL(fileURLWithPath: path))
        manager = loaded
        return try await loaded.context().messages
    }

    private static func resolve(_ value: String, root: URL) throws -> SessionManager {
        let direct = URL(fileURLWithPath: value)
        if FileManager.default.fileExists(atPath: direct.path) {
            return try SessionManager.load(file: direct)
        }
        let matches = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.contains(value) }
        guard let selected = matches.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try SessionManager.load(file: selected)
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
        id: String? = nil
    ) throws -> SessionManager {
        try SessionManager(
            header: SessionHeader(
                id: id ?? UUID().uuidString.lowercased(),
                timestamp: ISO8601DateFormatter().string(from: Date()),
                cwd: cwd
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
