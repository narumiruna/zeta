import Foundation
import XCTest
import ZetaCore

@testable import ZetaAI

final class AuthenticationRegressionTests: XCTestCase {
    func testAnthropicRequestPreservesAPIKeyAndBearerCredentialKinds() async throws {
        let model = Model(
            id: "claude-test",
            name: "Claude",
            api: "anthropic-messages",
            provider: "anthropic",
            baseURL: URL(string: "https://api.anthropic.com")!,
            contextWindow: 1_000,
            maximumTokens: 100
        )
        let provider = HTTPProvider(
            configuration: ProviderConfiguration(
                id: model.provider,
                api: model.api,
                baseURL: model.baseURL,
                models: [model],
                apiKeyEnvironmentVariables: []
            )
        )

        let apiKeyRequest = try await provider.buildRequest(
            model: model,
            context: Context(),
            apiKey: "synthetic-api-key",
            options: StreamOptions()
        )
        XCTAssertEqual(
            apiKeyRequest.value(forHTTPHeaderField: "x-api-key"),
            "synthetic-api-key"
        )
        XCTAssertNil(apiKeyRequest.value(forHTTPHeaderField: "Authorization"))

        let oauthRequest = try await provider.buildRequest(
            model: model,
            context: Context(),
            bearerToken: "synthetic-oauth-token",
            options: StreamOptions()
        )
        XCTAssertEqual(
            oauthRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer synthetic-oauth-token"
        )
        XCTAssertNil(oauthRequest.value(forHTTPHeaderField: "x-api-key"))
    }
}
