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

    func testReplacementRestoresPreviousPackageWhenIndexPersistenceFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let installed = root.appendingPathComponent("installed")
        try createGitPackage(at: source, marker: "old")
        let packageSource = PackageSource.git(url: source.path, reference: nil)
        let manager = try ResourcePackageManager(root: installed)
        try await manager.install(packageSource)
        let originalList = await manager.list()
        let packageDirectory = try XCTUnwrap(originalList.first?.directory)
        let destination = installed.appendingPathComponent(packageDirectory)
        let originalPackage = try snapshot(directory: destination)
        let index = installed.appendingPathComponent("packages.json")
        let originalIndex = try Data(contentsOf: index)

        try Data("new".utf8).write(to: source.appendingPathComponent("marker.txt"))
        try commitAll(in: source, message: "update")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: index.path) }

        do {
            try await manager.install(packageSource)
            XCTFail("Expected index persistence to fail")
        } catch PackageInternalError.rollbackFailed(let message) {
            XCTFail("Expected rollback to succeed, got \(message)")
        } catch {}

        let restoredList = await manager.list()
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        XCTAssertEqual(try snapshot(directory: destination), originalPackage)
        XCTAssertEqual(restoredList, originalList)
        try assertNoTransactionDirectories(in: installed)
    }

    func testRemoveRestoresPackageWhenIndexPersistenceFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let installed = root.appendingPathComponent("installed")
        try createGitPackage(at: source, marker: "installed")
        let manager = try ResourcePackageManager(root: installed)
        let packageSource = PackageSource.git(url: source.path, reference: nil)
        try await manager.install(packageSource)
        let originalList = await manager.list()
        let packageDirectory = try XCTUnwrap(originalList.first?.directory)
        let destination = installed.appendingPathComponent(packageDirectory)
        let originalPackage = try snapshot(directory: destination)
        let index = installed.appendingPathComponent("packages.json")
        let originalIndex = try Data(contentsOf: index)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: index.path) }

        do {
            try await manager.remove(packageSource.identifier)
            XCTFail("Expected index persistence to fail")
        } catch PackageInternalError.rollbackFailed(let message) {
            XCTFail("Expected rollback to succeed, got \(message)")
        } catch {}

        let restoredList = await manager.list()
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        XCTAssertEqual(try snapshot(directory: destination), originalPackage)
        XCTAssertEqual(restoredList, originalList)
        try assertNoTransactionDirectories(in: installed)
    }

    func testUpdateRestoresPreviousPackageWhenIndexPersistenceFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let executableDirectory = root.appendingPathComponent("bin")
        let installed = root.appendingPathComponent("installed")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try writePackage(at: source, marker: "old")
        let fakeGit = executableDirectory.appendingPathComponent("git")
        let script = """
            #!/bin/sh
            for argument in "$@"; do destination="$argument"; done
            mkdir -p "$destination"
            cp -R '\(source.path)/.' "$destination/"
            """
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

        let packageSource = PackageSource.git(url: "https://example.invalid/resource", reference: nil)
        let manager = try ResourcePackageManager(root: installed)
        try await manager.install(packageSource)
        let originalList = await manager.list()
        let packageDirectory = try XCTUnwrap(originalList.first?.directory)
        let destination = installed.appendingPathComponent(packageDirectory)
        let originalPackage = try snapshot(directory: destination)
        let index = installed.appendingPathComponent("packages.json")
        let originalIndex = try Data(contentsOf: index)
        try writePackage(at: source, marker: "new")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: index.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: index.path) }

        do {
            try await manager.updateAll()
            XCTFail("Expected index persistence to fail")
        } catch PackageInternalError.rollbackFailed(let message) {
            XCTFail("Expected rollback to succeed, got \(message)")
        } catch {}

        let restoredList = await manager.list()
        XCTAssertEqual(try Data(contentsOf: index), originalIndex)
        XCTAssertEqual(try snapshot(directory: destination), originalPackage)
        XCTAssertEqual(restoredList, originalList)
        try assertNoTransactionDirectories(in: installed)
    }

    func testRemoveRejectsUnsafeRegistryDirectoryBeforeFilesystemMutation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let staticVariants = [
            "", ".", "..", "../outside", "../../outside", "nested/package",
            #"nested\package"#, #"..\outside"#,
        ]

        for (offset, staticValue) in staticVariants.enumerated() {
            try await assertUnsafeRegistryDirectory(staticValue, caseNumber: offset, base: base)
        }
        let absoluteCaseRoot = base.appendingPathComponent("case-\(staticVariants.count)")
        let absoluteOutside = absoluteCaseRoot.appendingPathComponent("outside")
        try await assertUnsafeRegistryDirectory(
            absoluteOutside.path,
            caseNumber: staticVariants.count,
            base: base
        )
    }

    func testInstallRejectsResourcePathTraversalVariantsWithoutPublication() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("marker.txt")
        try Data("outside".utf8).write(to: marker)
        let variants = [
            "../outside", "nested/../../outside", outside.path,
            #"..\outside"#,
        ]

        for (offset, path) in variants.enumerated() {
            let source = base.appendingPathComponent("source-\(offset)")
            let installed = base.appendingPathComponent("installed-\(offset)")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let manifest = try JSONSerialization.data(
                withJSONObject: ["name": "test", "pi": ["skills": [path]]],
                options: [.sortedKeys]
            )
            try manifest.write(to: source.appendingPathComponent("package.json"))
            try runProcess("git", ["init", "-q"], at: source)
            try commitAll(in: source, message: "unsafe")
            let manager = try ResourcePackageManager(root: installed)

            do {
                try await manager.install(.git(url: source.path, reference: nil))
                XCTFail("Expected unsafe resource path \(path.debugDescription) to be rejected")
            } catch PackageManagerError.unsafeArchive {
            } catch {
                XCTFail("Expected unsafe archive error, got \(error)")
            }

            let packages = await manager.list()
            XCTAssertTrue(packages.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: installed.path), [])
            XCTAssertEqual(try Data(contentsOf: marker), Data("outside".utf8))
        }
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

private func createGitPackage(at directory: URL, marker: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writePackage(at: directory, marker: marker)
    try runProcess("git", ["init", "-q"], at: directory)
    try commitAll(in: directory, message: "initial")
}

private func writePackage(at directory: URL, marker: String) throws {
    try Data(#"{"name":"test","pi":{"skills":[]}}"#.utf8)
        .write(to: directory.appendingPathComponent("package.json"))
    try Data(marker.utf8).write(to: directory.appendingPathComponent("marker.txt"))
}

private func commitAll(in directory: URL, message: String) throws {
    try runProcess("git", ["add", "."], at: directory)
    try runProcess(
        "git",
        [
            "-c", "user.name=Test", "-c", "user.email=test@example.com",
            "commit", "-q", "-m", message,
        ],
        at: directory
    )
}

private func snapshot(directory: URL) throws -> [String: Data] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else {
        return [:]
    }
    var result: [String: Data] = [:]
    let prefix = directory.path + "/"
    for case let url as URL in enumerator {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            continue
        }
        result[String(url.path.dropFirst(prefix.count))] = try Data(contentsOf: url)
    }
    return result
}

private func assertNoTransactionDirectories(in root: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
    XCTAssertFalse(entries.contains { $0.hasPrefix(".backup-") || $0.hasPrefix(".staging-") })
}

private func assertUnsafeRegistryDirectory(
    _ directory: String,
    caseNumber: Int,
    base: URL
) async throws {
    let caseRoot = base.appendingPathComponent("case-\(caseNumber)")
    let packages = caseRoot.appendingPathComponent("packages")
    let outside = caseRoot.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: packages, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let marker = outside.appendingPathComponent("marker.txt")
    try Data("outside".utf8).write(to: marker)
    let identifier = "npm:test"
    let records = [
        identifier: InstalledPackage(
            source: identifier,
            directory: directory,
            pinned: false,
            installedAt: "2026-01-01T00:00:00Z"
        )
    ]
    let index = packages.appendingPathComponent("packages.json")
    let indexData = try JSONEncoder().encode(records)
    try indexData.write(to: index)
    let manager = try ResourcePackageManager(root: packages)

    do {
        try await manager.remove(identifier)
        XCTFail("Expected unsafe registry directory \(directory.debugDescription) to be rejected")
    } catch PackageInternalError.unsafeRegistryDirectory(let rejected) {
        XCTAssertEqual(rejected, directory)
    } catch {
        XCTFail("Expected unsafe registry directory error, got \(error)")
    }

    XCTAssertEqual(try Data(contentsOf: marker), Data("outside".utf8))
    XCTAssertEqual(try Data(contentsOf: index), indexData)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: packages.path), ["packages.json"])
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
