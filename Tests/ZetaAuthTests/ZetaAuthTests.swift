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

private actor Counter {
    var value = 0
    func increment() { value += 1 }
}
