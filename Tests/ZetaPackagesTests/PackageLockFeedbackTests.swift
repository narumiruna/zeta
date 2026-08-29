import Darwin
import XCTest

@testable import ZetaPackages

final class PackageLockFeedbackTests: XCTestCase {
    func testRegistryLockWaitDoesNotBlockActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let installed = root.appendingPathComponent("installed")
        try createGitPackage(at: source)
        let manager = try ResourcePackageManager(root: installed)
        let descriptor = open(
            installed.appendingPathComponent(".packages.lock").path,
            O_CREAT | O_RDWR,
            0o600
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        let installTask = Task {
            try await manager.install(.git(url: source.path, reference: nil))
        }
        var prepared = false
        for _ in 0..<200 {
            prepared = try preparedStagingDirectoryExists(in: installed)
            if prepared { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(prepared)
        try await Task.sleep(for: .milliseconds(50))

        let listCompleted = PackageLockFlag()
        let listTask = Task {
            _ = await manager.list()
            listCompleted.set()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(listCompleted.value)

        flock(descriptor, LOCK_UN)
        try await installTask.value
        _ = await listTask.value
    }

    private func preparedStagingDirectoryExists(in root: URL) throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".staging-") }
            .contains { staging in
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(staging)
                        .appendingPathComponent("package.json").path
                )
            }
    }

    private func createGitPackage(at directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data(#"{"name":"test","pi":{"skills":[]}}"#.utf8).write(
            to: directory.appendingPathComponent("package.json")
        )
        try runGit(["init", "-q"], at: directory)
        try runGit(["add", "package.json"], at: directory)
        try runGit(
            [
                "-c", "user.name=Test",
                "-c", "user.email=test@example.com",
                "commit", "-q", "-m", "initial",
            ],
            at: directory
        )
    }

    private func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private final class PackageLockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool { lock.withLock { storedValue } }
    func set() { lock.withLock { storedValue = true } }
}
