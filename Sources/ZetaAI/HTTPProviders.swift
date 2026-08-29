import Foundation
import ZetaCore

public struct ProviderConfiguration: Sendable {
    public let id: String
    public let api: String
    public let baseURL: URL
    public let models: [Model]
    public let apiKeyEnvironmentVariables: [String]
    public var defaultHeaders: [String: String]

    public init(
        id: String, api: String, baseURL: URL, models: [Model], apiKeyEnvironmentVariables: [String],
        defaultHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.api = api
        self.baseURL = baseURL
        self.models = models
        self.apiKeyEnvironmentVariables = apiKeyEnvironmentVariables
        self.defaultHeaders = defaultHeaders
    }
}

public struct HTTPProvider: AIProvider {
    public let configuration: ProviderConfiguration
    private let session: URLSession
    private let environment: @Sendable () -> [String: String]

    public init(
        configuration: ProviderConfiguration, session: URLSession = .shared,
        environment: @escaping @Sendable () -> [String: String] = { ProcessInfo.processInfo.environment }
    ) {
        self.configuration = configuration
        self.session = session
        self.environment = environment
    }

    public var id: String { configuration.id }
    public var models: [Model] { get async { configuration.models } }

    public func stream(model: Model, context: Context, options: StreamOptions) async -> AssistantEventStream {
        let output = AssistantEventStream()
        let producer = Task {
            var reducer = ProviderEventReducer(model: model)
            var started = false
            do {
                let requestEnvironment = environment().merging(options.environment) {
                    _, override in override
                }
                let apiKey =
                    options.apiKey
                    ?? configuration.apiKeyEnvironmentVariables.lazy.compactMap {
                        requestEnvironment[$0]
                    }.first
                guard let apiKey else { throw ProviderError.missingCredential(configuration.id) }
                let request = try await buildRequest(
                    model: model,
                    context: context,
                    apiKey: apiKey,
                    options: options,
                    environment: requestEnvironment
                )
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ProviderError.invalidResponse("Not an HTTP response")
                }
                guard 200..<300 ~= http.statusCode else {
                    var body = Data()
                    for try await byte in bytes { if body.count < 64 * 1_024 { body.append(byte) } }
                    throw ProviderError.http(status: http.statusCode, body: String(decoding: body, as: UTF8.self))
                }
                await output.emit(.start(reducer.partial))
                started = true
                var decoder = SSEDecoder()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    for record in decoder.push(byte) {
                        try await consume(
                            record: record,
                            reducer: &reducer,
                            output: output
                        )
                    }
                }
                for record in decoder.finish() {
                    try await consume(
                        record: record,
                        reducer: &reducer,
                        output: output
                    )
                }
                var partial = reducer.partial
                if partial.stopReason == .pending {
                    partial.stopReason =
                        partial.content.contains(where: {
                            if case .toolCall = $0 { true } else { false }
                        }) ? .toolUse : .stop
                }
                await output.emit(.done(reason: partial.stopReason, message: partial))
            } catch is CancellationError {
                if started {
                    var message = reducer.partial
                    message.stopReason = .aborted
                    message.errorMessage = "Operation aborted"
                    await output.emit(.error(reason: .aborted, message: message))
                } else {
                    await output.failBeforeStart(
                        api: model.api,
                        provider: model.provider,
                        model: model.id,
                        error: CancellationError(),
                        aborted: true
                    )
                }
            } catch {
                if started {
                    var message = reducer.partial
                    message.stopReason = .error
                    message.errorMessage = String(describing: error)
                    await output.emit(.error(reason: .error, message: message))
                } else {
                    await output.failBeforeStart(
                        api: model.api,
                        provider: model.provider,
                        model: model.id,
                        error: error
                    )
                }
            }
        }
        output.attachProducer(producer)
        return output
    }

    func buildRequest(
        model: Model,
        context: Context,
        apiKey: String,
        options: StreamOptions,
        environment: [String: String]? = nil
    ) async throws -> URLRequest {
        let requestEnvironment =
            environment
            ?? self.environment().merging(options.environment) { _, override in override }
        let baseURL = effectiveBaseURL(model: model, environment: requestEnvironment)
        let endpoint: URL
        switch model.api {
        case "anthropic-messages": endpoint = baseURL.appendingPathComponent("v1/messages")
        case "openai-responses", "azure-openai-responses", "openai-codex-responses":
            endpoint = baseURL.appendingPathComponent("responses")
        case "google-generative-ai":
            var components = URLComponents(
                url: baseURL.appendingPathComponent("models/\(model.id):streamGenerateContent"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            endpoint = components.url!
        case "google-vertex":
            endpoint = try vertexEndpoint(
                model: model,
                environment: requestEnvironment
            )
        case "mistral-conversations": endpoint = baseURL.appendingPathComponent("v1/conversations")
        case "pi-messages": endpoint = baseURL.appendingPathComponent("v1/messages")
        default: endpoint = baseURL.appendingPathComponent("chat/completions")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if let timeout = options.timeout {
            let components = timeout.components
            request.timeoutInterval = max(
                0.001,
                Double(components.seconds) + Double(components.attoseconds) / 1e18
            )
        }
        var headers = CaseInsensitiveHeaders([
            "Accept": "text/event-stream",
            "Content-Type": "application/json",
        ])
        headers.merge(configuration.defaultHeaders.mapValues(Optional.some))
        switch model.api {
        case "anthropic-messages":
            headers["x-api-key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        case "google-generative-ai", "google-vertex":
            headers["x-goog-api-key"] = apiKey
        case "azure-openai-responses":
            headers["api-key"] = apiKey
        default:
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        headers.merge((model.headers ?? [:]).mapValues(Optional.some))
        headers.merge(options.headers)
        if let transform = options.transformHeaders {
            let transformed = try await transform(
                headers.dictionary.mapValues(Optional.some)
            )
            headers = CaseInsensitiveHeaders(transformed)
        }
        for (key, value) in headers.dictionary {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = OrderedJSON.encode(
            try ProviderPayloadBuilder.build(model: model, context: context, options: options)
        )
        return request
    }

    private func vertexEndpoint(
        model: Model,
        environment: [String: String]
    ) throws -> URL {
        guard
            let project = environment["GOOGLE_CLOUD_PROJECT"]
                ?? environment["GCLOUD_PROJECT"],
            !project.isEmpty
        else {
            throw ProviderError.invalidResponse(
                "Vertex AI requires GOOGLE_CLOUD_PROJECT or GCLOUD_PROJECT"
            )
        }
        guard let location = environment["GOOGLE_CLOUD_LOCATION"],
            !location.isEmpty
        else {
            throw ProviderError.invalidResponse(
                "Vertex AI requires GOOGLE_CLOUD_LOCATION"
            )
        }
        let rawBaseURL = model.baseURLTemplate ?? model.baseURL.absoluteString
        guard
            let baseURL = URL(
                string: rawBaseURL.replacingOccurrences(
                    of: "{location}",
                    with: location
                )
            )
        else {
            throw ProviderError.invalidResponse("Invalid Vertex AI base URL")
        }
        let url =
            baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("projects")
            .appendingPathComponent(project)
            .appendingPathComponent("locations")
            .appendingPathComponent(location)
            .appendingPathComponent("publishers")
            .appendingPathComponent("google")
            .appendingPathComponent("models")
            .appendingPathComponent("\(model.id):streamGenerateContent")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
        return components.url!
    }

    private func effectiveBaseURL(
        model: Model,
        environment: [String: String]
    ) -> URL {
        if model.api == "azure-openai-responses",
            let raw = environment["AZURE_OPENAI_BASE_URL"],
            let configured = URL(string: raw)
        {
            return configured.path.contains("/openai")
                ? configured
                : configured.appendingPathComponent("openai/v1")
        }
        return model.baseURL
    }

    private func consume(
        record: SSERecord,
        reducer: inout ProviderEventReducer,
        output: AssistantEventStream
    ) async throws {
        guard !record.data.isEmpty, record.data != "[DONE]" else { return }
        let value = try OrderedJSON.decode(record.data)
        for event in try reducer.consume(value, eventName: record.event) {
            await output.emit(event)
        }
    }
}

public struct SSERecord: Sendable, Equatable {
    public var event: String?
    public var data: String
}

public struct SSEDecoder: Sendable {
    private var buffer = Data()
    public init() {}
    public mutating func push(_ byte: UInt8) -> [SSERecord] {
        buffer.append(byte)
        return drain()
    }
    public mutating func finish() -> [SSERecord] {
        defer { buffer.removeAll() }
        guard !buffer.isEmpty else { return [] }
        return parse(String(decoding: buffer, as: UTF8.self))
    }
    private mutating func drain() -> [SSERecord] {
        var output: [SSERecord] = []
        while let range = recordBoundary() {
            let data = buffer[..<range.lowerBound]
            buffer.removeSubrange(..<range.upperBound)
            output += parse(String(decoding: data, as: UTF8.self))
        }
        return output
    }
    private func recordBoundary() -> Range<Data.Index>? {
        let bytes = Array(buffer)
        for offset in bytes.indices {
            let length: Int
            if offset + 3 < bytes.count,
                bytes[offset...offset + 3] == [0x0D, 0x0A, 0x0D, 0x0A]
            {
                length = 4
            } else if offset + 1 < bytes.count,
                (bytes[offset] == 0x0A && bytes[offset + 1] == 0x0A)
                    || (bytes[offset] == 0x0D && bytes[offset + 1] == 0x0D)
            {
                length = 2
            } else {
                continue
            }
            let lower = buffer.index(buffer.startIndex, offsetBy: offset)
            let upper = buffer.index(lower, offsetBy: length)
            return lower..<upper
        }
        return nil
    }
    private func parse(_ raw: String) -> [SSERecord] {
        var event: String?
        var data: [String] = []
        let normalized =
            raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("event:") {
                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                data.append(line.dropFirst(5).trimmingCharacters(in: .whitespaces))
            }
        }
        return data.isEmpty ? [] : [SSERecord(event: event, data: data.joined(separator: "\n"))]
    }
}

private extension OrderedJSONObject {
    func string(_ key: String) -> String? { if case .string(let value)? = self[key] { value } else { nil } }
    func int(_ key: String) -> Int? {
        if case .number(let value)? = self[key] { value.safeIntegerValue.map(Int.init) } else { nil }
    }
    func pathString(_ path: [String]) -> String? {
        var current: JSONValue = .object(self)
        for key in path {
            if case .object(let object) = current, let next = object[key] {
                current = next
            } else if case .array(let values) = current, let index = Int(key), values.indices.contains(index) {
                current = values[index]
            } else {
                return nil
            }
        }
        if case .string(let value) = current { return value }
        return nil
    }
}
