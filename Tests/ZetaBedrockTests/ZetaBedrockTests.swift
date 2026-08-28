import Foundation
import XCTest

@testable import ZetaBedrock

final class ZetaBedrockTests: XCTestCase {
    func testEventStreamFragmentationHeadersAndCRC() throws {
        let message = eventMessage(
            headers: [":message-type": "event", ":event-type": "chunk"],
            payload: Data("{\"contentBlockDelta\":{}}".utf8)
        )
        for split in 1..<message.count {
            var decoder = AWSEventStreamDecoder()
            XCTAssertTrue(try decoder.push(Data(message[..<split])).isEmpty)
            let decoded = try decoder.push(Data(message[split...]))
            XCTAssertEqual(decoded.count, 1)
            XCTAssertEqual(decoded[0].headers[":event-type"], "chunk")
            try decoder.finish()
        }
    }

    func testEventStreamRejectsCRCAndTruncation() throws {
        var corrupted = eventMessage(headers: [:], payload: Data("x".utf8))
        corrupted[corrupted.count - 1] ^= 0xFF
        var decoder = AWSEventStreamDecoder()
        XCTAssertThrowsError(try decoder.push(corrupted))
        var truncated = AWSEventStreamDecoder()
        _ = try truncated.push(Data(eventMessage(headers: [:], payload: Data()).dropLast()))
        XCTAssertThrowsError(try truncated.finish())
    }
}

private func eventMessage(headers: [String: String], payload: Data) -> Data {
    var headerData = Data()
    for key in headers.keys.sorted() {
        let name = Data(key.utf8)
        let value = Data(headers[key]!.utf8)
        headerData.append(UInt8(name.count))
        headerData.append(name)
        headerData.append(7)
        headerData.append(UInt8(value.count >> 8))
        headerData.append(UInt8(value.count & 0xFF))
        headerData.append(value)
    }
    let total = 16 + headerData.count + payload.count
    var message = Data()
    message.appendUInt32(UInt32(total))
    message.appendUInt32(UInt32(headerData.count))
    message.appendUInt32(crc32(message))
    message.append(headerData)
    message.append(payload)
    message.appendUInt32(crc32(message))
    return message
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0)
        }
    }
    return crc ^ 0xFFFF_FFFF
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
