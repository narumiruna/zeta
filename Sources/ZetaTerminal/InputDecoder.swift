import Foundation

public struct TerminalInputDecoder: Sendable {
    private var buffer = Data()
    private var paste = false

    public init() {}

    public mutating func push(_ data: Data) -> [Data] {
        buffer.append(data)
        var output: [Data] = []
        while !buffer.isEmpty {
            if paste || buffer.starts(with: Data("\u{1B}[200~".utf8)) {
                paste = true
                guard let end = buffer.range(of: Data("\u{1B}[201~".utf8)) else {
                    break
                }
                output.append(Data(buffer[..<end.upperBound]))
                buffer = Data(buffer[end.upperBound...])
                paste = false
                continue
            }
            guard buffer.first == 0x1B else {
                let scalarLength = utf8ScalarLength(buffer.first!)
                guard buffer.count >= scalarLength else { break }
                output.append(Data(buffer.prefix(scalarLength)))
                buffer = Data(buffer.dropFirst(scalarLength))
                continue
            }
            guard buffer.count > 1 else { break }
            let second = buffer[buffer.index(after: buffer.startIndex)]
            if second == 0x5B {
                guard let end = csiEnd(buffer) else { break }
                output.append(Data(buffer.prefix(end + 1)))
                buffer = Data(buffer.dropFirst(end + 1))
            } else if second == 0x5D || second == 0x50 || second == 0x5F {
                guard let end = stringSequenceEnd(buffer) else { break }
                output.append(Data(buffer.prefix(end)))
                buffer = Data(buffer.dropFirst(end))
            } else {
                let length = min(2, buffer.count)
                output.append(Data(buffer.prefix(length)))
                buffer = Data(buffer.dropFirst(length))
            }
        }
        return output
    }

    public var hasPendingEscape: Bool {
        buffer == Data([0x1B])
    }

    public mutating func flushEscape() -> [Data] {
        guard buffer == Data([0x1B]) else { return [] }
        defer { buffer.removeAll() }
        return [Data([0x1B])]
    }

    public mutating func finish() -> [Data] {
        guard !buffer.isEmpty else { return [] }
        defer {
            buffer.removeAll()
            paste = false
        }
        return [buffer]
    }

    public static func isKeyRelease(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.hasPrefix("\u{1B}[") && text.hasSuffix("u")
            && text.split(separator: ";").last?.hasPrefix("3") == true
    }

    private func csiEnd(_ data: Data) -> Int? {
        guard data.count > 2 else { return nil }
        for (offset, byte) in data.enumerated().dropFirst(2)
        where byte >= 0x40 && byte <= 0x7E {
            return offset
        }
        return nil
    }

    private func stringSequenceEnd(_ data: Data) -> Int? {
        let bytes = Array(data)
        for index in 2..<bytes.count {
            if bytes[index] == 0x07 { return index + 1 }
            if bytes[index] == 0x5C, bytes[index - 1] == 0x1B {
                return index + 1
            }
        }
        return nil
    }

    private func utf8ScalarLength(_ first: UInt8) -> Int {
        if first < 0x80 { return 1 }
        if first & 0xE0 == 0xC0 { return 2 }
        if first & 0xF0 == 0xE0 { return 3 }
        if first & 0xF8 == 0xF0 { return 4 }
        return 1
    }
}
