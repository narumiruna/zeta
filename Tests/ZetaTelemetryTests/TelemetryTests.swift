import Foundation
import Testing

@testable import ZetaTelemetry

@Suite struct TelemetryTests {
    @Test func inMemoryAdapterConformance() async throws {
        let cases = TelemetryAdapterConformance.cases {
            let context = InMemoryTelemetryContext()
            return TelemetryAdapterFixture(context: context, getSpans: { context.spans() })
        }
        #expect(cases.count == 7)
        for testCase in cases { try await testCase.run() }
    }

    @Test func snapshotsAreDetachedAndExposeOpenState() async {
        let context = InMemoryTelemetryContext()
        let openState = StateBox<(Bool, Int?)?>(nil)
        await context.startSpan(.init(name: "snapshot", attributes: ["tags": ["initial"]])) { span in
            span.addEvent("event", attributes: ["value": 1])
            let open = context.spans()[0]
            await openState.set((open.settled, open.endSequence))
        }
        let observed = await openState.get()
        #expect(observed?.0 == false)
        #expect(observed?.1 == nil)
        let first = context.spans()[0]
        #expect(first.settled)
        #expect(first.endSequence == 1)
        var changedAttributes = first.attributes
        changedAttributes["tags"] = ["mutated"]
        var changedEvents = first.events
        changedEvents[0] = .init(name: "changed")
        #expect(changedAttributes != context.spans()[0].attributes)
        #expect(changedEvents != context.spans()[0].events)
    }

    @Test func noOpReusesOneInertSpanAndPropagatesErrors() async {
        let identities = StateBox<[ObjectIdentifier]>([])
        let result = await NoOpTelemetryContext.shared.startSpan(.init(name: "first")) { span in
            await identities.append(ObjectIdentifier(span as AnyObject))
            let child = await span.startSpan(.init(name: "child")) { child -> ObjectIdentifier in
                child.setAttributes(["ignored": true])
                return ObjectIdentifier(child as AnyObject)
            }
            await identities.append(child)
            return 42
        }
        #expect(result == 42)
        let values = await identities.get()
        #expect(values.count == 2)
        #expect(values[0] == values[1])
        do {
            try await NoOpTelemetryContext.shared.startSpan(.init(name: "error")) { _ in
                throw TelemetryTestError.expected
            }
            Issue.record("Expected error")
        } catch TelemetryTestError.expected {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func concurrentRootsReceiveUniqueOrderedIDs() async {
        let context = InMemoryTelemetryContext()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { await context.startSpan(.init(name: "span-\(index)")) { _ in } }
            }
        }
        let spans = context.spans()
        #expect(spans.count == 100)
        #expect(Set(spans.map(\.id)) == Set(1...100))
        #expect(Set(spans.compactMap(\.endSequence)) == Set(1...100))
        #expect(spans.allSatisfy { $0.parentID == nil && $0.settled })
    }

    @Test func explicitExpectedFailureCanReturnNormally() async {
        let context = InMemoryTelemetryContext()
        let result = await context.startSpan(.init(name: "expected")) { span in
            span.setStatus(.error(.init(name: "Expected", message: "normal result")))
            return false
        }
        #expect(!result)
        #expect(context.spans()[0].status == .error(.init(name: "Expected", message: "normal result")))
    }
}

private enum TelemetryTestError: Error { case expected }

private actor StateBox<Value: Sendable> {
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { value }
    func set(_ value: Value) { self.value = value }
    func append<Element>(_ element: Element) where Value == [Element], Element: Sendable { value.append(element) }
}
