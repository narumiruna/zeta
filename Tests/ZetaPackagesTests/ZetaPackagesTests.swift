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
