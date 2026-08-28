import Foundation
import ZetaCore

public enum TelemetryAttributeValue: Sendable, Equatable, Codable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case strings([String])
    case numbers([Double])
    case booleans([Bool])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .number(value)
        } else if let value = try? container.decode([String].self) {
            self = .strings(value)
        } else if let value = try? container.decode([Bool].self) {
            self = .booleans(value)
        } else {
            let value = try container.decode([Double].self)
            guard value.allSatisfy(\.isFinite) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Telemetry numbers must be finite")
            }
            self = .numbers(value)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value, .init(codingPath: encoder.codingPath, debugDescription: "Telemetry numbers must be finite"))
            }
            try container.encode(value)
        case let .boolean(value): try container.encode(value)
        case let .strings(value): try container.encode(value)
        case let .numbers(value):
            guard value.allSatisfy(\.isFinite) else {
                throw EncodingError.invalidValue(
                    value, .init(codingPath: encoder.codingPath, debugDescription: "Telemetry numbers must be finite"))
            }
            try container.encode(value)
        case let .booleans(value): try container.encode(value)
        }
    }
}

extension TelemetryAttributeValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) {
        precondition(value.isFinite)
        self = .number(value)
    }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(arrayLiteral elements: TelemetryAttributeValue...) {
        if elements.allSatisfy({ if case .string = $0 { true } else { false } }) {
            self = .strings(elements.compactMap { if case let .string(value) = $0 { value } else { nil } })
        } else if elements.allSatisfy({ if case .number = $0 { true } else { false } }) {
            self = .numbers(elements.compactMap { if case let .number(value) = $0 { value } else { nil } })
        } else if elements.allSatisfy({ if case .boolean = $0 { true } else { false } }) {
            self = .booleans(elements.compactMap { if case let .boolean(value) = $0 { value } else { nil } })
        } else {
            preconditionFailure("Telemetry attribute arrays must be homogeneous scalars")
        }
    }
}

public typealias AttributeValue = TelemetryAttributeValue
public typealias SpanAttributes = [String: TelemetryAttributeValue]

public struct SpanOptions: Sendable, Equatable {
    public let name: String
    public let attributes: SpanAttributes

    public init(name: String, attributes: SpanAttributes = [:]) {
        self.name = name
        self.attributes = attributes
    }
}

public struct TelemetryErrorStatus: Sendable, Equatable, Codable {
    public let name: String
    public let message: String

    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}

public enum SpanStatus: Sendable, Equatable, Codable {
    case ok
    case error(TelemetryErrorStatus? = nil)
}

public protocol TelemetryContext: Sendable {
    func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        operation: @escaping @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result
}

public protocol TelemetrySpan: TelemetryContext {
    func addEvent(_ name: String, attributes: SpanAttributes)
    func setAttributes(_ attributes: SpanAttributes)
    func setStatus(_ status: SpanStatus)
}

public extension TelemetrySpan {
    func addEvent(_ name: String) { addEvent(name, attributes: [:]) }
}

public struct RecordedTelemetryEvent: Sendable, Equatable {
    public let name: String
    public let attributes: SpanAttributes

    public init(name: String, attributes: SpanAttributes = [:]) {
        self.name = name
        self.attributes = attributes
    }
}

public struct RecordedTelemetrySpan: Sendable, Equatable {
    public let id: Int
    public let parentID: Int?
    public let name: String
    public let attributes: SpanAttributes
    public let events: [RecordedTelemetryEvent]
    public let status: SpanStatus
    public let settled: Bool
    public let endSequence: Int?

    public var parentId: Int? { parentID }

    public init(
        id: Int,
        parentID: Int?,
        name: String,
        attributes: SpanAttributes,
        events: [RecordedTelemetryEvent],
        status: SpanStatus,
        settled: Bool,
        endSequence: Int?
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.attributes = attributes
        self.events = events
        self.status = status
        self.settled = settled
        self.endSequence = endSequence
    }
}

private final class MutableRecordedSpan: @unchecked Sendable {
    let id: Int
    let parentID: Int?
    let name: String
    var attributes: SpanAttributes
    var events: [RecordedTelemetryEvent] = []
    var status: SpanStatus = .ok
    var explicitStatus = false
    var settled = false
    var endSequence: Int?

    init(id: Int, parentID: Int?, options: SpanOptions) {
        self.id = id
        self.parentID = parentID
        name = options.name
        attributes = options.attributes
    }
}

private final class InMemoryTelemetryState: @unchecked Sendable {
    let lock = NSLock()
    var spans: [MutableRecordedSpan] = []
    var nextSpanID = 1
    var nextEndSequence = 1

    func create(parent: MutableRecordedSpan?, options: SpanOptions) -> MutableRecordedSpan? {
        lock.lock()
        defer { lock.unlock() }
        if parent?.settled == true { return nil }
        let span = MutableRecordedSpan(id: nextSpanID, parentID: parent?.id, options: options)
        nextSpanID += 1
        spans.append(span)
        return span
    }

    func mutate(_ span: MutableRecordedSpan, _ body: (MutableRecordedSpan) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !span.settled else { return }
        body(span)
    }

    func settle(_ span: MutableRecordedSpan, error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        guard !span.settled else { return }
        if let error, !span.explicitStatus {
            let normalized = NormalizedError.normalize(error)
            span.status = .error(.init(name: normalized.name, message: normalized.message))
        }
        span.settled = true
        span.endSequence = nextEndSequence
        nextEndSequence += 1
    }

    func snapshot() -> [RecordedTelemetrySpan] {
        lock.lock()
        defer { lock.unlock() }
        return spans.map {
            RecordedTelemetrySpan(
                id: $0.id,
                parentID: $0.parentID,
                name: $0.name,
                attributes: $0.attributes,
                events: $0.events,
                status: $0.status,
                settled: $0.settled,
                endSequence: $0.endSequence
            )
        }
    }
}

private final class InMemoryTelemetrySpan: TelemetrySpan, @unchecked Sendable {
    private let state: InMemoryTelemetryState
    private let record: MutableRecordedSpan

    init(state: InMemoryTelemetryState, record: MutableRecordedSpan) {
        self.state = state
        self.record = record
    }

    func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        operation: @escaping @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        guard let child = state.create(parent: record, options: options) else {
            return try await NoOpTelemetryContext.shared.startSpan(options, operation: operation)
        }
        return try await Self.run(state: state, record: child, operation: operation)
    }

    func addEvent(_ name: String, attributes: SpanAttributes) {
        state.mutate(record) { $0.events.append(.init(name: name, attributes: attributes)) }
    }

    func setAttributes(_ attributes: SpanAttributes) {
        state.mutate(record) { span in
            for (name, value) in attributes { span.attributes[name] = value }
        }
    }

    func setStatus(_ status: SpanStatus) {
        state.mutate(record) {
            $0.status = status
            $0.explicitStatus = true
        }
    }

    static func run<Result: Sendable>(
        state: InMemoryTelemetryState,
        record: MutableRecordedSpan,
        operation: @escaping @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        let span = InMemoryTelemetrySpan(state: state, record: record)
        do {
            let result = try await operation(span)
            state.settle(record, error: nil)
            return result
        } catch {
            state.settle(record, error: error)
            throw error
        }
    }
}

/// Deterministic, unbounded, process-local telemetry capture.
public final class InMemoryTelemetryContext: TelemetryContext, @unchecked Sendable {
    private let state = InMemoryTelemetryState()

    public init() {}

    public func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        operation: @escaping @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        let record = state.create(parent: nil, options: options)!
        return try await InMemoryTelemetrySpan.run(state: state, record: record, operation: operation)
    }

    /// Returns fully detached value snapshots in span-start order.
    public func spans() -> [RecordedTelemetrySpan] { state.snapshot() }

    public func getSpans() -> [RecordedTelemetrySpan] { spans() }
}

private final class NoOpTelemetrySpan: TelemetrySpan, @unchecked Sendable {
    static let shared = NoOpTelemetrySpan()
    private init() {}

    func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        operation: @escaping @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        try await operation(self)
    }

    func addEvent(_ name: String, attributes: SpanAttributes) {}
    func setAttributes(_ attributes: SpanAttributes) {}
    func setStatus(_ status: SpanStatus) {}
}

public struct NoOpTelemetryContext: TelemetryContext, Sendable {
    public static let shared = NoOpTelemetryContext()
    public init() {}

    public func startSpan<Result: Sendable>(
        _ options: SpanOptions,
        operation: @escaping @Sendable (any TelemetrySpan) async throws -> Result
    ) async rethrows -> Result {
        try await operation(NoOpTelemetrySpan.shared)
    }
}

public let noopTelemetryContext: any TelemetryContext = NoOpTelemetryContext.shared
