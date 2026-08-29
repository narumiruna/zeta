import Foundation

public struct TelemetryAdapterFixture: Sendable {
    public let context: any TelemetryContext
    public let getSpans: @Sendable () async throws -> [RecordedTelemetrySpan]
    public let close: @Sendable () async -> Void

    public init(
        context: any TelemetryContext,
        getSpans: @escaping @Sendable () async throws -> [RecordedTelemetrySpan],
        close: @escaping @Sendable () async -> Void = {}
    ) {
        self.context = context
        self.getSpans = getSpans
        self.close = close
    }
}

public struct TelemetryAdapterConformanceCase: Sendable {
    public let group: String
    public let name: String
    private let body: @Sendable () async throws -> Void

    public init(group: String, name: String, body: @escaping @Sendable () async throws -> Void) {
        self.group = group
        self.name = name
        self.body = body
    }

    public func run() async throws { try await body() }
}

public struct TelemetryConformanceFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

private actor ConformanceBox<Value: Sendable> {
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { value }
    func set(_ value: Value) { self.value = value }
}

private actor ConformanceGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

/// Runner-independent normalized cases for callback telemetry adapters.
public enum TelemetryAdapterConformance {
    public typealias Factory = @Sendable () async throws -> TelemetryAdapterFixture

    public static func cases(factory: @escaping Factory) -> [TelemetryAdapterConformanceCase] {
        [
            make(factory, group: "callback lifecycle", name: "preserves callback result") { fixture in
                let result = await fixture.context.startSpan(.init(name: "success")) { _ in 42 }
                try require(result == 42, "Callback result changed")
                let span = try find("success", in: await fixture.getSpans())
                try require(span.settled && span.status == .ok, "Successful span did not settle as ok")
            },
            make(factory, group: "callback lifecycle", name: "records callback errors") { fixture in
                do {
                    _ = try await fixture.context.startSpan(.init(name: "failure")) { _ -> Int in
                        throw ConformanceError.expected
                    }
                    throw TelemetryConformanceFailure("Expected callback to throw")
                } catch ConformanceError.expected {}
                let span = try find("failure", in: await fixture.getSpans())
                guard case .error = span.status else {
                    throw TelemetryConformanceFailure("Thrown callback did not set error status")
                }
                try require(span.settled, "Failed span did not settle")
            },
            make(factory, group: "status", name: "last explicit status wins") { fixture in
                await fixture.context.startSpan(.init(name: "status")) { span in
                    span.setStatus(.error(.init(name: "Expected", message: "first")))
                    span.setStatus(.ok)
                }
                let span = try find("status", in: await fixture.getSpans())
                try require(span.status == .ok, "Last explicit status did not win")
            },
            make(factory, group: "status", name: "explicit status resists automatic overwrite") { fixture in
                do {
                    try await fixture.context.startSpan(.init(name: "explicit-error")) { span in
                        span.setStatus(.ok)
                        throw ConformanceError.expected
                    }
                } catch ConformanceError.expected {}
                let span = try find("explicit-error", in: await fixture.getSpans())
                try require(span.status == .ok, "Automatic error overwrote explicit status")
            },
            make(factory, group: "recording", name: "merges attributes and orders events") { fixture in
                await fixture.context.startSpan(
                    .init(name: "recording", attributes: ["start": "value", "overwrite": "start"])
                ) { span in
                    span.setAttributes(["count": 1, "overwrite": "middle"])
                    span.setAttributes(["overwrite": "end"])
                    span.addEvent("first", attributes: ["index": 1])
                    span.addEvent("second", attributes: ["index": 2])
                }
                let span = try find("recording", in: await fixture.getSpans())
                try require(
                    span.attributes == ["start": "value", "overwrite": "end", "count": 1], "Attributes did not merge")
                try require(span.events.map(\.name) == ["first", "second"], "Events lost source order")
            },
            make(factory, group: "recording", name: "post-settlement calls are inert") { fixture in
                let captured = ConformanceBox<(any TelemetrySpan)?>(nil)
                await fixture.context.startSpan(.init(name: "settled", attributes: ["value": "initial"])) { span in
                    await captured.set(span)
                }
                guard let span = await captured.get() else {
                    throw TelemetryConformanceFailure("Span was not captured")
                }
                span.setAttributes(["value": "late"])
                span.addEvent("late")
                span.setStatus(.error())
                let child = await span.startSpan(.init(name: "late-child")) { _ in 7 }
                try require(child == 7, "Late child callback result changed")
                let spans = try await fixture.getSpans()
                try require(spans.count == 1, "Late child was recorded")
                try require(
                    spans[0].attributes == ["value": "initial"] && spans[0].events.isEmpty, "Late mutation was recorded"
                )
            },
            make(factory, group: "parentage", name: "nested concurrent parentage and settlement order") { fixture in
                let gate = ConformanceGate()
                try await fixture.context.startSpan(.init(name: "parent")) { parent in
                    async let first: Void = parent.startSpan(.init(name: "first-child")) { _ in await gate.wait() }
                    let second = await parent.startSpan(.init(name: "second-child")) { _ in "done" }
                    try require(second == "done", "Second child result changed")
                    await gate.release()
                    await first
                }
                let spans = try await fixture.getSpans()
                let parent = try find("parent", in: spans)
                let first = try find("first-child", in: spans)
                let second = try find("second-child", in: spans)
                try require(first.parentID == parent.id && second.parentID == parent.id, "Child parent ID is incorrect")
                guard let firstEnd = first.endSequence, let secondEnd = second.endSequence,
                    let parentEnd = parent.endSequence
                else {
                    throw TelemetryConformanceFailure("Settled spans lack end sequences")
                }
                try require(secondEnd < firstEnd && firstEnd < parentEnd, "Settlement order is incorrect")
            },
        ]
    }

    private enum ConformanceError: Error { case expected }

    private static func make(
        _ factory: @escaping Factory,
        group: String,
        name: String,
        test: @escaping @Sendable (TelemetryAdapterFixture) async throws -> Void
    ) -> TelemetryAdapterConformanceCase {
        TelemetryAdapterConformanceCase(group: group, name: name) {
            let fixture = try await factory()
            do {
                try await test(fixture)
                await fixture.close()
            } catch {
                await fixture.close()
                throw error
            }
        }
    }

    private static func find(_ name: String, in spans: [RecordedTelemetrySpan]) throws -> RecordedTelemetrySpan {
        guard let span = spans.first(where: { $0.name == name }) else {
            throw TelemetryConformanceFailure("Expected recorded span \(name)")
        }
        return span
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TelemetryConformanceFailure(message) }
    }
}
