import Foundation

public enum TransportPreference: String, Codable, Sendable, CaseIterable {
    case sse
    case websocket
    case auto
}

public enum QueueMode: String, Codable, Sendable, CaseIterable {
    case all
    case oneAtATime = "one-at-a-time"
}

public enum ProjectTrustDefault: String, Codable, Sendable, CaseIterable {
    case ask
    case always
    case never
}

public struct CompactionSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var reserveTokens = 16_384
    public var keepRecentTokens = 20_000
}

public struct RetrySettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var maxRetries = 3
    public var baseDelayMs = 2_000
    public var maxRetryDelayMs = 60_000
}

public struct Settings: Codable, Sendable, Equatable {
    public var transport: TransportPreference = .auto
    public var steeringMode: QueueMode = .oneAtATime
    public var followUpMode: QueueMode = .oneAtATime
    public var theme = "dark"
    public var compaction = CompactionSettings()
    public var retry = RetrySettings()
    public var httpIdleTimeoutMs = 300_000
    public var showImages = true
    public var imageWidth = 60
    public var imageAutoResize = true
    public var blockImages = false
    public var tuiMode = "regular"
    public var fullscreenExit = "transcript"
    public var fullscreenScrollbar = "auto"
    public var fullscreenCopyOnSelect = true
    public var outputPadding = 1
    public var editorPadding = 0
    public var autocompleteMaxVisible = 5
    public var defaultProjectTrust: ProjectTrustDefault = .ask
    public var enableInstallTelemetry = true

    public init() {}
}

public struct ZetaPaths: Sendable {
    public let home: URL
    public let workingDirectory: URL
    public let agentDirectory: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        workingDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.agentDirectory =
            environment["PI_CODING_AGENT_DIR"].map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".pi/agent")
    }

    public var globalSettings: URL { agentDirectory.appendingPathComponent("settings.json") }
    public var projectSettings: URL { workingDirectory.appendingPathComponent(".pi/settings.json") }
    public var auth: URL { agentDirectory.appendingPathComponent("auth.json") }
    public var trust: URL { agentDirectory.appendingPathComponent("trust.json") }
    public var sessions: URL { agentDirectory.appendingPathComponent("sessions") }
}

public actor SettingsStore {
    private let paths: ZetaPaths
    private var settings: Settings

    public init(paths: ZetaPaths, includeProject: Bool = true) throws {
        self.paths = paths
        self.settings = try Self.loadMerged(
            globalURL: paths.globalSettings,
            projectURL: includeProject && FileManager.default.fileExists(atPath: paths.projectSettings.path)
                ? paths.projectSettings : nil
        )
    }

    public func current() -> Settings { settings }

    public func modify(_ body: @Sendable (inout Settings) -> Void) throws {
        var candidate = settings
        body(&candidate)
        try Self.write(candidate, to: paths.globalSettings)
        settings = candidate
    }

    /// Returns after all settings accepted by this actor are durable.
    ///
    /// Writes are performed synchronously while isolated to the actor, so this
    /// method is an explicit durability boundary rather than a second write.
    public func flush() async {}

    /// Returns persistence errors that were deferred by the store.
    ///
    /// `modify` reports failures directly and never admits a failed write, so
    /// the synchronous implementation has no deferred errors to drain.
    public func drainErrors() -> [String] { [] }

    public static func merge(global: Settings, project: Settings) -> Settings {
        // Typed decoding cannot distinguish an omitted field from its default.
        // File-level merging is handled by mergeJSON before decoding; this method
        // is retained for callers that intentionally replace all project values.
        project
    }

    public static func loadMerged(globalURL: URL, projectURL: URL?) throws -> Settings {
        let defaults = try encodedObject(Settings())
        let global = migrate(try readObject(globalURL) ?? [:])
        let project = migrate(try projectURL.flatMap(readObject) ?? [:])
        let merged = mergeJSON(mergeJSON(defaults, global), project)
        let data = try JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    private static func migrate(_ input: [String: Any]) -> [String: Any] {
        var result = input
        if let queueMode = result.removeValue(forKey: "queueMode") as? String,
            result["steeringMode"] == nil
        {
            result["steeringMode"] = queueMode
        }
        if let websockets = result.removeValue(forKey: "websockets") as? Bool,
            result["transport"] == nil
        {
            result["transport"] = websockets ? "websocket" : "sse"
        }
        if var retry = result["retry"] as? [String: Any],
            let legacyDelay = retry.removeValue(forKey: "maxDelayMs"),
            retry["maxRetryDelayMs"] == nil
        {
            retry["maxRetryDelayMs"] = legacyDelay
            result["retry"] = retry
        }
        return result
    }

    private static func mergeJSON(_ base: [String: Any], _ override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let nested = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = mergeJSON(existing, nested)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func encodedObject(_ settings: Settings) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        guard let object = value as? [String: Any] else { throw CocoaError(.propertyListWriteInvalid) }
        return object
    }

    private static func readObject(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? [String: Any] else { throw CocoaError(.propertyListReadCorrupt) }
        return object
    }

    private static func write(_ settings: Settings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(settings)
        try withAdvisoryFileLock(url: url) {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
