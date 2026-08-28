import Foundation
import ZetaCore

private func boundedCodecMessage(_ error: any Error) -> String {
    let message = String(describing: error)
    return message.count <= 500 ? message : String(message.prefix(497)) + "..."
}

private func encodeProtocolMessage<Message>(
    _ value: JSONValue,
    kind: String,
    options: FrameDecoderOptions,
    parse: (JSONValue) throws -> Message
) throws -> Data {
    do {
        _ = try parse(value)
        let payload = try encodeCBOR(
            CBORValue(jsonValue: value),
            options: .init(maximumByteLength: options.maximumFrameLength)
        )
        let frame = try encodeFrame(payload)
        try assertCompleteFrame(frame, options: options)
        return frame
    } catch let error as ProtocolValidationError {
        throw error
    } catch {
        throw ProtocolValidationError("Unable to encode \(kind) protocol message: \(boundedCodecMessage(error))")
    }
}

public func encodeClientMessage(
    _ message: ClientMessage,
    options: FrameDecoderOptions = .init()
) throws -> Data {
    try encodeProtocolMessage(message.protocolJSONValue(), kind: "client", options: options, parse: parseClientMessage)
}

public func encodeServerMessage(
    _ message: ServerMessage,
    options: FrameDecoderOptions = .init()
) throws -> Data {
    try encodeProtocolMessage(message.protocolJSONValue(), kind: "server", options: options, parse: parseServerMessage)
}

private final class ValidatedMessageDecoder<Message: Sendable>: @unchecked Sendable {
    typealias Parse = @Sendable (CBORValue) throws -> Message

    private let lock = NSLock()
    private let frames: FrameDecoder
    private let kind: String
    private let maximumFrameLength: Int
    private let parse: Parse
    private var failed = false

    init(kind: String, options: FrameDecoderOptions, parse: @escaping Parse) throws {
        frames = try FrameDecoder(options: options)
        self.kind = kind
        maximumFrameLength = options.maximumFrameLength
        self.parse = parse
    }

    func push(_ chunk: Data) throws -> [Message] {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw ProtocolValidationError("\(kind) message decoder has failed") }
        do {
            return try frames.push(chunk).map {
                try parse(decodeCBOR($0, options: .init(maximumByteLength: maximumFrameLength)))
            }
        } catch {
            failed = true
            if let error = error as? ProtocolValidationError { throw error }
            throw ProtocolValidationError("Invalid \(kind) protocol frame: \(boundedCodecMessage(error))")
        }
    }

    func end() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !failed else { throw ProtocolValidationError("\(kind) message decoder has failed") }
        do { try frames.end() } catch {
            failed = true
            throw ProtocolValidationError("Invalid \(kind) protocol framing: \(boundedCodecMessage(error))")
        }
    }
}

public final class ClientMessageDecoder: @unchecked Sendable {
    private let decoder: ValidatedMessageDecoder<ClientMessage>

    public init(options: FrameDecoderOptions = .init()) throws {
        decoder = try ValidatedMessageDecoder(kind: "client", options: options, parse: parseClientMessage)
    }

    public func push(_ chunk: Data) throws -> [ClientMessage] { try decoder.push(chunk) }
    public func end() throws { try decoder.end() }
}

public final class ServerMessageDecoder: @unchecked Sendable {
    private let decoder: ValidatedMessageDecoder<ServerMessage>

    public init(options: FrameDecoderOptions = .init()) throws {
        decoder = try ValidatedMessageDecoder(kind: "server", options: options, parse: parseServerMessage)
    }

    public func push(_ chunk: Data) throws -> [ServerMessage] { try decoder.push(chunk) }
    public func end() throws { try decoder.end() }
}

public func createClientMessageDecoder(options: FrameDecoderOptions = .init()) throws -> ClientMessageDecoder {
    try ClientMessageDecoder(options: options)
}

public func createServerMessageDecoder(options: FrameDecoderOptions = .init()) throws -> ServerMessageDecoder {
    try ServerMessageDecoder(options: options)
}
