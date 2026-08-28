import Foundation

public enum StoredCredential: Codable, Sendable, Equatable {
    case apiKey(key: String?, environment: [String: String]?)
    case oauth(access: String, refresh: String, expires: Int64, extras: [String: String])

    private enum CodingKeys: String, CodingKey { case type, key, env, access, refresh, expires }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "api_key":
            self = .apiKey(
                key: try container.decodeIfPresent(String.self, forKey: .key),
                environment: try container.decodeIfPresent([String: String].self, forKey: .env)
            )
        case "oauth":
            self = .oauth(
                access: try container.decode(String.self, forKey: .access),
                refresh: try container.decode(String.self, forKey: .refresh),
                expires: try container.decode(Int64.self, forKey: .expires),
                extras: [:]
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown credential type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .apiKey(let key, let environment):
            try container.encode("api_key", forKey: .type)
            try container.encodeIfPresent(key, forKey: .key)
            try container.encodeIfPresent(environment, forKey: .env)
        case .oauth(let access, let refresh, let expires, _):
            try container.encode("oauth", forKey: .type)
            try container.encode(access, forKey: .access)
            try container.encode(refresh, forKey: .refresh)
            try container.encode(expires, forKey: .expires)
        }
    }

    public var kind: String {
        switch self {
        case .apiKey: "api_key"
        case .oauth: "oauth"
        }
    }
}

public actor AuthStore {
    private let url: URL
    private var credentials: [String: StoredCredential]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            self.credentials = try JSONDecoder().decode([String: StoredCredential].self, from: Data(contentsOf: url))
        } else {
            self.credentials = [:]
        }
    }

    public func read(provider: String) -> StoredCredential? { credentials[provider] }

    public func list() -> [(provider: String, type: String)] {
        credentials.map { ($0.key, $0.value.kind) }.sorted { $0.provider < $1.provider }
    }

    public func set(provider: String, credential: StoredCredential) throws {
        credentials[provider] = credential
        try persist()
    }

    public func delete(provider: String) throws {
        credentials[provider] = nil
        try persist()
    }

    public func resolveAPIKey(provider: String, environment: [String: String], fallbackVariables: [String]) async throws
        -> String?
    {
        if let credential = credentials[provider] {
            switch credential {
            case .apiKey(let stored, let scoped):
                let merged = environment.merging(scoped ?? [:]) { _, storedValue in storedValue }
                if let stored { return try await Self.expand(stored, environment: merged) }
                for variable in fallbackVariables where merged[variable] != nil { return merged[variable] }
                return nil
            case .oauth(let access, _, let expires, _):
                if expires > Int64(Date().timeIntervalSince1970 * 1_000), !access.isEmpty {
                    return access
                }
            }
        }
        for variable in fallbackVariables where environment[variable] != nil { return environment[variable] }
        return nil
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(credentials)
        try withAdvisoryFileLock(url: url) {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        }
    }

    private static func expand(_ value: String, environment: [String: String]) async throws -> String {
        if value.hasPrefix("!") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-lc", String(value.dropFirst())]
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let sentinelDollar = "\u{0}DOLLAR\u{0}"
        let sentinelBang = "\u{0}BANG\u{0}"
        var expanded = value.replacingOccurrences(of: "$$", with: sentinelDollar)
            .replacingOccurrences(of: "$!", with: sentinelBang)
        let regex = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)"#)
        let full = NSRange(expanded.startIndex..<expanded.endIndex, in: expanded)
        for match in regex.matches(in: expanded, range: full).reversed() {
            let variableRange = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 2)
            guard let range = Range(variableRange, in: expanded), let fullRange = Range(match.range, in: expanded)
            else { continue }
            expanded.replaceSubrange(fullRange, with: environment[String(expanded[range])] ?? "")
        }
        return expanded.replacingOccurrences(of: sentinelDollar, with: "$")
            .replacingOccurrences(of: sentinelBang, with: "!")
    }
}
