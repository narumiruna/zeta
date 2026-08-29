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
            buffer = Data(buffer.dropFirst(total))
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

    static func authorizedRequest(
        _ request: URLRequest,
        body: Data,
        region: String,
        credential: AWSCredential,
        date: Date
    ) throws -> URLRequest {
        switch credential.authentication {
        case .bearer(let token):
            var authorized = request
            authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            authorized.httpBody = body
            return authorized
        case .signatureV4:
            return try AWSSignatureV4.sign(
                request: request,
                body: body,
                service: "bedrock",
                region: region,
                credential: credential,
                date: date
            ).request
        }
    }

    static func endpointURL(baseURL: URL, modelID: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            let encodedID = modelID.addingPercentEncoding(
                withAllowedCharacters: CharacterSet(
                    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
                )
            )
        else {
            throw ProviderError.invalidResponse("Invalid Bedrock endpoint URL")
        }
        let basePath =
            components.percentEncodedPath.hasSuffix("/")
            ? components.percentEncodedPath
            : components.percentEncodedPath + "/"
        components.percentEncodedPath = basePath + "model/\(encodedID)/converse-stream"
        guard let url = components.url else {
            throw ProviderError.invalidResponse("Invalid Bedrock endpoint URL")
        }
        return url
    }

    public func stream(
        model: Model,
        context: Context,
        options: StreamOptions
    ) async -> AssistantEventStream {
        let result = AssistantEventStream()
        let producer = Task {
            var partial = AssistantMessage(
                api: model.api,
                provider: model.provider,
                model: model.id
            )
            var started = false
            do {
                let body = OrderedJSON.encode(
                    try ProviderPayloadBuilder.build(
                        model: model,
                        context: context,
                        options: options
                    )
                )
                var request = URLRequest(
                    url: try Self.endpointURL(
                        baseURL: model.baseURL,
                        modelID: model.id
                    )
                )
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request = try Self.authorizedRequest(
                    request,
                    body: body,
                    region: region,
                    credential: try await credential(),
                    date: Date()
                )
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse,
                    200..<300 ~= http.statusCode
                else {
                    throw ProviderError.http(
                        status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                        body: "Bedrock request failed"
                    )
                }
                await result.emit(.start(partial))
                started = true
                var decoder = AWSEventStreamDecoder()
                var toolInputBuffers: [Int: String] = [:]
                var chunk = Data()
                for try await byte in bytes {
                    chunk.append(byte)
                    if chunk.count >= 4_096 {
                        try await consume(
                            decoder.push(chunk),
                            partial: &partial,
                            toolInputBuffers: &toolInputBuffers,
                            stream: result
                        )
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                try await consume(
                    decoder.push(chunk),
                    partial: &partial,
                    toolInputBuffers: &toolInputBuffers,
                    stream: result
                )
                try decoder.finish()
                if partial.stopReason == .pending {
                    partial.stopReason =
                        partial.content.contains {
                            if case .toolCall = $0 { true } else { false }
                        } ? .toolUse : .stop
                }
                await result.emit(.done(reason: partial.stopReason, message: partial))
            } catch is CancellationError {
                if started {
                    await result.fail(
                        CancellationError(),
                        preserving: partial,
                        aborted: true
                    )
                } else {
                    await result.failBeforeStart(
                        api: model.api,
                        provider: model.provider,
                        model: model.id,
                        error: CancellationError(),
                        aborted: true
                    )
                }
            } catch {
                if started {
                    await result.fail(error, preserving: partial)
                } else {
                    await result.failBeforeStart(
                        api: model.api,
                        provider: model.provider,
                        model: model.id,
                        error: error
                    )
                }
            }
        }
        result.attachProducer(producer)
        return result
    }

    func consume(
        _ messages: [AWSEventStreamMessage],
        partial: inout AssistantMessage,
        toolInputBuffers: inout [Int: String],
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

            if case .object(let blockStart)? = object["contentBlockStart"],
                let index = blockStart.integer("contentBlockIndex"),
                case .object(let start)? = blockStart["start"],
                case .object(let toolUse)? = start["toolUse"]
            {
                let call = ToolCall(
                    id: toolUse.string("toolUseId") ?? "call-\(index)",
                    name: toolUse.string("name") ?? "tool"
                )
                try setContent(.toolCall(call), at: index, partial: &partial)
                toolInputBuffers[index] = ""
                await stream.emit(.toolCallStart(index: index, partial: partial))
            }

            if case .object(let blockDelta)? = object["contentBlockDelta"],
                let index = blockDelta.integer("contentBlockIndex"),
                case .object(let delta)? = blockDelta["delta"]
            {
                if let text = delta.string("text") {
                    if index == partial.content.count {
                        partial.content.append(.text(text: ""))
                        await stream.emit(.textStart(index: index, partial: partial))
                    }
                    guard partial.content.indices.contains(index),
                        case .text(let current, let signature) = partial.content[index]
                    else {
                        throw ProviderError.invalidResponse(
                            "Invalid Bedrock text content block index \(index)"
                        )
                    }
                    partial.content[index] = .text(
                        text: current + text,
                        signature: signature
                    )
                    await stream.emit(
                        .textDelta(index: index, delta: text, partial: partial)
                    )
                }
                if case .object(let toolUse)? = delta["toolUse"],
                    let input = toolUse.string("input")
                {
                    guard partial.content.indices.contains(index),
                        case .toolCall(var call) = partial.content[index]
                    else {
                        throw ProviderError.invalidResponse(
                            "Invalid Bedrock tool-use content block index \(index)"
                        )
                    }
                    toolInputBuffers[index, default: ""] += input
                    if let arguments = decodedToolInput(toolInputBuffers[index]!) {
                        call.arguments = arguments
                        partial.content[index] = .toolCall(call)
                    }
                    await stream.emit(
                        .toolCallDelta(index: index, delta: input, partial: partial)
                    )
                }
            }

            if case .object(let blockStop)? = object["contentBlockStop"],
                let index = blockStop.integer("contentBlockIndex"),
                partial.content.indices.contains(index)
            {
                switch partial.content[index] {
                case .text(let text, _):
                    await stream.emit(
                        .textEnd(index: index, content: text, partial: partial)
                    )
                case .toolCall(var call):
                    let input = toolInputBuffers[index] ?? ""
                    guard let arguments = decodedToolInput(input) else {
                        throw ProviderError.invalidResponse(
                            "Invalid Bedrock tool-use input at content block index \(index)"
                        )
                    }
                    call.arguments = arguments
                    partial.content[index] = .toolCall(call)
                    await stream.emit(
                        .toolCallEnd(index: index, call: call, partial: partial)
                    )
                    toolInputBuffers[index] = nil
                case .thinking, .image:
                    break
                }
            }

            if case .object(let messageStop)? = object["messageStop"],
                let reason = messageStop.string("stopReason")
            {
                partial.rawStopReason = reason
                switch reason {
                case "tool_use", "toolUse":
                    partial.stopReason = .toolUse
                case "max_tokens", "maxTokens":
                    partial.stopReason = .length
                default:
                    partial.stopReason = .stop
                }
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

    private func setContent(
        _ block: ContentBlock,
        at index: Int,
        partial: inout AssistantMessage
    ) throws {
        guard index >= 0, index <= partial.content.count else {
            throw ProviderError.invalidResponse(
                "Invalid Bedrock content block index \(index)"
            )
        }
        if index == partial.content.count {
            partial.content.append(block)
        } else {
            partial.content[index] = block
        }
    }

    private func decodedToolInput(_ input: String) -> JSONValue? {
        if input.isEmpty { return [:] }
        return try? OrderedJSON.decode(Data(input.utf8))
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

    func string(_ key: String) -> String? {
        guard case .string(let value)? = self[key] else { return nil }
        return value
    }
}
