import Foundation

public let defaultMaximumFrameLength = 16 * 1024 * 1024
private let frameHeaderLength = 4

public struct FrameDecoderOptions: Sendable, Equatable {
    public var maximumFrameLength: Int

    public init(maximumFrameLength: Int = defaultMaximumFrameLength) {
        self.maximumFrameLength = maximumFrameLength
    }

    public init(maxFrameLength: Int) {
        self.init(maximumFrameLength: maxFrameLength)
    }

    public var maxFrameLength: Int {
        get { maximumFrameLength }
        set { maximumFrameLength = newValue }
    }

    fileprivate func validate() throws {
        guard maximumFrameLength >= 0, UInt64(maximumFrameLength) <= UInt64(UInt32.max) else {
            throw FrameError("maximumFrameLength must be an integer between 0 and \(UInt32.max)")
        }
    }
}

public struct FrameError: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Prefixes a copied payload with its unsigned 32-bit big-endian byte length.
public func encodeFrame(_ payload: Data) throws -> Data {
    guard UInt64(payload.count) <= UInt64(UInt32.max) else {
        throw FrameError("Frame payload exceeds the unsigned 32-bit length limit")
    }
    let length = UInt32(payload.count)
    var frame = Data([
        UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
        UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length),
    ])
    frame.append(payload)
    return frame
}

public func assertCompleteFrame(_ frame: Data, options: FrameDecoderOptions = .init()) throws {
    try options.validate()
    guard frame.count >= frameHeaderLength else {
        throw FrameError("Frame does not contain a complete length prefix")
    }
    let length = frame.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    guard length <= UInt64(options.maximumFrameLength) else {
        throw FrameError("Frame length \(length) exceeds configured limit of \(options.maximumFrameLength)")
    }
    guard UInt64(frame.count) == UInt64(frameHeaderLength) + length else {
        throw FrameError("Frame must contain exactly one complete payload")
    }
}

public final class FrameDecoder: @unchecked Sendable {
    private enum State { case open, ended, failed }

    private let lock = NSLock()
    private let maximumFrameLength: Int
    private var state = State.open
    private var header: [UInt8] = []
    private var expectedPayloadLength: Int?
    private var payload = Data()

    public init(options: FrameDecoderOptions = .init()) throws {
        try options.validate()
        maximumFrameLength = options.maximumFrameLength
        header.reserveCapacity(frameHeaderLength)
    }

    /// Splits arbitrary fragmentation/coalescing and returns detached payload copies.
    public func push(_ chunk: Data) throws -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .ended: throw FrameError("Frame decoder has ended")
        case .failed: throw FrameError("Frame decoder has failed")
        case .open: break
        }

        var frames: [Data] = []
        let bytes = [UInt8](chunk)
        var offset = 0
        while offset < bytes.count {
            if expectedPayloadLength == nil {
                let headerCount = min(frameHeaderLength - header.count, bytes.count - offset)
                header.append(contentsOf: bytes[offset..<(offset + headerCount)])
                offset += headerCount
                if header.count < frameHeaderLength { continue }

                let declared = header.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                header.removeAll(keepingCapacity: true)
                guard declared <= UInt64(maximumFrameLength) else {
                    try fail("Frame length \(declared) exceeds configured limit of \(maximumFrameLength)")
                }
                let length = Int(declared)
                if length == 0 {
                    frames.append(Data())
                    continue
                }
                expectedPayloadLength = length
                payload = Data()
                payload.reserveCapacity(length)
            }

            guard let expectedPayloadLength else { continue }
            let payloadCount = min(expectedPayloadLength - payload.count, bytes.count - offset)
            payload.append(contentsOf: bytes[offset..<(offset + payloadCount)])
            offset += payloadCount
            if payload.count == expectedPayloadLength {
                frames.append(Data(payload))
                payload = Data()
                self.expectedPayloadLength = nil
            }
        }
        return frames
    }

    public func end() throws {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .ended: throw FrameError("Frame decoder has ended")
        case .failed: throw FrameError("Frame decoder has failed")
        case .open: break
        }
        guard header.isEmpty, expectedPayloadLength == nil else {
            try fail("Truncated frame at end of stream")
        }
        state = .ended
    }

    private func fail(_ message: String) throws -> Never {
        state = .failed
        header.removeAll(keepingCapacity: false)
        expectedPayloadLength = nil
        payload = Data()
        throw FrameError(message)
    }
}
