import Foundation
import XCTest

@testable import ZetaPackages

final class ZetaPackagesTests: XCTestCase {
    func testSourceParsingAndPinning() throws {
        XCTAssertEqual(
            try PackageSource("npm:@scope/tools@1.2.3"),
            .npm(name: "@scope/tools", version: "1.2.3")
        )
        XCTAssertTrue(try PackageSource("github.com/user/repo@v1").pinned)
        XCTAssertFalse(try PackageSource("github.com/user/repo").pinned)
    }

    func testLocalGitInstallAndAtomicReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name":"test","pi":{"skills":["skills"]}}"#.utf8)
            .write(to: source.appendingPathComponent("package.json"))
        try runProcess("git", ["init", "-q"], at: source)
        try runProcess("git", ["add", "package.json"], at: source)
        try runProcess(
            "git",
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "-q", "-m", "initial",
            ],
            at: source
        )
        let manager = try ResourcePackageManager(root: installed)
        try await manager.install(.git(url: source.path, reference: nil))
        let firstList = await manager.list()
        XCTAssertEqual(firstList.count, 1)
        try await manager.install(.git(url: source.path, reference: nil))
        let secondList = await manager.list()
        XCTAssertEqual(secondList.count, 1)
    }

    func testTrustBlocksMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let manager = try ResourcePackageManager(root: root)
        do {
            try await manager.install(.git(url: "/tmp/missing", reference: nil), trusted: false)
            XCTFail("Expected trust error")
        } catch PackageManagerError.untrusted {}
    }

    func testInstallSubprocessDoesNotBlockActorAndCancelsCleanly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executableDirectory = root.appendingPathComponent("bin")
        let installed = root.appendingPathComponent("installed")
        let marker = root.appendingPathComponent("started")
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        let fakeGit = executableDirectory.appendingPathComponent("git")
        let script = "#!/bin/sh\ntouch '\(marker.path)'\nexec /bin/sleep 30\n"
        try Data(script.utf8).write(to: fakeGit)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeGit.path)
        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", "\(executableDirectory.path):\(originalPath ?? "")", 1)
        defer {
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
            }
        }

        let manager = try ResourcePackageManager(root: installed)
        let installTask = Task {
            try await manager.install(.git(url: "/unused", reference: nil))
        }
        defer { installTask.cancel() }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        let listCompleted = LockedFlag()
        let listTask = Task {
            _ = await manager.list()
            listCompleted.set()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(listCompleted.value)

        let cancellationStart = ContinuousClock.now
        installTask.cancel()
        do {
            try await installTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(ContinuousClock.now - cancellationStart, .seconds(2))
        _ = await listTask.value

        let packages = await manager.list()
        XCTAssertTrue(packages.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: installed.path)
        XCTAssertFalse(leftovers.contains(where: { $0.hasPrefix(".staging-") }))
    }

    func testExtensionBearingPackageIsRejectedWithoutPublication() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("source")
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"name":"legacy","pi":{"extensions":["index.ts"],"skills":["skills"]}}"#.utf8)
            .write(to: source.appendingPathComponent("package.json"))
        try runProcess("git", ["init", "-q"], at: source)
        try runProcess("git", ["add", "package.json"], at: source)
        try runProcess(
            "git",
            [
                "-c", "user.name=Test", "-c", "user.email=test@example.com",
                "commit", "-q", "-m", "legacy",
            ],
            at: source
        )
        let manager = try ResourcePackageManager(root: installed)
        do {
            try await manager.install(.git(url: source.path, reference: nil))
            XCTFail("Expected TypeScript extension rejection")
        } catch PackageManagerError.unsupportedExtensionPackage {}
        let packages = await manager.list()
        XCTAssertTrue(packages.isEmpty)
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var value: Bool { lock.withLock { completed } }

    func set() {
        lock.withLock { completed = true }
    }
}

private func runProcess(_ executable: String, _ arguments: [String], at directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
}
