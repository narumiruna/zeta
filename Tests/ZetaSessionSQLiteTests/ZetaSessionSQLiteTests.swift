import SQLite3
import XCTest
import ZetaCore

@testable import ZetaSessionSQLite

final class ZetaSessionSQLiteTests: XCTestCase {
    func testDatabaseOperationsUseDedicatedSerialStorageExecutor() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteSessionRepository(url: url)

        let isDedicated = await repository.isOnDedicatedStorageExecutor()
        XCTAssertTrue(isDedicated)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    try await repository.createSession(
                        SQLiteSessionMetadata(
                            id: "session-\(index)",
                            createdAt: Int64(index),
                            cwd: "/tmp"
                        )
                    )
                }
            }
            try await group.waitForAll()
        }
        let sessions = try await repository.listSessions()
        XCTAssertEqual(sessions.count, 20)
        let integrity = try await repository.integrityCheck()
        XCTAssertEqual(integrity, "ok")
    }

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

    func testSearchBuildsOnceAndTriggersMaintainTheIndexAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var repository: SQLiteSessionRepository? = try SQLiteSessionRepository(url: url)
        try await repository?.createSession(SQLiteSessionMetadata(id: "s", createdAt: 1, cwd: "/tmp"))
        let storedLease = try await repository?.acquireLease(sessionID: "s", ownerID: "owner", now: 1)
        let lease = try XCTUnwrap(storedLease)
        _ = try await repository?.append(
            sessionID: "s", id: "before", parentID: nil, type: "message", timestamp: 2,
            payload: ["text": "beforetoken"], lease: lease, now: 2)
        let initialHits = try await repository?.search("beforetoken") ?? []
        XCTAssertEqual(initialHits.map(\.entryID), ["before"])
        _ = try await repository?.append(
            sessionID: "s", id: "after", parentID: "before", type: "message", timestamp: 3,
            payload: ["text": "aftertoken"], lease: lease, now: 3)
        let triggeredHits = try await repository?.search("aftertoken") ?? []
        XCTAssertEqual(triggeredHits.map(\.entryID), ["after"])
        repository = nil

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "INSERT INTO entries_fts(entries_fts,rowid,payload) "
                    + "SELECT 'delete',rowid,payload FROM entries WHERE id='before'",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(database)

        let reopened = try SQLiteSessionRepository(url: url)
        let hits = try await reopened.search("beforetoken")
        XCTAssertTrue(hits.isEmpty)
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
            payload: [
                "cause": "assistant",
                "usage": [
                    "input": 7, "output": 2, "cacheRead": 3, "cacheWrite": 4, "totalTokens": 16,
                    "cost": ["input": 0.1, "output": 0.2, "cacheRead": 0.05, "cacheWrite": 0.15],
                ],
            ],
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
        XCTAssertEqual(
            stats,
            SQLiteSessionStats(
                messageCount: 2,
                cachedTokens: 3,
                uncachedTokens: 11,
                totalTokens: 16,
                costTotal: 0.5
            )
        )
        try await repository.repairBranchCache(sessionID: "s")
        let integrity = try await repository.integrityCheck()
        XCTAssertEqual(integrity, "ok")
    }

    func testUsageRecordFailuresRollBackRecordSequenceAndStats() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = try SQLiteSessionRepository(url: url)
        try await repository.createSession(
            SQLiteSessionMetadata(id: "valid", createdAt: 1, cwd: "/tmp")
        )
        let validLease = try await repository.acquireLease(
            sessionID: "valid",
            ownerID: "owner",
            now: 1
        )
        do {
            _ = try await repository.appendRecord(
                sessionID: "valid",
                id: "malformed",
                lane: "main",
                runID: nil,
                type: "usage",
                operationKind: nil,
                timestamp: 2,
                payload: ["cause": "adjustment"],
                lease: validLease,
                now: 2
            )
            XCTFail("Expected malformed usage rejection")
        } catch {
            XCTAssertEqual(
                (error as? SQLiteRepositoryError)?.errorDescription,
                "SQLite operation failed: Invalid usage record payload"
            )
        }
        let emptyRecords = try await repository.records(sessionID: "valid")
        let emptyStats = try await repository.stats(sessionID: "valid")
        XCTAssertEqual(emptyRecords, [])
        XCTAssertEqual(
            emptyStats,
            SQLiteSessionStats(
                messageCount: 0,
                cachedTokens: 0,
                uncachedTokens: 0,
                totalTokens: 0,
                costTotal: 0
            )
        )

        let payload: JSONValue = [
            "cause": "adjustment",
            "usage": [
                "input": 7, "output": 2, "cacheRead": 3, "cacheWrite": 4, "totalTokens": 16,
                "cost": ["input": 0.1, "output": 0.2, "cacheRead": 0.05, "cacheWrite": 0.15, "total": 0.5],
            ],
        ]
        let committed = try await repository.appendRecord(
            sessionID: "valid",
            id: "usage",
            lane: "main",
            runID: nil,
            type: "usage",
            operationKind: nil,
            timestamp: 3,
            payload: payload,
            lease: validLease,
            now: 3
        )
        XCTAssertEqual(committed.sequence, 1)
        let aggregateStats = try await repository.stats(sessionID: "valid")
        XCTAssertEqual(
            aggregateStats,
            SQLiteSessionStats(
                messageCount: 0,
                cachedTokens: 3,
                uncachedTokens: 11,
                totalTokens: 16,
                costTotal: 0.5
            )
        )

        try await repository.createSession(
            SQLiteSessionMetadata(id: "corrupt", createdAt: 4, cwd: "/tmp")
        )
        let corruptLease = try await repository.acquireLease(
            sessionID: "corrupt",
            ownerID: "owner",
            now: 4
        )
        try executeSQL(
            "DELETE FROM session_stats WHERE session_id='corrupt'",
            at: url
        )
        do {
            _ = try await repository.appendRecord(
                sessionID: "corrupt",
                id: "rolled-back",
                lane: "main",
                runID: nil,
                type: "usage",
                operationKind: nil,
                timestamp: 5,
                payload: payload,
                lease: corruptLease,
                now: 5
            )
            XCTFail("Expected missing statistics rejection")
        } catch {
            XCTAssertEqual(
                (error as? SQLiteRepositoryError)?.errorDescription,
                "SQLite operation failed: Missing session statistics"
            )
        }
        let corruptRecords = try await repository.records(sessionID: "corrupt")
        XCTAssertEqual(corruptRecords, [])
        try executeSQL(
            "INSERT INTO session_stats VALUES('corrupt',0,0,0,0,0)",
            at: url
        )
        let retried = try await repository.appendRecord(
            sessionID: "corrupt",
            id: "retried",
            lane: "main",
            runID: nil,
            type: "usage",
            operationKind: nil,
            timestamp: 6,
            payload: payload,
            lease: corruptLease,
            now: 6
        )
        XCTAssertEqual(retried.sequence, 1)
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

    private func executeSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw SQLiteRepositoryError.open("test database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
    }
}
