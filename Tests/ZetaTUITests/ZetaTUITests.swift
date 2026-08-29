import XCTest

@testable import ZetaTUI
@testable import ZetaTerminal

final class ZetaTUITests: XCTestCase {
    func testWidthsAndWrapping() {
        XCTAssertEqual(ANSI.visibleWidth("abc"), 3)
        XCTAssertEqual(ANSI.visibleWidth("漢🙂"), 4)
        XCTAssertEqual(ANSI.visibleWidth("\u{1B}[31mred\u{1B}[0m"), 3)
        XCTAssertEqual(ANSI.wrap("ab漢c", width: 3), ["ab", "漢c"])
    }

    func testEditorUndoPasteAndAutocomplete() {
        let editor = Editor()
        editor.setValue("hello")
        editor.handleInput(" world")
        XCTAssertEqual(editor.value(), "hello world")
        editor.handleInput("\u{1A}")
        XCTAssertEqual(editor.value(), "hello")
        let largePaste = String(repeating: "x\n", count: 11)
        editor.handleInput("\u{1B}[200~" + largePaste + "\u{1B}[201~")
        XCTAssertEqual(editor.value(), "hello" + largePaste)
        editor.autocompleteProvider = CombinedAutocompleteProvider(
            commands: ["help", "history"],
            baseDirectory: FileManager.default.temporaryDirectory
        )
        editor.setValue("/he")
        editor.handleInput("\t")
        XCTAssertEqual(editor.value(), "/help")
    }

    func testEditorClearsFullValueAfterSubmit() {
        let recorder = SubmissionRecorder()
        let editor = Editor()
        editor.onSubmit = { recorder.record($0) }
        let largePaste = String(repeating: "submitted line\n", count: 20)
        editor.handleInput("\u{1B}[200~" + largePaste + "\u{1B}[201~")

        editor.handleInput("\r")

        XCTAssertEqual(recorder.value, largePaste)
        XCTAssertEqual(editor.value(), "")
    }

    func testInteractiveComponentsAndLayouts() {
        let select = SelectList(
            items: [
                SelectItem(value: "a", label: "Alpha"),
                SelectItem(value: "b", label: "Beta"),
            ]
        )
        select.handleInput("\u{1B}[B")
        XCTAssertTrue(select.render(width: 20)[1].hasPrefix("> "))

        let settings = SettingsList(
            items: [
                SettingItem(
                    id: "theme",
                    label: "Theme",
                    currentValue: "dark",
                    values: ["dark", "light"]
                )
            ]
        )
        settings.handleInput("\n")
        XCTAssertTrue(settings.render(width: 20)[0].contains("light"))

        let stack = HStack(
            [StackEntry(Text("left")), StackEntry(Text("right"))]
        )
        XCTAssertLessThanOrEqual(ANSI.visibleWidth(stack.render(width: 20)[0]), 20)
        XCTAssertTrue(Markdown("# Heading").render(width: 20)[0].contains("Heading"))
    }

    func testScrollViewNavigation() {
        let content = Container((0..<10).map { Text("line \($0)") })
        let scroll = ScrollView(child: content, viewportHeight: 3)
        XCTAssertEqual(scroll.render(width: 20).count, 3)
        XCTAssertTrue(scroll.render(width: 20).last?.contains("line 9") == true)
        scroll.handleInput("\u{1B}[A")
        XCTAssertTrue(scroll.render(width: 20).last?.contains("line 8") == true)
    }

    func testFragmentedInputPasteAndEscapeBuffering() {
        var decoder = TerminalInputDecoder()
        XCTAssertTrue(decoder.push(Data("\u{1B}[".utf8)).isEmpty)
        XCTAssertEqual(
            decoder.push(Data("A".utf8)),
            [Data("\u{1B}[A".utf8)]
        )
        let paste = "\u{1B}[200~a\nb\u{1B}[201~"
        var fragments: [Data] = []
        for byte in paste.utf8 {
            fragments += decoder.push(Data([byte]))
        }
        XCTAssertEqual(fragments, [Data(paste.utf8)])
        XCTAssertTrue(decoder.push(Data([0x1B])).isEmpty)
        XCTAssertEqual(decoder.flushEscape(), [Data([0x1B])])
    }

    func testTerminalInputPipelineSerializesEscapeCancellationAndFlush() async throws {
        let pipeline = TerminalInputPipeline()
        let recorder = InputRecorder()
        let record: @Sendable (Data) -> Void = { recorder.record($0) }

        pipeline.submit(Data([0x1B]), escapeDelay: 0.05, onInput: record)
        pipeline.submit(Data("[A".utf8), escapeDelay: 0.05, onInput: record)
        pipeline.waitUntilIdle()
        try await Task.sleep(for: .milliseconds(100))
        pipeline.waitUntilIdle()
        XCTAssertEqual(recorder.values, [Data("\u{1B}[A".utf8)])

        pipeline.submit(Data([0x1B]), escapeDelay: 0.05, onInput: record)
        pipeline.waitUntilIdle()
        pipeline.reset()
        try await Task.sleep(for: .milliseconds(100))
        pipeline.waitUntilIdle()
        XCTAssertEqual(recorder.values, [Data("\u{1B}[A".utf8)])
    }

    func testCapabilitiesImagesAndAltScreenLifecycle() throws {
        let capabilities = TerminalCapabilities.detect(environment: [
            "TERM_PROGRAM": "Ghostty",
            "KITTY_WINDOW_ID": "1",
            "PI_TRUE_COLOR": "1",
        ])
        XCTAssertEqual(capabilities.imageProtocol, .kitty)
        XCTAssertTrue(capabilities.trueColor)
        let fallback = InlineImage(
            base64: "aGVsbG8=",
            mimeType: "image/png",
            capabilities: TerminalCapabilities(
                hyperlinks: false,
                trueColor: false,
                imageProtocol: .none,
                kittyKeyboard: false
            )
        )
        XCTAssertTrue(fallback.render(width: 20)[0].contains("Image"))

        let terminal = VirtualTerminal(columns: 20, rows: 3)
        let root = Container((0..<5).map { Text("line \($0)") })
        let tui = AltScreenTUI(
            terminal: terminal,
            root: root,
            transcriptOnExit: true
        )
        try tui.start()
        tui.stop()
        XCTAssertTrue(terminal.output.contains("\u{1B}[?1049h"))
        XCTAssertTrue(terminal.output.contains("\u{1B}[?1049l"))
        XCTAssertTrue(terminal.output.contains("line 4"))
    }

    func testOverlaysClipboardAndHyperlinks() throws {
        let terminal = VirtualTerminal(columns: 30, rows: 8)
        let tui = TUI(terminal: terminal, root: Container([Text("base")]))
        try tui.start()
        let handle = tui.showOverlay(
            Text("overlay"),
            options: OverlayOptions(width: 10, anchor: .center)
        )
        XCTAssertTrue(tui.hasOverlay())
        XCTAssertTrue(terminal.output.contains("overlay"))
        handle.setHidden(true)
        XCTAssertFalse(tui.hasOverlay())
        handle.setHidden(false)
        XCTAssertTrue(tui.hasOverlay())
        handle.hide()
        XCTAssertFalse(tui.hasOverlay())
        XCTAssertTrue(ClipboardEscape.osc52("copy").contains("Y29weQ=="))
        let link = ClipboardEscape.hyperlink(
            text: "example",
            url: URL(string: "https://example.com")!
        )
        XCTAssertTrue(link.contains("\u{1B}]8;;https://example.com"))
        tui.stop()
    }

    func testDifferentialRendererUsesSynchronizedOutputAndResets() throws {
        let terminal = VirtualTerminal(columns: 20, rows: 5)
        let root = Container([Text("hello")])
        let tui = TUI(terminal: terminal, root: root)
        try tui.start()
        XCTAssertTrue(terminal.output.contains("\u{1B}[?2026h"))
        XCTAssertTrue(terminal.output.contains("\u{1B}[0m"))
        XCTAssertTrue(terminal.output.contains("\u{1B}]8;;\u{07}"))
        tui.stop()
    }
}

private final class InputRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Data] = []

    var values: [Data] { lock.withLock { storedValues } }
    func record(_ value: Data) { lock.withLock { storedValues.append(value) } }
}

private final class SubmissionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ value: String) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}
