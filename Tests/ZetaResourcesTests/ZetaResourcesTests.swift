import XCTest

@testable import ZetaResources

final class ZetaResourcesTests: XCTestCase {
    func testTrustGatesProjectResourcesAndDiagnosesTypeScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let cwd = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(
            at: cwd.appendingPathComponent(".pi/extensions"), withIntermediateDirectories: true)
        try Data("export default {}".utf8).write(to: cwd.appendingPathComponent(".pi/extensions/test.ts"))
        let denied = ResourceLoader(home: home, workingDirectory: cwd, trusted: false).load()
        XCTAssertTrue(denied.unsupportedExtensions.isEmpty)
        let allowed = ResourceLoader(home: home, workingDirectory: cwd, trusted: true).load()
        XCTAssertEqual(allowed.unsupportedExtensions.count, 1)
        XCTAssertTrue(allowed.diagnostics[0].message.contains("ZetaPluginSDK"))
    }

    func testContextOverrideWinsWithinDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("normal".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        try Data("override".utf8).write(to: root.appendingPathComponent("AGENTS.override.md"))
        let loaded = ResourceLoader(home: root.appendingPathComponent("home"), workingDirectory: root, trusted: true)
            .load()
        XCTAssertTrue(loaded.context.contains("override"))
        XCTAssertFalse(loaded.context.contains("normal"))
    }
}
