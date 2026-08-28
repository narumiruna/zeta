import XCTest

@testable import ZetaEvals

final class ZetaEvalsTests: XCTestCase {
    func testSeededReportsAreStable() async {
        let runner = EvaluationRunner { prompt in
            prompt == "one" ? "alpha beta" : "gamma"
        }
        let cases = [
            EvaluationCase(id: "b", prompt: "two", requiredSubstrings: ["gamma"]),
            EvaluationCase(id: "a", prompt: "one", requiredSubstrings: ["alpha", "beta"]),
        ]
        let first = await runner.run(cases: cases, seed: 42)
        let second = await runner.run(cases: cases, seed: 42)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.passed, 2)
        XCTAssertEqual(first.score, 1)
        XCTAssertEqual(first.results.map(\.id), ["a", "b"])
    }
}
