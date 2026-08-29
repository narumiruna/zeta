import CryptoKit
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
        await Task.yield()
        _ = try await URLSession.shared.data(from: components.url!)
        let callbackValue = try await callback.value
        XCTAssertEqual(
            callbackValue,
            OAuthCallback(code: "code", state: "state")
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
