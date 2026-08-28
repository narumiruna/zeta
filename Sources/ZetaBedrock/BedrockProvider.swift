import Foundation
import ZetaAI
import ZetaAuth
import ZetaCore

public struct AWSEventStreamMessage: Sendable, Equatable {
    public var headers: [String: String]
    public var payload: Data
}

public enum AWSEventStreamError: Error, Sendable {
    case invalidLength
    case invalidCRC
    case invalidHeader
    case truncated
}

public struct AWSEventStreamDecoder: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func push(_ data: Data) throws -> [AWSEventStreamMessage] {
        buffer.append(data)
        var output: [AWSEventStreamMessage] = []
        while buffer.count >= 12 {
            let total = Int(buffer.uint32(at: 0))
            let headersLength = Int(buffer.uint32(at: 4))
            guard total >= 16, headersLength <= total - 16 else {
                throw AWSEventStreamError.invalidLength
            }
            guard buffer.count >= total else { break }
            let message = Data(buffer.prefix(total))
            buffer.removeFirst(total)
            guard CRC32.checksum(message.prefix(8)) == message.uint32(at: 8),
                CRC32.checksum(message.prefix(total - 4)) == message.uint32(at: total - 4)
            else {
                throw AWSEventStreamError.invalidCRC
            }
            let headersData = message[12..<(12 + headersLength)]
            let payload = Data(message[(12 + headersLength)..<(total - 4)])
            output.append(
                AWSEventStreamMessage(
                    headers: try decodeHeaders(Data(headersData)),
                    payload: payload
                )
            )
        }
        return output
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw AWSEventStreamError.truncated }
    }

    private func decodeHeaders(_ data: Data) throws -> [String: String] {
        var index = 0
        var output: [String: String] = [:]
        while index < data.count {
            guard index < data.count else { throw AWSEventStreamError.invalidHeader }
            let nameLength = Int(data[index])
            index += 1
            guard index + nameLength + 1 <= data.count else {
                throw AWSEventStreamError.invalidHeader
            }
            let name = String(decoding: data[index..<(index + nameLength)], as: UTF8.self)
            index += nameLength
            let type = data[index]
            index += 1
            guard type == 7, index + 2 <= data.count else {
                throw AWSEventStreamError.invalidHeader
            }
            let valueLength = Int(data.uint16(at: index))
            index += 2
            guard index + valueLength <= data.count else {
                throw AWSEventStreamError.invalidHeader
            }
            output[name] = String(
                decoding: data[index..<(index + valueLength)],
                as: UTF8.self
            )
            index += valueLength
        }
        return output
    }
}

public struct BedrockProvider: AIProvider {
    public let id = "amazon-bedrock"
    public let modelDefinitions: [Model]
    private let session: URLSession
    private let credential: @Sendable () async throws -> AWSCredential
    private let region: String

    public init(
        models: [Model],
        region: String,
        session: URLSession = .shared,
        credential: @escaping @Sendable () async throws -> AWSCredential
    ) {
        modelDefinitions = models
        self.region = region
        self.session = session
        self.credential = credential
    }

    public var models: [Model] { get async { modelDefinitions } }

    public func stream(
        model: Model,
        context: Context,
        options: StreamOptions
    ) async -> AssistantEventStream {
        let result = AssistantEventStream()
        Task {
            do {
                let body = OrderedJSON.encode(
                    try ProviderPayloadBuilder.build(
                        model: model,
                        context: context,
                        options: options
                    )
                )
                let encodedID = model.id.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed
                )!
                var request = URLRequest(
                    url: model.baseURL.appendingPathComponent(
                        "model/\(encodedID)/converse-stream"
                    )
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let signed = try AWSSignatureV4.sign(
                    request: request,
                    body: body,
                    service: "bedrock",
                    region: region,
                    credential: try await credential(),
                    date: Date()
                )
                let (bytes, response) = try await session.bytes(for: signed.request)
                guard let http = response as? HTTPURLResponse,
                    200..<300 ~= http.statusCode
                else {
                    throw ProviderError.http(
                        status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                        body: "Bedrock request failed"
                    )
                }
                var partial = AssistantMessage(
                    api: model.api,
                    provider: model.provider,
                    model: model.id
                )
                await result.emit(.start(partial))
                var decoder = AWSEventStreamDecoder()
                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 4_096 {
                        try await consume(
                            decoder.push(chunk),
                            partial: &partial,
                            stream: result
                        )
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                try await consume(
                    decoder.push(chunk),
                    partial: &partial,
                    stream: result
                )
                try decoder.finish()
                if partial.stopReason == .pending { partial.stopReason = .stop }
                await result.emit(.done(reason: partial.stopReason, message: partial))
            } catch is CancellationError {
                await result.failBeforeStart(
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    error: CancellationError(),
                    aborted: true
                )
            } catch {
                await result.failBeforeStart(
                    api: model.api,
                    provider: model.provider,
                    model: model.id,
                    error: error
                )
            }
        }
        return result
    }

    private func consume(
        _ messages: [AWSEventStreamMessage],
        partial: inout AssistantMessage,
        stream: AssistantEventStream
    ) async throws {
        for message in messages {
            if message.headers[":message-type"] == "exception" {
                throw ProviderError.invalidResponse(
                    String(decoding: message.payload, as: UTF8.self)
                )
            }
            guard let value = try? OrderedJSON.decode(message.payload),
                case .object(let object) = value
            else {
                continue
            }
            if case .object(let delta)? = object["contentBlockDelta"],
                case .object(let content)? = delta["delta"],
                case .string(let text)? = content["text"]
            {
                let index: Int
                if let existing = partial.content.firstIndex(where: {
                    if case .text = $0 { true } else { false }
                }) {
                    index = existing
                } else {
                    index = partial.content.count
                    partial.content.append(.text(text: ""))
                    await stream.emit(.textStart(index: index, partial: partial))
                }
                if case .text(let current, let signature) = partial.content[index] {
                    partial.content[index] = .text(
                        text: current + text,
                        signature: signature
                    )
                }
                await stream.emit(
                    .textDelta(index: index, delta: text, partial: partial)
                )
            }
            if case .object(let metadata)? = object["metadata"],
                case .object(let usage)? = metadata["usage"]
            {
                partial.usage.input =
                    usage.integer("inputTokens")
                    ?? partial.usage.input
                partial.usage.output =
                    usage.integer("outputTokens")
                    ?? partial.usage.output
                partial.usage.totalTokens = partial.usage.input + partial.usage.output
            }
        }
    }
}

private enum CRC32 {
    static func checksum<D: DataProtocol>(_ data: D) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB8_8320 : 0)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    func uint16(at index: Int) -> UInt16 {
        UInt16(self[index]) << 8 | UInt16(self[index + 1])
    }
    func uint32(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24
            | UInt32(self[index + 1]) << 16
            | UInt32(self[index + 2]) << 8
            | UInt32(self[index + 3])
    }
}

private extension OrderedJSONObject {
    func integer(_ key: String) -> Int? {
        guard case .number(let number)? = self[key],
            let value = number.safeIntegerValue
        else {
            return nil
        }
        return Int(value)
    }
}
