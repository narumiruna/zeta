import Foundation

public enum FileToolError: Error, LocalizedError, Equatable {
    case invalidPath(String)
    case unreadable(String)
    case invalidEdit(String)
    case noMatch(String)
    case multipleMatches(String)
    case overlappingEdits
    case processFailed(String)
    case timedOut
    case aborted

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let value): "Invalid path: \(value)"
        case .unreadable(let value): "Could not read file: \(value)"
        case .invalidEdit(let value): "Invalid edit: \(value)"
        case .noMatch(let value): "oldText did not match in \(value)"
        case .multipleMatches(let value): "oldText matched multiple locations in \(value)"
        case .overlappingEdits: "Edits overlap in the original file"
        case .processFailed(let value): value
        case .timedOut: "Command timed out"
        case .aborted: "Operation aborted"
        }
    }
}

public struct TextReplacement: Sendable, Codable, Equatable {
    public let oldText: String
    public let newText: String

    public init(oldText: String, newText: String) {
        self.oldText = oldText
        self.newText = newText
    }
}

public struct EditResult: Sendable, Equatable {
    public let replacements: Int
    public let firstChangedLine: Int?
    public let original: String
    public let updated: String
}

package enum FileReadContent: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
}

public actor FileMutationCoordinator {
    public static let shared = FileMutationCoordinator()
    private var active: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public func perform<T: Sendable>(at path: String, operation: @escaping @Sendable () async throws -> T) async throws
        -> T
    {
        await acquire(path)
        do {
            let value = try await operation()
            release(path)
            return value
        } catch {
            release(path)
            throw error
        }
    }

    private func acquire(_ path: String) async {
        if active.insert(path).inserted { return }
        await withCheckedContinuation { waiters[path, default: []].append($0) }
    }

    private func release(_ path: String) {
        if var queued = waiters[path], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[path] = queued.isEmpty ? nil : queued
            next.resume()
        } else {
            active.remove(path)
        }
    }
}

public struct FileTools: @unchecked Sendable {
    public let workingDirectory: URL
    private let fileManager: FileManager

    public init(workingDirectory: URL, fileManager: FileManager = .default) {
        self.workingDirectory = workingDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func resolve(_ path: String) throws -> URL {
        let stripped = path.hasPrefix("@") ? String(path.dropFirst()) : path
        guard !stripped.isEmpty else { throw FileToolError.invalidPath(path) }
        let expanded = (stripped as NSString).expandingTildeInPath
        let url =
            expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : workingDirectory.appendingPathComponent(expanded)
        return url.standardizedFileURL
    }

    public func read(path: String, offset: Int = 1, limit: Int? = nil) throws -> String {
        guard offset >= 1 else { throw FileToolError.invalidPath("offset must be at least 1") }
        if let limit, limit < 0 {
            throw FileToolError.invalidPath("limit must not be negative")
        }
        let maximumLines = min(limit ?? defaultMaximumLines, defaultMaximumLines)
        guard maximumLines > 0 else { return "" }
        let url = try regularFileURL(path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FileToolError.unreadable(path)
        }
        defer { try? handle.close() }

        var lineNumber = 1
        var selectedLines = 0
        var output = Data()
        var line = Data()
        do {
            while let chunk = try handle.read(upToCount: 16 * 1_024), !chunk.isEmpty {
                for byte in chunk {
                    if lineNumber < offset {
                        if byte == 0x0A { lineNumber += 1 }
                        continue
                    }
                    if byte == 0x0A {
                        guard append(line: line, lineNumber: selectedLines, to: &output) else {
                            return String(decoding: output, as: UTF8.self)
                        }
                        selectedLines += 1
                        if selectedLines >= maximumLines {
                            return String(decoding: output, as: UTF8.self)
                        }
                        line.removeAll(keepingCapacity: true)
                        lineNumber += 1
                    } else {
                        let separatorBytes = selectedLines == 0 ? 0 : 1
                        guard output.count + separatorBytes + line.count + 1 <= defaultMaximumBytes else {
                            return String(decoding: output, as: UTF8.self)
                        }
                        line.append(byte)
                    }
                }
            }
            if lineNumber >= offset, selectedLines < maximumLines {
                _ = append(line: line, lineNumber: selectedLines, to: &output)
            }
            return String(decoding: output, as: UTF8.self)
        } catch {
            throw FileToolError.unreadable(path)
        }
    }

    package func readContent(path: String, offset: Int = 1, limit: Int? = nil) throws -> FileReadContent {
        if let image = try readImage(path: path) { return image }
        return .text(try read(path: path, offset: offset, limit: limit))
    }

    private func readImage(path: String) throws -> FileReadContent? {
        let url = try regularFileURL(path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw FileToolError.unreadable(path)
        }
        defer { try? handle.close() }
        do {
            let prefix = try handle.read(upToCount: 12) ?? Data()
            guard let mimeType = imageMIMEType(prefix) else { return nil }
            try handle.seek(toOffset: 0)
            var data = Data()
            while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                data.append(chunk)
            }
            return .image(data: data, mimeType: mimeType)
        } catch {
            throw FileToolError.unreadable(path)
        }
    }

    private func regularFileURL(_ path: String) throws -> URL {
        let url = try resolve(path)
        let resolved = url.resolvingSymlinksInPath()
        guard
            let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
        else {
            throw FileToolError.unreadable(path)
        }
        return resolved
    }

    public func write(path: String, content: String) throws {
        let url = try resolve(path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    public func edit(path: String, replacements: [TextReplacement]) async throws -> EditResult {
        guard !replacements.isEmpty else {
            throw FileToolError.invalidEdit("edits must contain at least one replacement")
        }
        let url = try resolve(path)
        return try await FileMutationCoordinator.shared.perform(at: url.path) {
            guard let data = self.fileManager.contents(atPath: url.path) else {
                throw FileToolError.unreadable(path)
            }
            try Task.checkCancellation()
            let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
            let contentBytes = hasBOM ? data.dropFirst(3) : data[...]
            guard let raw = String(bytes: contentBytes, encoding: .utf8) else {
                throw FileToolError.unreadable(path)
            }
            let bom = hasBOM ? "\u{FEFF}" : ""
            let normalizedView = NormalizedText(raw)
            let normalized = normalizedView.text
            var ranges: [(range: Range<String.Index>, replacement: String)] = []
            for replacement in replacements {
                guard !replacement.oldText.isEmpty else { throw FileToolError.invalidEdit("oldText must not be empty") }
                let needle = replacement.oldText.replacingOccurrences(of: "\r\n", with: "\n")
                let matches = normalized.ranges(of: needle)
                guard !matches.isEmpty else { throw FileToolError.noMatch(path) }
                guard matches.count == 1 else { throw FileToolError.multipleMatches(path) }
                ranges.append(
                    (
                        matches[0],
                        replacement.newText.replacingOccurrences(of: "\r\n", with: "\n")
                    )
                )
            }
            let sorted = ranges.sorted { $0.range.lowerBound < $1.range.lowerBound }
            for pair in zip(sorted, sorted.dropFirst()) where pair.0.range.upperBound > pair.1.range.lowerBound {
                throw FileToolError.overlappingEdits
            }
            let rawBytes = Array(raw.utf8)
            let fallbackLineEnding = firstLineEnding(in: rawBytes) ?? [0x0A]
            var updatedBytes = rawBytes
            for edit in sorted.reversed() {
                let rawRange = normalizedView.rawUTF8Range(for: edit.range)
                let replacementBytes = restoreLineEndings(
                    in: edit.replacement,
                    from: Array(rawBytes[rawRange]),
                    fallback: fallbackLineEnding
                )
                updatedBytes.replaceSubrange(rawRange, with: replacementBytes)
            }
            let firstIndex = sorted.first?.range.lowerBound
            let firstLine = firstIndex.map { normalized[..<$0].reduce(1) { $1 == "\n" ? $0 + 1 : $0 } }
            let restored = bom + String(decoding: updatedBytes, as: UTF8.self)
            try Task.checkCancellation()
            try Data(restored.utf8).write(to: url, options: .atomic)
            return EditResult(
                replacements: replacements.count, firstChangedLine: firstLine, original: bom + raw, updated: restored)
        }
    }

    public func list(path: String = ".", limit: Int = 500) throws -> [String] {
        let url = try resolve(path)
        let values = try fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        return try values.compactMap { value in
            let isDirectory = try value.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            return value.lastPathComponent + (isDirectory ? "/" : "")
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.prefix(limit).map { $0 }
    }
}

private func append(line: Data, lineNumber: Int, to output: inout Data) -> Bool {
    let separatorBytes = lineNumber == 0 ? 0 : 1
    guard output.count + separatorBytes + line.count <= defaultMaximumBytes else { return false }
    if separatorBytes == 1 { output.append(0x0A) }
    output.append(line)
    return true
}

private func imageMIMEType(_ data: Data) -> String? {
    let bytes = [UInt8](data.prefix(12))
    if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
    if bytes.starts(with: Array("BM".utf8)) { return "image/bmp" }
    if bytes.count >= 12,
        String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
        String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP"
    {
        return "image/webp"
    }
    return nil
}

private struct NormalizedText {
    let text: String
    private let rawOffsets: [Int]

    init(_ raw: String) {
        let bytes = Array(raw.utf8)
        var normalized: [UInt8] = []
        var offsets = [0]
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                normalized.append(0x0A)
                index += 2
            } else {
                normalized.append(bytes[index])
                index += 1
            }
            offsets.append(index)
        }
        self.text = String(decoding: normalized, as: UTF8.self)
        self.rawOffsets = offsets
    }

    func rawUTF8Range(for range: Range<String.Index>) -> Range<Int> {
        let utf8 = text.utf8
        let lower = range.lowerBound.samePosition(in: utf8) ?? utf8.startIndex
        let upper = range.upperBound.samePosition(in: utf8) ?? utf8.endIndex
        let lowerOffset = utf8.distance(from: utf8.startIndex, to: lower)
        let upperOffset = utf8.distance(from: utf8.startIndex, to: upper)
        return rawOffsets[lowerOffset]..<rawOffsets[upperOffset]
    }
}

private func firstLineEnding(in bytes: [UInt8]) -> [UInt8]? {
    for index in bytes.indices where bytes[index] == 0x0A {
        return index > bytes.startIndex && bytes[index - 1] == 0x0D ? [0x0D, 0x0A] : [0x0A]
    }
    return nil
}

private func restoreLineEndings(
    in replacement: String,
    from originalBytes: [UInt8],
    fallback: [UInt8]
) -> [UInt8] {
    var originalEndings: [[UInt8]] = []
    var index = 0
    while index < originalBytes.count {
        if originalBytes[index] == 0x0D,
            index + 1 < originalBytes.count,
            originalBytes[index + 1] == 0x0A
        {
            originalEndings.append([0x0D, 0x0A])
            index += 2
        } else {
            if originalBytes[index] == 0x0A { originalEndings.append([0x0A]) }
            index += 1
        }
    }

    var restored: [UInt8] = []
    var endingIndex = 0
    for byte in replacement.utf8 {
        if byte == 0x0A {
            restored.append(contentsOf: endingIndex < originalEndings.count ? originalEndings[endingIndex] : fallback)
            endingIndex += 1
        } else {
            restored.append(byte)
        }
    }
    return restored
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        var output: [Range<String.Index>] = []
        var start = startIndex
        while start < endIndex, let range = range(of: needle, range: start..<endIndex) {
            output.append(range)
            start = range.upperBound
        }
        return output
    }
}
