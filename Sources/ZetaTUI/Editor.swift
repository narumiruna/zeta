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
            lines += completions.prefix(5).map {
                ANSI.truncate(
                    ANSI.sanitizeUntrusted("  \($0)"),
                    width: width
                )
            }
        }
        return lines.isEmpty ? [""] : lines
    }

    public func handleInput(_ data: String) {
        let pasteStart = "\u{1B}[200~".utf8
        let pasteEnd = "\u{1B}[201~".utf8
        if data.utf8.starts(with: pasteStart), data.utf8.suffix(pasteEnd.count).elementsEqual(pasteEnd) {
            let pasted = data.utf8.dropFirst(pasteStart.count).dropLast(pasteEnd.count)
            insertPaste(String(decoding: pasted, as: UTF8.self))
            return
        }
        switch data {
        case "\r", "\n":
            guard !disableSubmit else { return }
            let submitted = value()
            setValue("")
            onSubmit?(submitted)
        case "\u{1B}\r", "\u{1B}\n", "\u{1B}[13;2u", "\u{1B}[13;5u":
            insert("\n")
        case "\u{7F}":
            guard cursor > 0 else { return }
            checkpoint()
            replaceCharacters(in: (cursor - 1)..<cursor, with: "")
            changed()
        case "\u{1B}[3~":
            guard cursor < characters.count else { return }
            checkpoint()
            replaceCharacters(in: cursor..<(cursor + 1), with: "")
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
        replaceCharacters(in: cursor..<cursor, with: value)
        changed()
    }

    private func insertPaste(_ value: String) {
        insert(value)
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
        replaceCharacters(in: start..<cursor, with: "")
        changed()
    }

    private func deleteToLineEnd() {
        let end = lineEnd()
        guard cursor < end else { return }
        checkpoint()
        replaceCharacters(in: cursor..<end, with: "")
        changed()
    }

    private func deleteWordBackward() {
        guard cursor > 0 else { return }
        checkpoint()
        var start = cursor
        while start > 0, characters[start - 1].isWhitespace { start -= 1 }
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        replaceCharacters(in: start..<cursor, with: "")
        changed()
    }

    private func replaceCharacters(in range: Range<Int>, with replacement: String) {
        let result = replacingGraphemes(characters, in: range, with: replacement)
        characters = result.characters
        cursor = result.cursor
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
        replaceCharacters(in: tokenStart..<cursor, with: completion)
        changed()
    }
}
