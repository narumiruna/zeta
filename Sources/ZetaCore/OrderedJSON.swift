import Foundation

public let javaScriptMaximumSafeInteger: Int64 = 9_007_199_254_740_991
public let javaScriptMinimumSafeInteger: Int64 = -9_007_199_254_740_991

public struct JSONLimits: Sendable, Equatable {
    public var maximumByteCount: Int
    public var maximumContainerCount: Int
    public var maximumDepth: Int

    public init(
        maximumByteCount: Int = 16 * 1024 * 1024,
        maximumContainerCount: Int = 1_000_000,
        maximumDepth: Int = 64
    ) {
        precondition(maximumByteCount >= 0)
        precondition(maximumContainerCount >= 0)
        precondition(maximumDepth >= 0)
        self.maximumByteCount = maximumByteCount
        self.maximumContainerCount = maximumContainerCount
        self.maximumDepth = maximumDepth
    }

    public static let `default` = JSONLimits()
}

public struct JSONError: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case invalidUTF8
        case invalidSyntax
        case invalidNumber
        case nonFiniteNumber
        case duplicateKey
        case trailingData
        case limitExceeded
        case typeMismatch
    }

    public let code: Code
    public let message: String
    public let offset: Int?

    public init(_ code: Code, _ message: String, offset: Int? = nil) {
        self.code = code
        self.message = message
        self.offset = offset
    }

    public var description: String {
        guard let offset else { return message }
        return "\(message) at offset \(offset)"
    }
}

/// A finite JSON number that preserves its original valid JSON spelling.
public struct JSONNumber: Sendable, Hashable, Codable, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral {
    public let rawValue: String
    public let doubleValue: Double

    public init(validating rawValue: String) throws {
        guard JSONNumber.hasValidSyntax(rawValue) else {
            throw JSONError(.invalidNumber, "Invalid JSON number")
        }
        guard let value = Double(rawValue), value.isFinite else {
            throw JSONError(.nonFiniteNumber, "JSON numbers must be finite")
        }
        self.rawValue = rawValue
        self.doubleValue = value
    }

    public init(_ value: Int64) {
        rawValue = String(value)
        doubleValue = Double(value)
    }

    public init(_ value: Int) {
        self.init(Int64(value))
    }

    public init(_ value: Double) throws {
        guard value.isFinite else {
            throw JSONError(.nonFiniteNumber, "JSON numbers must be finite")
        }
        doubleValue = value
        if value == 0, value.sign == .minus {
            rawValue = "-0"
        } else {
            rawValue = String(value)
        }
    }

    public init(integerLiteral value: Int64) {
        self.init(value)
    }

    public init(floatLiteral value: Double) {
        precondition(value.isFinite, "JSON numbers must be finite")
        try! self.init(value)
    }

    public var isInteger: Bool {
        doubleValue.rounded(.towardZero) == doubleValue
    }

    public var isJavaScriptSafeInteger: Bool {
        isInteger && abs(doubleValue) <= Double(javaScriptMaximumSafeInteger)
    }

    public var safeIntegerValue: Int64? {
        guard isJavaScriptSafeInteger else { return nil }
        return Int64(doubleValue)
    }

    public static func == (lhs: JSONNumber, rhs: JSONNumber) -> Bool {
        if lhs.doubleValue == 0, rhs.doubleValue == 0 {
            return lhs.doubleValue.sign == rhs.doubleValue.sign
        }
        return lhs.doubleValue == rhs.doubleValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(doubleValue.bitPattern)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            self.init(integer)
            return
        }
        let value = try container.decode(Double.self)
        try self.init(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let integer = safeIntegerValue, rawValue.firstIndex(where: { ".eE".contains($0) }) == nil {
            try container.encode(integer)
        } else {
            try container.encode(doubleValue)
        }
    }

    private static func hasValidSyntax(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty else { return false }
        var index = 0
        if bytes[index] == 0x2d {
            index += 1
            guard index < bytes.count else { return false }
        }
        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 { return false }
        } else {
            guard bytes[index] >= 0x31, bytes[index] <= 0x39 else { return false }
            repeat { index += 1 } while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39
        }
        if index < bytes.count, bytes[index] == 0x2e {
            index += 1
            guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }
            repeat { index += 1 } while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39
        }
        if index < bytes.count, (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count, (bytes[index] == 0x2b || bytes[index] == 0x2d) { index += 1 }
            guard index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 else { return false }
            repeat { index += 1 } while index < bytes.count && bytes[index] >= 0x30 && bytes[index] <= 0x39
        }
        return index == bytes.count
    }
}

public struct OrderedJSONObject: Sendable, Equatable, ExpressibleByDictionaryLiteral, RandomAccessCollection {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public var value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    private var storage: [Entry]
    public typealias Index = Int

    public init() {
        storage = []
    }

    public init(_ entries: [Entry]) throws {
        var keys = Set<String>()
        for entry in entries where !keys.insert(entry.key).inserted {
            throw JSONError(.duplicateKey, "Duplicate JSON object key \"\(entry.key)\"")
        }
        storage = entries
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        storage = []
        for (key, value) in elements { self[key] = value }
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }
    public func index(after index: Int) -> Int { storage.index(after: index) }
    public func index(before index: Int) -> Int { storage.index(before: index) }
    public subscript(position: Int) -> Entry { storage[position] }

    public subscript(key: String) -> JSONValue? {
        get { storage.first(where: { $0.key == key })?.value }
        set {
            if let index = storage.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    storage[index].value = newValue
                } else {
                    storage.remove(at: index)
                }
            } else if let newValue {
                storage.append(Entry(key: key, value: newValue))
            }
        }
    }

    public var keys: [String] { storage.map(\.key) }
    public var entries: [Entry] { storage }

    public mutating func append(key: String, value: JSONValue) throws {
        guard self[key] == nil else {
            throw JSONError(.duplicateKey, "Duplicate JSON object key \"\(key)\"")
        }
        storage.append(Entry(key: key, value: value))
    }
}

public indirect enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(OrderedJSONObject)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(JSONNumber.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            let keyed = try decoder.container(keyedBy: DynamicCodingKey.self)
            var entries: [OrderedJSONObject.Entry] = []
            for key in keyed.allKeys {
                entries.append(.init(key: key.stringValue, value: try keyed.decode(JSONValue.self, forKey: key)))
            }
            self = .object(try OrderedJSONObject(entries))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case let .bool(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .number(value):
            try value.encode(to: encoder)
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(value):
            var container = encoder.unkeyedContainer()
            for item in value { try container.encode(item) }
        case let .object(value):
            var container = encoder.container(keyedBy: DynamicCodingKey.self)
            for entry in value {
                try container.encode(entry.value, forKey: DynamicCodingKey(entry.key))
            }
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .number(JSONNumber(value)) }
    public init(floatLiteral value: Double) { self = .number(JSONNumber(floatLiteral: value)) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object = OrderedJSONObject()
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public enum OrderedJSON {
    public struct EncodingOptions: Sendable, Equatable {
        public var prettyPrinted: Bool
        public var sortedKeys: Bool

        public init(prettyPrinted: Bool = false, sortedKeys: Bool = false) {
            self.prettyPrinted = prettyPrinted
            self.sortedKeys = sortedKeys
        }
    }

    public static func decode(_ data: Data, limits: JSONLimits = .default) throws -> JSONValue {
        guard data.count <= limits.maximumByteCount else {
            throw JSONError(.limitExceeded, "JSON byte count exceeds configured limit of \(limits.maximumByteCount)")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw JSONError(.invalidUTF8, "JSON input contains invalid UTF-8")
        }
        var parser = JSONParser(source: source, limits: limits)
        return try parser.parse()
    }

    public static func decode(_ source: String, limits: JSONLimits = .default) throws -> JSONValue {
        try decode(Data(source.utf8), limits: limits)
    }

    public static func encode(_ value: JSONValue, options: EncodingOptions = .init()) -> Data {
        Data(string(value, options: options).utf8)
    }

    public static func string(_ value: JSONValue, options: EncodingOptions = .init()) -> String {
        var output = ""
        write(value, into: &output, depth: 0, options: options)
        return output
    }

    private static func write(
        _ value: JSONValue,
        into output: inout String,
        depth: Int,
        options: EncodingOptions
    ) {
        switch value {
        case .null: output += "null"
        case let .bool(value): output += value ? "true" : "false"
        case let .number(value): output += value.rawValue
        case let .string(value): writeString(value, into: &output)
        case let .array(items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                if options.prettyPrinted { output += "\n" + String(repeating: "  ", count: depth + 1) }
                write(item, into: &output, depth: depth + 1, options: options)
            }
            if options.prettyPrinted, !items.isEmpty { output += "\n" + String(repeating: "  ", count: depth) }
            output += "]"
        case let .object(object):
            output += "{"
            let entries = options.sortedKeys ? object.entries.sorted { $0.key < $1.key } : object.entries
            for (index, entry) in entries.enumerated() {
                if index > 0 { output += "," }
                if options.prettyPrinted { output += "\n" + String(repeating: "  ", count: depth + 1) }
                writeString(entry.key, into: &output)
                output += options.prettyPrinted ? ": " : ":"
                write(entry.value, into: &output, depth: depth + 1, options: options)
            }
            if options.prettyPrinted, !entries.isEmpty { output += "\n" + String(repeating: "  ", count: depth) }
            output += "}"
        }
    }

    private static func writeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: output += "\\\""
            case 0x5c: output += "\\\\"
            case 0x08: output += "\\b"
            case 0x0c: output += "\\f"
            case 0x0a: output += "\\n"
            case 0x0d: output += "\\r"
            case 0x09: output += "\\t"
            case 0..<0x20: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

private struct JSONParser {
    private let scalars: [Unicode.Scalar]
    private let limits: JSONLimits
    private var index = 0

    init(source: String, limits: JSONLimits) {
        scalars = Array(source.unicodeScalars)
        self.limits = limits
    }

    mutating func parse() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        guard index == scalars.count else { throw error(.trailingData, "JSON input contains trailing data") }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> JSONValue {
        guard depth <= limits.maximumDepth else {
            throw error(.limitExceeded, "JSON nesting depth exceeds configured limit of \(limits.maximumDepth)")
        }
        guard index < scalars.count else { throw error(.invalidSyntax, "Unexpected end of JSON input") }
        switch scalars[index].value {
        case 0x6e:
            try consume("null")
            return .null
        case 0x74:
            try consume("true")
            return .bool(true)
        case 0x66:
            try consume("false")
            return .bool(false)
        case 0x22: return .string(try parseString())
        case 0x5b: return try parseArray(depth: depth)
        case 0x7b: return try parseObject(depth: depth)
        case 0x2d, 0x30...0x39: return .number(try parseNumber())
        default: throw error(.invalidSyntax, "Unexpected token in JSON input")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSONValue {
        index += 1
        skipWhitespace()
        var values: [JSONValue] = []
        if take(0x5d) { return .array(values) }
        while true {
            guard values.count < limits.maximumContainerCount else {
                throw error(
                    .limitExceeded, "JSON array count exceeds configured limit of \(limits.maximumContainerCount)")
            }
            values.append(try parseValue(depth: depth + 1))
            skipWhitespace()
            if take(0x5d) { return .array(values) }
            guard take(0x2c) else { throw error(.invalidSyntax, "Expected ',' or ']' in JSON array") }
            skipWhitespace()
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSONValue {
        index += 1
        skipWhitespace()
        var object = OrderedJSONObject()
        if take(0x7d) { return .object(object) }
        while true {
            guard object.count < limits.maximumContainerCount else {
                throw error(
                    .limitExceeded, "JSON object count exceeds configured limit of \(limits.maximumContainerCount)")
            }
            guard index < scalars.count, scalars[index].value == 0x22 else {
                throw error(.invalidSyntax, "Expected a string key in JSON object")
            }
            let key = try parseString()
            skipWhitespace()
            guard take(0x3a) else { throw error(.invalidSyntax, "Expected ':' after JSON object key") }
            skipWhitespace()
            try object.append(key: key, value: parseValue(depth: depth + 1))
            skipWhitespace()
            if take(0x7d) { return .object(object) }
            guard take(0x2c) else { throw error(.invalidSyntax, "Expected ',' or '}' in JSON object") }
            skipWhitespace()
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var result = String.UnicodeScalarView()
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar.value == 0x22 { return String(result) }
            if scalar.value == 0x5c {
                guard index < scalars.count else { throw error(.invalidSyntax, "Truncated JSON escape") }
                let escape = scalars[index].value
                index += 1
                switch escape {
                case 0x22, 0x2f, 0x5c: result.append(Unicode.Scalar(escape)!)
                case 0x62: result.append("\u{8}")
                case 0x66: result.append("\u{c}")
                case 0x6e: result.append("\n")
                case 0x72: result.append("\r")
                case 0x74: result.append("\t")
                case 0x75: try appendUnicodeEscape(to: &result)
                default: throw error(.invalidSyntax, "Invalid JSON escape")
                }
            } else {
                guard scalar.value >= 0x20 else {
                    throw error(.invalidSyntax, "Unescaped control character in JSON string")
                }
                result.append(scalar)
            }
        }
        throw error(.invalidSyntax, "Unterminated JSON string")
    }

    private mutating func appendUnicodeEscape(to output: inout String.UnicodeScalarView) throws {
        let first = try readHexQuad()
        if first >= 0xd800, first <= 0xdbff {
            guard index + 1 < scalars.count, scalars[index].value == 0x5c, scalars[index + 1].value == 0x75 else {
                throw error(.invalidSyntax, "JSON high surrogate must be followed by a low surrogate")
            }
            index += 2
            let second = try readHexQuad()
            guard second >= 0xdc00, second <= 0xdfff else {
                throw error(.invalidSyntax, "Invalid JSON low surrogate")
            }
            let scalar = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00
            output.append(Unicode.Scalar(scalar)!)
        } else {
            guard !(first >= 0xdc00 && first <= 0xdfff) else {
                throw error(.invalidSyntax, "Unexpected JSON low surrogate")
            }
            output.append(Unicode.Scalar(first)!)
        }
    }

    private mutating func readHexQuad() throws -> UInt32 {
        guard index + 4 <= scalars.count else { throw error(.invalidSyntax, "Truncated JSON Unicode escape") }
        var result: UInt32 = 0
        for _ in 0..<4 {
            let value = scalars[index].value
            index += 1
            let digit: UInt32
            switch value {
            case 0x30...0x39: digit = value - 0x30
            case 0x41...0x46: digit = value - 0x41 + 10
            case 0x61...0x66: digit = value - 0x61 + 10
            default: throw error(.invalidSyntax, "Invalid JSON Unicode escape")
            }
            result = result * 16 + digit
        }
        return result
    }

    private mutating func parseNumber() throws -> JSONNumber {
        let start = index
        if take(0x2d), index == scalars.count { throw error(.invalidNumber, "Truncated JSON number") }
        if take(0x30) {
            if index < scalars.count, scalars[index].value >= 0x30, scalars[index].value <= 0x39 {
                throw error(.invalidNumber, "JSON numbers cannot have leading zeroes")
            }
        } else {
            guard index < scalars.count, scalars[index].value >= 0x31, scalars[index].value <= 0x39 else {
                throw error(.invalidNumber, "Invalid JSON number")
            }
            while index < scalars.count, scalars[index].value >= 0x30, scalars[index].value <= 0x39 { index += 1 }
        }
        if take(0x2e) {
            let fractionStart = index
            while index < scalars.count, scalars[index].value >= 0x30, scalars[index].value <= 0x39 { index += 1 }
            guard index > fractionStart else { throw error(.invalidNumber, "JSON fraction requires a digit") }
        }
        if index < scalars.count, (scalars[index].value == 0x65 || scalars[index].value == 0x45) {
            index += 1
            if index < scalars.count, (scalars[index].value == 0x2b || scalars[index].value == 0x2d) { index += 1 }
            let exponentStart = index
            while index < scalars.count, scalars[index].value >= 0x30, scalars[index].value <= 0x39 { index += 1 }
            guard index > exponentStart else { throw error(.invalidNumber, "JSON exponent requires a digit") }
        }
        return try JSONNumber(validating: String(String.UnicodeScalarView(scalars[start..<index])))
    }

    private mutating func consume(_ literal: String) throws {
        for scalar in literal.unicodeScalars {
            guard index < scalars.count, scalars[index] == scalar else {
                throw error(.invalidSyntax, "Invalid JSON literal")
            }
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while index < scalars.count, [0x20, 0x09, 0x0a, 0x0d].contains(scalars[index].value) { index += 1 }
    }

    private mutating func take(_ value: UInt32) -> Bool {
        guard index < scalars.count, scalars[index].value == value else { return false }
        index += 1
        return true
    }

    private func error(_ code: JSONError.Code, _ message: String) -> JSONError {
        JSONError(code, message, offset: index)
    }
}
