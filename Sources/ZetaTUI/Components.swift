import Foundation

public final class Box: Component, @unchecked Sendable {
    public var child: Component
    public var horizontalPadding: Int
    public var verticalPadding: Int

    public init(
        _ child: Component,
        horizontalPadding: Int = 1,
        verticalPadding: Int = 1
    ) {
        self.child = child
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public func render(width: Int) -> [String] {
        let innerWidth = max(1, width - horizontalPadding * 2)
        let horizontal = String(repeating: " ", count: horizontalPadding)
        let blank = String(repeating: " ", count: width)
        return Array(repeating: blank, count: verticalPadding)
            + child.render(width: innerWidth).map { horizontal + $0 + horizontal }
            + Array(repeating: blank, count: verticalPadding)
    }

    public func handleInput(_ data: String) { child.handleInput(data) }
    public func invalidate() { child.invalidate() }
}

public final class TruncatedText: Component, @unchecked Sendable {
    public var value: String
    public var ellipsis: String

    public init(_ value: String, ellipsis: String = "...") {
        self.value = value
        self.ellipsis = ellipsis
    }

    public func render(width: Int) -> [String] {
        [
            ANSI.truncate(
                ANSI.sanitizeUntrusted(value),
                width: width,
                ellipsis: ellipsis
            )
        ]
    }
}

public struct SelectItem: Sendable, Equatable {
    public var value: String
    public var label: String
    public var description: String?

    public init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}

public final class SelectList: Focusable, @unchecked Sendable {
    public var focused = false
    public var onSelect: (@Sendable (SelectItem) -> Void)?
    public var onCancel: (@Sendable () -> Void)?
    public var onSelectionChange: (@Sendable (SelectItem) -> Void)?
    public var maximumVisible: Int
    private var items: [SelectItem]
    private var filtered: [SelectItem]
    private var selected = 0

    public init(items: [SelectItem], maximumVisible: Int = 10) {
        self.items = items
        filtered = items
        self.maximumVisible = maximumVisible
    }

    public func setFilter(_ value: String) {
        filtered =
            value.isEmpty
            ? items
            : items.filter {
                $0.label.localizedCaseInsensitiveContains(value)
                    || $0.value.localizedCaseInsensitiveContains(value)
            }
        selected = min(selected, max(0, filtered.count - 1))
    }

    public func render(width: Int) -> [String] {
        guard !filtered.isEmpty else { return ["No matches"] }
        let start = max(0, min(selected, filtered.count - maximumVisible))
        return filtered[start..<min(filtered.count, start + maximumVisible)]
            .enumerated().map { offset, item in
                let index = start + offset
                let prefix = index == selected ? "> " : "  "
                let description = item.description.map { " — \($0)" } ?? ""
                return ANSI.truncate(
                    ANSI.sanitizeUntrusted(prefix + item.label + description),
                    width: width
                )
            }
    }

    public func handleInput(_ data: String) {
        guard !filtered.isEmpty else {
            if data == "\u{1B}" { onCancel?() }
            return
        }
        switch data {
        case "\u{1B}[A":
            selected = max(0, selected - 1)
            onSelectionChange?(filtered[selected])
        case "\u{1B}[B":
            selected = min(filtered.count - 1, selected + 1)
            onSelectionChange?(filtered[selected])
        case "\r", "\n":
            onSelect?(filtered[selected])
        case "\u{1B}":
            onCancel?()
        default:
            break
        }
    }
}

public struct SettingItem: Sendable, Equatable {
    public var id: String
    public var label: String
    public var description: String?
    public var currentValue: String
    public var values: [String]

    public init(
        id: String,
        label: String,
        description: String? = nil,
        currentValue: String,
        values: [String]
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.currentValue = currentValue
        self.values = values
    }
}

public final class SettingsList: Focusable, @unchecked Sendable {
    public var focused = false
    public var onChange: (@Sendable (String, String) -> Void)?
    public var onCancel: (@Sendable () -> Void)?
    private var items: [SettingItem]
    private var selected = 0

    public init(items: [SettingItem]) { self.items = items }

    public func updateValue(id: String, value: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].currentValue = value
    }

    public func render(width: Int) -> [String] {
        items.enumerated().map { index, item in
            let prefix = index == selected ? "> " : "  "
            return ANSI.truncate(
                ANSI.sanitizeUntrusted(
                    "\(prefix)\(item.label): \(item.currentValue)"
                ),
                width: width
            )
        }
    }

    public func handleInput(_ data: String) {
        guard !items.isEmpty else { return }
        switch data {
        case "\u{1B}[A": selected = max(0, selected - 1)
        case "\u{1B}[B": selected = min(items.count - 1, selected + 1)
        case "\r", "\n", " ":
            let item = items[selected]
            guard !item.values.isEmpty else { return }
            let current = item.values.firstIndex(of: item.currentValue) ?? -1
            let value = item.values[(current + 1) % item.values.count]
            items[selected].currentValue = value
            onChange?(item.id, value)
        case "\u{1B}": onCancel?()
        default: break
        }
    }
}

public struct StackEntry: @unchecked Sendable {
    public var component: Component
    public var basis: Int?
    public var grow: Int
    public var minimumSize: Int

    public init(
        _ component: Component,
        basis: Int? = nil,
        grow: Int = 0,
        minimumSize: Int = 0
    ) {
        self.component = component
        self.basis = basis
        self.grow = grow
        self.minimumSize = minimumSize
    }
}

public final class VStack: Component, @unchecked Sendable {
    public var entries: [StackEntry]
    public init(_ entries: [StackEntry]) { self.entries = entries }
    public convenience init(_ components: [Component]) {
        self.init(components.map { StackEntry($0) })
    }
    public func render(width: Int) -> [String] {
        entries.flatMap { $0.component.render(width: width) }
    }
}

public final class HStack: Component, @unchecked Sendable {
    public var entries: [StackEntry]
    public var spacing: Int
    public init(_ entries: [StackEntry], spacing: Int = 1) {
        self.entries = entries
        self.spacing = spacing
    }
    public func render(width: Int) -> [String] {
        guard !entries.isEmpty else { return [] }
        let totalSpacing = spacing * max(0, entries.count - 1)
        let each = max(1, (width - totalSpacing) / entries.count)
        let columns = entries.map { $0.component.render(width: each) }
        let height = columns.map(\.count).max() ?? 0
        return (0..<height).map { row in
            columns.map { column in
                let value = row < column.count ? column[row] : ""
                return value + String(repeating: " ", count: max(0, each - ANSI.visibleWidth(value)))
            }.joined(separator: String(repeating: " ", count: spacing))
        }
    }
}

public final class ScrollView: Focusable, @unchecked Sendable {
    public var focused = false
    public let child: Component
    public var viewportHeight: Int
    public var followsEnd: Bool
    private var offset = 0

    public init(child: Component, viewportHeight: Int, followsEnd: Bool = true) {
        self.child = child
        self.viewportHeight = max(1, viewportHeight)
        self.followsEnd = followsEnd
    }

    public func render(width: Int) -> [String] {
        let all = child.render(width: width)
        if followsEnd { offset = max(0, all.count - viewportHeight) }
        offset = min(offset, max(0, all.count - viewportHeight))
        return Array(all.dropFirst(offset).prefix(viewportHeight))
    }

    public func handleInput(_ data: String) {
        switch data {
        case "\u{1B}[A":
            followsEnd = false
            offset = max(0, offset - 1)
        case "\u{1B}[B":
            followsEnd = false
            offset += 1
        case "\u{1B}[5~":
            followsEnd = false
            offset = max(0, offset - viewportHeight)
        case "\u{1B}[6~":
            followsEnd = false
            offset += viewportHeight
        case "\u{1B}[F": followsEnd = true
        default: child.handleInput(data)
        }
    }
}

public final class Markdown: Component, @unchecked Sendable {
    public var source: String
    public init(_ source: String) { self.source = source }

    public func render(width: Int) -> [String] {
        ANSI.sanitizeUntrusted(source).components(separatedBy: "\n").flatMap { line in
            let rendered: String
            if line.hasPrefix("# ") {
                rendered = "\u{1B}[1m" + String(line.dropFirst(2)) + "\u{1B}[22m"
            } else if line.hasPrefix("> ") {
                rendered = "│ " + String(line.dropFirst(2))
            } else if line.hasPrefix("- ") {
                rendered = "• " + String(line.dropFirst(2))
            } else {
                rendered = line
            }
            return ANSI.wrap(rendered, width: width)
        }
    }
}

public protocol AutocompleteProvider: Sendable {
    func completions(for text: String) -> [String]
}

public struct CombinedAutocompleteProvider: AutocompleteProvider {
    public var commands: [String]
    public var baseDirectory: URL

    public init(commands: [String], baseDirectory: URL) {
        self.commands = commands
        self.baseDirectory = baseDirectory
    }

    public func completions(for text: String) -> [String] {
        if text.hasPrefix("/") {
            return commands.filter { $0.hasPrefix(String(text.dropFirst())) }.map { "/" + $0 }
        }
        let prefix = text.split(separator: " ").last.map(String.init) ?? text
        let directory = baseDirectory.appendingPathComponent(
            (prefix as NSString).deletingLastPathComponent
        )
        let stem = (prefix as NSString).lastPathComponent
        let values =
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
        return values.filter { $0.lastPathComponent.hasPrefix(stem) }.map(\.path)
    }
}
