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

    func testSSHSourceParsingKeepsUserInfoAndSplitsPathReferences() throws {
        XCTAssertEqual(
            try PackageSource("ssh://git@example.com/owner/repository"),
            .git(url: "ssh://git@example.com/owner/repository", reference: nil)
        )
        XCTAssertEqual(
            try PackageSource("ssh://git@example.com/owner/repository@release/v1"),
            .git(
                url: "ssh://git@example.com/owner/repository",
                reference: "release/v1"
            )
        )
        XCTAssertEqual(
            try PackageSource("git@example.com:owner/repository"),
            .git(url: "git@example.com:owner/repository", reference: nil)
        )
        XCTAssertEqual(
            try PackageSource("git@example.com:owner/repository@v1.2.3"),
            .git(url: "git@example.com:owner/repository", reference: "v1.2.3")
        )
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

    func testCollidingLegacyNamesUseDistinctDirectoriesAndRemoveIndependently() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dashedSource = root.appendingPathComponent("source-name")
        let underscoredSource = root.appendingPathComponent("source_name")
        let installed = root.appendingPathComponent("installed")
        try createGitPackage(at: dashedSource, marker: "dashed")
        try createGitPackage(at: underscoredSource, marker: "underscored")
        let dashed = PackageSource.git(url: dashedSource.path, reference: nil)
        let underscored = PackageSource.git(url: underscoredSource.path, reference: nil)
        let manager = try ResourcePackageManager(root: installed)

        try await manager.install(dashed)
        try await manager.install(underscored)

        let packages = await manager.list()
        XCTAssertEqual(packages.count, 2)
        XCTAssertEqual(Set(packages.map(\.directory)).count, 2)
        let underscoredRecord = try XCTUnwrap(
            packages.first { $0.source == underscored.identifier }
        )
        let underscoredDirectory = installed.appendingPathComponent(
            underscoredRecord.directory
        )
        try await manager.remove(dashed.identifier)

        let remaining = await manager.list()
        XCTAssertEqual(remaining.map(\.source), [underscored.identifier])
        XCTAssertEqual(
            try Data(contentsOf: underscoredDirectory.appendingPathComponent("marker.txt")),
            Data("underscored".utf8)
        )
    }

    func testExistingRegistryDirectoryIsReusedDuringMigrationCompatibleUpdate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let installed = root.appendingPathComponent("installed")
        let legacyDirectory = installed.appendingPathComponent("legacy-directory")
        try createGitPackage(at: source, marker: "new")
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        try writePackage(at: legacyDirectory, marker: "old")
        let packageSource = PackageSource.git(url: source.path, reference: nil)
        let record = InstalledPackage(
            source: packageSource.identifier,
            directory: legacyDirectory.lastPathComponent,
            pinned: false,
            installedAt: "2026-01-01T00:00:00Z"
        )
        try JSONEncoder().encode([packageSource.identifier: record]).write(
            to: installed.appendingPathComponent("packages.json")
        )
        let manager = try ResourcePackageManager(root: installed)

        try await manager.install(packageSource)

        let updated = await manager.list()
        XCTAssertEqual(updated.first?.directory, "legacy-directory")
        XCTAssertEqual(
            try Data(contentsOf: legacyDirectory.appendingPathComponent("marker.txt")),
            Data("new".utf8)
        )
    }

    func testDuplicateRegistryDirectoryIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = InstalledPackage(
            source: "npm:first",
            directory: "shared",
            pinned: false,
            installedAt: "2026-01-01T00:00:00Z"
        )
        let second = InstalledPackage(
            source: "npm:second",
            directory: "SHARED",
            pinned: false,
            installedAt: "2026-01-01T00:00:00Z"
        )
        try JSONEncoder().encode([first.source: first, second.source: second]).write(
            to: root.appendingPathComponent("packages.json")
        )

        XCTAssertThrowsError(try ResourcePackageManager(root: root)) { error in
            guard case PackageInternalError.duplicateRegistryDirectory = error else {
                return XCTFail("Expected duplicate registry directory, got \(error)")
            }
        }
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

    func testNPMArchiveDownloadRejectsCompressedSizeLimitWithoutPublication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        NPMArchiveURLProtocol.configure(
            archiveStatus: 200,
            archiveChunks: [Data(repeating: 0x61, count: 40), Data(repeating: 0x62, count: 40)]
        )
        let session = npmTestSession()
        let manager = try ResourcePackageManager(
            root: root,
            session: session,
            maximumCompressedArchiveBytes: 64
        )

        do {
            try await manager.install(.npm(name: "test", version: nil))
            XCTFail("Expected compressed archive size rejection")
        } catch PackageManagerError.unsafeArchive {
        } catch {
            XCTFail("Expected unsafe archive error, got \(error)")
        }

        let installed = await manager.list()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testNPMArchiveDownloadPreservesHTTPStatusAndCleanup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        NPMArchiveURLProtocol.configure(
            archiveStatus: 503,
            archiveChunks: [Data("unavailable".utf8)]
        )
        let manager = try ResourcePackageManager(
            root: root,
            session: npmTestSession(),
            maximumCompressedArchiveBytes: 64
        )

        do {
            try await manager.install(.npm(name: "test", version: nil))
            XCTFail("Expected status rejection")
        } catch PackageManagerError.invalidSource(let source) {
            XCTAssertEqual(source, "npm:test")
        } catch {
            XCTFail("Expected invalid source error, got \(error)")
        }

        let installed = await manager.list()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testNPMArchiveDownloadCancellationCleansPartialFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        NPMArchiveURLProtocol.configure(
            archiveStatus: 200,
            archiveChunks: (0..<200).map { _ in Data(repeating: 0x61, count: 1_024) },
            delayMicroseconds: 10_000
        )
        let manager = try ResourcePackageManager(
            root: root,
            session: npmTestSession(),
            maximumCompressedArchiveBytes: 1_000_000
        )
        let task = Task {
            try await manager.install(.npm(name: "test", version: nil))
        }
        defer { task.cancel() }
        for _ in 0..<200 where !NPMArchiveURLProtocol.archiveStarted {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(NPMArchiveURLProtocol.archiveStarted)

        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let installed = await manager.list()
        XCTAssertTrue(installed.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
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

private func npmTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [NPMArchiveURLProtocol.self]
    return URLSession(configuration: configuration)
}

private final class NPMArchiveURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Script: Sendable {
        var archiveStatus: Int
        var archiveChunks: [Data]
        var delayMicroseconds: useconds_t
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var script = Script(archiveStatus: 200, archiveChunks: [], delayMicroseconds: 0)
        var archiveStarted = false
    }

    private static let storage = Storage()
    private let stopLock = NSLock()
    private var stopped = false

    static var archiveStarted: Bool {
        storage.lock.withLock { storage.archiveStarted }
    }

    static func configure(
        archiveStatus: Int,
        archiveChunks: [Data],
        delayMicroseconds: useconds_t = 0
    ) {
        storage.lock.withLock {
            storage.script = Script(
                archiveStatus: archiveStatus,
                archiveChunks: archiveChunks,
                delayMicroseconds: delayMicroseconds
            )
            storage.archiveStarted = false
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }
        let script = Self.storage.lock.withLock { Self.storage.script }
        let isArchive = url.host == "packages.test"
        let status = isArchive ? script.archiveStatus : 200
        let chunks = isArchive ? script.archiveChunks : [Self.metadata]
        if isArchive {
            Self.storage.lock.withLock { Self.storage.archiveStarted = true }
        }
        guard
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/octet-stream"]
            )
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            guard !stopLock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didLoad: chunk)
            if script.delayMicroseconds > 0 { usleep(script.delayMicroseconds) }
        }
        guard !stopLock.withLock({ stopped }) else { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopLock.withLock { stopped = true }
    }

    private static let metadata = Data(
        #"{"versions":{"1.0.0":{"dist":{"tarball":"https://packages.test/archive.tgz"}}},"dist-tags":{"latest":"1.0.0"}}"#
            .utf8
    )
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
