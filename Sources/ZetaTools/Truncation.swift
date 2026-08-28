import Foundation

public let defaultMaximumLines = 2_000
public let defaultMaximumBytes = 50 * 1_024
public let grepMaximumLineLength = 500

public enum TruncationLimit: String, Sendable, Codable {
    case lines
    case bytes
}

public struct TruncationResult: Sendable, Equatable {
    public let content: String
    public let truncated: Bool
    public let truncatedBy: TruncationLimit?
    public let totalLines: Int
    public let totalBytes: Int
    public let outputLines: Int
    public let outputBytes: Int
    public let partialBoundaryLine: Bool
    public let firstLineExceedsLimit: Bool
    public let maximumLines: Int
    public let maximumBytes: Int
}

public enum Truncation {
    public static func head(
        _ content: String,
        maximumLines: Int = defaultMaximumLines,
        maximumBytes: Int = defaultMaximumBytes
    ) -> TruncationResult {
        let lines = splitLines(content)
        let totalBytes = content.utf8.count
        guard lines.count > maximumLines || totalBytes > maximumBytes else {
            return unchanged(
                content, lines: lines, bytes: totalBytes, maximumLines: maximumLines, maximumBytes: maximumBytes)
        }
        guard let first = lines.first, first.utf8.count <= maximumBytes else {
            return TruncationResult(
                content: "", truncated: true, truncatedBy: .bytes,
                totalLines: lines.count, totalBytes: totalBytes,
                outputLines: 0, outputBytes: 0, partialBoundaryLine: false,
                firstLineExceedsLimit: true,
                maximumLines: maximumLines, maximumBytes: maximumBytes
            )
        }
        var selected: [String] = []
        var bytes = 0
        var limit: TruncationLimit = .lines
        for line in lines.prefix(maximumLines) {
            let added = line.utf8.count + (selected.isEmpty ? 0 : 1)
            if bytes + added > maximumBytes {
                limit = .bytes
                break
            }
            selected.append(line)
            bytes += added
        }
        if selected.count == maximumLines { limit = .lines }
        let output = selected.joined(separator: "\n")
        return TruncationResult(
            content: output, truncated: true, truncatedBy: limit,
            totalLines: lines.count, totalBytes: totalBytes,
            outputLines: selected.count, outputBytes: output.utf8.count,
            partialBoundaryLine: false, firstLineExceedsLimit: false,
            maximumLines: maximumLines, maximumBytes: maximumBytes
        )
    }

    public static func tail(
        _ content: String,
        maximumLines: Int = defaultMaximumLines,
        maximumBytes: Int = defaultMaximumBytes
    ) -> TruncationResult {
        let lines = splitLines(content)
        let totalBytes = content.utf8.count
        guard lines.count > maximumLines || totalBytes > maximumBytes else {
            return unchanged(
                content, lines: lines, bytes: totalBytes, maximumLines: maximumLines, maximumBytes: maximumBytes)
        }
        var selected: [String] = []
        var bytes = 0
        var limit: TruncationLimit = .lines
        var partial = false
        for line in lines.reversed() where selected.count < maximumLines {
            let added = line.utf8.count + (selected.isEmpty ? 0 : 1)
            if bytes + added > maximumBytes {
                limit = .bytes
                if selected.isEmpty {
                    let suffix = utf8Suffix(line, maximumBytes: maximumBytes)
                    selected.insert(suffix, at: 0)
                    bytes = suffix.utf8.count
                    partial = true
                }
                break
            }
            selected.insert(line, at: 0)
            bytes += added
        }
        if selected.count == maximumLines { limit = .lines }
        let output = selected.joined(separator: "\n")
        return TruncationResult(
            content: output, truncated: true, truncatedBy: limit,
            totalLines: lines.count, totalBytes: totalBytes,
            outputLines: selected.count, outputBytes: output.utf8.count,
            partialBoundaryLine: partial, firstLineExceedsLimit: false,
            maximumLines: maximumLines, maximumBytes: maximumBytes
        )
    }

    public static func line(_ line: String, maximumCharacters: Int = grepMaximumLineLength) -> (String, Bool) {
        guard line.count > maximumCharacters else { return (line, false) }
        return (String(line.prefix(maximumCharacters)) + "... [truncated]", true)
    }

    public static func format(bytes: Int) -> String {
        if bytes < 1_024 { return "\(bytes)B" }
        if bytes < 1_024 * 1_024 { return String(format: "%.1fKB", Double(bytes) / 1_024) }
        return String(format: "%.1fMB", Double(bytes) / Double(1_024 * 1_024))
    }

    private static func splitLines(_ content: String) -> [String] {
        guard !content.isEmpty else { return [] }
        var lines = content.components(separatedBy: "\n")
        if content.hasSuffix("\n") { lines.removeLast() }
        return lines
    }

    private static func utf8Suffix(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else { return value }
        var bytes = Array(value.utf8.suffix(maximumBytes))
        while let first = bytes.first, first & 0xC0 == 0x80 { bytes.removeFirst() }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func unchanged(
        _ content: String,
        lines: [String],
        bytes: Int,
        maximumLines: Int,
        maximumBytes: Int
    ) -> TruncationResult {
        TruncationResult(
            content: content, truncated: false, truncatedBy: nil,
            totalLines: lines.count, totalBytes: bytes,
            outputLines: lines.count, outputBytes: bytes,
            partialBoundaryLine: false, firstLineExceedsLimit: false,
            maximumLines: maximumLines, maximumBytes: maximumBytes
        )
    }
}
