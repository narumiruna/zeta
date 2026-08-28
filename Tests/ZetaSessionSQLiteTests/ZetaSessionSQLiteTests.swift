import SQLite3
import XCTest
import ZetaCore

@testable import ZetaSessionSQLite

final class ZetaSessionSQLiteTests: XCTestCase {
    func testSchemaLeaseEntriesAndSearch() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteSessionRepository(url: url)
        try await repository.createSession(
            SQLiteSessionMetadata(id: "s", createdAt: 1, cwd: "/tmp", metadata: ["name": "test"]))
        let lease = try await repository.acquireLease(sessionID: "s", ownerID: "owner", now: 1)
        _ = try await repository.append(
            sessionID: "s", id: "e", parentID: nil, type: "message", timestamp: 2,
            payload: ["text": "needle in payload"], lease: lease, now: 2)
        let entries = try await repository.entries(sessionID: "s")
        XCTAssertEqual(entries.count, 1)
        let integrity = try await repository.integrityCheck()
        XCTAssertEqual(integrity, "ok")
        let hits = try await repository.search("needle")
        XCTAssertEqual(hits.first?.entryID, "e")
    }

    func testRecordsFactsBranchesAndRepair() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteSessionRepository(url: url)
        try await repository.createSession(
            SQLiteSessionMetadata(id: "s", createdAt: 1, cwd: "/tmp")
        )
        let lease = try await repository.acquireLease(
            sessionID: "s",
            ownerID: "owner",
            now: 1
        )
        _ = try await repository.append(
            sessionID: "s",
            id: "root",
            parentID: nil,
            type: "message",
            timestamp: 2,
            payload: ["text": "root"],
            lease: lease,
            now: 2
        )
        _ = try await repository.append(
            sessionID: "s",
            id: "left",
            parentID: "root",
            type: "custom",
            timestamp: 3,
            payload: ["customType": "test"],
            lease: lease,
            now: 3
        )
        _ = try await repository.append(
            sessionID: "s",
            id: "right",
            parentID: "root",
            type: "message",
            timestamp: 4,
            payload: ["text": "right"],
            lease: lease,
            now: 4
        )
        _ = try await repository.appendRecord(
            sessionID: "s",
            id: "record",
            lane: "main",
            runID: "run",
            type: "usage",
            operationKind: nil,
            timestamp: 5,
            payload: ["cause": "assistant"],
            lease: lease,
            now: 5
        )
        try await repository.setName(
            sessionID: "s",
            name: "Session",
            lease: lease,
            now: 6
        )
        try await repository.setLabel(
            sessionID: "s",
            entryID: "root",
            label: "bookmark",
            lease: lease,
            now: 7
        )
        let records = try await repository.records(sessionID: "s")
        let name = try await repository.name(sessionID: "s")
        let label = try await repository.label(sessionID: "s", entryID: "root")
        let stats = try await repository.stats(sessionID: "s")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(name, "Session")
        XCTAssertEqual(label, "bookmark")
        XCTAssertEqual(stats.messageCount, 2)
        try await repository.repairBranchCache(sessionID: "s")
        let integrity = try await repository.integrityCheck()
        XCTAssertEqual(integrity, "ok")
    }

    func testBranchAndTreeForksReassignSequencesAndDeleteExplicitly() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteSessionRepository(url: url)
        try await repository.createSession(
            SQLiteSessionMetadata(id: "source", createdAt: 1, cwd: "/source")
        )
        let lease = try await repository.acquireLease(
            sessionID: "source",
            ownerID: "owner",
            now: 1
        )
        _ = try await repository.append(
            sessionID: "source",
            id: "root",
            parentID: nil,
            type: "message",
            timestamp: 2,
            payload: ["text": "root"],
            lease: lease,
            now: 2
        )
        _ = try await repository.append(
            sessionID: "source",
            id: "left",
            parentID: "root",
            type: "message",
            timestamp: 3,
            payload: ["text": "left"],
            lease: lease,
            now: 3
        )
        _ = try await repository.append(
            sessionID: "source",
            id: "right",
            parentID: "root",
            type: "custom",
            timestamp: 4,
            payload: ["customType": "branch"],
            lease: lease,
            now: 4
        )
        try await repository.setName(
            sessionID: "source",
            name: "Source",
            lease: lease,
            now: 5
        )
        try await repository.setLabel(
            sessionID: "source",
            entryID: "root",
            label: "root-label",
            lease: lease,
            now: 6
        )
        try await repository.forkSession(
            sourceID: "source",
            destination: SQLiteSessionMetadata(
                id: "branch",
                createdAt: 7,
                cwd: "/branch"
            ),
            scope: .branch(entryID: "left", includeTarget: false)
        )
        let branchEntries = try await repository.entries(sessionID: "branch")
        XCTAssertEqual(branchEntries.map(\.id), ["root"])
        XCTAssertEqual(branchEntries.map(\.sequence), [1])
        let branchName = try await repository.name(sessionID: "branch")
        let branchLabel = try await repository.label(
            sessionID: "branch",
            entryID: "root"
        )
        XCTAssertEqual(branchName, "Source")
        XCTAssertEqual(branchLabel, "root-label")
        try await repository.forkSession(
            sourceID: "source",
            destination: SQLiteSessionMetadata(
                id: "tree",
                createdAt: 8,
                cwd: "/tree"
            ),
            scope: .tree
        )
        let treeEntries = try await repository.entries(sessionID: "tree")
        let treeRecords = try await repository.records(sessionID: "tree")
        XCTAssertEqual(treeEntries.count, 3)
        XCTAssertEqual(treeRecords, [])
        try await repository.deleteSession("branch")
        let sessions = try await repository.listSessions()
        XCTAssertFalse(sessions.contains { $0.id == "branch" })
    }

    func testHistoricalSchemaIsRejectedWithoutMutation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE migrations(id TEXT PRIMARY KEY,applied_at TEXT);"
                    + "INSERT INTO migrations VALUES('001_initial.sql','old');"
                    + "CREATE TABLE entries(timestamp TEXT);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(database)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try SQLiteSessionRepository(url: url))
        let after = try Data(contentsOf: url)
        XCTAssertEqual(before, after)
    }

    func testStaleLeaseCannotRenewAfterTakeover() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteSessionRepository(url: url, leaseTTL: 10)
        try await repository.createSession(SQLiteSessionMetadata(id: "s", createdAt: 1, cwd: "/tmp"))
        let old = try await repository.acquireLease(sessionID: "s", ownerID: "old", now: 0)
        _ = try await repository.acquireLease(sessionID: "s", ownerID: "new", now: 11)
        do {
            _ = try await repository.renew(old, now: 12)
            XCTFail("Expected stale lease")
        } catch {}
    }
}
