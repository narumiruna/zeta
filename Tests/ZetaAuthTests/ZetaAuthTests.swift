import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import ZetaAuth

final class ZetaAuthTests: XCTestCase {
    func testPinnedPKCEVector() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = try PKCEChallenge(verifier: verifier)
        XCTAssertEqual(
            challenge.challenge,
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testSerializedRefreshSharesOneOperation() async throws {
        let refresher = SerializedCredentialRefresh()
        let counter = Counter()
        let first = Task {
            try await refresher.refresh(provider: "test") {
                await counter.increment()
                try await Task.sleep(for: .milliseconds(20))
                return OAuthCredential(access: "a", refresh: "r", expires: 1)
            }
        }
        while await counter.value == 0 { await Task.yield() }
        let second = Task {
            try await refresher.refresh(provider: "test") {
                await counter.increment()
                return OAuthCredential(access: "b", refresh: "r", expires: 1)
            }
        }
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, secondValue)
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testCredentialResolutionAndOAuthCallback() async throws {
        XCTAssertEqual(
            CredentialResolver.apiKey(
                explicit: "explicit",
                stored: "stored",
                environment: ["KEY": "environment"],
                variables: ["KEY"]
            )?.source,
            "explicit"
        )
        let laterEnvironmentKey = CredentialResolver.apiKey(
            explicit: " \n",
            stored: "\t",
            environment: [
                "EMPTY_KEY": "  ",
                "VALID_KEY": "environment",
            ],
            variables: ["EMPTY_KEY", "VALID_KEY"]
        )
        XCTAssertEqual(laterEnvironmentKey?.apiKey, "environment")
        XCTAssertEqual(laterEnvironmentKey?.source, "VALID_KEY")
        XCTAssertEqual(
            CredentialResolver.aws(environment: [
                "AWS_ACCESS_KEY_ID": "access",
                "AWS_SECRET_ACCESS_KEY": "secret",
                "AWS_SESSION_TOKEN": "session",
            ]),
            AWSCredential(
                accessKeyID: "access",
                secretAccessKey: "secret",
                sessionToken: "session"
            )
        )
        XCTAssertEqual(
            CredentialResolver.aws(environment: [
                "AWS_BEARER_TOKEN_BEDROCK": "bedrock-token",
                "AWS_ACCESS_KEY_ID": "ignored-access",
                "AWS_SECRET_ACCESS_KEY": "ignored-secret",
            ])?.authentication,
            .bearer(token: "bedrock-token")
        )
        XCTAssertEqual(
            CredentialResolver.aws(environment: [
                "AWS_BEARER_TOKEN_BEDROCK": " \n",
                "AWS_ACCESS_KEY_ID": "access",
                "AWS_SECRET_ACCESS_KEY": "secret",
            ])?.authentication,
            .signatureV4
        )

        let server = OAuthCallbackServer(expectedState: "state")
        var components = URLComponents(
            url: try await server.start(),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "code", value: "code"),
            URLQueryItem(name: "state", value: "state"),
        ]
        let callback = Task { try await server.waitForCallback() }
        try await waitUntil { server.isWaitingForCallback }
        _ = try await URLSession.shared.data(from: components.url!)
        let callbackValue = try await callback.value
        XCTAssertEqual(
            callbackValue,
            OAuthCallback(code: "code", state: "state")
        )
    }

    func testInvalidOAuthCallbackReturnsBadRequestAndKeepsWaiting() async throws {
        let server = OAuthCallbackServer(expectedState: "valid-state")
        let callbackURL = try await server.start()
        let callback = Task { try await server.waitForCallback() }
        try await waitUntil { server.isWaitingForCallback }

        var invalid = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
        invalid.queryItems = [
            URLQueryItem(name: "code", value: "wrong-code"),
            URLQueryItem(name: "state", value: "wrong-state"),
        ]
        let (_, invalidResponse) = try await URLSession.shared.data(from: invalid.url!)
        XCTAssertEqual((invalidResponse as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(server.isWaitingForCallback)

        var valid = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
        valid.queryItems = [
            URLQueryItem(name: "code", value: "valid-code"),
            URLQueryItem(name: "state", value: "valid-state"),
        ]
        let (_, validResponse) = try await URLSession.shared.data(from: valid.url!)
        XCTAssertEqual((validResponse as? HTTPURLResponse)?.statusCode, 200)
        let value = try await callback.value
        XCTAssertEqual(value, OAuthCallback(code: "valid-code", state: "valid-state"))
    }

    func testFragmentedOAuthRequestLineWaitsForLineEnding() async throws {
        let server = OAuthCallbackServer(expectedState: "fragment-state")
        let callbackURL = try await server.start()
        let callback = Task { try await server.waitForCallback() }
        defer {
            callback.cancel()
            server.stop()
        }
        try await waitUntil { server.isWaitingForCallback }
        let port = try XCTUnwrap(callbackURL.port)

        let response = try await fragmentedHTTPRequest(
            port: UInt16(port),
            fragments: [
                Data("GET /callback?code=frag".utf8),
                Data("mented&state=fragment-state HTTP/1.1\r".utf8),
                Data("\nHost: 127.0.0.1\r\n\r\n".utf8),
            ]
        )

        XCTAssertTrue(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 200 OK"))
        let value = try await callback.value
        XCTAssertEqual(value, OAuthCallback(code: "fragmented", state: "fragment-state"))
    }

    func testOAuthCallbackRejectsRequestLineAtBufferLimit() async throws {
        let server = OAuthCallbackServer(expectedState: "limit-state")
        let callbackURL = try await server.start()
        let callback = Task { try await server.waitForCallback() }
        defer {
            callback.cancel()
            server.stop()
        }
        try await waitUntil { server.isWaitingForCallback }
        let port = try XCTUnwrap(callbackURL.port)
        let prefix = Data("GET /callback?code=oversized&state=limit-state&padding=".utf8)
        let suffix = Data(" HTTP/1.1\n".utf8)
        var oversized = prefix
        oversized.append(Data(repeating: 0x61, count: 16 * 1_024 - prefix.count - suffix.count))
        oversized.append(suffix)

        let rejected = try await fragmentedHTTPRequest(port: UInt16(port), fragments: [oversized])
        XCTAssertTrue(String(decoding: rejected, as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request"))
        XCTAssertTrue(server.isWaitingForCallback)

        var valid = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
        valid.queryItems = [
            URLQueryItem(name: "code", value: "within-limit"),
            URLQueryItem(name: "state", value: "limit-state"),
        ]
        let (_, response) = try await URLSession.shared.data(from: valid.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let value = try await callback.value
        XCTAssertEqual(value, OAuthCallback(code: "within-limit", state: "limit-state"))
    }

    func testOAuthCallbackCompletedBeforeWaiterIsPreserved() async throws {
        let server = OAuthCallbackServer(expectedState: "early-state")
        var components = URLComponents(
            url: try await server.start(),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "code", value: "early-code"),
            URLQueryItem(name: "state", value: "early-state"),
        ]

        _ = try await URLSession.shared.data(from: components.url!)

        let callback = try await server.waitForCallback()
        XCTAssertEqual(
            callback,
            OAuthCallback(code: "early-code", state: "early-state")
        )
    }

    func testVertexResolutionDistinguishesAPIKeyAndADCBearer() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let credentialFile = directory.appendingPathComponent("adc.json")
        try Data(#"{"access_token":"adc-access"}"#.utf8).write(to: credentialFile)
        let environment = [
            "GOOGLE_APPLICATION_CREDENTIALS": credentialFile.path,
            "GOOGLE_CLOUD_API_KEY": "environment-key",
        ]

        let apiKey = try CredentialResolver.vertex(
            explicitAPIKey: "explicit-key",
            environment: environment
        )
        XCTAssertEqual(apiKey?.apiKey, "explicit-key")
        XCTAssertNil(apiKey?.bearerToken)

        let bearer = try CredentialResolver.vertex(
            explicitAPIKey: nil,
            environment: ["GOOGLE_APPLICATION_CREDENTIALS": credentialFile.path]
        )
        XCTAssertNil(bearer?.apiKey)
        XCTAssertEqual(bearer?.bearerToken, "adc-access")
    }

    func testVertexRefreshCredentialExchangesForBearerToken() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let credentialFile = directory.appendingPathComponent("adc.json")
        try Data(
            #"{"refresh_token":"refresh","client_id":"client","client_secret":"secret"}"#.utf8
        ).write(to: credentialFile)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VertexTokenURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let authentication = try await CredentialResolver.vertexAccessAuthentication(
            explicitAPIKey: nil,
            environment: ["GOOGLE_APPLICATION_CREDENTIALS": credentialFile.path],
            session: session
        )

        XCTAssertEqual(authentication?.bearerToken, "refreshed-access")
        XCTAssertNil(authentication?.apiKey)
        let requestBody = String(
            decoding: try XCTUnwrap(VertexTokenURLProtocol.requestBody),
            as: UTF8.self
        )
        XCTAssertTrue(requestBody.contains("grant_type=refresh_token"))
        XCTAssertTrue(requestBody.contains("refresh_token=refresh"))
    }

    func testAWSSigningPreservesEncodedBedrockModelSeparator() throws {
        var request = URLRequest(
            url: URL(
                string:
                    "https://bedrock.example.com/runtime/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A123%3Amodel%2Fprofile/converse-stream"
            )!
        )
        request.httpMethod = "POST"
        let signed = try AWSSignatureV4.sign(
            request: request,
            body: Data("{}".utf8),
            service: "bedrock",
            region: "us-east-1",
            credential: AWSCredential(
                accessKeyID: "access",
                secretAccessKey: "secret"
            ),
            date: ISO8601DateFormatter().date(from: "2024-01-02T03:04:05Z")!
        )
        let canonicalURI = signed.canonicalRequest.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )[1]

        XCTAssertEqual(
            canonicalURI,
            "/runtime/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A123%3Amodel%2Fprofile/converse-stream"
        )
        XCTAssertFalse(canonicalURI.contains("%252F"))
        XCTAssertEqual(
            signed.signature,
            "4bdc45cde52ccf671f04d994c458cc39f20cc30458bc25eb54c9e6685cd2887a"
        )
    }

    func testAWSCanonicalPathNormalizesPercentEncodingExactlyOnce() throws {
        var request = URLRequest(
            url: URL(string: "https://example.com/a%2fb/%7e/%252F/a%20b")!
        )
        request.httpMethod = "GET"
        let signed = try AWSSignatureV4.sign(
            request: request,
            body: Data(),
            service: "execute-api",
            region: "us-east-1",
            credential: AWSCredential(
                accessKeyID: "access",
                secretAccessKey: "secret"
            ),
            date: Date(timeIntervalSince1970: 0)
        )
        let canonicalURI = signed.canonicalRequest.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )[1]

        XCTAssertEqual(canonicalURI, "/a%2Fb/~/%252F/a%20b")
    }

    func testAWSSigningIsDeterministic() throws {
        var request = URLRequest(
            url: URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!
        )
        request.httpMethod = "GET"
        let formatter = ISO8601DateFormatter()
        let signed = try AWSSignatureV4.sign(
            request: request,
            body: Data(),
            service: "iam",
            region: "us-east-1",
            credential: AWSCredential(
                accessKeyID: "AKIDEXAMPLE",
                secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
            ),
            date: formatter.date(from: "2015-08-30T12:36:00Z")!
        )
        XCTAssertEqual(signed.signature.count, 64)
        XCTAssertTrue(signed.canonicalRequest.contains("Action=ListUsers&Version=2010-05-08"))
        XCTAssertNotNil(signed.request.value(forHTTPHeaderField: "Authorization"))
    }
}

private enum OAuthSocketError: Error {
    case systemCall(String, Int32)
}

private func fragmentedHTTPRequest(port: UInt16, fragments: [Data]) async throws -> Data {
    try await Task.detached {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw OAuthSocketError.systemCall("socket", errno) }
        defer { Darwin.close(descriptor) }
        var noSignal: Int32 = 1
        guard
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
                == 0
        else {
            throw OAuthSocketError.systemCall("setsockopt", errno)
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            throw OAuthSocketError.systemCall("inet_pton", errno)
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw OAuthSocketError.systemCall("connect", errno) }

        for (index, fragment) in fragments.enumerated() {
            guard try writeAll(fragment, to: descriptor) else { break }
            if index < fragments.count - 1 { usleep(50_000) }
        }
        _ = shutdown(descriptor, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return response }
            if count < 0 {
                if errno == EINTR { continue }
                throw OAuthSocketError.systemCall("read", errno)
            }
            response.append(buffer, count: count)
        }
    }.value
}

private func writeAll(_ data: Data, to descriptor: Int32) throws -> Bool {
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EPIPE || errno == ECONNRESET { return false }
                throw OAuthSocketError.systemCall("write", errno)
            }
            offset += count
        }
        return true
    }
}

private func waitUntil(
    timeout: Duration = .seconds(1),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            XCTFail("Timed out waiting for callback state")
            return
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private final class VertexTokenURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = request.httpBody {
            Self.requestBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var bytes = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(bytes, count: count)
            }
            Self.requestBody = body
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"access_token":"refreshed-access"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
