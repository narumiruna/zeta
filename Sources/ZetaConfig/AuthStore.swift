import Darwin
import Foundation

public enum StoredCredential: Codable, Sendable, Equatable {
    case apiKey(key: String?, environment: [String: String]?)
    case oauth(access: String, refresh: String, expires: Int64, extras: [String: String])

    private enum CodingKeys: String, CodingKey { case type, key, env, access, refresh, expires, extras }

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
                extras: try container.decodeIfPresent([String: String].self, forKey: .extras) ?? [:]
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
        case .oauth(let access, let refresh, let expires, let extras):
            try container.encode("oauth", forKey: .type)
            try container.encode(access, forKey: .access)
            try container.encode(refresh, forKey: .refresh)
            try container.encode(expires, forKey: .expires)
            try container.encode(extras, forKey: .extras)
        }
    }

    public var kind: String {
        switch self {
        case .apiKey: "api_key"
        case .oauth: "oauth"
        }
    }
}

public struct ResolvedStoredCredential: Sendable, Equatable {
    public var apiKey: String?
    public var bearerToken: String?
    public var environment: [String: String]

    public init(
        apiKey: String? = nil,
        bearerToken: String? = nil,
        environment: [String: String]
    ) {
        self.apiKey = apiKey
        self.bearerToken = bearerToken
        self.environment = environment
    }
}

public actor AuthStore {
    private let url: URL
    private let persistence: @Sendable ([String: StoredCredential], URL) throws -> Void
    private var credentials: [String: StoredCredential]

    public init(url: URL) throws {
        self.url = url
        self.persistence = { credentials, url in
            try Self.persist(credentials, to: url)
        }
        self.credentials = try Self.load(from: url)
    }

    init(
        url: URL,
        persistence: @escaping @Sendable ([String: StoredCredential], URL) throws -> Void
    ) throws {
        self.url = url
        self.persistence = persistence
        self.credentials = try Self.load(from: url)
    }

    public func read(provider: String) -> StoredCredential? { credentials[provider] }

    public func list() -> [(provider: String, type: String)] {
        credentials.map { ($0.key, $0.value.kind) }.sorted { $0.provider < $1.provider }
    }

    public func set(provider: String, credential: StoredCredential) throws {
        var candidate = credentials
        candidate[provider] = credential
        try persistence(candidate, url)
        credentials = candidate
    }

    public func delete(provider: String) throws {
        var candidate = credentials
        candidate[provider] = nil
        try persistence(candidate, url)
        credentials = candidate
    }

    public func resolveCredential(
        provider: String,
        environment: [String: String],
        fallbackVariables: [String],
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) async throws -> ResolvedStoredCredential {
        var resolvedEnvironment = environment
        if case .apiKey(_, let scoped)? = credentials[provider] {
            resolvedEnvironment.merge(scoped ?? [:]) { _, storedValue in storedValue }
        }

        if let credential = credentials[provider] {
            switch credential {
            case .apiKey(let stored, _):
                if let stored {
                    let value = try await Self.expand(stored, environment: resolvedEnvironment)
                    if Self.hasContent(value) {
                        return ResolvedStoredCredential(
                            apiKey: value,
                            environment: resolvedEnvironment
                        )
                    }
                }
            case .oauth(let access, _, let expires, _):
                if expires > nowMilliseconds, Self.hasContent(access) {
                    return ResolvedStoredCredential(
                        bearerToken: access,
                        environment: resolvedEnvironment
                    )
                }
            }
        }
        for variable in fallbackVariables {
            if let value = resolvedEnvironment[variable], Self.hasContent(value) {
                return ResolvedStoredCredential(
                    apiKey: value,
                    environment: resolvedEnvironment
                )
            }
        }
        return ResolvedStoredCredential(environment: resolvedEnvironment)
    }

    public func resolveAPIKey(provider: String, environment: [String: String], fallbackVariables: [String]) async throws
        -> String?
    {
        let resolved = try await resolveCredential(
            provider: provider,
            environment: environment,
            fallbackVariables: fallbackVariables
        )
        return resolved.apiKey ?? resolved.bearerToken
    }

    private static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func load(from url: URL) throws -> [String: StoredCredential] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try JSONDecoder().decode([String: StoredCredential].self, from: Data(contentsOf: url))
    }

    private static func persist(_ credentials: [String: StoredCredential], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(credentials)
        try withAdvisoryFileLock(url: url) {
            let temporaryURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try data.write(to: temporaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporaryURL.path
            )
            guard rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
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
            _ = setpgid(process.processIdentifier, process.processIdentifier)
            let data = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: CredentialHelperResult.self) { group in
                    group.addTask {
                        do {
                            var output = Data()
                            for try await byte in pipe.fileHandleForReading.bytes {
                                guard output.count < 1_048_576 else {
                                    throw CredentialHelperError.outputTooLarge
                                }
                                output.append(byte)
                            }
                            while process.isRunning {
                                try Task.checkCancellation()
                                try await Task.sleep(for: .milliseconds(10))
                            }
                            return .completed(output, process.terminationStatus)
                        } catch {
                            Self.terminateCredentialHelper(process, closing: pipe.fileHandleForReading)
                            throw error
                        }
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(30))
                        return .timedOut
                    }
                    guard let first = try await group.next() else {
                        throw CredentialHelperError.failed
                    }
                    group.cancelAll()
                    switch first {
                    case .completed(let output, let status):
                        guard status == 0 else { throw CredentialHelperError.failed }
                        return output
                    case .timedOut:
                        Self.terminateCredentialHelper(process, closing: pipe.fileHandleForReading)
                        throw CredentialHelperError.timedOut
                    }
                }
            } onCancel: {
                Self.terminateCredentialHelper(process, closing: pipe.fileHandleForReading)
            }
            return String(decoding: data, as: UTF8.self)
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

    private nonisolated static func terminateCredentialHelper(
        _ process: Process,
        closing handle: FileHandle? = nil
    ) {
        try? handle?.close()
        let identifier = process.processIdentifier
        guard identifier > 0 else { return }
        signalCredentialHelperTree(identifier, signal: SIGTERM)
        signalCredentialHelperTree(identifier, signal: SIGKILL)
    }

    private nonisolated static func signalCredentialHelperTree(_ identifier: pid_t, signal: Int32) {
        let descendants = credentialHelperDescendants(of: identifier)
        _ = kill(-identifier, signal)
        for child in descendants.reversed() { _ = kill(child, signal) }
        _ = kill(identifier, signal)
    }

    private nonisolated static func credentialHelperDescendants(of identifier: pid_t) -> [pid_t] {
        let count = proc_listchildpids(identifier, nil, 0)
        guard count > 0 else { return [] }
        var children = [pid_t](repeating: 0, count: Int(count))
        let actualCount = children.withUnsafeMutableBytes { buffer in
            proc_listchildpids(identifier, buffer.baseAddress, Int32(buffer.count))
        }
        guard actualCount > 0 else { return [] }
        children.removeSubrange(min(Int(actualCount), children.count)..<children.count)
        return children.filter { $0 > 0 }.flatMap { child in credentialHelperDescendants(of: child) + [child] }
    }
}

private enum CredentialHelperResult: Sendable {
    case completed(Data, Int32)
    case timedOut
}

private enum CredentialHelperError: Error, Sendable {
    case failed
    case timedOut
    case outputTooLarge
}
