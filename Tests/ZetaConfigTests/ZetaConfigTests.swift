import Darwin
import XCTest

@testable import ZetaConfig

final class ZetaConfigTests: XCTestCase {
    func testNestedProjectSettingsOverrideWithoutReplacingSiblings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let global = directory.appendingPathComponent("global.json")
        let project = directory.appendingPathComponent("project.json")
        try Data(
            #"{"transport":"sse","retry":{"enabled":true,"maxRetries":3,"baseDelayMs":2000,"maxRetryDelayMs":60000}}"#
                .utf8
        ).write(to: global)
        try Data(#"{"retry":{"enabled":false}}"#.utf8).write(to: project)
        let result = try SettingsStore.loadMerged(globalURL: global, projectURL: project)
        XCTAssertEqual(result.transport, .sse)
        XCTAssertFalse(result.retry.enabled)
        XCTAssertEqual(result.retry.maxRetries, 3)
    }

    func testLegacySettingsAndParentTrustMigrate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let global = directory.appendingPathComponent("settings.json")
        try Data(
            #"{"queueMode":"all","websockets":true,"retry":{"maxDelayMs":1234}}"#.utf8
        ).write(to: global)
        let settings = try SettingsStore.loadMerged(globalURL: global, projectURL: nil)
        XCTAssertEqual(settings.steeringMode, .all)
        XCTAssertEqual(settings.transport, .websocket)
        XCTAssertEqual(settings.retry.maxRetryDelayMs, 1_234)

        let trust = try TrustStore(url: directory.appendingPathComponent("trust.json"))
        let parent = directory.appendingPathComponent("projects")
        try await trust.set(.trusted, for: parent)
        let decision = await trust.decision(for: parent.appendingPathComponent("child"))
        XCTAssertEqual(decision, .trusted)
        let stored =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: directory.appendingPathComponent("trust.json"))
            ) as? [String: Bool]
        XCTAssertEqual(stored?[parent.path], true)
    }

    func testFailedSettingsModificationDoesNotPublishCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blockedAgentDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blockedAgentDirectory)
        let paths = ZetaPaths(
            home: directory,
            workingDirectory: directory,
            environment: ["PI_CODING_AGENT_DIR": blockedAgentDirectory.path]
        )
        let store = try SettingsStore(paths: paths, includeProject: false)

        do {
            try await store.modify { $0.theme = "rejected" }
            XCTFail("Expected persistence failure")
        } catch {}

        let current = await store.current()
        XCTAssertEqual(current.theme, "dark")
        XCTAssertEqual(try String(contentsOf: blockedAgentDirectory, encoding: .utf8), "blocker")
    }

    func testOAuthExtrasRoundTripThroughDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("auth.json")
        let credential = StoredCredential.oauth(
            access: "access",
            refresh: "refresh",
            expires: 123,
            extras: ["accountId": "account", "region": "test"]
        )
        let store = try AuthStore(url: url)
        try await store.set(provider: "provider", credential: credential)

        let reopened = try AuthStore(url: url)
        let stored = await reopened.read(provider: "provider")
        XCTAssertEqual(stored, credential)
    }

    func testCredentialResolutionRejectsExpiredAndEmptyContent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AuthStore(url: directory.appendingPathComponent("auth.json"))
        try await store.set(
            provider: "oauth",
            credential: .oauth(
                access: "expired-access",
                refresh: "refresh",
                expires: 99,
                extras: [:]
            )
        )
        let expired = try await store.resolveCredential(
            provider: "oauth",
            environment: [:],
            fallbackVariables: [],
            nowMilliseconds: 100
        )
        XCTAssertNil(expired.apiKey)
        XCTAssertNil(expired.bearerToken)

        try await store.set(
            provider: "oauth",
            credential: .oauth(
                access: "   \n",
                refresh: "refresh",
                expires: 101,
                extras: [:]
            )
        )
        let blank = try await store.resolveCredential(
            provider: "oauth",
            environment: [:],
            fallbackVariables: [],
            nowMilliseconds: 100
        )
        XCTAssertNil(blank.bearerToken)

        let fallback = try await store.resolveCredential(
            provider: "oauth",
            environment: ["OAUTH_KEY": "environment-key"],
            fallbackVariables: ["OAUTH_KEY"],
            nowMilliseconds: 100
        )
        XCTAssertEqual(fallback.apiKey, "environment-key")
        XCTAssertNil(fallback.bearerToken)

        let laterFallback = try await store.resolveCredential(
            provider: "oauth",
            environment: [
                "EMPTY_KEY": " \t\n",
                "VALID_KEY": "later-environment-key",
            ],
            fallbackVariables: ["EMPTY_KEY", "MISSING_KEY", "VALID_KEY"],
            nowMilliseconds: 100
        )
        XCTAssertEqual(laterFallback.apiKey, "later-environment-key")

        try await store.set(
            provider: "empty",
            credential: .apiKey(key: "", environment: ["EMPTY_KEY": ""])
        )
        let empty = try await store.resolveCredential(
            provider: "empty",
            environment: [:],
            fallbackVariables: ["EMPTY_KEY"]
        )
        XCTAssertNil(empty.apiKey)
        XCTAssertNil(empty.bearerToken)
    }

    func testCredentialHelperDrainsLargeOutputWithoutDeadlock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try AuthStore(url: directory.appendingPathComponent("auth.json"))
        try await store.set(
            provider: "helper",
            credential: .apiKey(
                key: "!awk 'BEGIN { for (i=0; i<200000; i++) printf \"x\" }'",
                environment: nil
            )
        )

        let credential = try await store.resolveAPIKey(
            provider: "helper",
            environment: [:],
            fallbackVariables: []
        )

        XCTAssertEqual(credential?.count, 200_000)
        XCTAssertEqual(credential?.first, "x")
        XCTAssertEqual(credential?.last, "x")
    }

    func testOversizedCredentialHelperOutputTerminatesProcessTree() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let parentFile = directory.appendingPathComponent("helper-parent.pid")
        let childFile = directory.appendingPathComponent("helper-child.pid")
        let store = try AuthStore(url: directory.appendingPathComponent("auth.json"))
        let command = """
            !/bin/sleep 30 & child=$!; echo $$ > '\(parentFile.path)'; echo $child > '\(childFile.path)'; /usr/bin/awk 'BEGIN { for (i=0; i<1100000; i++) printf "x" }'; wait
            """
        try await store.set(
            provider: "helper",
            credential: .apiKey(key: command, environment: nil)
        )

        do {
            _ = try await store.resolveAPIKey(
                provider: "helper",
                environment: [:],
                fallbackVariables: []
            )
            XCTFail("Expected oversized helper output to fail")
        } catch {}

        let parent = try readProcessID(parentFile)
        let child = try readProcessID(childFile)
        try await waitForCondition {
            !processIsRunning(parent) && !processIsRunning(child)
        }
    }

    func testCredentialKindsDoNotExposeSecretsInList() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try AuthStore(url: directory.appendingPathComponent("auth.json"))
        try await store.set(provider: "openai", credential: .apiKey(key: "secret", environment: nil))
        let listed = await store.list()
        XCTAssertEqual(listed.map(\.provider), ["openai"])
        XCTAssertEqual(listed.map(\.type), ["api_key"])
        XCTAssertFalse(String(describing: listed).contains("secret"))

        try await store.set(
            provider: "openai-codex",
            credential: .oauth(
                access: "oauth-access",
                refresh: "refresh",
                expires: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
                extras: [:]
            )
        )
        let access = try await store.resolveAPIKey(
            provider: "openai-codex",
            environment: [:],
            fallbackVariables: []
        )
        XCTAssertEqual(access, "oauth-access")
    }
}

private func readProcessID(_ url: URL) throws -> pid_t {
    pid_t(
        try XCTUnwrap(
            Int32(String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )
    )
}

private func processIsRunning(_ identifier: pid_t) -> Bool {
    kill(identifier, 0) == 0 || errno == EPERM
}

private func waitForCondition(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else { throw ConfigTestError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum ConfigTestError: Error {
    case timedOut
}
