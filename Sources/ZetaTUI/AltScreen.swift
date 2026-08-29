import Foundation
import ZetaTerminal

public final class AltScreenTUI: @unchecked Sendable {
    private let terminal: Terminal
    private let root: Component
    private weak var focus: Component?
    private var previous: [String] = []
    private var inputListeners: [@Sendable (String) -> Bool] = []
    private var offset = 0
    private var followingEnd = true
    private var started = false
    private var componentCallbackDepth = 0
    private var rendering = false
    private var renderPending = false
    private var forceRenderPending = false
    private let transcriptOnExit: Bool
    private let executor = TUIExecutor(label: "works.earendil.zeta.tui-alt-screen")

    public init(
        terminal: Terminal,
        root: Component,
        transcriptOnExit: Bool = true
    ) {
        self.terminal = terminal
        self.root = root
        self.transcriptOnExit = transcriptOnExit
    }

    public func addInputListener(
        _ listener: @escaping @Sendable (String) -> Bool
    ) {
        executor.sync { inputListeners.append(listener) }
    }

    public func setFocus(_ component: (Component & Focusable)?) {
        executor.sync {
            if let old = focus as? Focusable { old.focused = false }
            focus = component
            if let component { component.focused = true }
            scheduleRender(force: true)
        }
    }

    public func start() throws {
        try executor.sync {
            guard !started else { return }
            started = true
            terminal.write(Data("\u{1B}[?1049h\u{1B}[?7l\u{1B}[?25l".utf8))
            do {
                try terminal.start(
                    onInput: { [weak self] data in
                        self?.handleInput(String(decoding: data, as: UTF8.self))
                    },
                    onResize: { [weak self] in self?.requestRender(force: true) }
                )
            } catch {
                started = false
                throw error
            }
            scheduleRender(force: true)
        }
    }

    public func stop() {
        executor.sync {
            guard started else { return }
            let transcript = root.render(width: terminal.columns)
            terminal.write(Data("\u{1B}[?2026h\u{1B}[?7h\u{1B}[?1049l\u{1B}[?2026l".utf8))
            terminal.stop()
            if transcriptOnExit {
                terminal.write(Data((transcript.joined(separator: "\n") + "\n").utf8))
            }
            started = false
            renderPending = false
            forceRenderPending = false
        }
    }

    public func requestRender(force: Bool = false) {
        executor.sync { scheduleRender(force: force) }
    }

    private func render(force: Bool) {
        let document = root.render(width: terminal.columns)
        let height = max(1, terminal.rows)
        if followingEnd { offset = max(0, document.count - height) }
        offset = min(offset, max(0, document.count - height))
        var viewport = Array(document.dropFirst(offset).prefix(height))
        viewport += Array(repeating: "", count: max(0, height - viewport.count))
        guard force || viewport != previous else { return }
        var output = "\u{1B}[?2026h\u{1B}[H"
        for (index, line) in viewport.enumerated() {
            if force || previous.indices.contains(index) == false
                || previous[index] != line
            {
                if index > 0 { output += "\u{1B}[\(index + 1);1H" }
                output +=
                    ANSI.truncate(line, width: terminal.columns)
                    + "\u{1B}[0m\u{1B}]8;;\u{07}\u{1B}[K"
            }
        }
        output += "\u{1B}[?2026l"
        terminal.write(Data(output.utf8))
        previous = viewport
    }

    private func handleInput(_ data: String) {
        executor.sync {
            guard started else { return }
            componentCallbackDepth += 1
            if inputListeners.reversed().contains(where: { $0(data) }) {
                componentCallbackDepth -= 1
                scheduleRender()
                return
            }
            switch data {
            case "\u{1B}[A":
                followingEnd = false
                offset = max(0, offset - 1)
            case "\u{1B}[B":
                followingEnd = false
                offset += 1
            case "\u{1B}[5~":
                followingEnd = false
                offset = max(0, offset - terminal.rows)
            case "\u{1B}[6~":
                followingEnd = false
                offset += terminal.rows
            case "\u{1B}[F": followingEnd = true
            default: focus?.handleInput(data)
            }
            componentCallbackDepth -= 1
            scheduleRender()
        }
    }

    private func scheduleRender(force: Bool = false) {
        guard started else { return }
        renderPending = true
        forceRenderPending = forceRenderPending || force
        drainRender()
    }

    private func drainRender() {
        guard renderPending, componentCallbackDepth == 0, !rendering else { return }
        let shouldForce = forceRenderPending
        renderPending = false
        forceRenderPending = false
        rendering = true
        render(force: shouldForce)
        rendering = false
        if renderPending {
            executor.async { [weak self] in self?.drainRender() }
        }
    }

    deinit { stop() }
}

public final class InlineImage: Component, @unchecked Sendable {
    public var base64: String
    public var mimeType: String
    public var filename: String?
    public var maximumWidth: Int
    public var capabilities: TerminalCapabilities

    public init(
        base64: String,
        mimeType: String,
        filename: String? = nil,
        maximumWidth: Int = 60,
        capabilities: TerminalCapabilities = .detect()
    ) {
        self.base64 = base64
        self.mimeType = mimeType
        self.filename = filename
        self.maximumWidth = maximumWidth
        self.capabilities = capabilities
    }

    public func render(width: Int) -> [String] {
        switch capabilities.imageProtocol {
        case .kitty:
            let chunks = stride(from: 0, to: base64.count, by: 4_096).map { start -> String in
                let lower = base64.index(base64.startIndex, offsetBy: start)
                let upper = base64.index(
                    lower,
                    offsetBy: min(4_096, base64.count - start)
                )
                let more = upper < base64.endIndex ? 1 : 0
                return "\u{1B}_Ga=T,f=100,m=\(more);\(base64[lower..<upper])\u{1B}\\"
            }
            return [chunks.joined()]
        case .iterm:
            let name = Data((filename ?? "image").utf8).base64EncodedString()
            return [
                "\u{1B}]1337;File=name=\(name);inline=1;width=\(min(width, maximumWidth)):\(base64)\u{07}"
            ]
        case .none:
            return ["[Image: \(filename ?? mimeType)]"]
        }
    }
}
