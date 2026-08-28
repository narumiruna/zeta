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

    func testManifestRequiresIdentityAndExecutable() {
        XCTAssertThrowsError(try PluginManifest(name: "", version: "1", executable: "", capabilities: []).validate())
    }
}
