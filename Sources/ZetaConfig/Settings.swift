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
    public var fullscreenExitOutput = "transcript"
    public var fullscreenScrollbar = "auto"
    public var fullscreenCopyOnSelect = true
    public var outputPadding = 1
    public var editorPadding = 0
    public var autocompleteMaxVisible = 5
    public var defaultProjectTrust: ProjectTrustDefault = .ask
    public var enableInstallTelemetry = true

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case transport
        case steeringMode
        case followUpMode
        case theme
        case compaction
        case retry
        case httpIdleTimeoutMs
        case showImages
        case imageWidth
        case imageAutoResize
        case blockImages
        case tuiMode
        case fullscreenExitOutput
        case fullscreenScrollbar
        case fullscreenCopyOnSelect
        case outputPadding
        case editorPadding
        case autocompleteMaxVisible
        case defaultProjectTrust
        case enableInstallTelemetry
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case fullscreenExit
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transport = try container.decode(TransportPreference.self, forKey: .transport)
        steeringMode = try container.decode(QueueMode.self, forKey: .steeringMode)
        followUpMode = try container.decode(QueueMode.self, forKey: .followUpMode)
        theme = try container.decode(String.self, forKey: .theme)
        compaction = try container.decode(CompactionSettings.self, forKey: .compaction)
        retry = try container.decode(RetrySettings.self, forKey: .retry)
        httpIdleTimeoutMs = try container.decode(Int.self, forKey: .httpIdleTimeoutMs)
        showImages = try container.decode(Bool.self, forKey: .showImages)
        imageWidth = try container.decode(Int.self, forKey: .imageWidth)
        imageAutoResize = try container.decode(Bool.self, forKey: .imageAutoResize)
        blockImages = try container.decode(Bool.self, forKey: .blockImages)
        tuiMode = try container.decode(String.self, forKey: .tuiMode)
        fullscreenScrollbar = try container.decode(String.self, forKey: .fullscreenScrollbar)
        fullscreenCopyOnSelect = try container.decode(Bool.self, forKey: .fullscreenCopyOnSelect)
        outputPadding = try container.decode(Int.self, forKey: .outputPadding)
        editorPadding = try container.decode(Int.self, forKey: .editorPadding)
        autocompleteMaxVisible = try container.decode(Int.self, forKey: .autocompleteMaxVisible)
        defaultProjectTrust = try container.decode(
            ProjectTrustDefault.self,
            forKey: .defaultProjectTrust
        )
        enableInstallTelemetry = try container.decode(Bool.self, forKey: .enableInstallTelemetry)
        if container.contains(.fullscreenExitOutput) {
            fullscreenExitOutput = try container.decode(String.self, forKey: .fullscreenExitOutput)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            fullscreenExitOutput = try legacy.decode(String.self, forKey: .fullscreenExit)
        }
    }

    @available(*, deprecated, renamed: "fullscreenExitOutput")
    public var fullscreenExit: String {
        get { fullscreenExitOutput }
        set { fullscreenExitOutput = newValue }
    }
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
    private let projectOverrides: [String: Any]
    private var globalSettings: Settings
    private var settings: Settings

    public init(paths: ZetaPaths, includeProject: Bool = true) throws {
        self.paths = paths
        let globalSettings = try Self.loadMerged(
            globalURL: paths.globalSettings,
            projectURL: nil
        )
        let projectOverrides =
            includeProject
            ? Self.migrate(try Self.readObject(paths.projectSettings) ?? [:])
            : [:]
        self.projectOverrides = projectOverrides
        self.globalSettings = globalSettings
        self.settings = try Self.applying(
            projectOverrides: projectOverrides,
            to: globalSettings
        )
    }

    public func current() -> Settings { settings }

    public func modify(_ body: @Sendable (inout Settings) -> Void) throws {
        var effectiveCandidate = settings
        body(&effectiveCandidate)
        let globalCandidate = try Self.applyingChanges(
            from: settings,
            to: effectiveCandidate,
            global: globalSettings
        )
        try Self.write(globalCandidate, to: paths.globalSettings)
        globalSettings = globalCandidate
        settings = try Self.applying(
            projectOverrides: projectOverrides,
            to: globalCandidate
        )
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
        return try decode(mergeJSON(mergeJSON(defaults, global), project))
    }

    private static func applying(
        projectOverrides: [String: Any],
        to global: Settings
    ) throws -> Settings {
        try decode(mergeJSON(encodedObject(global), projectOverrides))
    }

    private static func decode(_ object: [String: Any]) throws -> Settings {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    private static func applyingChanges(
        from original: Settings,
        to modified: Settings,
        global: Settings
    ) throws -> Settings {
        let changes = try changedValues(
            from: encodedObject(original),
            to: encodedObject(modified)
        )
        return try decode(mergeJSON(encodedObject(global), changes))
    }

    private static func changedValues(
        from original: [String: Any],
        to modified: [String: Any]
    ) throws -> [String: Any] {
        var changes: [String: Any] = [:]
        for (key, modifiedValue) in modified {
            if let originalNested = original[key] as? [String: Any],
                let modifiedNested = modifiedValue as? [String: Any]
            {
                let nestedChanges = try changedValues(
                    from: originalNested,
                    to: modifiedNested
                )
                if !nestedChanges.isEmpty { changes[key] = nestedChanges }
            } else if try !jsonValuesEqual(original[key], modifiedValue) {
                changes[key] = modifiedValue
            }
        }
        return changes
    }

    private static func jsonValuesEqual(_ lhs: Any?, _ rhs: Any) throws -> Bool {
        guard let lhs else { return false }
        let left = try JSONSerialization.data(withJSONObject: [lhs], options: [.sortedKeys])
        let right = try JSONSerialization.data(withJSONObject: [rhs], options: [.sortedKeys])
        return left == right
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
        if let legacyFullscreenExit = result.removeValue(forKey: "fullscreenExit"),
            result["fullscreenExitOutput"] == nil
        {
            result["fullscreenExitOutput"] = legacyFullscreenExit
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
