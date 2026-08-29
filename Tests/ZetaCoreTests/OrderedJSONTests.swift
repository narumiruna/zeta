import Foundation
import Testing

@testable import ZetaCore

@Suite struct OrderedJSONTests {
    @Test func preservesObjectOrderAndNumberSpellings() throws {
        let source = #"{"z":1.0,"a":-0,"nested":{"first":true,"second":null}}"#
        let value = try OrderedJSON.decode(source)
        guard case let .object(object) = value else {
            Issue.record("Expected object")
            return
        }
        #expect(object.keys == ["z", "a", "nested"])
        #expect(OrderedJSON.string(value) == source)
    }

    @Test func rejectsDuplicateKeysAndInvalidUnicodeEscapes() throws {
        expectJSONThrow { try OrderedJSON.decode(#"{"a":1,"a":2}"#) }
        for source in [#""\ud800""#, #""\udc00""#, #""\ud800\u0041""#] {
            expectJSONThrow { try OrderedJSON.decode(source) }
        }
        #expect(try OrderedJSON.decode(#""\ud800\udc00""#) == .string("𐀀"))
    }

    @Test func rejectsMalformedAndNonfiniteNumbers() throws {
        for source in ["01", "-", "1.", "1e", "+1", "1e400"] {
            expectJSONThrow { try OrderedJSON.decode(source) }
        }
        #expect(try JSONNumber(validating: "9007199254740991").isJavaScriptSafeInteger)
        #expect(try !JSONNumber(validating: "9007199254740992").isJavaScriptSafeInteger)
        #expect(try JSONNumber(validating: "1.0").isInteger)
    }

    @Test func rejectsInvalidUTF8AndLimits() {
        expectJSONThrow { try OrderedJSON.decode(Data([0xff])) }
        expectJSONThrow { try OrderedJSON.decode("[1,2]", limits: .init(maximumContainerCount: 1)) }
        expectJSONThrow { try OrderedJSON.decode("[[null]]", limits: .init(maximumDepth: 1)) }
        expectJSONThrow { try OrderedJSON.decode("null", limits: .init(maximumByteCount: 3)) }
    }

    @Test func escapingAndPrettyEncodingAreStable() throws {
        let value: JSONValue = ["control": .string("\u{0}\n\"\\"), "array": [1, "水"]]
        let compact = OrderedJSON.string(value)
        #expect(try OrderedJSON.decode(compact) == value)
        #expect(
            OrderedJSON.string(value, options: .init(prettyPrinted: true))
                == "{\n  \"control\": \"\\u0000\\n\\\"\\\\\",\n  \"array\": [\n    1,\n    \"水\"\n  ]\n}"
        )
    }

    @Test func parsesLargeUniqueKeyObjectsWithoutQuadraticDuplicateChecks() throws {
        let source = "{" + (0..<50_000).map { "\"key\($0)\":\($0)" }.joined(separator: ",") + "}"
        guard case .object(let object) = try OrderedJSON.decode(source) else {
            Issue.record("Expected object")
            return
        }
        #expect(object.count == 50_000)
        #expect(object.keys.first == "key0")
        #expect(object.keys.last == "key49999")
    }

    @Test func randomizedRoundTrips() throws {
        var generator = SeededGenerator(seed: 0x56700d42)
        for _ in 0..<500 {
            let value = randomValue(depth: 0, using: &generator)
            #expect(try OrderedJSON.decode(OrderedJSON.encode(value)) == value)
        }
    }

    private func randomValue(depth: Int, using generator: inout SeededGenerator) -> JSONValue {
        let choice = depth >= 4 ? Int(generator.next() % 4) : Int(generator.next() % 6)
        switch choice {
        case 0: return .null
        case 1: return .bool(generator.next() & 1 == 0)
        case 2: return .number(JSONNumber(Int64(generator.next() % 1_000) - 500))
        case 3: return .string(["", "ascii", "水", "😀", "quote\"\n"][Int(generator.next() % 5)])
        case 4:
            return .array((0..<Int(generator.next() % 5)).map { _ in randomValue(depth: depth + 1, using: &generator) })
        default:
            var object = OrderedJSONObject()
            for index in 0..<Int(generator.next() % 5) {
                object["k\(index)"] = randomValue(depth: depth + 1, using: &generator)
            }
            return .object(object)
        }
    }
}

private func expectJSONThrow<Value>(_ body: () throws -> Value) {
    do {
        _ = try body()
        Issue.record("Expected operation to throw")
    } catch {}
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58476d1ce4e5b9
        value = (value ^ (value >> 27)) &* 0x94d049bb133111eb
        return value ^ (value >> 31)
    }
}
