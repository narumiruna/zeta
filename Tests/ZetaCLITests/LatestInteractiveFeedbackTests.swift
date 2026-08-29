import Darwin
import Foundation
import XCTest
import ZetaAI
import ZetaAgent
import ZetaConfig
import ZetaTUI
import ZetaTerminal
import ZetaTools

@testable import ZetaCLI

final class LatestInteractiveFeedbackTests: XCTestCase {
    func testFullscreenSettingSelectsAlternateScreenRenderer() {
        var settings = Settings()
        settings.tuiMode = "fullscreen"
        settings.fullscreenExitOutput = "resume-hint"
        let renderer = ZetaCLI.makeInteractiveTUI(
            settings: settings,
            terminal: CLITestTerminal(),
            root: Container()
        )

        XCTAssertTrue(renderer is AltScreenTUI)
    }

    func testInteractiveExitCancelsAndWaitsForDirectShell() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pidFile = directory.appendingPathComponent("shell.pid")
        let model = Model(
            id: "model",
            name: "Model",
            api: "test",
            provider: "test",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 1_000,
            maximumTokens: 100
        )
        let agent = Agent(state: AgentState(systemPrompt: "", model: model)) { _, _, _ in
            AssistantEventStream()
        }
        let runner = InteractiveRunner(
            agent: agent,
            transcript: Container(),
            tui: CLITestInteractiveTUI(),
            session: nil,
            shell: ShellTool(workingDirectory: directory)
        )
        let submission = Task {
            await runner.submit("!echo $$ > '\(pidFile.path)'; sleep 300")
        }
        try await waitUntil {
            FileManager.default.fileExists(atPath: pidFile.path)
        }
        let pid = try XCTUnwrap(
            Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))
        )

        await runner.requestExit()
        await submission.value

        XCTAssertNotEqual(kill(pid, 0), 0)
        XCTAssertEqual(errno, ESRCH)
        let hadFailure = await runner.hadFailure()
        XCTAssertFalse(hadFailure)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private final class CLITestTerminal: Terminal, @unchecked Sendable {
    var columns: Int { 80 }
    var rows: Int { 24 }
    func start(
        onInput: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable () -> Void
    ) throws {}
    func stop() {}
    func write(_ data: Data) {}
}

private final class CLITestInteractiveTUI: InteractiveTUI, @unchecked Sendable {
    func addInputListener(_ listener: @escaping @Sendable (String) -> Bool) {}
    func setFocus(_ component: (Component & Focusable)?) {}
    func start() throws {}
    func stop() {}
    func requestRender(force: Bool) {}
}
