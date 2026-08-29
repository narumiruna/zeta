import Foundation
import ZetaAI
import ZetaCore
import ZetaPluginAPI
import ZetaProtocol
import ZetaSearch
import ZetaSessionSQLite
import ZetaTUI
import ZetaTerminal

struct BenchmarkResult: Codable {
    var name: String
    var iterations: Int
    var milliseconds: Double
}

@main
enum Benchmarks {
    static func main() async throws {
        var results: [BenchmarkResult] = []
        let json: JSONValue = [
            "message": "hello",
            "values": .array((0..<100).map { .number(JSONNumber($0)) }),
        ]
        results.append(
            measure("ordered-json", iterations: 1_000) {
                _ = try! OrderedJSON.decode(OrderedJSON.encode(json))
            })
        let cbor = try encodeCBOR(CBORValue(jsonValue: json))
        results.append(
            measure("cbor", iterations: 1_000) {
                _ = try! decodeCBOR(cbor)
            })
        let text = Text(String(repeating: "hello 漢🙂 ", count: 100))
        results.append(
            measure("tui-render", iterations: 1_000) {
                _ = text.render(width: 100)
            })
        results.append(
            measure("model-catalog", iterations: 10) {
                _ = try! BuiltinModelCatalog.bundled()
            })
        let envelope = PluginEnvelope(
            id: "id",
            type: "request",
            generation: 1,
            method: "tool",
            payload: Data(repeating: 1, count: 1_024)
        )
        results.append(
            measure("plugin-envelope", iterations: 10_000) {
                _ = try! JSONEncoder().encode(envelope)
            })
        let model = Model(
            id: "model",
            name: "Model",
            api: "openai-completions",
            provider: "test",
            baseURL: URL(string: "https://example.com")!,
            contextWindow: 100,
            maximumTokens: 10
        )
        results.append(
            measure("provider-events", iterations: 1_000) {
                var reducer = ProviderEventReducer(model: model)
                _ = try! reducer.consume([
                    "choices": .array([["delta": ["content": "hello"]]])
                ])
            })
        let documents = (0..<1_000).map {
            SearchDocument(
                sessionID: "session",
                entryID: "entry-\($0)",
                entryType: "message",
                text: $0 == 999 ? "needle" : "ordinary"
            )
        }
        results.append(
            try await measureAsync("session-search", iterations: 10) {
                let sources = ArraySearchSources([("session", documents)])
                for try await _ in SessionSearch.scan(sources, query: "needle") {}
            }
        )
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeta-benchmark-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let repository = try SQLiteSessionRepository(url: databaseURL)
        try await repository.createSession(
            SQLiteSessionMetadata(id: "session", createdAt: 0, cwd: "/tmp")
        )
        let lease = try await repository.acquireLease(
            sessionID: "session",
            ownerID: "benchmark",
            now: 0
        )
        var parent: String?
        results.append(
            try await measureAsync("sqlite-append", iterations: 100) {
                let id = UUID().uuidString
                _ = try await repository.append(
                    sessionID: "session",
                    id: id,
                    parentID: parent,
                    type: "message",
                    timestamp: 1,
                    payload: ["text": "hello"],
                    lease: lease,
                    now: 1
                )
                parent = id
            }
        )
        let output = try JSONEncoder.pretty.encode(results)
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    @MainActor
    private static func measureAsync(
        _ name: String,
        iterations: Int,
        operation: () async throws -> Void
    ) async throws -> BenchmarkResult {
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations { try await operation() }
        let duration = start.duration(to: clock.now)
        return result(name, iterations: iterations, duration: duration)
    }

    private static func measure(
        _ name: String,
        iterations: Int,
        operation: () -> Void
    ) -> BenchmarkResult {
        let clock = ContinuousClock()
        let duration = clock.measure {
            for _ in 0..<iterations { operation() }
        }
        return result(name, iterations: iterations, duration: duration)
    }

    private static func result(
        _ name: String,
        iterations: Int,
        duration: Duration
    ) -> BenchmarkResult {
        BenchmarkResult(
            name: name,
            iterations: iterations,
            milliseconds: Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1e15
        )
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
