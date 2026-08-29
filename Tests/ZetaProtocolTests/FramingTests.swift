import Foundation
import Testing

@testable import ZetaProtocol

@Suite struct FramingTests {
    @Test func fourByteBigEndianPrefix() throws {
        #expect(try encodeFrame(Data([0xaa, 0xbb, 0xcc])) == Data([0, 0, 0, 3, 0xaa, 0xbb, 0xcc]))
        #expect(try encodeFrame(Data()) == Data([0, 0, 0, 0]))
    }

    @Test func completeFrameValidation() throws {
        try assertCompleteFrame(Data([0, 0, 0, 2, 1, 2]), options: .init(maximumFrameLength: 2))
        expectFrameThrow { try assertCompleteFrame(Data([0, 0, 0, 2, 1])) }
        expectFrameThrow { try assertCompleteFrame(Data([0, 0, 0, 1, 1, 2])) }
        expectFrameThrow {
            try assertCompleteFrame(Data([0, 0, 0, 3, 1, 2, 3]), options: .init(maximumFrameLength: 2))
        }
    }

    @Test func fragmentedCoalescedAndEmptyFrames() throws {
        let expected = [Data([1, 2, 3]), Data(), Data([4])]
        let wire = try expected.map(encodeFrame).reduce(into: Data()) { $0.append($1) }
        let fragmented = try FrameDecoder()
        var frames: [Data] = []
        for byte in wire { frames += try fragmented.push(Data([byte])) }
        try fragmented.end()
        #expect(frames == expected)
        let coalesced = try FrameDecoder()
        #expect(try coalesced.push(wire) == expected)
        try coalesced.end()
    }

    @Test func everySplitPointAndPayloadCopyOwnership() throws {
        let wire = try encodeFrame(Data([10, 20, 30, 40]))
        for split in 0...wire.count {
            let decoder = try FrameDecoder()
            let frames = try decoder.push(wire.prefix(split)) + decoder.push(wire.suffix(wire.count - split))
            try decoder.end()
            #expect(frames == [Data([10, 20, 30, 40])])
        }
        var mutable = try encodeFrame(Data([1, 2, 3]))
        let decoder = try FrameDecoder()
        let frames = try decoder.push(mutable)
        mutable.resetBytes(in: 0..<mutable.count)
        #expect(frames == [Data([1, 2, 3])])
    }

    @Test func payloadSpanningLargeChunks() throws {
        let payload = Data((0..<70_000).map { UInt8($0 % 251) })
        let wire = try encodeFrame(payload)
        let decoder = try FrameDecoder()
        var frames = try decoder.push(wire.prefix(101))
        frames += try decoder.push(wire[101..<65_541])
        frames += try decoder.push(wire.suffix(from: 65_541))
        try decoder.end()
        #expect(frames == [payload])
    }

    @Test func stickyOversizedAndTruncatedFailures() throws {
        for wire in [Data([0, 0, 0]), Data([0, 0, 0, 2, 1])] {
            let decoder = try FrameDecoder()
            #expect(try decoder.push(wire) == [])
            expectFrameThrow { try decoder.end() }
            expectFrameThrow { try decoder.push(Data()) }
        }
        let oversized = try FrameDecoder(options: .init(maximumFrameLength: 3))
        expectFrameThrow { try oversized.push(Data([0, 0, 0, 4])) }
        expectFrameThrow { try oversized.push(Data([1])) }
    }

    @Test func stateAndBoundaryConditions() throws {
        let maximum = try FrameDecoder(options: .init(maximumFrameLength: 3))
        #expect(try maximum.push(encodeFrame(Data([1, 2, 3]))) == [Data([1, 2, 3])])
        try maximum.end()
        expectFrameThrow { try maximum.push(Data()) }
        expectFrameThrow { try maximum.end() }
        let empty = try FrameDecoder()
        #expect(try empty.push(Data()) == [])
        try empty.end()
        expectFrameThrow { try FrameDecoder(options: .init(maximumFrameLength: -1)) }
    }
}

private func expectFrameThrow<Value>(_ body: () throws -> Value) {
    do {
        _ = try body()
        Issue.record("Expected operation to throw")
    } catch {}
}
