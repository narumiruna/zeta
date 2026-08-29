import Foundation
import ZetaTerminal

public let cursorMarker = "\u{1B}_pi:c\u{07}"
private let sgrReset = "\u{1B}[0m"
private let hyperlinkReset = "\u{1B}]8;;\u{07}"

public protocol Component: AnyObject, Sendable {
    func render(width: Int) -> [String]
    func handleInput(_ data: String)
    func invalidate()
}

public extension Component {
    func handleInput(_ data: String) {}
    func invalidate() {}
}

public protocol Focusable: Component {
    var focused: Bool { get set }
}

public final class Text: Component, @unchecked Sendable {
    public var value: String
    public let horizontalPadding: Int
    public let verticalPadding: Int

    public init(_ value: String, horizontalPadding: Int = 0, verticalPadding: Int = 0) {
        self.value = value
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public func render(width: Int) -> [String] {
        let available = max(1, width - horizontalPadding * 2)
        let padding = String(repeating: " ", count: horizontalPadding)
        let body = value.components(separatedBy: "\n").flatMap { ANSI.wrap($0, width: available) }
            .map { padding + $0 + padding }
        let blank = String(repeating: " ", count: min(width, horizontalPadding * 2))
        return Array(repeating: blank, count: verticalPadding) + body + Array(repeating: blank, count: verticalPadding)
    }
}

public final class Spacer: Component, @unchecked Sendable {
    public let lines: Int
    public init(_ lines: Int = 1) { self.lines = max(0, lines) }
    public func render(width: Int) -> [String] { Array(repeating: "", count: lines) }
}

public class Container: Component, @unchecked Sendable {
    private let lock = NSLock()
    private var storedChildren: [Component]

    public var children: [Component] { lock.withLock { storedChildren } }

    public init(_ children: [Component] = []) { storedChildren = children }
    public func add(_ component: Component) { lock.withLock { storedChildren.append(component) } }
    public func remove(_ component: Component) { lock.withLock { storedChildren.removeAll { $0 === component } } }
    public func clear() { lock.withLock { storedChildren.removeAll() } }
    public func render(width: Int) -> [String] { children.flatMap { $0.render(width: width) } }
    public func invalidate() { children.forEach { $0.invalidate() } }
}

func replacingGraphemes(
    _ source: [Character], in range: Range<Int>, with replacement: String
) -> (characters: [Character], cursor: Int) {
    let prefix = String(source[..<range.lowerBound])
    let suffix = String(source[range.upperBound...])
    let cursorUTF8Offset = prefix.utf8.count + replacement.utf8.count
    let characters = Array(prefix + replacement + suffix)
    // An edit endpoint can become the interior of a merged grapheme, so round it to the following boundary.
    var byteOffset = 0
    var cursor = 0
    while cursor < characters.count, byteOffset < cursorUTF8Offset {
        byteOffset += String(characters[cursor]).utf8.count
        cursor += 1
    }
    return (characters, cursor)
}

public final class Input: Focusable, @unchecked Sendable {
    public var focused = false
    public var onSubmit: (@Sendable (String) -> Void)?
    private(set) public var value = ""
    private var cursor = 0

    public init() {}
    public func setValue(_ newValue: String) {
        value = newValue
        cursor = newValue.count
    }

    public func render(width: Int) -> [String] {
        let index = value.index(value.startIndex, offsetBy: min(cursor, value.count))
        let before = String(value[..<index])
        let after = String(value[index...])
        let cursorText = focused ? cursorMarker + "\u{1B}[7m \u{1B}[27m" : ""
        return [ANSI.truncate(before + cursorText + after, width: width)]
    }

    public func handleInput(_ data: String) {
        switch data {
        case "\r", "\n":
            let submitted = value
            setValue("")
            onSubmit?(submitted)
        case "\u{7F}":
            if cursor > 0 {
                replaceCharacters(in: (cursor - 1)..<cursor, with: "")
            }
        case "\u{1B}[D": cursor = max(0, cursor - 1)
        case "\u{1B}[C": cursor = min(value.count, cursor + 1)
        default:
            guard !data.hasPrefix("\u{1B}") else { return }
            replaceCharacters(in: cursor..<cursor, with: data)
        }
    }

    private func replaceCharacters(in range: Range<Int>, with replacement: String) {
        let result = replacingGraphemes(Array(value), in: range, with: replacement)
        value = String(result.characters)
        cursor = result.cursor
    }
}

final class TUIExecutor: @unchecked Sendable {
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()

    init(label: String) {
        queue = DispatchQueue(label: label)
        queue.setSpecific(key: queueKey, value: 1)
    }

    func sync<Result>(_ operation: () throws -> Result) rethrows -> Result {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }

    func async(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

public final class TUI: @unchecked Sendable {
    private struct ActiveOverlay {
        var id: UUID
        var component: Component
        var options: OverlayOptions
        var hidden: Bool
    }

    private let terminal: Terminal
    private let root: Container
    private weak var focus: Component?
    private var previous: [String] = []
    private var inputListeners: [@Sendable (String) -> Bool] = []
    private var overlays: [ActiveOverlay] = []
    private var started = false
    private var componentCallbackDepth = 0
    private var rendering = false
    private var renderPending = false
    private var forceRenderPending = false
    private let executor = TUIExecutor(label: "works.earendil.zeta.tui")

    public init(terminal: Terminal, root: Container = Container()) {
        self.terminal = terminal
        self.root = root
    }

    public func add(_ component: Component) {
        executor.sync {
            root.add(component)
            scheduleRender()
        }
    }

    public func addInputListener(
        _ listener: @escaping @Sendable (String) -> Bool
    ) {
        executor.sync { inputListeners.append(listener) }
    }

    public func showOverlay(
        _ component: Component,
        options: OverlayOptions = OverlayOptions()
    ) -> OverlayHandle {
        executor.sync {
            let id = UUID()
            overlays.append(
                ActiveOverlay(
                    id: id,
                    component: component,
                    options: options,
                    hidden: false
                )
            )
            if !options.nonCapturing, let focusable = component as? Focusable {
                setFocusWithoutRendering(focusable)
            }
            scheduleRender()
            return OverlayHandle(
                id: id,
                hide: { [weak self] id in self?.hideOverlay(id) },
                visibility: { [weak self] id, hidden in
                    self?.setOverlay(id, hidden: hidden)
                }
            )
        }
    }

    public func hasOverlay() -> Bool {
        executor.sync { overlays.contains { !$0.hidden } }
    }

    public func hideOverlay() {
        executor.sync {
            guard let id = overlays.last(where: { !$0.hidden })?.id else { return }
            hideOverlayWithoutRendering(id)
            scheduleRender()
        }
    }

    public func setFocus(_ component: (Component & Focusable)?) {
        executor.sync {
            setFocusWithoutRendering(component)
            scheduleRender()
        }
    }

    public func start() throws {
        try executor.sync {
            guard !started else { return }
            started = true
            do {
                try terminal.start(
                    onInput: { [weak self] data in
                        self?.handleInput(String(decoding: data, as: UTF8.self))
                    }, onResize: { [weak self] in self?.requestRender(force: true) })
            } catch {
                started = false
                throw error
            }
            terminal.write(Data("\u{1B}[?25l".utf8))
            scheduleRender(force: true)
        }
    }

    public func stop() {
        executor.sync {
            guard started else { return }
            terminal.write(Data("\u{1B}[?2026h\u{1B}[0m\u{1B}]8;;\u{07}\u{1B}[?2026l\u{1B}[?25h".utf8))
            terminal.stop()
            started = false
            renderPending = false
            forceRenderPending = false
        }
    }

    public func requestRender(force: Bool = false) {
        executor.sync { scheduleRender(force: force) }
    }

    private func render(force: Bool) {
        var lines = root.render(width: terminal.columns)
        for overlay in overlays where !overlay.hidden {
            lines = applyOverlay(overlay, to: lines, width: terminal.columns)
        }
        lines = lines.map { line in
            precondition(ANSI.visibleWidth(line) <= terminal.columns, "Component rendered beyond terminal width")
            return line + sgrReset + hyperlinkReset
        }
        let firstDifference =
            force
            ? 0
            : (0..<min(previous.count, lines.count)).first { previous[$0] != lines[$0] }
                ?? min(previous.count, lines.count)
        guard force || lines != previous else { return }
        var output = "\u{1B}[?2026h"
        if previous.isEmpty || force {
            output += "\u{1B}[2J\u{1B}[H" + lines.joined(separator: "\n")
        } else {
            let rowsUp = max(0, previous.count - firstDifference)
            if rowsUp > 0 { output += "\u{1B}[\(rowsUp)A" }
            output += "\r\u{1B}[J" + lines.dropFirst(firstDifference).joined(separator: "\n")
        }
        if let location = output.range(of: cursorMarker) {
            output.removeSubrange(location)
            output += "\u{1B}[?25h"
        }
        output += "\u{1B}[?2026l"
        terminal.write(Data(output.utf8))
        previous = lines
    }

    private func handleInput(_ value: String) {
        executor.sync {
            guard started else { return }
            componentCallbackDepth += 1
            let consumed = inputListeners.contains { $0(value) }
            if !consumed { focus?.handleInput(value) }
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

    private func setFocusWithoutRendering(_ component: (Component & Focusable)?) {
        if let old = focus as? Focusable { old.focused = false }
        focus = component
        if let component { component.focused = true }
    }

    private func hideOverlay(_ id: UUID) {
        executor.sync {
            hideOverlayWithoutRendering(id)
            scheduleRender()
        }
    }

    private func hideOverlayWithoutRendering(_ id: UUID) {
        overlays.removeAll { $0.id == id }
    }

    private func setOverlay(_ id: UUID, hidden: Bool) {
        executor.sync {
            guard let index = overlays.firstIndex(where: { $0.id == id }) else { return }
            overlays[index].hidden = hidden
            scheduleRender()
        }
    }

    private func applyOverlay(
        _ overlay: ActiveOverlay,
        to source: [String],
        width: Int
    ) -> [String] {
        let overlayWidth = min(
            width - overlay.options.margin * 2,
            overlay.options.width ?? min(80, width - overlay.options.margin * 2)
        )
        var rendered = overlay.component.render(width: max(1, overlayWidth))
        if let maximum = overlay.options.maximumHeight {
            rendered = Array(rendered.prefix(maximum))
        }
        var result = source
        let requiredHeight = max(result.count, rendered.count + overlay.options.margin * 2)
        result += Array(repeating: "", count: requiredHeight - result.count)
        let row: Int
        switch overlay.options.anchor {
        case .topLeft, .topRight, .topCenter:
            row = overlay.options.margin
        case .bottomLeft, .bottomRight, .bottomCenter:
            row = max(overlay.options.margin, result.count - rendered.count - overlay.options.margin)
        default:
            row = max(overlay.options.margin, (result.count - rendered.count) / 2)
        }
        let column: Int
        switch overlay.options.anchor {
        case .topLeft, .bottomLeft, .leftCenter:
            column = overlay.options.margin
        case .topRight, .bottomRight, .rightCenter:
            column = max(overlay.options.margin, width - overlayWidth - overlay.options.margin)
        default:
            column = max(overlay.options.margin, (width - overlayWidth) / 2)
        }
        for (offset, line) in rendered.enumerated() where row + offset < result.count {
            let prefix = String(repeating: " ", count: max(0, column + overlay.options.offsetX))
            let overlayLine = ANSI.truncate(line, width: overlayWidth)
            let combined = prefix + overlayLine
            result[row + offset] = ANSI.truncate(combined, width: width)
        }
        return result
    }

    deinit { stop() }
}

public enum ANSI {
    private static let escape = try! NSRegularExpression(
        pattern: #"\u001B(?:\[[0-?]*[ -/]*[@-~]|\][^\u0007]*(?:\u0007|\u001B\\)|_[^\u0007]*(?:\u0007|\u001B\\))"#)

    public static func strip(_ value: String) -> String {
        escape.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: "")
    }

    public static func visibleWidth(_ value: String) -> Int {
        strip(value).reduce(0) { $0 + characterWidth($1) }
    }

    public static func truncate(_ value: String, width: Int, ellipsis: String = "") -> String {
        guard visibleWidth(value) > width else { return value }
        let target = max(0, width - visibleWidth(ellipsis))
        var output = ""
        var pendingCursorPrefix = ""
        var preservingCursor = false
        var used = 0
        tokenLoop: for token in tokens(value) {
            switch token {
            case .control(let sequence):
                if sequence == cursorMarker {
                    preservingCursor = true
                    pendingCursorPrefix += sequence
                } else if preservingCursor {
                    if pendingCursorPrefix.isEmpty {
                        output += sequence
                    } else {
                        pendingCursorPrefix += sequence
                    }
                    if sequence == "\u{1B}[27m" { preservingCursor = false }
                }
            case .character(let character):
                let next = characterWidth(character)
                if used + next > target { break tokenLoop }
                output += pendingCursorPrefix
                pendingCursorPrefix = ""
                output.append(character)
                used += next
            }
        }
        return output + ellipsis
    }

    public static func wrap(_ value: String, width: Int) -> [String] {
        guard width > 0 else { return [""] }
        var lines = [""]
        var pendingCursorPrefix = ""
        var preservingCursor = false
        var used = 0
        for token in tokens(value) {
            switch token {
            case .control(let sequence):
                if sequence == cursorMarker {
                    preservingCursor = true
                    pendingCursorPrefix += sequence
                } else if preservingCursor {
                    if pendingCursorPrefix.isEmpty {
                        lines[lines.count - 1] += sequence
                    } else {
                        pendingCursorPrefix += sequence
                    }
                    if sequence == "\u{1B}[27m" { preservingCursor = false }
                }
            case .character(let character):
                if character == "\n" {
                    lines[lines.count - 1] += pendingCursorPrefix
                    pendingCursorPrefix = ""
                    lines.append("")
                    used = 0
                    continue
                }
                let next = characterWidth(character)
                if used + next > width {
                    lines.append("")
                    used = 0
                }
                lines[lines.count - 1] += pendingCursorPrefix
                pendingCursorPrefix = ""
                lines[lines.count - 1].append(character)
                used += next
            }
        }
        lines[lines.count - 1] += pendingCursorPrefix
        return lines
    }

    private enum Token {
        case control(String)
        case character(Character)
    }

    private static func tokens(_ value: String) -> [Token] {
        let source = value as NSString
        let matches = escape.matches(
            in: value,
            range: NSRange(location: 0, length: source.length)
        )
        var result: [Token] = []
        var location = 0
        for match in matches {
            if match.range.location > location {
                result += source.substring(
                    with: NSRange(location: location, length: match.range.location - location)
                ).map(Token.character)
            }
            result.append(.control(source.substring(with: match.range)))
            location = NSMaxRange(match.range)
        }
        if location < source.length {
            result += source.substring(from: location).map(Token.character)
        }
        return result
    }

    private static func characterWidth(_ character: Character) -> Int {
        if character.unicodeScalars.allSatisfy({
            $0.properties.generalCategory == .nonspacingMark || $0.properties.generalCategory == .enclosingMark
        }) {
            return 0
        }
        guard let scalar = character.unicodeScalars.first else { return 0 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0xA4CF, 0xAC00...0xD7A3,
            0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
            0x1F300...0x1FAFF, 0x20000...0x3FFFD:
            return 2
        default: return 1
        }
    }
}
