import Foundation

public struct ResolvedAuthentication: Sendable, Equatable {
    public var apiKey: String?
    public var bearerToken: String?
    public var headers: [String: String]
    public var source: String

    public init(
        apiKey: String? = nil,
        bearerToken: String? = nil,
        headers: [String: String] = [:],
        source: String
    ) {
        self.apiKey = apiKey
        self.bearerToken = bearerToken
        self.headers = headers
        self.source = source
    }
}

public enum CredentialResolverError: Error, LocalizedError, Sendable {
    case invalidTokenResponse
    case unsupportedServiceAccount

    public var errorDescription: String? {
        switch self {
        case .invalidTokenResponse:
            "Google OAuth token exchange returned an invalid response"
        case .unsupportedServiceAccount:
            "Google service-account token exchange is unavailable without a pre-issued access token"
        }
    }
}

public enum CredentialResolver {
    public static func apiKey(
        explicit: String?,
        stored: String?,
        environment: [String: String],
        variables: [String]
    ) -> ResolvedAuthentication? {
        if let explicit, !explicit.isEmpty {
            return ResolvedAuthentication(apiKey: explicit, source: "explicit")
        }
        if let stored, !stored.isEmpty {
            return ResolvedAuthentication(apiKey: stored, source: "stored")
        }
        for variable in variables {
            if let value = environment[variable], !value.isEmpty {
                return ResolvedAuthentication(apiKey: value, source: variable)
            }
        }
        return nil
    }

    public static func vertex(
        explicitAPIKey: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ResolvedAuthentication? {
        if let result = apiKey(
            explicit: explicitAPIKey,
            stored: nil,
            environment: environment,
            variables: ["GOOGLE_CLOUD_API_KEY"]
        ) {
            return result
        }
        let credentialPath =
            environment["GOOGLE_APPLICATION_CREDENTIALS"]
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".config/gcloud/application_default_credentials.json"
            ).path
        guard FileManager.default.fileExists(atPath: credentialPath) else {
            return nil
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: credentialPath))
        let object = try JSONDecoder().decode(GoogleCredentialFile.self, from: data)
        if let token = object.accessToken, !token.isEmpty {
            return ResolvedAuthentication(
                bearerToken: token,
                source: credentialPath
            )
        }
        if let refresh = object.refreshToken, !refresh.isEmpty {
            return ResolvedAuthentication(
                headers: [
                    "x-zeta-google-refresh-token": refresh,
                    "x-zeta-google-client-id": object.clientID ?? "",
                    "x-zeta-google-client-secret": object.clientSecret ?? "",
                ],
                source: credentialPath
            )
        }
        if let email = object.clientEmail,
            let key = object.privateKey,
            !email.isEmpty,
            !key.isEmpty
        {
            return ResolvedAuthentication(
                headers: [
                    "x-zeta-google-client-email": email,
                    "x-zeta-google-private-key": key,
                ],
                source: credentialPath
            )
        }
        return nil
    }

    public static func vertexAccessAuthentication(
        explicitAPIKey: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        session: URLSession = .shared
    ) async throws -> ResolvedAuthentication? {
        guard
            let authentication = try vertex(
                explicitAPIKey: explicitAPIKey,
                environment: environment
            )
        else {
            return nil
        }
        if authentication.apiKey != nil || authentication.bearerToken != nil {
            return authentication
        }
        guard let refreshToken = authentication.headers["x-zeta-google-refresh-token"],
            let clientID = authentication.headers["x-zeta-google-client-id"],
            let clientSecret = authentication.headers["x-zeta-google-client-secret"]
        else {
            throw CredentialResolverError.unsupportedServiceAccount
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formEncoded([
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
            200..<300 ~= http.statusCode,
            let token = try JSONDecoder().decode(GoogleTokenResponse.self, from: data).accessToken,
            !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CredentialResolverError.invalidTokenResponse
        }
        return ResolvedAuthentication(
            bearerToken: token,
            source: authentication.source
        )
    }

    public static func aws(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AWSCredential? {
        if let bearer = environment["AWS_BEARER_TOKEN_BEDROCK"],
            !bearer.isEmpty
        {
            return AWSCredential(bearerToken: bearer)
        }
        guard let access = environment["AWS_ACCESS_KEY_ID"],
            let secret = environment["AWS_SECRET_ACCESS_KEY"],
            !access.isEmpty,
            !secret.isEmpty
        else {
            return nil
        }
        return AWSCredential(
            accessKeyID: access,
            secretAccessKey: secret,
            sessionToken: environment["AWS_SESSION_TOKEN"]
        )
    }
    private static func formEncoded(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        let body = values.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = values[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}

private struct GoogleTokenResponse: Decodable {
    var accessToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}

private struct GoogleCredentialFile: Decodable {
    var accessToken: String?
    var refreshToken: String?
    var clientID: String?
    var clientSecret: String?
    var clientEmail: String?
    var privateKey: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case clientEmail = "client_email"
        case privateKey = "private_key"
    }
}
