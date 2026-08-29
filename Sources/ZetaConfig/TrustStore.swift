import Darwin
import Foundation

public enum TrustDecision: String, Codable, Sendable {
    case trusted
    case denied
}

public actor TrustStore {
    private static let blockingQueue = DispatchQueue(
        label: "works.earendil.zeta.trust.blocking",
        attributes: .concurrent
    )

    private let url: URL
    private var decisions: [String: TrustDecision]
    private var mutationActive = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(url: URL) throws {
        self.url = url
        decisions = try Self.load(url)
    }

    public func decision(for directory: URL) -> TrustDecision? {
        var current = directory.standardizedFileURL
        while current.path != "/" {
            if let decision = decisions[current.path] { return decision }
            current.deleteLastPathComponent()
        }
        return decisions["/"]
    }

    public func set(_ decision: TrustDecision, for directory: URL) async throws {
        await beginMutation()
        defer { endMutation() }
        let path = directory.standardizedFileURL.path
        let url = url
        decisions = try await Self.performBlocking {
            try Self.persist(decision, for: path, to: url)
        }
    }

    private func beginMutation() async {
        if !mutationActive {
            mutationActive = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func endMutation() {
        guard !mutationWaiters.isEmpty else {
            mutationActive = false
            return
        }
        mutationWaiters.removeFirst().resume()
    }

    private nonisolated static func performBlocking<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private nonisolated static func persist(
        _ decision: TrustDecision,
        for path: String,
        to url: URL
    ) throws -> [String: TrustDecision] {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try withAdvisoryFileLock(url: url) {
            var candidate = try load(url)
            candidate[path] = decision
            let values = candidate.mapValues { $0 == .trusted }
            let data = try JSONSerialization.data(
                withJSONObject: values,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return candidate
        }
    }

    private static func load(_ url: URL) throws -> [String: TrustDecision] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let values = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        return values.reduce(into: [:]) { result, pair in
            if let value = pair.value as? Bool {
                result[pair.key] = value ? .trusted : .denied
            } else if let value = pair.value as? String,
                let decision = TrustDecision(rawValue: value)
            {
                result[pair.key] = decision
            }
        }
    }
}

public func withAdvisoryFileLock<Result>(
    url: URL,
    operation: () throws -> Result
) throws -> Result {
    let lockURL = url.appendingPathExtension("lock")
    let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
}
