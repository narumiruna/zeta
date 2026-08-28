import Foundation
import ZetaCore

public enum AssistantEvent: Sendable, Equatable {
    case start(AssistantMessage)
    case textStart(index: Int, partial: AssistantMessage)
    case textDelta(index: Int, delta: String, partial: AssistantMessage)
    case textEnd(index: Int, content: String, partial: AssistantMessage)
    case thinkingStart(index: Int, partial: AssistantMessage)
    case thinkingDelta(index: Int, delta: String, partial: AssistantMessage)
    case thinkingEnd(index: Int, content: String, partial: AssistantMessage)
    case toolCallStart(index: Int, partial: AssistantMessage)
    case toolCallDelta(index: Int, delta: String, partial: AssistantMessage)
    case toolCallEnd(index: Int, call: ToolCall, partial: AssistantMessage)
    case done(reason: StopReason, message: AssistantMessage)
    case error(reason: StopReason, message: AssistantMessage)
}

public actor AssistantEventStream: AsyncSequence {
    public typealias Element = AssistantEvent
    public typealias AsyncIterator = AsyncThrowingStream<AssistantEvent, Error>.Iterator

    private let stream: AsyncThrowingStream<AssistantEvent, Error>
    private let continuation: AsyncThrowingStream<AssistantEvent, Error>.Continuation
    private var terminal: AssistantMessage?
    private var terminalWaiters: [CheckedContinuation<AssistantMessage, Never>] = []
    private var started = false
    private var finished = false

    public init(bufferingPolicy: AsyncThrowingStream<AssistantEvent, Error>.Continuation.BufferingPolicy = .unbounded) {
        let pair = AsyncThrowingStream<AssistantEvent, Error>.makeStream(bufferingPolicy: bufferingPolicy)
        stream = pair.stream
        continuation = pair.continuation
    }

    public nonisolated func makeAsyncIterator() -> AsyncIterator { stream.makeAsyncIterator() }

    public func emit(_ event: AssistantEvent) {
        guard !finished else { return }
        switch event {
        case .start:
            guard !started else { return }
            started = true
        case .done(let reason, let message):
            guard started, [.stop, .length, .toolUse, .deferred].contains(reason), message.stopReason == reason else {
                finishProtocolError("Invalid done event")
                return
            }
            settle(message, event: event)
            return
        case .error(let reason, let message):
            guard started, [.error, .aborted].contains(reason), message.stopReason == reason,
                message.errorMessage != nil
            else {
                finishProtocolError("Invalid error event")
                return
            }
            settle(message, event: event)
            return
        default:
            guard started else { return }
        }
        continuation.yield(event)
    }

    public func failBeforeStart(api: String, provider: String, model: String, error: Error, aborted: Bool = false) {
        guard !finished else { return }
        let reason: StopReason = aborted ? .aborted : .error
        let message = AssistantMessage(
            api: api, provider: provider, model: model, stopReason: reason, errorMessage: String(describing: error))
        emit(.start(AssistantMessage(api: api, provider: provider, model: model)))
        emit(.error(reason: reason, message: message))
    }

    public func result() async -> AssistantMessage {
        if let terminal { return terminal }
        return await withCheckedContinuation { terminalWaiters.append($0) }
    }

    public func cancel(api: String, provider: String, model: String) {
        failBeforeStart(api: api, provider: provider, model: model, error: CancellationError(), aborted: true)
    }

    private func settle(_ message: AssistantMessage, event: AssistantEvent) {
        terminal = message
        finished = true
        continuation.yield(event)
        continuation.finish()
        terminalWaiters.forEach { $0.resume(returning: message) }
        terminalWaiters.removeAll()
    }

    private func finishProtocolError(_ text: String) {
        finished = true
        continuation.finish(throwing: StreamProtocolError(text))
    }
}

public struct StreamProtocolError: Error, Sendable, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

public enum CacheRetention: String, Codable, Sendable {
    case none
    case short
    case long
}

public struct StreamOptions: Sendable {
    public var apiKey: String?
    public var headers: [String: String?]
    public var temperature: Double?
    public var maximumTokens: Int?
    public var thinking: ThinkingLevel?
    public var sessionID: String?
    public var timeout: Duration?
    public var cacheRetention: CacheRetention
    public var environment: [String: String]
    public var transformHeaders: HeaderTransform?

    public init(
        apiKey: String? = nil, headers: [String: String?] = [:], temperature: Double? = nil, maximumTokens: Int? = nil,
        thinking: ThinkingLevel? = nil, sessionID: String? = nil, timeout: Duration? = nil,
        cacheRetention: CacheRetention = .short,
        environment: [String: String] = [:],
        transformHeaders: HeaderTransform? = nil
    ) {
        self.apiKey = apiKey
        self.headers = headers
        self.temperature = temperature
        self.maximumTokens = maximumTokens
        self.thinking = thinking
        self.sessionID = sessionID
        self.timeout = timeout
        self.cacheRetention = cacheRetention
        self.environment = environment
        self.transformHeaders = transformHeaders
    }
}

public protocol AIProvider: Sendable {
    var id: ProviderID { get }
    var models: [Model] { get async }
    func stream(model: Model, context: Context, options: StreamOptions) async -> AssistantEventStream
}

public actor ModelRegistry {
    private var providers: [ProviderID: any AIProvider] = [:]

    public init() {}
    public func set(_ provider: any AIProvider) { providers[provider.id] = provider }
    public func remove(_ id: ProviderID) { providers[id] = nil }
    public func provider(_ id: ProviderID) -> (any AIProvider)? { providers[id] }
    public func allProviders() -> [ProviderID] { providers.keys.sorted() }

    public func allModels() async -> [Model] {
        var output: [Model] = []
        for key in providers.keys.sorted() { if let provider = providers[key] { output += await provider.models } }
        return output
    }

    public func model(provider: String, id: String) async -> Model? {
        guard let provider = providers[provider] else { return nil }
        return await provider.models.first { $0.id == id }
    }

    public func stream(model: Model, context: Context, options: StreamOptions = StreamOptions()) async
        -> AssistantEventStream
    {
        guard let provider = providers[model.provider] else {
            let stream = AssistantEventStream()
            await stream.failBeforeStart(
                api: model.api, provider: model.provider, model: model.id,
                error: ProviderError.unknownProvider(model.provider))
            return stream
        }
        return await provider.stream(model: model, context: context, options: options)
    }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case unknownProvider(String)
    case unknownModel(String)
    case missingCredential(String)
    case invalidResponse(String)
    case http(status: Int, body: String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let value): "Unknown provider: \(value)"
        case .unknownModel(let value): "Unknown model: \(value)"
        case .missingCredential(let value): "No credential configured for \(value)"
        case .invalidResponse(let value): "Invalid provider response: \(value)"
        case .http(let status, let body): "Provider returned HTTP \(status): \(body)"
        }
    }
}

public struct FauxCall: Sendable, Equatable {
    public var modelID: String
    public var messageCount: Int
    public var sessionID: String?
    public var cacheRetention: CacheRetention
}

public struct FauxProvider: AIProvider {
    public let id: String
    public let modelDefinitions: [Model]
    private let state: FauxState
    private let tokensPerSecond: Double?

    public init(
        id: String = "faux",
        models: [Model]? = nil,
        tokensPerSecond: Double? = nil
    ) {
        self.id = id
        self.modelDefinitions =
            models ?? [
                Model(
                    id: "faux", name: "Faux", api: "faux", provider: id,
                    baseURL: URL(string: "https://example.invalid")!, contextWindow: 128_000, maximumTokens: 32_000)
            ]
        self.state = FauxState()
        self.tokensPerSecond = tokensPerSecond
    }

    public var models: [Model] { get async { modelDefinitions } }
    public func enqueue(_ message: AssistantMessage) async { await state.enqueue(message) }
    public func pendingCount() async -> Int { await state.pendingCount }
    public func callCount() async -> Int { await state.calls.count }
    public func calls() async -> [FauxCall] { await state.calls }

    public func stream(model: Model, context: Context, options: StreamOptions) async -> AssistantEventStream {
        let stream = AssistantEventStream()
        let response =
            await state.take(model: model, context: context, options: options)
            ?? AssistantMessage(
                api: model.api, provider: id, model: model.id, stopReason: .error,
                errorMessage: "No more faux responses queued")
        Task {
            var partial = AssistantMessage(api: model.api, provider: id, model: model.id)
            await stream.emit(.start(partial))
            for block in response.content {
                let index = partial.content.count
                switch block {
                case .text(let text, let signature):
                    partial.content.append(.text(text: "", signature: signature))
                    await stream.emit(.textStart(index: index, partial: partial))
                    for character in text {
                        if Task.isCancelled {
                            await stream.cancel(api: model.api, provider: id, model: model.id)
                            return
                        }
                        if let tokensPerSecond, tokensPerSecond > 0 {
                            let delay = UInt64((1_000_000_000 / tokensPerSecond).rounded())
                            try? await Task.sleep(nanoseconds: delay)
                        }
                        let delta = String(character)
                        if case .text(let current, _) = partial.content[index] {
                            partial.content[index] = .text(text: current + delta, signature: signature)
                        }
                        await stream.emit(.textDelta(index: index, delta: delta, partial: partial))
                    }
                    await stream.emit(.textEnd(index: index, content: text, partial: partial))
                case .thinking(let text, let signature, let redacted):
                    partial.content.append(.thinking(text: "", signature: signature, redacted: redacted))
                    await stream.emit(.thinkingStart(index: index, partial: partial))
                    partial.content[index] = block
                    await stream.emit(.thinkingDelta(index: index, delta: text, partial: partial))
                    await stream.emit(.thinkingEnd(index: index, content: text, partial: partial))
                case .toolCall(let call):
                    partial.content.append(.toolCall(ToolCall(id: call.id, name: call.name)))
                    await stream.emit(.toolCallStart(index: index, partial: partial))
                    partial.content[index] = block
                    let delta = OrderedJSON.string(call.arguments)
                    await stream.emit(.toolCallDelta(index: index, delta: delta, partial: partial))
                    await stream.emit(.toolCallEnd(index: index, call: call, partial: partial))
                case .image: partial.content.append(block)
                }
            }
            if response.stopReason == .error || response.stopReason == .aborted {
                await stream.emit(.error(reason: response.stopReason, message: response))
            } else {
                await stream.emit(.done(reason: response.stopReason, message: response))
            }
        }
        return stream
    }
}

private actor FauxState {
    var queue: [AssistantMessage] = []
    var calls: [FauxCall] = []
    var cachedSessions: Set<String> = []
    var pendingCount: Int { queue.count }

    func enqueue(_ value: AssistantMessage) { queue.append(value) }

    func take(
        model: Model,
        context: Context,
        options: StreamOptions
    ) -> AssistantMessage? {
        calls.append(
            FauxCall(
                modelID: model.id,
                messageCount: context.messages.count,
                sessionID: options.sessionID,
                cacheRetention: options.cacheRetention
            )
        )
        guard !queue.isEmpty else { return nil }
        var response = queue.removeFirst()
        if response.usage.totalTokens == 0 {
            let inputCharacters = (try? JSONEncoder().encode(context.messages).count) ?? 0
            let outputCharacters = response.content.reduce(0) { total, block in
                switch block {
                case .text(let text, _): total + text.count
                case .thinking(let text, _, _): total + text.count
                case .toolCall(let call): total + OrderedJSON.string(call.arguments).count
                case .image: total + 4_800
                }
            }
            let inputTokens = max(1, (inputCharacters + 3) / 4)
            let outputTokens = max(1, (outputCharacters + 3) / 4)
            var cacheRead = 0
            var cacheWrite = 0
            if let sessionID = options.sessionID,
                options.cacheRetention != .none
            {
                if cachedSessions.contains(sessionID) {
                    cacheRead = inputTokens
                } else {
                    cacheWrite = inputTokens
                    cachedSessions.insert(sessionID)
                }
            }
            response.usage = Usage(
                input: inputTokens,
                output: outputTokens,
                cacheRead: cacheRead,
                cacheWrite: cacheWrite
            )
        }
        return response
    }
}
