import CryptoKit
import Foundation

public struct OAuthCredential: Codable, Sendable, Equatable {
    public var access: String
    public var refresh: String
    public var expires: Int64
    public var extra: [String: String]

    public init(
        access: String,
        refresh: String,
        expires: Int64,
        extra: [String: String] = [:]
    ) {
        self.access = access
        self.refresh = refresh
        self.expires = expires
        self.extra = extra
    }

    public func requiresRefresh(
        nowMilliseconds: Int64,
        minimumValidityMilliseconds: Int64 = 60_000
    ) -> Bool {
        expires <= nowMilliseconds + minimumValidityMilliseconds
    }
}

public struct PKCEChallenge: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String) throws {
        guard (43...128).contains(verifier.count),
            verifier.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || "-._~".contains($0))
            })
        else {
            throw OAuthError.invalidVerifier
        }
        self.verifier = verifier
        let digest = SHA256.hash(data: Data(verifier.utf8))
        challenge = Data(digest).base64URLEncodedString()
    }

    public static func random() throws -> PKCEChallenge {
        var bytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
        else {
            throw OAuthError.randomFailure
        }
        return try PKCEChallenge(
            verifier: Data(bytes).base64URLEncodedString()
        )
    }
}

public struct DeviceAuthorization: Codable, Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: URL
    public var expiresIn: Int
    public var interval: Int

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        expiresIn: Int,
        interval: Int = 5
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

public enum DeviceTokenPollResult: Sendable, Equatable {
    case pending
    case slowDown
    case authorized(OAuthCredential)
    case denied(String)
}

public enum OAuthError: Error, LocalizedError, Sendable {
    case invalidVerifier
    case randomFailure
    case expired
    case denied(String)
    case invalidCallback

    public var errorDescription: String? {
        switch self {
        case .invalidVerifier:
            "PKCE verifier is invalid"
        case .randomFailure:
            "Secure random generation failed"
        case .expired:
            "OAuth authorization expired"
        case .denied(let reason):
            "OAuth authorization was denied: \(reason)"
        case .invalidCallback:
            "OAuth callback is invalid"
        }
    }
}

public actor DeviceAuthorizationPoller {
    public typealias Poll = @Sendable (String) async throws -> DeviceTokenPollResult

    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.sleep = sleep
    }

    public func poll(
        authorization: DeviceAuthorization,
        operation: Poll
    ) async throws -> OAuthCredential {
        let deadline = ContinuousClock.now + .seconds(authorization.expiresIn)
        var interval = max(1, authorization.interval)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            switch try await operation(authorization.deviceCode) {
            case .pending:
                break
            case .slowDown:
                interval += 5
            case .authorized(let credential):
                return credential
            case .denied(let reason):
                throw OAuthError.denied(reason)
            }
            try await sleep(.seconds(interval))
        }
        throw OAuthError.expired
    }
}

public actor SerializedCredentialRefresh {
    private var tasks: [String: Task<OAuthCredential, Error>] = [:]

    public init() {}

    public func refresh(
        provider: String,
        operation: @escaping @Sendable () async throws -> OAuthCredential
    ) async throws -> OAuthCredential {
        if let existing = tasks[provider] {
            return try await existing.value
        }
        let task = Task { try await operation() }
        tasks[provider] = task
        do {
            let value = try await task.value
            tasks[provider] = nil
            return value
        } catch {
            tasks[provider] = nil
            throw error
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
