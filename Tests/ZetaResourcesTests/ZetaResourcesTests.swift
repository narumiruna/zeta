import Darwin
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

    func testFIFOResourcesAndPackageNodesAreRejectedWithoutBlocking() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let agent = home.appendingPathComponent(".pi/agent")
        let packages = agent.appendingPathComponent("packages")
        let package = packages.appendingPathComponent("unsafe-package")
        let workingDirectory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try Data(#"{"name":"unsafe","pi":{"prompts":[]}}"#.utf8).write(
            to: package.appendingPathComponent("package.json")
        )
        XCTAssertEqual(mkfifo(package.appendingPathComponent("blocked.md").path, 0o600), 0)
        XCTAssertEqual(mkfifo(agent.appendingPathComponent("AGENTS.md").path, 0o600), 0)
        try Data(#"{"unsafe":{"directory":"unsafe-package"}}"#.utf8).write(
            to: packages.appendingPathComponent("packages.json")
        )
        let start = ContinuousClock.now

        let snapshot = ResourceLoader(
            home: home,
            workingDirectory: workingDirectory,
            agentDirectory: agent,
            trusted: false
        ).load()

        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        XCTAssertTrue(snapshot.context.isEmpty)
        XCTAssertTrue(snapshot.prompts.isEmpty)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.message.contains("unsafe symbolic link or file type") })
    }

    func testCRLFAndLFFrontmatterPreserveResourceBodies() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let agent = home.appendingPathComponent(".pi/agent")
        let prompts = agent.appendingPathComponent("prompts")
        let skills = agent.appendingPathComponent("skills")
        let workingDirectory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: skills.appendingPathComponent("crlf"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: skills.appendingPathComponent("lf"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let crlfPrompt = "---\r\ndescription: CRLF prompt\r\n---\r\nfirst\r\nsecond\r\n"
        let lfPrompt = "---\ndescription: LF prompt\n---\nfirst\nsecond\n"
        let crlfSkill = "---\r\nname: crlf-skill\r\ndescription: CRLF skill\r\n---\r\nalpha\r\nbeta\r\n"
        let lfSkill = "---\nname: lf-skill\ndescription: LF skill\n---\nalpha\nbeta\n"
        try Data(crlfPrompt.utf8).write(to: prompts.appendingPathComponent("crlf.md"))
        try Data(lfPrompt.utf8).write(to: prompts.appendingPathComponent("lf.md"))
        try Data(crlfSkill.utf8).write(to: skills.appendingPathComponent("crlf/SKILL.md"))
        try Data(lfSkill.utf8).write(to: skills.appendingPathComponent("lf/SKILL.md"))

        let snapshot = ResourceLoader(
            home: home,
            workingDirectory: workingDirectory,
            agentDirectory: agent,
            trusted: false
        ).load()
        let loadedPrompts = Dictionary(uniqueKeysWithValues: snapshot.prompts.map { ($0.name, $0) })
        let loadedSkills = Dictionary(uniqueKeysWithValues: snapshot.skills.map { ($0.name, $0) })

        XCTAssertEqual(loadedPrompts["crlf"]?.description, "CRLF prompt")
        XCTAssertEqual(loadedPrompts["crlf"]?.body, "first\r\nsecond\r\n")
        XCTAssertEqual(loadedPrompts["lf"]?.description, "LF prompt")
        XCTAssertEqual(loadedPrompts["lf"]?.body, "first\nsecond\n")
        XCTAssertEqual(loadedSkills["crlf-skill"]?.description, "CRLF skill")
        XCTAssertEqual(loadedSkills["crlf-skill"]?.body, "alpha\r\nbeta\r\n")
        XCTAssertEqual(loadedSkills["lf-skill"]?.description, "LF skill")
        XCTAssertEqual(loadedSkills["lf-skill"]?.body, "alpha\nbeta\n")
        XCTAssertTrue(snapshot.diagnostics.isEmpty)
    }

    func testContextLoadingRejectsOversizedSparseFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let oversized = agent.appendingPathComponent("AGENTS.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data("ignored".utf8)))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(maximumContextFileBytes + 1))
        try handle.close()
        try Data("project context".utf8).write(to: project.appendingPathComponent("AGENTS.md"))

        let snapshot = ResourceLoader(
            home: root,
            workingDirectory: project,
            agentDirectory: agent,
            trusted: false
        ).load()

        XCTAssertEqual(snapshot.context, ["project context"])
    }

    func testContextBudgetPrioritizesDeepestFilesAndPreservesPresentationOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let agent = root.appendingPathComponent("agent")
        let project = root.appendingPathComponent("project")
        let first = project.appendingPathComponent("first")
        let second = first.appendingPathComponent("second")
        let workingDirectory = second.appendingPathComponent("working")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        func writeFullContext(_ label: String, to directory: URL) throws {
            let padding = String(
                repeating: "x",
                count: maximumContextFileBytes - label.utf8.count
            )
            try Data((label + padding).utf8).write(
                to: directory.appendingPathComponent("AGENTS.md")
            )
        }
        try writeFullContext("global", to: agent)
        try writeFullContext("project", to: project)
        try writeFullContext("first", to: first)
        try writeFullContext("second", to: second)
        try Data("working context".utf8).write(
            to: workingDirectory.appendingPathComponent("AGENTS.md")
        )

        let snapshot = ResourceLoader(
            home: root,
            workingDirectory: workingDirectory,
            agentDirectory: agent,
            trusted: false
        ).load()

        XCTAssertEqual(snapshot.context.count, 4)
        XCTAssertTrue(snapshot.context[0].hasPrefix("project"))
        XCTAssertTrue(snapshot.context[1].hasPrefix("first"))
        XCTAssertTrue(snapshot.context[2].hasPrefix("second"))
        XCTAssertEqual(snapshot.context[3], "working context")
        XCTAssertFalse(snapshot.context.contains { $0.hasPrefix("global") })
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
