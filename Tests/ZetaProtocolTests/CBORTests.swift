import Foundation
import Testing
import ZetaCore

@testable import ZetaProtocol

@Suite struct CBORTests {
    @Test func pinnedRFC8949Vectors() throws {
        let vectors: [(CBORValue, String)] = [
            (.null, "f6"), (.boolean(false), "f4"), (.boolean(true), "f5"),
            (.integer(0), "00"), (.integer(1), "01"), (.integer(10), "0a"), (.integer(23), "17"),
            (.integer(24), "1818"), (.integer(25), "1819"), (.integer(100), "1864"),
            (.integer(1_000), "1903e8"), (.integer(1_000_000), "1a000f4240"),
            (.integer(1_000_000_000_000), "1b000000e8d4a51000"),
            (.integer(9_007_199_254_740_991), "1b001fffffffffffff"),
            (.integer(-1), "20"), (.integer(-10), "29"), (.integer(-24), "37"),
            (.integer(-25), "3818"), (.integer(-100), "3863"), (.integer(-1_000), "3903e7"),
            (.integer(-1_000_000), "3a000f423f"), (.integer(-9_007_199_254_740_991), "3b001ffffffffffffe"),
            (.float(1.1), "fb3ff199999999999a"), (.float(-0.0), "fb8000000000000000"),
            (.byteString(Data([1, 2, 3, 4])), "4401020304"), (.textString(""), "60"),
            (.textString("IETF"), "6449455446"), (.textString("ü"), "62c3bc"),
            (.textString("水"), "63e6b0b4"), (.textString("𐅑"), "64f0908591"),
            (.array([]), "80"), (.array([1, 2, 3]), "83010203"),
            (.array([1, [2, 3], [4, 5]]), "8301820203820405"),
            (.map(["a": 1, "b": [2, 3]]), "a26161016162820203"),
        ]
        for (value, hex) in vectors {
            #expect(try encodeCBOR(value).hex == hex)
            let decoded = try decodeCBOR(Data(hex: hex))
            if case .float(let expected) = value, expected == 0, expected.sign == .minus {
                guard case let .float(actual) = decoded else {
                    Issue.record("Expected float")
                    continue
                }
                #expect(actual.sign == .minus)
            } else {
                #expect(decoded == value)
            }
        }
    }

    @Test func preservesBOMAndProtoKeyData() throws {
        #expect(try decodeCBOR(Data(hex: "63efbbbf")) == .textString("\u{feff}"))
        #expect(try decodeCBOR(Data(hex: "a1695f5f70726f746f5f5f6473616665")) == .map(["__proto__": "safe"]))
    }

    @Test func acceptsNonminimalIntegers() throws {
        #expect(try decodeCBOR(Data(hex: "1800")) == .integer(0))
        #expect(try decodeCBOR(Data(hex: "190017")) == .integer(23))
        #expect(try decodeCBOR(Data(hex: "1a00000018")) == .integer(24))
    }

    @Test func rejectsInvalidDecoderInputs() {
        let invalid = [
            "", "18", "1c", "5f", "7f", "9f", "bf", "c000", "f7", "e0", "ff",
            "f93c00", "fa3f800000", "fb7ff0000000000000", "fb7ff8000000000000", "fb3ff00000",
            "44010203", "636162", "8201", "a16161", "0000", "a10102", "a2616101616102",
            "61ff", "62c080", "63eda080", "1b0020000000000000", "3b001fffffffffffff", "fb4340000000000000",
        ]
        for hex in invalid { expectCBORThrow { try decodeCBOR(Data(hex: hex)) } }
    }

    @Test func rejectsInvalidEncoderValues() {
        for value in [
            CBORValue.integer(9_007_199_254_740_992), .integer(-9_007_199_254_740_992),
            .float(.nan), .float(.infinity), .float(9_007_199_254_740_992),
        ] { expectCBORThrow { try encodeCBOR(value) } }
    }

    @Test func depthAndDeclaredLengthLimits() {
        var tooDeep = Data(repeating: 0x81, count: defaultMaximumCBORDepth + 1)
        tooDeep.append(0xf6)
        expectCBORThrow { try decodeCBOR(tooDeep) }
        expectCBORThrow { try decodeCBOR(Data(hex: "5a01000001"), options: .init(maximumByteLength: 16 * 1024 * 1024)) }
        expectCBORThrow { try decodeCBOR(Data(hex: "9a00000003"), options: .init(maximumContainerLength: 2)) }
        expectCBORThrow { try encodeCBOR(.array([1, 2, 3]), options: .init(maximumContainerLength: 2)) }
        expectCBORThrow { try encodeCBOR(.textString("ab"), options: .init(maximumByteLength: 2)) }
    }

    @Test func jsonConversionRejectsByteStringsAndUnsafeValues() throws {
        expectCBORThrow { try CBORValue.byteString(Data([1])).jsonValue() }
        let json: JSONValue = ["a": [1, true, nil], "b": "text"]
        #expect(try CBORValue(jsonValue: json).jsonValue() == json)
    }
}

private func expectCBORThrow<Value>(_ body: () throws -> Value) {
    do {
        _ = try body()
        Issue.record("Expected operation to throw")
    } catch {}
}

private extension Data {
    init(hex: String) {
        precondition(hex.count.isMultiple(of: 2))
        self.init(
            stride(from: 0, to: hex.count, by: 2).map { offset in
                let start = hex.index(hex.startIndex, offsetBy: offset)
                return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
            })
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
