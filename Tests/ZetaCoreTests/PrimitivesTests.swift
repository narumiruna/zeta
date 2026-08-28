import Foundation
import Testing

@testable import ZetaCore

@Suite struct PrimitivesTests {
    @Test func uuidv7MatchesPinnedSourceVectorAndMonotonicOverflow() throws {
        let random = LockedRandomSequence([
            [0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xfe, 0x01, 0x11, 0x22, 0x33, 0x44, 0x55],
            [UInt8](repeating: 0, count: 16), [UInt8](repeating: 0, count: 16),
        ])
        let generator = UUIDv7Generator(clock: { 0x0123456789ab }, randomBytes: { random.next() })
        let first = try generator.next()
        let second = try generator.next()
        let third = try generator.next()
        #expect(first.rawValue == "01234567-89ab-7fff-bfff-f91122334455")
        #expect(second.rawValue == "01234567-89ab-7fff-bfff-fc0000000000")
        #expect(third.rawValue == "01234567-89ac-7000-8000-000000000000")
        #expect(first.timestamp.rawValue == 0x0123456789ab)
        #expect(first < second && second < third)
    }

    @Test func uuidv7Validation() throws {
        _ = try UUIDv7(rawValue: "018f47d2-4e80-7000-8000-000000000000")
        for invalid in [
            "018f47d2-4e80-6000-8000-000000000000", "018f47d2-4e80-7000-7000-000000000000",
            "018F47D2-4E80-7000-8000-000000000000", "not-a-uuid",
        ] { expectPrimitiveThrow { try UUIDv7(rawValue: invalid) } }
    }

    @Test func base64RequiresCanonicalEncoding() throws {
        let content = Base64Content(data: Data([0, 1, 2, 0xff]))
        #expect(content.rawValue == "AAEC/w==")
        #expect(content.data == Data([0, 1, 2, 0xff]))
        _ = try Base64Content(rawValue: "")
        for invalid in ["AAEC/w", "AAEC/w=", "AAEC/w==\n", "AB=="] {
            expectPrimitiveThrow { try Base64Content(rawValue: invalid) }
        }
    }

    @Test func timestampAndStableErrorNormalization() throws {
        let timestamp = try MillisecondTimestamp(rawValue: 1_234)
        #expect(try MillisecondTimestamp(date: timestamp.date).rawValue == 1_234)
        expectPrimitiveThrow { try MillisecondTimestamp(rawValue: -1) }
        expectPrimitiveThrow { try MillisecondTimestamp(rawValue: javaScriptMaximumSafeInteger + 1) }
        let normalized = NormalizedError.normalize(
            TestError(message: String(repeating: "x", count: 20)), maximumMessageLength: 10)
        #expect(normalized.name.contains("TestError"))
        #expect(normalized.message.count == 10)
        #expect(normalized.message.hasSuffix("..."))
    }
}

private struct TestError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func expectPrimitiveThrow<Value>(_ body: () throws -> Value) {
    do {
        _ = try body()
        Issue.record("Expected operation to throw")
    } catch {}
}

private final class LockedRandomSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[UInt8]]
    init(_ values: [[UInt8]]) { self.values = values }
    func next() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return values.removeFirst()
    }
}
