import Foundation
import ZetaCore

public enum SessionFileFormat: Sendable, Equatable {
    case codingAgent(version: Int)
    case harness(version: Int)
    case sqlite
    case unknown
}

public enum SessionFormatDetector {
    private static let sqliteHeader = Data("SQLite format 3\0".utf8)

    public static func detect(data: Data) -> SessionFileFormat {
        if data.starts(with: sqliteHeader) { return .sqlite }
        guard let first = data.split(separator: 0x0A).first,
            let value = try? OrderedJSON.decode(Data(first)),
            case .object(let object) = value
        else {
            return .unknown
        }
        if object["type"] == .string("session") {
            let version = integer(object["version"]) ?? 1
            return .codingAgent(version: version)
        }
        if object["kind"] == .string("header") {
            return .harness(version: integer(object["version"]) ?? -1)
        }
        return .unknown
    }

    public static func detect(file: URL) throws -> SessionFileFormat {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return detect(data: try handle.read(upToCount: 4_096) ?? Data())
    }

    public static func require(
        _ expected: SessionFileFormat,
        data: Data
    ) throws {
        let actual = detect(data: data)
        guard compatible(actual, expected) else {
            throw SessionFormatError.mismatch(expected: expected, actual: actual)
        }
    }

    private static func compatible(
        _ lhs: SessionFileFormat,
        _ rhs: SessionFileFormat
    ) -> Bool {
        switch (lhs, rhs) {
        case (.codingAgent(let left), .codingAgent(let right)):
            left == right
        case (.harness(let left), .harness(let right)):
            left == right
        case (.sqlite, .sqlite), (.unknown, .unknown):
            true
        default:
            false
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value,
            let integer = number.safeIntegerValue
        else {
            return nil
        }
        return Int(integer)
    }
}

public enum SessionFormatError: Error, LocalizedError, Sendable {
    case mismatch(expected: SessionFileFormat, actual: SessionFileFormat)

    public var errorDescription: String? {
        switch self {
        case .mismatch(let expected, let actual):
            "Session format mismatch: expected \(expected), found \(actual)"
        }
    }
}
