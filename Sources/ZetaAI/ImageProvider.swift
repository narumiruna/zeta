import Foundation
import ZetaCore

public protocol ImageProvider: Sendable {
    var id: String { get }
    var models: [ImageModel] { get }
    func generate(
        model: ImageModel,
        input: [ContentBlock],
        options: StreamOptions
    ) async -> AssistantImages
}

public struct OpenRouterImageProvider: ImageProvider {
    public let id = "openrouter"
    public let models: [ImageModel]
    private let session: URLSession
    private let environment: @Sendable () -> [String: String]
    private let maximumResponseBytes: Int

    public init(
        models: [ImageModel],
        session: URLSession = .shared,
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.models = models
        self.session = session
        self.environment = environment
        maximumResponseBytes = 32 * 1_024 * 1_024
    }

    package init(
        models: [ImageModel],
        session: URLSession,
        maximumResponseBytes: Int,
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        precondition(maximumResponseBytes > 0)
        self.models = models
        self.session = session
        self.environment = environment
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func generate(
        model: ImageModel,
        input: [ContentBlock],
        options: StreamOptions
    ) async -> AssistantImages {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
        do {
            try Task.checkCancellation()
            guard
                let key = options.apiKey
                    ?? options.environment["OPENROUTER_API_KEY"]
                    ?? environment()["OPENROUTER_API_KEY"]
            else {
                throw ProviderError.missingCredential(id)
            }
            var request = URLRequest(
                url: model.baseURL.appendingPathComponent("chat/completions")
            )
            request.httpMethod = "POST"
            if let timeout = options.timeout {
                let components = timeout.components
                request.timeoutInterval = max(
                    0.001,
                    Double(components.seconds) + Double(components.attoseconds) / 1e18
                )
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let content: [JSONValue] = input.compactMap { block in
                switch block {
                case .text(let text, _):
                    ["type": "text", "text": .string(text)]
                case .image(let data, let mime):
                    [
                        "type": "image_url",
                        "image_url": ["url": .string("data:\(mime);base64,\(data)")],
                    ]
                default:
                    nil
                }
            }
            request.httpBody = OrderedJSON.encode([
                "model": .string(model.id),
                "messages": .array([
                    [
                        "role": "user",
                        "content": .array(content),
                    ]
                ]),
                "modalities": .array(model.output.sorted().map(JSONValue.string)),
            ])
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.invalidResponse("Not an HTTP response")
            }
            guard 200..<300 ~= http.statusCode else {
                var body = Data()
                for try await byte in bytes {
                    if body.count == 64 * 1_024 { break }
                    body.append(byte)
                }
                throw ProviderError.http(
                    status: http.statusCode,
                    body: String(decoding: body, as: UTF8.self)
                )
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw ProviderError.invalidResponse(
                        "Image response exceeds the configured byte limit"
                    )
                }
                data.append(byte)
            }
            let value = try OrderedJSON.decode(data)
            guard case .object(let object) = value else {
                throw ProviderError.invalidResponse("Expected image response object")
            }
            var output: [ContentBlock] = []
            if let text = object.pathString(["choices", "0", "message", "content"]) {
                output.append(.text(text: text))
            }
            if case .array(let images)? = object.path(["choices", "0", "message", "images"]) {
                for image in images {
                    guard case .object(let imageObject) = image,
                        let url = imageObject.pathString(["image_url", "url"]),
                        let decoded = decodeDataURL(url)
                    else {
                        continue
                    }
                    output.append(.image(data: decoded.data, mimeType: decoded.mime))
                }
            }
            return AssistantImages(
                api: model.api,
                provider: model.provider,
                model: model.id,
                output: output,
                responseID: object.string("id"),
                stopReason: .stop,
                timestamp: timestamp
            )
        } catch is CancellationError {
            return AssistantImages(
                api: model.api,
                provider: model.provider,
                model: model.id,
                output: [],
                stopReason: .aborted,
                errorMessage: "Operation aborted",
                timestamp: timestamp
            )
        } catch {
            return AssistantImages(
                api: model.api,
                provider: model.provider,
                model: model.id,
                output: [],
                stopReason: .error,
                errorMessage: String(describing: error),
                timestamp: timestamp
            )
        }
    }

    private func decodeDataURL(_ value: String) -> (mime: String, data: String)? {
        guard value.hasPrefix("data:"),
            let separator = value.range(of: ";base64,")
        else {
            return nil
        }
        let mime = String(value[value.index(value.startIndex, offsetBy: 5)..<separator.lowerBound])
        let data = String(value[separator.upperBound...])
        guard Data(base64Encoded: data) != nil else { return nil }
        return (mime, data)
    }
}

private extension OrderedJSONObject {
    func string(_ key: String) -> String? {
        if case .string(let value)? = self[key] { value } else { nil }
    }

    func path(_ path: [String]) -> JSONValue? {
        var current: JSONValue = .object(self)
        for key in path {
            if case .object(let object) = current, let next = object[key] {
                current = next
            } else if case .array(let values) = current,
                let index = Int(key), values.indices.contains(index)
            {
                current = values[index]
            } else {
                return nil
            }
        }
        return current
    }

    func pathString(_ path: [String]) -> String? {
        guard case .string(let value)? = self.path(path) else { return nil }
        return value
    }
}
