import Foundation
import XCTest
import ZetaCore

@testable import ZetaHarnessSessions

final class ZetaHarnessSessionsTests: XCTestCase {
    func testJSONLRoundTripLanesFactsAndOpenOperations() async throws {
        let header = try HarnessSessionHeader(
            id: "session",
            createdAt: 1,
            cwd: "/tmp"
        )
        let storage = HarnessSessionStorage(header: header)
        let entry = HarnessEntry(
            id: "entry",
            sequence: 1,
            parentID: nil,
            type: "custom",
            timestamp: 2,
            fields: ["customType": "test", "data": ["value": true]]
        )
        try await storage.apply(.entry(lane: "main", entry))
        let operation = HarnessRecord(
            id: "run",
            sequence: 2,
            lane: "main",
            type: "operation_started",
            timestamp: 3,
            fields: ["intent": ["kind": "run"]]
        )
        try await storage.apply(.record(operation))
        try await storage.apply(.name(sequence: 3, value: "name"))
        let encoded = await storage.encodeJSONL()
        let decoded = try await HarnessSessionStorage.decodeJSONL(encoded)
        let name = await decoded.sessionName()
        let openOperationIDs = await decoded.openOperations(lane: "main").map(\.id)
        let decodedEntry = await decoded.entry("entry")
        XCTAssertEqual(name, "name")
        XCTAssertEqual(openOperationIDs, ["run"])
        XCTAssertEqual(decodedEntry, entry)
    }

    func testRejectsFormatConfusionAndNonconsecutiveSequences() async throws {
        let codingAgentHeader = Data(
            #"{"type":"session","version":3,"id":"s","timestamp":"x","cwd":"/tmp"}\n"#.utf8
        )
        do {
            _ = try await HarnessSessionStorage.decodeJSONL(codingAgentHeader)
            XCTFail("Expected format rejection")
        } catch {}

        let storage = HarnessSessionStorage(
            header: try HarnessSessionHeader(id: "s", createdAt: 0, cwd: "/tmp")
        )
        do {
            try await storage.apply(.lane(sequence: 2, lane: "other", leafID: nil))
            XCTFail("Expected sequence rejection")
        } catch {}
    }

    func testTornSyntaxTailIsDiscardedButCompleteInvalidTailFails() async throws {
        let storage = HarnessSessionStorage(
            header: try HarnessSessionHeader(id: "s", createdAt: 0, cwd: "/tmp")
        )
        try await storage.apply(.lane(sequence: 1, lane: "main", leafID: nil))
        var torn = await storage.encodeJSONL()
        torn.append(Data("{\"kind\":".utf8))
        let recovered = try await HarnessSessionStorage.decodeJSONL(torn)
        let recoveredCount = await recovered.allMutations().count
        XCTAssertEqual(recoveredCount, 1)

        var invalid = await storage.encodeJSONL()
        invalid.append(Data("{\"kind\":\"unknown\",\"seq\":2}\n".utf8))
        do {
            _ = try await HarnessSessionStorage.decodeJSONL(invalid)
            XCTFail("Expected complete invalid tail rejection")
        } catch {}
    }

    func testOneOpenOperationPerLane() async throws {
        let storage = HarnessSessionStorage(
            header: try HarnessSessionHeader(id: "s", createdAt: 0, cwd: "/tmp")
        )
        for (sequence, id) in [(Int64(1), "one"), (Int64(2), "two")] {
            let record = HarnessRecord(
                id: id,
                sequence: sequence,
                lane: "main",
                type: "operation_started",
                timestamp: sequence,
                fields: ["intent": ["kind": "run"]]
            )
            if id == "one" {
                try await storage.apply(.record(record))
            } else {
                do {
                    try await storage.apply(.record(record))
                    XCTFail("Expected open-operation rejection")
                } catch {}
            }
        }
    }
}
