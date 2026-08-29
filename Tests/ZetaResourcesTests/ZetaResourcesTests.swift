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

    func testLoadsOnlyValidatedRegisteredGlobalAndTrustedProjectPackages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let agent = home.appendingPathComponent(".pi/agent")
        let cwd = root.appendingPathComponent("project")
        let globalPackages = agent.appendingPathComponent("packages")
        let globalPackage = globalPackages.appendingPathComponent("global-package")
        try FileManager.default.createDirectory(
            at: globalPackage.appendingPathComponent("assets"),
            withIntermediateDirectories: true
        )
        try Data("global prompt".utf8).write(
            to: globalPackage.appendingPathComponent("assets/global.md")
        )
        try Data(
            #"{"name":"global","pi":{"prompts":["assets/global.md"]}}"#.utf8
        ).write(to: globalPackage.appendingPathComponent("package.json"))
        let externalPackage = root.appendingPathComponent("external-package")
        try FileManager.default.createDirectory(at: externalPackage, withIntermediateDirectories: true)
        try Data(#"{"name":"external","pi":{"prompts":[]}}"#.utf8).write(
            to: externalPackage.appendingPathComponent("package.json")
        )
        try FileManager.default.createSymbolicLink(
            at: globalPackages.appendingPathComponent("linked-package"),
            withDestinationURL: externalPackage
        )
        try Data(
            #"{"global":{"directory":"global-package"},"escape":{"directory":"../escape"},"linked":{"directory":"linked-package"}}"#
                .utf8
        ).write(to: globalPackages.appendingPathComponent("packages.json"))

        let projectPackages = cwd.appendingPathComponent(".pi/packages")
        let projectPackage = projectPackages.appendingPathComponent("project-package")
        try FileManager.default.createDirectory(
            at: projectPackage.appendingPathComponent("skill"),
            withIntermediateDirectories: true
        )
        try Data("---\nname: packaged\ndescription: packaged skill\n---\nbody".utf8).write(
            to: projectPackage.appendingPathComponent("skill/SKILL.md")
        )
        try Data(
            #"{"name":"project","pi":{"skills":["skill"]}}"#.utf8
        ).write(to: projectPackage.appendingPathComponent("package.json"))
        try Data(
            #"{"project":{"directory":"project-package"}}"#.utf8
        ).write(to: projectPackages.appendingPathComponent("packages.json"))

        let denied = ResourceLoader(
            home: home,
            workingDirectory: cwd,
            agentDirectory: agent,
            trusted: false
        ).load()
        XCTAssertEqual(denied.prompts.map(\.name), ["global"])
        XCTAssertTrue(denied.skills.isEmpty)
        XCTAssertTrue(denied.diagnostics.contains { $0.message.contains("unsafe registry directory") })
        XCTAssertTrue(denied.diagnostics.contains { $0.message.contains("unsafe symbolic link") })

        let allowed = ResourceLoader(
            home: home,
            workingDirectory: cwd,
            agentDirectory: agent,
            trusted: true
        ).load()
        XCTAssertEqual(allowed.prompts.map(\.name), ["global"])
        XCTAssertEqual(allowed.skills.map(\.name), ["packaged"])
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
