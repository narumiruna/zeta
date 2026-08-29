import XCTest

@testable import ZetaTUI
@testable import ZetaTerminal

final class ZetaTUITests: XCTestCase {
    func testUntrustedComponentsCannotActivateCursorMarkerControls() {
        let malicious =
            "safe" + cursorMarker + "\u{1B}]52;c;YXR0YWNr\u{07}"
            + "\u{1B}[7m hidden\u{1B}[27m"

        for lines in [
            Text(malicious).render(width: 80),
            TruncatedText(malicious).render(width: 80),
            Markdown(malicious).render(width: 80),
        ] {
            let rendered = lines.joined()
            XCTAssertFalse(rendered.contains(cursorMarker))
            XCTAssertFalse(rendered.contains("\u{1B}]52"))
            XCTAssertEqual(ANSI.strip(rendered), "safe hidden")
        }
    }

    func testWidthsAndWrapping() {
        XCTAssertEqual(ANSI.visibleWidth("abc"), 3)
        XCTAssertEqual(ANSI.visibleWidth("漢🙂"), 4)
        XCTAssertEqual(ANSI.visibleWidth("\u{1B}[31mred\u{1B}[0m"), 3)
        XCTAssertEqual(ANSI.wrap("ab漢c", width: 3), ["ab", "漢c"])
    }

    func testFocusedEditorWrappingPreservesCursorMarkerAndStyle() {
        let editor = Editor()
        editor.focused = true
        editor.setValue("abcdEF")

        let lines = editor.render(width: 4)

        XCTAssertEqual(lines.map(ANSI.visibleWidth), [4, 3])
        XCTAssertTrue(lines[1].contains(cursorMarker))
        XCTAssertTrue(lines[1].contains("\u{1B}[7m \u{1B}[27m"))
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

    func testEditorKeepsCursorOnGraphemeBoundariesAfterUnicodeInsertion() {
        let editor = Editor()
        editor.focused = true

        editor.handleInput("a")
        editor.handleInput("\u{301}")
        XCTAssertEqual(editor.value(), "a\u{301}")
        XCTAssertEqual(editor.value().count, 1)
        XCTAssertFalse(editor.render(width: 10).isEmpty)
        editor.handleInput("\u{7F}")
        XCTAssertEqual(editor.value(), "")

        editor.handleInput("👩")
        editor.handleInput("\u{200D}")
        editor.handleInput("💻")
        XCTAssertEqual(editor.value(), "👩‍💻")
        XCTAssertEqual(editor.value().count, 1)
        editor.handleInput("\u{7F}")
        XCTAssertEqual(editor.value(), "")

        editor.setValue("aX")
        editor.handleInput("\u{1B}[D")
        editor.handleInput("\u{1B}[200~\u{301}\u{1B}[201~")
        XCTAssertEqual(editor.value(), "a\u{301}X")
        editor.handleInput("\u{1B}[3~")
        editor.handleInput("\u{7F}")
        XCTAssertEqual(editor.value(), "")

        editor.autocompleteProvider = FixedAutocompleteProvider(completion: "a\u{301}")
        editor.setValue("/a")
        editor.handleInput("\t")
        XCTAssertEqual(editor.value(), "a\u{301}")
        editor.handleInput("\u{7F}")
        XCTAssertEqual(editor.value(), "")
    }

    func testInputKeepsCursorOnGraphemeBoundariesAfterUnicodeInsertion() {
        let input = Input()

        input.handleInput("a")
        input.handleInput("\u{301}")
        XCTAssertEqual(input.value, "a\u{301}")
        XCTAssertEqual(input.value.count, 1)
        input.handleInput("\u{7F}")
        XCTAssertEqual(input.value, "")

        input.handleInput("👩")
        input.handleInput("\u{200D}")
        input.handleInput("💻")
        XCTAssertEqual(input.value, "👩‍💻")
        input.handleInput("\u{7F}")
        XCTAssertEqual(input.value, "")
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

    func testAltScreenStartupFailureDoesNotChangeTerminalModes() {
        let terminal = FailingStartTerminal()
        let tui = AltScreenTUI(
            terminal: terminal,
            root: Container([Text("never rendered")])
        )

        XCTAssertThrowsError(try tui.start())
        tui.stop()

        XCTAssertEqual(terminal.output, "")
        XCTAssertEqual(terminal.stopCount, 0)
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

    func testInputMutationAndRenderingStaySerializedUnderStress() throws {
        let terminal = VirtualTerminal(columns: 20, rows: 5)
        let component = SerializationCheckingInput()
        let tui = TUI(terminal: terminal, root: Container([component]))
        component.onInput = { tui.requestRender() }
        tui.setFocus(component)
        try tui.start()

        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            if index.isMultiple(of: 2) {
                terminal.send("x")
            } else {
                tui.requestRender(force: index.isMultiple(of: 11))
            }
        }

        let snapshot = component.snapshot
        XCTAssertEqual(snapshot.inputCount, 500)
        XCTAssertFalse(snapshot.overlapped)
        tui.stop()
    }
}

private final class FailingStartTerminal: Terminal, @unchecked Sendable {
    private(set) var output = ""
    private(set) var stopCount = 0
    var columns: Int { 80 }
    var rows: Int { 24 }

    func start(
        onInput: @escaping @Sendable (Data) -> Void,
        onResize: @escaping @Sendable () -> Void
    ) throws {
        throw POSIXError(.ENOTTY)
    }

    func stop() { stopCount += 1 }
    func write(_ data: Data) { output += String(decoding: data, as: UTF8.self) }
}

private struct FixedAutocompleteProvider: AutocompleteProvider {
    var completion: String

    func completions(for text: String) -> [String] { [completion] }
}

private final class SerializationCheckingInput: Focusable, @unchecked Sendable {
    var focused = false
    var onInput: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var active = false
    private var overlapDetected = false
    private var storedInputCount = 0

    var snapshot: (inputCount: Int, overlapped: Bool) {
        lock.withLock { (storedInputCount, overlapDetected) }
    }

    func render(width: Int) -> [String] {
        beginOperation()
        defer { endOperation() }
        return ["inputs: \(lock.withLock { storedInputCount })"]
    }

    func handleInput(_ data: String) {
        beginOperation()
        defer { endOperation() }
        lock.withLock { storedInputCount += 1 }
        onInput?()
    }

    private func beginOperation() {
        lock.withLock {
            if active { overlapDetected = true }
            active = true
        }
    }

    private func endOperation() {
        lock.withLock { active = false }
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
