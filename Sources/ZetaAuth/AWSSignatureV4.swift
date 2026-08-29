import CryptoKit
import Foundation

public struct AWSCredential: Sendable, Equatable {
    public var accessKeyID: String
    public var secretAccessKey: String
    public var sessionToken: String?
    package var authentication: AWSAuthentication

    public init(
        accessKeyID: String,
        secretAccessKey: String,
        sessionToken: String? = nil
    ) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        authentication = .signatureV4
    }

    package init(bearerToken: String) {
        accessKeyID = ""
        secretAccessKey = ""
        sessionToken = nil
        authentication = .bearer(token: bearerToken)
    }
}

package enum AWSAuthentication: Sendable, Equatable {
    case bearer(token: String)
    case signatureV4
}

public struct AWSSignedRequest: Sendable {
    public var request: URLRequest
    public var canonicalRequest: String
    public var stringToSign: String
    public var signature: String
}

public enum AWSSignatureError: Error, LocalizedError, Sendable {
    case invalidURL
    case missingHost

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "AWS request URL is invalid"
        case .missingHost:
            "AWS request host is missing"
        }
    }
}

public enum AWSSignatureV4 {
    public static func sign(
        request: URLRequest,
        body: Data,
        service: String,
        region: String,
        credential: AWSCredential,
        date: Date
    ) throws -> AWSSignedRequest {
        guard let url = request.url,
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw AWSSignatureError.invalidURL
        }
        guard let host = components.host else {
            throw AWSSignatureError.missingHost
        }
        let timestamp = awsTimestamp(date)
        let day = String(timestamp.prefix(8))
        var headers = request.allHTTPHeaderFields ?? [:]
        headers["host"] = host
        headers["x-amz-date"] = timestamp
        if let token = credential.sessionToken {
            headers["x-amz-security-token"] = token
        }
        let normalized = Dictionary(
            headers.map { ($0.key.lowercased(), normalize($0.value)) },
            uniquingKeysWith: { _, newest in newest }
        )
        let headerNames = normalized.keys.sorted()
        let canonicalHeaders =
            headerNames
            .map { "\($0):\(normalized[$0]!)\n" }
            .joined()
        let signedHeaders = headerNames.joined(separator: ";")
        components.percentEncodedQuery = canonicalQuery(components)
        let canonicalURI =
            components.percentEncodedPath.isEmpty
            ? "/" : awsEncodePath(components.percentEncodedPath)
        let payloadHash = sha256(body)
        let canonicalRequest = [
            request.httpMethod ?? "GET",
            canonicalURI,
            components.percentEncodedQuery ?? "",
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = [
            "AWS4-HMAC-SHA256",
            timestamp,
            scope,
            sha256(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")
        let dateKey = hmac(
            key: Data(("AWS4" + credential.secretAccessKey).utf8),
            data: Data(day.utf8)
        )
        let regionKey = hmac(key: dateKey, data: Data(region.utf8))
        let serviceKey = hmac(key: regionKey, data: Data(service.utf8))
        let signingKey = hmac(key: serviceKey, data: Data("aws4_request".utf8))
        let signature = hmac(
            key: signingKey,
            data: Data(stringToSign.utf8)
        ).hex
        var signed = request
        signed.setValue(timestamp, forHTTPHeaderField: "x-amz-date")
        signed.setValue(host, forHTTPHeaderField: "host")
        if let token = credential.sessionToken {
            signed.setValue(token, forHTTPHeaderField: "x-amz-security-token")
        }
        signed.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credential.accessKeyID)/\(scope), "
                + "SignedHeaders=\(signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization"
        )
        signed.httpBody = body
        return AWSSignedRequest(
            request: signed,
            canonicalRequest: canonicalRequest,
            stringToSign: stringToSign,
            signature: signature
        )
    }

    private static func awsTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func canonicalQuery(_ components: URLComponents) -> String {
        let encoded: [(String, String)] = (components.queryItems ?? []).map { item in
            (awsEncode(item.name), awsEncode(item.value ?? ""))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
        }
        return sorted.map { pair in
            pair.0 + "=" + pair.1
        }.joined(separator: "&")
    }

    private static func normalize(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func awsEncode(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
            )
        ) ?? ""
    }

    private static func awsEncodePath(_ percentEncodedPath: String) -> String {
        percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .map { awsEncodePathSegment($0) }
            .joined(separator: "/")
    }

    private static func awsEncodePathSegment(_ segment: Substring) -> String {
        let encoded = Array(segment.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(encoded.count)
        var index = 0
        while index < encoded.count {
            if encoded[index] == 0x25,
                index + 2 < encoded.count,
                let high = hexValue(encoded[index + 1]),
                let low = hexValue(encoded[index + 2])
            {
                decoded.append(high << 4 | low)
                index += 3
            } else {
                decoded.append(encoded[index])
                index += 1
            }
        }
        return decoded.map { byte in
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                String(UnicodeScalar(byte))
            default:
                String(format: "%%%02X", byte)
            }
        }.joined()
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).hex
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
}

private extension Data {
    var hex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
