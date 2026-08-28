import Foundation

public struct StoredModelCatalog: Codable, Sendable, Equatable {
    public var models: [Model]
    public var lastModified: String?
    public var checkedAt: Int64?
    public var etag: String?

    public init(
        models: [Model],
        lastModified: String? = nil,
        checkedAt: Int64? = nil,
        etag: String? = nil
    ) {
        self.models = models
        self.lastModified = lastModified
        self.checkedAt = checkedAt
        self.etag = etag
    }
}

public protocol ModelCatalogStore: Sendable {
    func read(provider: String) async throws -> StoredModelCatalog?
    func write(provider: String, entry: StoredModelCatalog) async throws
    func delete(provider: String) async throws
}

public actor InMemoryModelCatalogStore: ModelCatalogStore {
    private var entries: [String: StoredModelCatalog] = [:]
    public init() {}
    public func read(provider: String) -> StoredModelCatalog? { entries[provider] }
    public func write(provider: String, entry: StoredModelCatalog) { entries[provider] = entry }
    public func delete(provider: String) { entries[provider] = nil }
}

public actor FileModelCatalogStore: ModelCatalogStore {
    private let url: URL
    private var entries: [String: StoredModelCatalog]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            entries = try JSONDecoder().decode(
                [String: StoredModelCatalog].self,
                from: Data(contentsOf: url)
            )
        } else {
            entries = [:]
        }
    }

    public func read(provider: String) -> StoredModelCatalog? { entries[provider] }
    public func write(provider: String, entry: StoredModelCatalog) throws {
        entries[provider] = entry
        try persist()
    }
    public func delete(provider: String) throws {
        entries[provider] = nil
        try persist()
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
    }
}

public struct ModelRefreshResult: Sendable {
    public var aborted: Bool
    public var errors: [String: String]
    public var refreshed: Set<String>
}

public actor DynamicModelProvider: AIProvider {
    public typealias Fetch =
        @Sendable (
            _ stored: StoredModelCatalog?
        ) async throws -> StoredModelCatalog
    public typealias Stream =
        @Sendable (
            Model,
            Context,
            StreamOptions
        ) async -> AssistantEventStream

    public nonisolated let id: String
    private var currentModels: [Model]
    private var generation: UInt64 = 0
    private let store: any ModelCatalogStore
    private let fetch: Fetch
    private let streamFunction: Stream

    public init(
        id: String,
        initialModels: [Model] = [],
        store: any ModelCatalogStore,
        fetch: @escaping Fetch,
        stream: @escaping Stream
    ) {
        self.id = id
        currentModels = initialModels
        self.store = store
        self.fetch = fetch
        streamFunction = stream
    }

    public var models: [Model] { currentModels }

    public func restore() async throws {
        if let stored = try await store.read(provider: id) {
            currentModels = stored.models
        }
    }

    public func refresh(allowNetwork: Bool = true) async throws {
        generation &+= 1
        let requestedGeneration = generation
        let stored = try await store.read(provider: id)
        if !allowNetwork {
            if let stored { currentModels = stored.models }
            return
        }
        let fetched = try await fetch(stored)
        try Task.checkCancellation()
        guard generation == requestedGeneration else { return }
        currentModels = fetched.models
        try await store.write(provider: id, entry: fetched)
    }

    public func stream(
        model: Model,
        context: Context,
        options: StreamOptions
    ) async -> AssistantEventStream {
        await streamFunction(model, context, options)
    }
}

public enum ModelRefresh {
    public static func all(
        _ providers: [DynamicModelProvider],
        allowNetwork: Bool = true
    ) async -> ModelRefreshResult {
        if Task.isCancelled {
            return ModelRefreshResult(
                aborted: true,
                errors: [:],
                refreshed: []
            )
        }
        var errors: [String: String] = [:]
        var refreshed: Set<String> = []
        await withTaskGroup(of: (String, Error?).self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        try await provider.refresh(allowNetwork: allowNetwork)
                        return (provider.id, nil)
                    } catch {
                        return (provider.id, error)
                    }
                }
            }
            for await (id, error) in group {
                if let error { errors[id] = String(describing: error) } else { refreshed.insert(id) }
            }
        }
        return ModelRefreshResult(
            aborted: Task.isCancelled,
            errors: errors,
            refreshed: refreshed
        )
    }
}
