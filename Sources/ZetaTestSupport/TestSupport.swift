import Foundation

public actor DeterministicClock {
    private var milliseconds: Int64
    private var sleepers: [(deadline: Int64, continuation: CheckedContinuation<Void, Never>)] = []

    public init(milliseconds: Int64 = 0) { self.milliseconds = milliseconds }
    public func now() -> Int64 { milliseconds }
    public func advance(by delta: Int64) {
        milliseconds += delta
        let ready = sleepers.filter { $0.deadline <= milliseconds }
        sleepers.removeAll { $0.deadline <= milliseconds }
        ready.forEach { $0.continuation.resume() }
    }
    public func sleep(milliseconds delta: Int64) async {
        let deadline = milliseconds + delta
        await withCheckedContinuation { sleepers.append((deadline, $0)) }
    }
}

public actor DeterministicIDs {
    private var nextValue: Int
    public init(start: Int = 1) { nextValue = start }
    public func next(prefix: String = "id") -> String {
        defer { nextValue += 1 }
        return "\(prefix)-\(nextValue)"
    }
}

public actor EffectGate {
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public init() {}
    public func wait() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
    public func release(_ count: Int = 1) {
        for _ in 0..<count {
            if !waiters.isEmpty { waiters.removeFirst().resume() } else { permits += 1 }
        }
    }
}

public enum ByteFragmenter {
    public static func everySplit(_ data: Data) -> [[Data]] {
        guard data.count > 1 else { return [[data]] }
        return (1..<data.count).map { [Data(data[..<$0]), Data(data[$0...])] }
    }

    public static func chunks(_ data: Data, sizes: [Int]) -> [Data] {
        var output: [Data] = []
        var offset = 0
        for size in sizes where offset < data.count {
            let end = min(data.count, offset + max(1, size))
            output.append(Data(data[offset..<end]))
            offset = end
        }
        if offset < data.count { output.append(Data(data[offset...])) }
        return output
    }
}

public actor FailureInjector<Value: Sendable> {
    public enum Failure: Error, Sendable { case injected(Int) }
    private var values: [Value] = []
    private var operationCount = 0
    private var failurePoints: Set<Int>

    public init(failurePoints: Set<Int> = []) { self.failurePoints = failurePoints }
    public func append(_ value: Value) throws {
        operationCount += 1
        if failurePoints.contains(operationCount) { throw Failure.injected(operationCount) }
        values.append(value)
    }
    public func snapshot() -> [Value] { values }
}

public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL
    public init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}
