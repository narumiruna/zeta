import Foundation

public struct EvaluationCase: Codable, Sendable, Equatable {
    public var id: String
    public var prompt: String
    public var requiredSubstrings: [String]

    public init(id: String, prompt: String, requiredSubstrings: [String]) {
        self.id = id
        self.prompt = prompt
        self.requiredSubstrings = requiredSubstrings
    }
}

public struct EvaluationResult: Codable, Sendable, Equatable {
    public var id: String
    public var passed: Bool
    public var score: Double
    public var output: String
    public var missing: [String]
}

public struct EvaluationReport: Codable, Sendable, Equatable {
    public var seed: UInt64
    public var results: [EvaluationResult]
    public var passed: Int
    public var total: Int
    public var score: Double
}

public actor EvaluationRunner {
    public typealias Execute = @Sendable (String) async throws -> String

    private let execute: Execute

    public init(execute: @escaping Execute) {
        self.execute = execute
    }

    public func run(
        cases: [EvaluationCase],
        seed: UInt64 = 0
    ) async -> EvaluationReport {
        let ordered = stableOrder(cases, seed: seed)
        var results: [EvaluationResult] = []
        for test in ordered {
            do {
                let output = try await execute(test.prompt)
                let missing = test.requiredSubstrings.filter {
                    !output.localizedCaseInsensitiveContains($0)
                }
                let score =
                    test.requiredSubstrings.isEmpty
                    ? 1
                    : Double(test.requiredSubstrings.count - missing.count)
                        / Double(test.requiredSubstrings.count)
                results.append(
                    EvaluationResult(
                        id: test.id,
                        passed: missing.isEmpty,
                        score: score,
                        output: output,
                        missing: missing
                    )
                )
            } catch {
                results.append(
                    EvaluationResult(
                        id: test.id,
                        passed: false,
                        score: 0,
                        output: "",
                        missing: [String(describing: error)]
                    )
                )
            }
        }
        let passed = results.filter(\.passed).count
        let score =
            results.isEmpty
            ? 0
            : results.reduce(0) { $0 + $1.score } / Double(results.count)
        return EvaluationReport(
            seed: seed,
            results: results.sorted { $0.id < $1.id },
            passed: passed,
            total: results.count,
            score: score
        )
    }

    private func stableOrder(
        _ values: [EvaluationCase],
        seed: UInt64
    ) -> [EvaluationCase] {
        values.sorted { lhs, rhs in
            stableHash(lhs.id, seed: seed) < stableHash(rhs.id, seed: seed)
        }
    }

    private func stableHash(_ value: String, seed: UInt64) -> UInt64 {
        value.utf8.reduce(1_469_598_103_934_665_603 ^ seed) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}
