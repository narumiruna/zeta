import XCTest

@testable import ZetaPluginAPI

final class ZetaPluginAPITests: XCTestCase {
    func testManifestRejectsUnknownVersion() {
        let value = PluginManifest(
            name: "test", version: "1", protocolVersion: 2, executable: "plugin", capabilities: [])
        XCTAssertThrowsError(try value.validate()) { error in
            XCTAssertEqual(error as? PluginError, .unsupportedProtocol(2))
        }
    }

    func testHostTrustTransactionalRegistrationAndCrashIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("plugin.py")
        let source = #"""
            #!/usr/bin/env python3
            import base64,json,sys
            for line in sys.stdin:
                request=json.loads(line)
                registrations=[{"kind":"tool","name":"echo","callback":"tool.echo"}]
                payload=base64.b64encode(json.dumps(registrations,separators=(',',':')).encode()).decode()
                response={"id":request.get("id"),"type":"response","generation":request["generation"],"payload":payload}
                print(json.dumps(response,separators=(',',':')),flush=True)
            """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        let manifest = PluginManifest(
            name: "test",
            version: "1",
            executable: script.lastPathComponent,
            capabilities: [.tools]
        )
        let host = PluginHost()
        do {
            try await host.start(
                manifest: manifest,
                baseDirectory: directory,
                trusted: false
            )
            XCTFail("Expected trust failure")
        } catch PluginError.untrusted {}
        try await host.start(
            manifest: manifest,
            baseDirectory: directory,
            trusted: true
        )
        let registrations = await host.registrations
        XCTAssertEqual(registrations.count, 1)
        await host.stop()
        let stoppedRegistrations = await host.registrations
        XCTAssertTrue(stoppedRegistrations.isEmpty)
    }

    func testSilentPluginTimesOutAndCleansUp() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("silent.sh")
        try Data("#!/bin/sh\nread line\nsleep 5\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var configuration = PluginHost.Configuration()
        configuration.requestTimeout = .milliseconds(20)
        let host = PluginHost(configuration: configuration)
        do {
            try await host.start(
                manifest: PluginManifest(
                    name: "silent",
                    version: "1",
                    executable: script.lastPathComponent,
                    capabilities: []
                ),
                baseDirectory: directory,
                trusted: true
            )
            XCTFail("Expected timeout")
        } catch PluginError.timedOut {}
        let registrations = await host.currentRegistrations()
        XCTAssertTrue(registrations.isEmpty)
    }

    func testTimedOutRequestInvalidatesHostBeforeQueuedRequest() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("delayed.py")
        let source = #"""
            #!/usr/bin/env python3
            import base64,json,sys,time
            for line in sys.stdin:
                request=json.loads(line)
                method=request.get("method")
                if method == "slow":
                    open("slow-started", "w").close()
                    time.sleep(1.5)
                value = b"[]" if method == "initialize" else method.encode()
                response={"id":request.get("id"),"type":"response","generation":request["generation"],"payload":base64.b64encode(value).decode()}
                print(json.dumps(response,separators=(',',':')),flush=True)
            """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        let manifest = PluginManifest(
            name: "delayed",
            version: "1",
            executable: script.lastPathComponent,
            capabilities: []
        )
        var configuration = PluginHost.Configuration()
        configuration.requestTimeout = .seconds(1)
        let host = PluginHost(configuration: configuration)
        try await host.start(manifest: manifest, baseDirectory: directory, trusted: true)

        let first = Task { try await host.request(method: "slow") }
        let marker = directory.appendingPathComponent("slow-started").path
        try await waitUntil { FileManager.default.fileExists(atPath: marker) }
        let second = Task { try await host.request(method: "fast") }

        do {
            _ = try await first.value
            XCTFail("Expected first request to time out")
        } catch {
            XCTAssertEqual(error as? PluginError, .timedOut)
        }
        do {
            _ = try await second.value
            XCTFail("Expected queued request to observe the invalidated host")
        } catch {
            guard let pluginError = error as? PluginError,
                case .crashed = pluginError
            else {
                return XCTFail("Expected crashed host, got \(error)")
            }
        }

        try await host.start(manifest: manifest, baseDirectory: directory, trusted: true)
        let restartedResponse = try await host.request(method: "fast")
        XCTAssertEqual(restartedResponse, Data("fast".utf8))
        await host.stop()
    }

    func testManifestRequiresIdentityAndExecutable() {
        XCTAssertThrowsError(try PluginManifest(name: "", version: "1", executable: "", capabilities: []).validate())
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
        guard clock.now < deadline else {
            throw PluginTestError.timedOutWaitingForCondition
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum PluginTestError: Error {
    case timedOutWaitingForCondition
}
