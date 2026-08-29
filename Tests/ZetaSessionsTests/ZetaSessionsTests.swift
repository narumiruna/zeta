import XCTest
import ZetaAI

@testable import ZetaSessions

final class ZetaSessionsTests: XCTestCase {
    func testDelayedCreationAndContextProjection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let file = directory.appendingPathComponent("session.jsonl")
        let header = SessionHeader(id: "session-1", timestamp: "2026-01-01T00:00:00Z", cwd: directory.path)
        let manager = try SessionManager(header: header, file: file)
        let userBase = SessionEntryBase(id: "00000001", parentId: nil, timestamp: header.timestamp)
        try await manager.append(.message(userBase, .user(UserMessage("hello", timestamp: 1))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let assistantBase = SessionEntryBase(id: "00000002", parentId: userBase.id, timestamp: header.timestamp)
        let assistant = AssistantMessage(
            content: [.text(text: "hi")], api: "faux", provider: "faux", model: "faux", stopReason: .stop, timestamp: 2)
        try await manager.append(.message(assistantBase, .assistant(assistant)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let loaded = try SessionManager.load(file: file)
        let context = try await loaded.context()
        XCTAssertEqual(context.messages.count, 2)
    }

    func testLoadedSessionAppendsAssistantWithoutRewritingExistingJSONL() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        let original = """
            {"type":"session","version":3,"id":"existing","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}
            not valid json

            """
        try Data(original.utf8).write(to: file)
        let manager = try SessionManager.load(file: file)
        let assistant = AssistantMessage(
            content: [.text(text: "appended")], api: "faux", provider: "faux", model: "faux", stopReason: .stop,
            timestamp: 1)
        try await manager.append(
            .message(
                SessionEntryBase(id: "00000001", parentId: nil, timestamp: "2026-01-01T00:00:01Z"),
                .assistant(assistant)
            )
        )

        let persisted = try Data(contentsOf: file)
        XCTAssertTrue(persisted.starts(with: Data(original.utf8)))
        XCTAssertTrue(String(decoding: persisted, as: UTF8.self).contains("not valid json\n"))
        let reloaded = try SessionManager.load(file: file)
        let entries = await reloaded.allEntries()
        XCTAssertEqual(entries.map(\.base.id), ["00000001"])
    }

    func testExistingFileAppendFailureDoesNotMutateSessionState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        let original =
            #"{"type":"session","version":3,"id":"existing","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}"#
            + "\nnot valid json\n"
        try Data(original.utf8).write(to: file)
        let manager = try SessionManager.load(file: file)
        let entry = SessionEntry.message(
            SessionEntryBase(id: "00000001", parentId: nil, timestamp: "2026-01-01T00:00:01Z"),
            .assistant(
                AssistantMessage(
                    content: [.text(text: "appended")], api: "faux", provider: "faux", model: "faux",
                    stopReason: .stop, timestamp: 1
                ))
        )

        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            try await manager.append(entry)
            XCTFail("Expected persistence failure")
        } catch {}

        let entriesAfterFailure = await manager.allEntries()
        let leafAfterFailure = await manager.leaf()
        let branchAfterFailure = try await manager.branch()
        XCTAssertTrue(entriesAfterFailure.isEmpty)
        XCTAssertNil(leafAfterFailure)
        XCTAssertTrue(branchAfterFailure.isEmpty)

        try FileManager.default.removeItem(at: file)
        try Data(original.utf8).write(to: file)
        try await manager.append(entry)
        let entriesAfterRetry = await manager.allEntries()
        let leafAfterRetry = await manager.leaf()
        XCTAssertEqual(entriesAfterRetry.map(\.base.id), ["00000001"])
        XCTAssertEqual(leafAfterRetry?.base.id, "00000001")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).hasPrefix(original))
    }

    func testFirstAssistantMaterializationFailureDoesNotMutateSessionState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedParent = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blockedParent)
        let file = blockedParent.appendingPathComponent("session.jsonl")
        let header = SessionHeader(id: "delayed", timestamp: "2026-01-01T00:00:00Z", cwd: directory.path)
        let manager = try SessionManager(header: header, file: file)
        let user = SessionEntry.message(
            SessionEntryBase(id: "00000001", parentId: nil, timestamp: header.timestamp),
            .user(UserMessage("hello", timestamp: 1))
        )
        let assistant = SessionEntry.message(
            SessionEntryBase(id: "00000002", parentId: "00000001", timestamp: header.timestamp),
            .assistant(
                AssistantMessage(
                    content: [.text(text: "reply")], api: "faux", provider: "faux", model: "faux",
                    stopReason: .stop, timestamp: 2
                ))
        )
        try await manager.append(user)

        do {
            try await manager.append(assistant)
            XCTFail("Expected materialization failure")
        } catch {}

        let entriesAfterFailure = await manager.allEntries()
        let leafAfterFailure = await manager.leaf()
        let branchAfterFailure = try await manager.branch()
        XCTAssertEqual(entriesAfterFailure.map(\.base.id), ["00000001"])
        XCTAssertEqual(leafAfterFailure?.base.id, "00000001")
        XCTAssertEqual(branchAfterFailure.map(\.base.id), ["00000001"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        try FileManager.default.removeItem(at: blockedParent)
        try FileManager.default.createDirectory(at: blockedParent, withIntermediateDirectories: false)
        try await manager.append(assistant)
        let entriesAfterRetry = await manager.allEntries()
        let leafAfterRetry = await manager.leaf()
        XCTAssertEqual(entriesAfterRetry.map(\.base.id), ["00000001", "00000002"])
        XCTAssertEqual(leafAfterRetry?.base.id, "00000002")
        let loaded = try SessionManager.load(file: file)
        let loadedEntries = await loaded.allEntries()
        XCTAssertEqual(loadedEntries.map(\.base.id), ["00000001", "00000002"])
    }

    func testV1MigrationForkCloneAndNewlineRepair() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("v1.jsonl")
        let content = """
            {"type":"session","id":"legacy","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}
            {"type":"message","timestamp":"2026-01-01T00:00:01Z","message":{"role":"user","content":[{"type":"text","text":"hello"}],"timestamp":1}}
            {"type":"message","timestamp":"2026-01-01T00:00:02Z","message":{"role":"assistant","content":[{"type":"text","text":"hi"}],"api":"faux","provider":"faux","model":"faux","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}},"stopReason":"stop","timestamp":2}}
            """
        try Data(content.utf8).write(to: file)
        let manager = try SessionManager.load(file: file)
        let entries = await manager.allEntries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertNil(entries[0].base.parentId)
        XCTAssertEqual(entries[1].base.parentId, entries[0].base.id)
        let migratedData = try Data(contentsOf: file)
        XCTAssertEqual(migratedData.last, 0x0A)
        let migratedObjects = try migratedData.split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(migratedObjects[0]["version"] as? Int, currentCodingSessionVersion)
        XCTAssertEqual(migratedObjects[1]["id"] as? String, entries[0].base.id)
        XCTAssertEqual(migratedObjects[2]["parentId"] as? String, entries[0].base.id)

        let fork = try await manager.fork(
            header: SessionHeader(
                id: "forked",
                timestamp: "2026-01-01T00:00:03Z",
                cwd: "/tmp"
            ),
            file: nil,
            at: entries[1].base.id,
            includeTarget: false
        )
        let forkEntries = await fork.allEntries()
        XCTAssertEqual(forkEntries.count, 1)
        let clone = try await manager.clone(
            header: SessionHeader(
                id: "cloned",
                timestamp: "2026-01-01T00:00:03Z",
                cwd: "/tmp"
            ),
            file: nil
        )
        let cloneEntries = await clone.allEntries()
        XCTAssertEqual(cloneEntries.count, 2)
    }

    func testStrictJSONLSplitsOnlyLF() {
        var decoder = StrictJSONLDecoder()
        let records = decoder.push(Data("{\"x\":\"a\u{2028}b\"}\r\nlast".utf8)) + decoder.finish()
        XCTAssertEqual(records.map { String(decoding: $0, as: UTF8.self) }, ["{\"x\":\"a\u{2028}b\"}", "last"])
    }
}
