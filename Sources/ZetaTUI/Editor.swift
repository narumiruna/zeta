import Foundation

public final class Editor: Focusable, @unchecked Sendable {
    public var focused = false
    public var onSubmit: (@Sendable (String) -> Void)?
    public var onChange: (@Sendable (String) -> Void)?
    public var disableSubmit = false
    public var maximumVisibleLines = 10
    public var autocompleteProvider: (any AutocompleteProvider)?

    private var characters: [Character] = []
    private var cursor = 0
    private var undoStack: [([Character], Int)] = []
    private var redoStack: [([Character], Int)] = []
    private var pasteCounter = 0
    private var completions: [String] = []

    public init() {}

    public func value() -> String { String(characters) }

    public func setValue(_ value: String) {
        characters = Array(value)
        cursor = characters.count
        undoStack.removeAll()
        redoStack.removeAll()
        changed()
    }

    public func render(width: Int) -> [String] {
        var display = characters
        if focused {
            display.insert(contentsOf: Array(cursorMarker + "\u{1B}[7m \u{1B}[27m"), at: cursor)
        }
        var lines = ANSI.wrap(String(display), width: max(1, width))
        if lines.count > maximumVisibleLines {
            lines = Array(lines.suffix(maximumVisibleLines))
        }
        if !completions.isEmpty {
            lines += completions.prefix(5).map { ANSI.truncate("  \($0)", width: width) }
        }
        return lines.isEmpty ? [""] : lines
    }

    public func handleInput(_ data: String) {
        if data.hasPrefix("\u{1B}[200~"), data.hasSuffix("\u{1B}[201~") {
            let start = data.index(data.startIndex, offsetBy: 6)
            let end = data.index(data.endIndex, offsetBy: -6)
            insertPaste(String(data[start..<end]))
            return
        }
        switch data {
        case "\r", "\n":
            guard !disableSubmit else { return }
            let submitted = value()
            onSubmit?(submitted)
        case "\u{1B}\r", "\u{1B}\n", "\u{1B}[13;2u", "\u{1B}[13;5u":
            insert("\n")
        case "\u{7F}":
            guard cursor > 0 else { return }
            checkpoint()
            cursor -= 1
            characters.remove(at: cursor)
            changed()
        case "\u{1B}[3~":
            guard cursor < characters.count else { return }
            checkpoint()
            characters.remove(at: cursor)
            changed()
        case "\u{1B}[D":
            cursor = max(0, cursor - 1)
            updateCompletions()
        case "\u{1B}[C":
            cursor = min(characters.count, cursor + 1)
            updateCompletions()
        case "\u{01}": cursor = lineStart()
        case "\u{05}": cursor = lineEnd()
        case "\u{15}": deleteToLineStart()
        case "\u{0B}": deleteToLineEnd()
        case "\u{17}": deleteWordBackward()
        case "\u{1A}": undo()
        case "\u{19}": redo()
        case "\t": applyCompletion()
        default:
            guard !data.hasPrefix("\u{1B}") else { return }
            insert(data)
        }
    }

    private func insert(_ value: String) {
        checkpoint()
        let added = Array(value)
        characters.insert(contentsOf: added, at: cursor)
        cursor += added.count
        changed()
    }

    private func insertPaste(_ value: String) {
        let lineCount = value.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        if lineCount > 10 {
            pasteCounter += 1
            insert("[paste #\(pasteCounter) +\(lineCount) lines]")
        } else {
            insert(value)
        }
    }

    private func checkpoint() {
        undoStack.append((characters, cursor))
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let state = undoStack.popLast() else { return }
        redoStack.append((characters, cursor))
        (characters, cursor) = state
        changed()
    }

    private func redo() {
        guard let state = redoStack.popLast() else { return }
        undoStack.append((characters, cursor))
        (characters, cursor) = state
        changed()
    }

    private func lineStart() -> Int {
        guard cursor > 0 else { return 0 }
        return (characters[..<cursor].lastIndex(of: "\n").map { $0 + 1 }) ?? 0
    }

    private func lineEnd() -> Int {
        characters[cursor...].firstIndex(of: "\n") ?? characters.count
    }

    private func deleteToLineStart() {
        let start = lineStart()
        guard start < cursor else { return }
        checkpoint()
        characters.removeSubrange(start..<cursor)
        cursor = start
        changed()
    }

    private func deleteToLineEnd() {
        let end = lineEnd()
        guard cursor < end else { return }
        checkpoint()
        characters.removeSubrange(cursor..<end)
        changed()
    }

    private func deleteWordBackward() {
        guard cursor > 0 else { return }
        checkpoint()
        var start = cursor
        while start > 0, characters[start - 1].isWhitespace { start -= 1 }
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        characters.removeSubrange(start..<cursor)
        cursor = start
        changed()
    }

    private func changed() {
        updateCompletions()
        onChange?(value())
    }

    private func updateCompletions() {
        completions = autocompleteProvider?.completions(for: value()) ?? []
    }

    private func applyCompletion() {
        guard let completion = completions.first else { return }
        checkpoint()
        let text = value()
        let tokenStart =
            text[..<text.index(text.startIndex, offsetBy: cursor)]
            .lastIndex(where: { $0.isWhitespace })
            .map { text.distance(from: text.startIndex, to: text.index(after: $0)) } ?? 0
        characters.replaceSubrange(tokenStart..<cursor, with: Array(completion))
        cursor = tokenStart + completion.count
        changed()
    }
}
