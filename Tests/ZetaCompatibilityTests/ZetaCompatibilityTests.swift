import Foundation
import XCTest
import ZetaAI
import ZetaCore
import ZetaHarnessSessions
import ZetaModes
import ZetaProtocol
import ZetaSessionSQLite
import ZetaSessions
import ZetaTUI
import ZetaTools

final class ZetaCompatibilityTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CompatibilityFixtures/v1")
    }

    func testCanonicalJSONProtocolAndStructuredTranscripts() throws {
        let canonical = try Data(contentsOf: fixtures.appendingPathComponent("canonical-json/values.json"))
        let value = try OrderedJSON.decode(canonical)
        XCTAssertEqual(try OrderedJSON.decode(OrderedJSON.encode(value)), value)

        let framed = try Data(contentsOf: fixtures.appendingPathComponent("protocol/framed-hello.bin"))
        let decoder = try ClientMessageDecoder()
        XCTAssertEqual(try decoder.push(framed), [.hello(try ClientHello())])
        try decoder.end()

        let vectors = try fixtureObject("protocol/cbor-vectors.json")
        guard case .array(let items)? = vectors["vectors"] else { return XCTFail("Missing CBOR vectors") }
        for item in items {
            guard case .object(let object) = item,
                case .string(let hex)? = object["hex"]
            else { return XCTFail("Invalid CBOR vector") }
            _ = try decodeCBOR(Data(hex: hex))
        }

        let events = try jsonLines("events/agent-events.jsonl")
        XCTAssertEqual(events.first?.objectString("type"), "agent_start")
        XCTAssertEqual(events.last?.objectString("type"), "agent_end")
        let rpc = try jsonLines("rpc/transcript.jsonl")
        _ = try StrictRPCRequest.decode(OrderedJSON.encode(rpc[0]))
        XCTAssertEqual(rpc[1].objectString("command"), "prompt")
        XCTAssertEqual(rpc[2].objectString("type"), "agent_event")
    }

    func testProviderTerminalMigrationAndToolFixtures() async throws {
        let requests = try fixtureObject("providers/requests.json")
        for family in ["openai-chat-completions", "anthropic-messages", "google-generative-ai"] {
            XCTAssertNotNil(requests[family])
        }
        let streams = try jsonLines("providers/streams.jsonl")
        XCTAssertEqual(streams.map { $0.objectString("event")! }, ["start", "text_delta", "text_delta", "done"])

        let terminal = try fixtureObject("terminal/ansi-render.json")
        guard case .string(let input)? = terminal["input"],
            case .string(let plain)? = terminal["plainText"],
            case .number(let columns)? = terminal["columns"]
        else { return XCTFail("Invalid terminal fixture") }
        XCTAssertEqual(ANSI.strip(input), plain)
        XCTAssertEqual(ANSI.wrap(input, width: Int(columns.safeIntegerValue!)), [plain])

        let migration = try fixtureObject("migrations/auth-settings.json")
        XCTAssertNotNil(migration["legacySettings"])
        XCTAssertNotNil(migration["expectedSettings"])

        let expected = try fixtureObject("tools/results.json")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = FileTools(workingDirectory: directory)
        try files.write(path: "fixture.txt", content: "alpha\nbeta\n")
        guard case .object(let read)? = expected["read"], case .string(let content)? = read["content"] else {
            return XCTFail("Invalid tool fixture")
        }
        XCTAssertEqual(try files.read(path: "fixture.txt"), content)
        let search = SearchTools(workingDirectory: directory)
        let grep = try await search.grep(pattern: "beta")
        let found = try await search.find(pattern: "*.txt")
        let shell = try await ShellTool(workingDirectory: directory).run(command: "printf 'ok\\n'")
        XCTAssertEqual(grep.first?.line, 2)
        XCTAssertTrue(found.contains { $0.hasSuffix("fixture.txt") })
        XCTAssertEqual(try files.list(), ["fixture.txt"])
        XCTAssertEqual(shell.output, "ok\n")
    }

    func testCurrentSessionAndSQLiteArtifactsOpenWithoutMutation() async throws {
        let sourceV3 = fixtures.appendingPathComponent("sessions/coding-agent-v3.jsonl")
        let temporaryV3 = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jsonl")
        try FileManager.default.copyItem(at: sourceV3, to: temporaryV3)
        defer { try? FileManager.default.removeItem(at: temporaryV3) }
        let session = try SessionManager.load(file: temporaryV3)
        let sessionVersion = await session.header.version
        let sessionEntries = await session.allEntries()
        XCTAssertEqual(sessionVersion, 3)
        XCTAssertEqual(sessionEntries.count, 1)

        let harnessData = try Data(contentsOf: fixtures.appendingPathComponent("sessions/agent-core-v4.jsonl"))
        let harness = try await HarnessSessionStorage.decodeJSONL(harnessData)
        let harnessID = await harness.header.id
        let harnessEntry = await harness.entry("entry-1")
        let harnessLeaf = await harness.lane("main")
        XCTAssertEqual(harnessID, "session-fixture")
        XCTAssertNotNil(harnessEntry)
        XCTAssertEqual(harnessLeaf, "entry-1")

        let sourceDatabase = fixtures.appendingPathComponent("sqlite/current-schema.sqlite3")
        let temporaryDatabase = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString).sqlite3")
        try FileManager.default.copyItem(at: sourceDatabase, to: temporaryDatabase)
        defer {
            try? FileManager.default.removeItem(at: temporaryDatabase)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: temporaryDatabase.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: temporaryDatabase.path + "-shm"))
        }
        let repository = try SQLiteSessionRepository(url: temporaryDatabase)
        let integrity = try await repository.integrityCheck()
        let sessions = try await repository.listSessions().map(\.id)
        let entries = try await repository.entries(sessionID: "session-fixture").map(\.id)
        XCTAssertEqual(integrity, "ok")
        XCTAssertEqual(sessions, ["session-fixture"])
        XCTAssertEqual(entries, ["entry-1"])
    }

    private func fixtureObject(_ path: String) throws -> OrderedJSONObject {
        let value = try OrderedJSON.decode(Data(contentsOf: fixtures.appendingPathComponent(path)))
        guard case .object(let object) = value else { throw CocoaError(.propertyListReadCorrupt) }
        return object
    }

    private func jsonLines(_ path: String) throws -> [JSONValue] {
        try String(contentsOf: fixtures.appendingPathComponent(path), encoding: .utf8)
            .split(separator: "\n")
            .map { try OrderedJSON.decode(Data($0.utf8)) }
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}

private extension JSONValue {
    func objectString(_ key: String) -> String? {
        guard case .object(let object) = self,
            case .string(let value)? = object[key]
        else { return nil }
        return value
    }
}
