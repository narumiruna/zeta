import Foundation

public enum PrimitiveValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case timestampOutOfRange
    case invalidBase64
    case invalidUUIDv7
    case invalidRandomByteCount

    public var description: String {
        switch self {
        case .timestampOutOfRange: "Timestamp must be a nonnegative JavaScript-safe millisecond integer"
        case .invalidBase64: "Content must be canonical RFC 4648 base64"
        case .invalidUUIDv7: "Value must be an RFC 9562 UUIDv7 string"
        case .invalidRandomByteCount: "UUIDv7 random source must return exactly 16 bytes"
        }
    }
}

public struct MillisecondTimestamp: Codable, Sendable, Hashable, Comparable {
    public let rawValue: Int64

    public init(rawValue: Int64) throws {
        guard rawValue >= 0, rawValue <= javaScriptMaximumSafeInteger else {
            throw PrimitiveValidationError.timestampOutOfRange
        }
        self.rawValue = rawValue
    }

    public init(date: Date) throws {
        let milliseconds = date.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite,
            milliseconds >= 0,
            milliseconds <= Double(javaScriptMaximumSafeInteger)
        else { throw PrimitiveValidationError.timestampOutOfRange }
        try self.init(rawValue: Int64(milliseconds.rounded()))
    }

    public var date: Date { Date(timeIntervalSince1970: Double(rawValue) / 1_000) }

    public static func < (lhs: MillisecondTimestamp, rhs: MillisecondTimestamp) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int64.self)
        try self.init(rawValue: value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Base64Content: Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard let decoded = Data(base64Encoded: rawValue), decoded.base64EncodedString() == rawValue else {
            throw PrimitiveValidationError.invalidBase64
        }
        self.rawValue = rawValue
    }

    public init(data: Data) {
        rawValue = data.base64EncodedString()
    }

    public var data: Data { Data(base64Encoded: rawValue)! }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct UUIDv7: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        let hyphens = Set([8, 13, 18, 23])
        guard bytes.count == 36,
            bytes.enumerated().allSatisfy({ index, byte in
                hyphens.contains(index) ? byte == 0x2d : Self.isLowercaseHex(byte)
            }),
            bytes[14] == 0x37,
            [0x38, 0x39, 0x61, 0x62].contains(bytes[19])
        else { throw PrimitiveValidationError.invalidUUIDv7 }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public var timestamp: MillisecondTimestamp {
        let prefix = rawValue.replacingOccurrences(of: "-", with: "").prefix(12)
        return try! MillisecondTimestamp(rawValue: Int64(prefix, radix: 16)!)
    }

    public static func < (lhs: UUIDv7, rhs: UUIDv7) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: any Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }
}

/// Thread-safe UUIDv7 generator with injectable deterministic time and randomness.
public final class UUIDv7Generator: @unchecked Sendable {
    public typealias Clock = @Sendable () -> Int64
    public typealias RandomBytes = @Sendable () -> [UInt8]

    private let lock = NSLock()
    private let clock: Clock
    private let randomBytes: RandomBytes
    private var lastTimestamp = Int64.min
    private var sequence: UInt32 = 0

    public init(
        clock: @escaping Clock = { Int64(Date().timeIntervalSince1970 * 1_000) },
        randomBytes: @escaping RandomBytes = { (0..<16).map { _ in UInt8.random(in: .min ... .max) } }
    ) {
        self.clock = clock
        self.randomBytes = randomBytes
    }

    public func next() throws -> UUIDv7 {
        lock.lock()
        defer { lock.unlock() }

        let random = randomBytes()
        guard random.count == 16 else { throw PrimitiveValidationError.invalidRandomByteCount }
        let timestamp = clock()
        if timestamp > lastTimestamp {
            sequence =
                UInt32(random[6]) << 24
                | UInt32(random[7]) << 16
                | UInt32(random[8]) << 8
                | UInt32(random[9])
            lastTimestamp = timestamp
        } else {
            sequence &+= 1
            if sequence == 0 { lastTimestamp &+= 1 }
        }
        guard lastTimestamp >= 0, lastTimestamp <= 0x0000_ffff_ffff_ffff else {
            throw PrimitiveValidationError.timestampOutOfRange
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[0] = UInt8(truncatingIfNeeded: lastTimestamp >> 40)
        bytes[1] = UInt8(truncatingIfNeeded: lastTimestamp >> 32)
        bytes[2] = UInt8(truncatingIfNeeded: lastTimestamp >> 24)
        bytes[3] = UInt8(truncatingIfNeeded: lastTimestamp >> 16)
        bytes[4] = UInt8(truncatingIfNeeded: lastTimestamp >> 8)
        bytes[5] = UInt8(truncatingIfNeeded: lastTimestamp)
        bytes[6] = 0x70 | UInt8((sequence >> 28) & 0x0f)
        bytes[7] = UInt8((sequence >> 20) & 0xff)
        bytes[8] = 0x80 | UInt8((sequence >> 14) & 0x3f)
        bytes[9] = UInt8((sequence >> 6) & 0xff)
        bytes[10] = UInt8((sequence & 0x3f) << 2) | (random[10] & 0x03)
        bytes[11...15] = random[11...15]

        let hex = bytes.map { String(format: "%02x", $0) }
        let value =
            hex[0...3].joined() + "-"
            + hex[4...5].joined() + "-"
            + hex[6...7].joined() + "-"
            + hex[8...9].joined() + "-"
            + hex[10...15].joined()
        return try UUIDv7(rawValue: value)
    }

    public static let shared = UUIDv7Generator()
}

public func uuidv7() -> String {
    try! UUIDv7Generator.shared.next().rawValue
}

public struct NormalizedError: Sendable, Equatable, Codable {
    public let name: String
    public let message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }

    public static func normalize(_ error: any Error, maximumMessageLength: Int = 500) -> NormalizedError {
        let name = String(reflecting: type(of: error))
        let rawMessage = String(describing: error)
        guard maximumMessageLength >= 0, rawMessage.count > maximumMessageLength else {
            return NormalizedError(name: name, message: rawMessage)
        }
        if maximumMessageLength <= 3 {
            return NormalizedError(name: name, message: String(rawMessage.prefix(maximumMessageLength)))
        }
        return NormalizedError(name: name, message: String(rawMessage.prefix(maximumMessageLength - 3)) + "...")
    }
}
