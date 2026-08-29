import Foundation
import ZetaCore

public let defaultMaximumCBORByteLength = 16 * 1024 * 1024
public let defaultMaximumCBORContainerLength = 1_000_000
public let defaultMaximumCBORDepth = 64

public struct CBOROptions: Sendable, Equatable {
    public var maximumByteLength: Int
    public var maximumContainerLength: Int
    public var maximumDepth: Int

    public init(
        maximumByteLength: Int = defaultMaximumCBORByteLength,
        maximumContainerLength: Int = defaultMaximumCBORContainerLength,
        maximumDepth: Int = defaultMaximumCBORDepth
    ) {
        self.maximumByteLength = maximumByteLength
        self.maximumContainerLength = maximumContainerLength
        self.maximumDepth = maximumDepth
    }

    public init(
        maxByteLength: Int, maxContainerLength: Int = defaultMaximumCBORContainerLength,
        maxDepth: Int = defaultMaximumCBORDepth
    ) {
        self.init(
            maximumByteLength: maxByteLength,
            maximumContainerLength: maxContainerLength,
            maximumDepth: maxDepth
        )
    }

    fileprivate func validate() throws {
        guard maximumByteLength >= 0, UInt64(maximumByteLength) <= UInt64(UInt32.max) else {
            throw CBORError("maximumByteLength must be an integer between 0 and \(UInt32.max)")
        }
        guard maximumContainerLength >= 0, UInt64(maximumContainerLength) <= UInt64(UInt32.max) else {
            throw CBORError("maximumContainerLength must be an integer between 0 and \(UInt32.max)")
        }
        guard maximumDepth >= 0, maximumDepth <= 512 else {
            throw CBORError("maximumDepth must be an integer between 0 and 512")
        }
    }
}

public struct CBORError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct OrderedCBORMap: Sendable, Equatable, ExpressibleByDictionaryLiteral, RandomAccessCollection {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public var value: CBORValue
        public init(key: String, value: CBORValue) {
            self.key = key
            self.value = value
        }
    }

    private var storage: [Entry]
    public typealias Index = Int

    public init() { storage = [] }

    public init(_ entries: [Entry]) throws {
        var keys = Set<String>()
        for entry in entries where !keys.insert(entry.key).inserted {
            throw CBORError("CBOR map contains a duplicate key")
        }
        storage = entries
    }

    fileprivate init(validatedEntries: [Entry]) {
        storage = validatedEntries
    }

    public init(dictionaryLiteral elements: (String, CBORValue)...) {
        storage = []
        for (key, value) in elements { self[key] = value }
    }

    public var startIndex: Int { storage.startIndex }
    public var endIndex: Int { storage.endIndex }
    public func index(after index: Int) -> Int { storage.index(after: index) }
    public func index(before index: Int) -> Int { storage.index(before: index) }
    public subscript(position: Int) -> Entry { storage[position] }

    public subscript(key: String) -> CBORValue? {
        get { storage.first(where: { $0.key == key })?.value }
        set {
            if let index = storage.firstIndex(where: { $0.key == key }) {
                if let newValue { storage[index].value = newValue } else { storage.remove(at: index) }
            } else if let newValue {
                storage.append(.init(key: key, value: newValue))
            }
        }
    }

    public var entries: [Entry] { storage }

    public mutating func append(key: String, value: CBORValue) throws {
        guard self[key] == nil else { throw CBORError("CBOR map contains a duplicate key") }
        storage.append(.init(key: key, value: value))
    }
}

public indirect enum CBORValue: Sendable, Equatable {
    case null
    case boolean(Bool)
    case integer(Int64)
    case float(Double)
    case byteString(Data)
    case textString(String)
    case array([CBORValue])
    case map(OrderedCBORMap)

    public init(jsonValue: JSONValue) throws {
        switch jsonValue {
        case .null: self = .null
        case let .bool(value): self = .boolean(value)
        case let .number(value):
            if let integer = value.safeIntegerValue, !(value.doubleValue == 0 && value.doubleValue.sign == .minus) {
                self = .integer(integer)
            } else {
                guard !value.isInteger || value.isJavaScriptSafeInteger else {
                    throw CBORError("CBOR integers must be JavaScript-safe integers")
                }
                self = .float(value.doubleValue)
            }
        case let .string(value): self = .textString(value)
        case let .array(values): self = .array(try values.map(CBORValue.init(jsonValue:)))
        case let .object(object):
            self = .map(
                try OrderedCBORMap(
                    object.map {
                        .init(key: $0.key, value: try CBORValue(jsonValue: $0.value))
                    }))
        }
    }

    public func jsonValue() throws -> JSONValue {
        switch self {
        case .null: return .null
        case let .boolean(value): return .bool(value)
        case let .integer(value):
            guard value >= javaScriptMinimumSafeInteger, value <= javaScriptMaximumSafeInteger else {
                throw CBORError("Decoded CBOR integer is outside the safe range")
            }
            return .number(JSONNumber(value))
        case let .float(value): return .number(try JSONNumber(value))
        case .byteString: throw CBORError("CBOR byte strings are not JSON values")
        case let .textString(value): return .string(value)
        case let .array(values): return .array(try values.map { try $0.jsonValue() })
        case let .map(map):
            return .object(
                try OrderedJSONObject(
                    map.map {
                        .init(key: $0.key, value: try $0.value.jsonValue())
                    }))
        }
    }
}

extension CBORValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(stringLiteral value: String) { self = .textString(value) }
    public init(arrayLiteral elements: CBORValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, CBORValue)...) {
        var map = OrderedCBORMap()
        for (key, value) in elements { map[key] = value }
        self = .map(map)
    }
}

private struct CBORWriter {
    private(set) var bytes: [UInt8] = []
    let maximum: Int

    mutating func append(_ byte: UInt8) throws {
        try ensure(1)
        bytes.append(byte)
    }

    mutating func append(contentsOf value: some Sequence<UInt8>) throws {
        let copy = Array(value)
        try ensure(copy.count)
        bytes.append(contentsOf: copy)
    }

    mutating func uint16(_ value: UInt64) throws {
        try append(contentsOf: [UInt8(value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    mutating func uint32(_ value: UInt64) throws {
        try append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value),
        ])
    }

    mutating func uint64(_ value: UInt64) throws {
        try append(
            contentsOf: stride(from: 56, through: 0, by: -8).map { UInt8(truncatingIfNeeded: value >> UInt64($0)) })
    }

    private func ensure(_ additional: Int) throws {
        guard additional <= maximum - bytes.count else {
            throw CBORError("CBOR byte length exceeds configured limit of \(maximum)")
        }
    }
}

public enum CBORCodec {
    public static func encode(_ value: CBORValue, options: CBOROptions = .init()) throws -> Data {
        try options.validate()
        var writer = CBORWriter(maximum: options.maximumByteLength)
        try encode(value, writer: &writer, options: options, depth: 0)
        return Data(writer.bytes)
    }

    public static func decode(_ data: Data, options: CBOROptions = .init()) throws -> CBORValue {
        try options.validate()
        guard data.count <= options.maximumByteLength else {
            throw CBORError("CBOR byte length exceeds configured limit of \(options.maximumByteLength)")
        }
        var reader = CBORReader(bytes: Array(data), options: options)
        return try reader.decode()
    }

    private static func encode(
        _ value: CBORValue,
        writer: inout CBORWriter,
        options: CBOROptions,
        depth: Int
    ) throws {
        guard depth <= options.maximumDepth else {
            throw CBORError("CBOR nesting depth exceeds configured limit of \(options.maximumDepth)")
        }
        switch value {
        case .null: try writer.append(0xf6)
        case let .boolean(value): try writer.append(value ? 0xf5 : 0xf4)
        case let .integer(value):
            guard value >= javaScriptMinimumSafeInteger, value <= javaScriptMaximumSafeInteger else {
                throw CBORError("CBOR integers must be JavaScript-safe integers")
            }
            if value >= 0 {
                try argument(UInt64(value), major: 0, writer: &writer)
            } else {
                try argument(UInt64(-1 - value), major: 1, writer: &writer)
            }
        case let .float(value):
            guard value.isFinite else { throw CBORError("CBOR numbers must be finite") }
            if value.rounded(.towardZero) == value,
                !(value == 0 && value.sign == .minus),
                abs(value) > Double(javaScriptMaximumSafeInteger)
            {
                throw CBORError("CBOR integers must be JavaScript-safe integers")
            }
            try writer.append(0xfb)
            try writer.uint64(value.bitPattern)
        case let .byteString(data):
            guard data.count <= options.maximumByteLength else {
                throw CBORError("CBOR byte string length exceeds configured limit of \(options.maximumByteLength)")
            }
            try argument(UInt64(data.count), major: 2, writer: &writer)
            try writer.append(contentsOf: data)
        case let .textString(string):
            let data = Data(string.utf8)
            guard data.count <= options.maximumByteLength else {
                throw CBORError("CBOR text string length exceeds configured limit of \(options.maximumByteLength)")
            }
            try argument(UInt64(data.count), major: 3, writer: &writer)
            try writer.append(contentsOf: data)
        case let .array(values):
            guard values.count <= options.maximumContainerLength else {
                throw CBORError("CBOR array length exceeds configured limit of \(options.maximumContainerLength)")
            }
            try argument(UInt64(values.count), major: 4, writer: &writer)
            for value in values { try encode(value, writer: &writer, options: options, depth: depth + 1) }
        case let .map(map):
            guard map.count <= options.maximumContainerLength else {
                throw CBORError("CBOR map length exceeds configured limit of \(options.maximumContainerLength)")
            }
            try argument(UInt64(map.count), major: 5, writer: &writer)
            for entry in map {
                try encode(.textString(entry.key), writer: &writer, options: options, depth: depth + 1)
                try encode(entry.value, writer: &writer, options: options, depth: depth + 1)
            }
        }
    }

    private static func argument(_ value: UInt64, major: UInt8, writer: inout CBORWriter) throws {
        let prefix = major << 5
        switch value {
        case 0..<24: try writer.append(prefix | UInt8(value))
        case 24...0xff:
            try writer.append(prefix | 24)
            try writer.append(UInt8(value))
        case 0x100...0xffff:
            try writer.append(prefix | 25)
            try writer.uint16(value)
        case 0x1_0000...0xffff_ffff:
            try writer.append(prefix | 26)
            try writer.uint32(value)
        default:
            try writer.append(prefix | 27)
            try writer.uint64(value)
        }
    }
}

private struct CBORReader {
    let bytes: [UInt8]
    let options: CBOROptions
    var offset = 0

    mutating func decode() throws -> CBORValue {
        let value = try item(depth: 0)
        guard offset == bytes.count else { throw CBORError("CBOR payload contains trailing data") }
        return value
    }

    private mutating func item(depth: Int) throws -> CBORValue {
        guard depth <= options.maximumDepth else {
            throw CBORError("CBOR nesting depth exceeds configured limit of \(options.maximumDepth)")
        }
        let initial = try byte()
        let major = initial >> 5
        let info = initial & 0x1f
        switch major {
        case 0:
            let value = try argument(info)
            guard value <= UInt64(javaScriptMaximumSafeInteger) else {
                throw CBORError("Decoded CBOR integer is outside the safe range")
            }
            return .integer(Int64(value))
        case 1:
            let argument = try argument(info)
            guard argument <= UInt64(javaScriptMaximumSafeInteger - 1) else {
                throw CBORError("Decoded CBOR integer is outside the safe range")
            }
            return .integer(-1 - Int64(argument))
        case 2:
            let length = try length(info, kind: "byte string", limit: options.maximumByteLength)
            return .byteString(Data(try read(length)))
        case 3:
            let length = try length(info, kind: "text string", limit: options.maximumByteLength)
            let text = try read(length)
            guard Self.isValidUTF8(text) else { throw CBORError("CBOR text string contains invalid UTF-8") }
            return .textString(String(decoding: text, as: UTF8.self))
        case 4:
            let count = try length(info, kind: "array", limit: options.maximumContainerLength)
            var values: [CBORValue] = []
            values.reserveCapacity(min(count, 4_096))
            for _ in 0..<count { values.append(try item(depth: depth + 1)) }
            return .array(values)
        case 5:
            let count = try length(info, kind: "map", limit: options.maximumContainerLength)
            var entries: [OrderedCBORMap.Entry] = []
            entries.reserveCapacity(min(count, 4_096))
            var keys = Set<String>()
            keys.reserveCapacity(min(count, 4_096))
            for _ in 0..<count {
                guard case let .textString(key) = try item(depth: depth + 1) else {
                    throw CBORError("CBOR map keys must be strings")
                }
                guard keys.insert(key).inserted else {
                    throw CBORError("CBOR map contains a duplicate key")
                }
                entries.append(
                    .init(key: key, value: try item(depth: depth + 1))
                )
            }
            return .map(OrderedCBORMap(validatedEntries: entries))
        case 6:
            throw CBORError("CBOR tags are not supported")
        case 7:
            return try simple(info)
        default:
            throw CBORError("Malformed CBOR major type")
        }
    }

    private mutating func simple(_ info: UInt8) throws -> CBORValue {
        switch info {
        case 20: return .boolean(false)
        case 21: return .boolean(true)
        case 22: return .null
        case 27:
            let bits = try readUInt64()
            let value = Double(bitPattern: bits)
            guard value.isFinite else { throw CBORError("Decoded CBOR number must be finite") }
            if value.rounded(.towardZero) == value, abs(value) > Double(javaScriptMaximumSafeInteger) {
                throw CBORError("Decoded CBOR integer is outside the safe range")
            }
            return .float(value)
        case 31: throw CBORError("CBOR break marker is not supported")
        default: throw CBORError("Unsupported CBOR simple value or floating-point width")
        }
    }

    private mutating func length(_ info: UInt8, kind: String, limit: Int) throws -> Int {
        guard info != 31 else { throw CBORError("Indefinite-length CBOR \(kind)s are not supported") }
        let value = try argument(info)
        guard value <= UInt64(limit) else {
            throw CBORError("CBOR \(kind) length exceeds configured limit of \(limit)")
        }
        return Int(value)
    }

    private mutating func argument(_ info: UInt8) throws -> UInt64 {
        switch info {
        case 0..<24: return UInt64(info)
        case 24: return UInt64(try byte())
        case 25:
            return try read(2).reduce(0) { $0 << 8 | UInt64($1) }
        case 26: return try readUInt32()
        case 27: return try readUInt64()
        case 31: throw CBORError("Indefinite-length CBOR items are not supported")
        default: throw CBORError("Malformed CBOR additional information")
        }
    }

    private mutating func readUInt32() throws -> UInt64 {
        let value = try read(4)
        return value.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func readUInt64() throws -> UInt64 {
        let value = try read(8)
        return value.reduce(0) { $0 << 8 | UInt64($1) }
    }

    private mutating func byte() throws -> UInt8 {
        guard offset < bytes.count else { throw CBORError("Truncated CBOR payload") }
        defer { offset += 1 }
        return bytes[offset]
    }

    private mutating func read(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count <= bytes.count - offset else { throw CBORError("Truncated CBOR payload") }
        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }

    private static func isValidUTF8(_ bytes: ArraySlice<UInt8>) -> Bool {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let first = bytes[index]
            if first <= 0x7f {
                index += 1
                continue
            }
            let count: Int
            let minimum: UInt32
            var scalar: UInt32
            switch first {
            case 0xc2...0xdf:
                count = 2
                minimum = 0x80
                scalar = UInt32(first & 0x1f)
            case 0xe0...0xef:
                count = 3
                minimum = 0x800
                scalar = UInt32(first & 0x0f)
            case 0xf0...0xf4:
                count = 4
                minimum = 0x10000
                scalar = UInt32(first & 0x07)
            default: return false
            }
            guard index + count <= bytes.endIndex else { return false }
            for continuation in 1..<count {
                let byte = bytes[index + continuation]
                guard byte & 0xc0 == 0x80 else { return false }
                scalar = scalar << 6 | UInt32(byte & 0x3f)
            }
            guard scalar >= minimum, scalar <= 0x10ffff, !(scalar >= 0xd800 && scalar <= 0xdfff) else { return false }
            index += count
        }
        return true
    }
}

public func encodeCBOR(_ value: CBORValue, options: CBOROptions = .init()) throws -> Data {
    try CBORCodec.encode(value, options: options)
}

public func decodeCBOR(_ data: Data, options: CBOROptions = .init()) throws -> CBORValue {
    try CBORCodec.decode(data, options: options)
}

public func encodeCbor(_ value: CBORValue, options: CBOROptions = .init()) throws -> Data {
    try encodeCBOR(value, options: options)
}

public func decodeCbor(_ data: Data, options: CBOROptions = .init()) throws -> CBORValue {
    try decodeCBOR(data, options: options)
}
