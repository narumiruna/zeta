import Darwin
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

    func testCancellingQueuedRequestRemovesWaiterWithoutStoppingHost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("queued.py")
        let source = #"""
            #!/usr/bin/env python3
            import base64,json,os,sys,time
            for line in sys.stdin:
                request=json.loads(line)
                method=request.get("method")
                if method == "slow":
                    open("slow-started", "w").close()
                    while not os.path.exists("release-slow"):
                        time.sleep(0.001)
                elif method != "initialize":
                    open(method + "-received", "w").close()
                value = b"[]" if method == "initialize" else method.encode()
                response={"id":request.get("id"),"type":"response","generation":request["generation"],"payload":base64.b64encode(value).decode()}
                print(json.dumps(response,separators=(',',':')),flush=True)
            """#
        try Data(source.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var configuration = PluginHost.Configuration()
        configuration.requestTimeout = .seconds(2)
        let host = PluginHost(configuration: configuration)
        try await host.start(
            manifest: PluginManifest(
                name: "queued",
                version: "1",
                executable: script.lastPathComponent,
                capabilities: []
            ),
            baseDirectory: directory,
            trusted: true
        )

        let active = Task { try await host.request(method: "slow") }
        try await waitUntil {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("slow-started").path)
        }
        let cancelled = Task { try await host.request(method: "cancelled") }
        try await waitUntilAsync { await host.queuedRequestCount == 1 }

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("Expected queued request cancellation")
        } catch is CancellationError {}
        let queuedCount = await host.queuedRequestCount
        XCTAssertEqual(queuedCount, 0)

        try Data().write(to: directory.appendingPathComponent("release-slow"))
        let activeResponse = try await active.value
        XCTAssertEqual(activeResponse, Data("slow".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled-received").path))
        let fastResponse = try await host.request(method: "fast")
        XCTAssertEqual(fastResponse, Data("fast".utf8))
        await host.stop()
    }

    func testPluginRequestTimeoutIncludesBlockedStdinWrite() async throws {
        let fixture = try makeBackpressuredPluginFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var configuration = PluginHost.Configuration()
        configuration.requestTimeout = .milliseconds(500)
        configuration.maximumRecordBytes = 8 * 1_024 * 1_024
        let host = PluginHost(configuration: configuration)
        try await host.start(manifest: fixture.manifest, baseDirectory: fixture.directory, trusted: true)

        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await host.request(
                method: "blocked",
                payload: Data(repeating: 0x61, count: 4 * 1_024 * 1_024)
            )
            XCTFail("Expected timeout")
        } catch PluginError.timedOut {}
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))

        let pid = try readPID(fixture.pidFile)
        try await waitUntil { !processExists(pid) }
    }

    func testCancellingBlockedPluginWriteTerminatesProcess() async throws {
        let fixture = try makeBackpressuredPluginFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var configuration = PluginHost.Configuration()
        configuration.requestTimeout = .seconds(10)
        configuration.maximumRecordBytes = 8 * 1_024 * 1_024
        let host = PluginHost(configuration: configuration)
        try await host.start(manifest: fixture.manifest, baseDirectory: fixture.directory, trusted: true)

        let request = Task {
            try await host.request(
                method: "blocked",
                payload: Data(repeating: 0x63, count: 4 * 1_024 * 1_024)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))

        let pid = try readPID(fixture.pidFile)
        try await waitUntil { !processExists(pid) }
    }

    func testStopCanTerminatePluginWithBlockedStdinWrite() async throws {
        let fixture = try makeBackpressuredPluginFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        var configuration = PluginHost.Configuration()
        configuration.requestTimeout = .seconds(10)
        configuration.maximumRecordBytes = 8 * 1_024 * 1_024
        let host = PluginHost(configuration: configuration)
        try await host.start(manifest: fixture.manifest, baseDirectory: fixture.directory, trusted: true)

        let request = Task {
            try await host.request(
                method: "blocked",
                payload: Data(repeating: 0x62, count: 4 * 1_024 * 1_024)
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        let clock = ContinuousClock()
        let start = clock.now
        await host.stop()
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
        request.cancel()
        _ = await request.result

        let pid = try readPID(fixture.pidFile)
        try await waitUntil { !processExists(pid) }
    }

    func testManifestRequiresIdentityAndExecutable() {
        XCTAssertThrowsError(try PluginManifest(name: "", version: "1", executable: "", capabilities: []).validate())
    }
}

private func makeBackpressuredPluginFixture() throws -> (
    directory: URL,
    manifest: PluginManifest,
    pidFile: URL
) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let script = directory.appendingPathComponent("blocked.py")
    let source = #"""
        #!/usr/bin/env python3
        import base64,json,os,sys,time
        open("plugin.pid", "w").write(str(os.getpid()))
        request=json.loads(sys.stdin.readline())
        response={"id":request.get("id"),"type":"response","generation":request["generation"],"payload":base64.b64encode(b"[]").decode()}
        print(json.dumps(response,separators=(',',':')),flush=True)
        open("initialized", "w").close()
        time.sleep(30)
        """#
    try Data(source.utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return (
        directory,
        PluginManifest(
            name: "blocked",
            version: "1",
            executable: script.lastPathComponent,
            capabilities: []
        ),
        directory.appendingPathComponent("plugin.pid")
    )
}

private func readPID(_ url: URL) throws -> pid_t {
    pid_t(
        try XCTUnwrap(
            Int32(String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )
    )
}

private func processExists(_ identifier: pid_t) -> Bool {
    kill(identifier, 0) == 0 || errno == EPERM
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

private func waitUntilAsync(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            throw PluginTestError.timedOutWaitingForCondition
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum PluginTestError: Error {
    case timedOutWaitingForCondition
}
