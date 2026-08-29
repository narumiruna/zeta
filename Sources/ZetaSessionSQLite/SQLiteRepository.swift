import Foundation
import SQLite3
import ZetaCore

public enum SQLiteRepositoryError: Error, LocalizedError, Sendable {
    case open(String)
    case execute(String)
    case unsupportedSQLite(String)
    case staleLease
    case unsupportedSchema

    public var errorDescription: String? {
        switch self {
        case .open(let value): "Could not open SQLite database: \(value)"
        case .execute(let value): "SQLite operation failed: \(value)"
        case .unsupportedSQLite(let value): "SQLite capability is unavailable: \(value)"
        case .staleLease: "Session writer lease is stale"
        case .unsupportedSchema:
            "Database was created by an unsupported historical schema; export it with the matching Pi version before importing"
        }
    }
}

public struct SQLiteSessionMetadata: Codable, Sendable, Equatable {
    public var id: String
    public var createdAt: Int64
    public var cwd: String
    public var parentSessionID: String?
    public var metadata: JSONValue?

    public init(
        id: String,
        createdAt: Int64,
        cwd: String,
        parentSessionID: String? = nil,
        metadata: JSONValue? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.cwd = cwd
        self.parentSessionID = parentSessionID
        self.metadata = metadata
    }
}

public struct SQLiteEntry: Codable, Sendable, Equatable {
    public var sessionID: String
    public var sequence: Int64
    public var id: String
    public var parentID: String?
    public var type: String
    public var timestamp: Int64
    public var payload: JSONValue
}

public struct SQLiteRecord: Codable, Sendable, Equatable {
    public var sessionID: String
    public var sequence: Int64
    public var id: String
    public var lane: String
    public var runID: String?
    public var type: String
    public var operationKind: String?
    public var timestamp: Int64
    public var payload: JSONValue
}

public struct SQLiteSessionStats: Sendable, Equatable {
    public var messageCount: Int64
    public var cachedTokens: Double
    public var uncachedTokens: Double
    public var totalTokens: Double
    public var costTotal: Double
}

public enum SQLiteForkScope: Sendable, Equatable {
    case branch(entryID: String?, includeTarget: Bool)
    case tree
}

public struct WriterLease: Sendable, Equatable {
    public var sessionID: String
    public var ownerID: String
    public var fence: Int64
    public var expiresAtMilliseconds: Int64
}

public actor SQLiteSessionRepository {
    private let storageExecutor = SQLiteStorageExecutor()
    nonisolated(unsafe) private var database: OpaquePointer?
    public let url: URL
    public let leaseTTL: Int64
    private var searchInitialized = false

    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        storageExecutor.asUnownedSerialExecutor()
    }

    public init(url: URL, leaseTTL: Int64 = 30_000) throws {
        self.url = url
        self.leaseTTL = leaseTTL
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
                == SQLITE_OK, let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw SQLiteRepositoryError.open(message)
        }
        database = handle
        do {
            try Self.verifyExistingSchema(handle)
            try Self.execute(handle, "PRAGMA journal_mode=WAL;")
            try Self.execute(handle, "PRAGMA synchronous=FULL;")
            try Self.execute(handle, "PRAGMA busy_timeout=5000;")
            try Self.execute(handle, SQLiteRepositorySchema.schema)
            try Self.verifyCapabilities(handle)
        } catch {
            sqlite3_close(handle)
            database = nil
            throw error
        }
    }

    deinit { if let database { sqlite3_close(database) } }

    public func createSession(_ value: SQLiteSessionMetadata) throws {
        try transaction {
            try execute(
                "INSERT INTO sessions(id,created_at,cwd,parent_session_id,metadata) VALUES(?,?,?,?,?)",
                [
                    .text(value.id), .integer(value.createdAt), .text(value.cwd),
                    value.parentSessionID.map(Binding.text) ?? .null,
                    value.metadata.map { .text(OrderedJSON.string($0)) } ?? .null,
                ])
            try execute("INSERT INTO session_sequences(session_id,next_seq) VALUES(?,1)", [.text(value.id)])
            try execute(
                "INSERT INTO session_stats(session_id,message_count,cached_tokens,uncached_tokens,total_tokens,cost_total) VALUES(?,0,0,0,0,0)",
                [.text(value.id)])
            try execute(
                "INSERT INTO lanes(session_id,lane,leaf_id,open_operation_id) VALUES(?,'main',NULL,NULL)",
                [.text(value.id)])
        }
    }

    public func listSessions() throws -> [SQLiteSessionMetadata] {
        try query("SELECT id,created_at,cwd,parent_session_id,metadata FROM sessions ORDER BY created_at DESC", []) {
            statement in
            SQLiteSessionMetadata(
                id: Self.text(statement, 0)!, createdAt: sqlite3_column_int64(statement, 1),
                cwd: Self.text(statement, 2)!,
                parentSessionID: Self.text(statement, 3),
                metadata: try Self.text(statement, 4).map { try OrderedJSON.decode($0) }
            )
        }
    }

    public func acquireLease(sessionID: String, ownerID: String, now: Int64) throws -> WriterLease {
        let expires = now + leaseTTL
        let rows = try query(
            """
            INSERT INTO writer_leases(session_id,owner_id,fence,expires_at_ms) VALUES(?,?,1,?)
            ON CONFLICT(session_id) DO UPDATE SET owner_id=excluded.owner_id,fence=writer_leases.fence+1,expires_at_ms=excluded.expires_at_ms
            WHERE writer_leases.expires_at_ms<=? OR writer_leases.owner_id=excluded.owner_id
            RETURNING fence,expires_at_ms
            """, [.text(sessionID), .text(ownerID), .integer(expires), .integer(now)]
        ) { statement in
            WriterLease(
                sessionID: sessionID, ownerID: ownerID, fence: sqlite3_column_int64(statement, 0),
                expiresAtMilliseconds: sqlite3_column_int64(statement, 1))
        }
        guard let lease = rows.first else { throw SQLiteRepositoryError.staleLease }
        return lease
    }

    public func renew(_ lease: WriterLease, now: Int64) throws -> WriterLease {
        let expires = now + leaseTTL
        try execute(
            "UPDATE writer_leases SET expires_at_ms=? WHERE session_id=? AND owner_id=? AND fence=? AND expires_at_ms>?",
            [.integer(expires), .text(lease.sessionID), .text(lease.ownerID), .integer(lease.fence), .integer(now)])
        guard sqlite3_changes(database) == 1 else { throw SQLiteRepositoryError.staleLease }
        return WriterLease(
            sessionID: lease.sessionID, ownerID: lease.ownerID, fence: lease.fence, expiresAtMilliseconds: expires)
    }

    public func append(
        sessionID: String, id: String, parentID: String?, type: String, timestamp: Int64, payload: JSONValue,
        lease: WriterLease, now: Int64
    ) throws -> SQLiteEntry {
        try transaction {
            _ = try renew(lease, now: now)
            let sequence = try nextSequence(sessionID)
            try execute(
                "INSERT INTO entries(session_id,seq,id,parent_id,type,timestamp,payload) VALUES(?,?,?,?,?,?,?)",
                [
                    .text(sessionID), .integer(sequence), .text(id), parentID.map(Binding.text) ?? .null, .text(type),
                    .integer(timestamp), .text(OrderedJSON.string(payload)),
                ])
            try updateBranchCache(
                sessionID: sessionID,
                entryID: id,
                parentID: parentID,
                sequence: sequence,
                entryType: type,
                payload: payload
            )
            try execute("UPDATE lanes SET leaf_id=? WHERE session_id=? AND lane='main'", [.text(id), .text(sessionID)])
            if type == "message" {
                try execute(
                    "UPDATE session_stats SET message_count=message_count+1 WHERE session_id=?", [.text(sessionID)])
            }
            return SQLiteEntry(
                sessionID: sessionID, sequence: sequence, id: id, parentID: parentID, type: type, timestamp: timestamp,
                payload: payload)
        }
    }

    public func entries(sessionID: String) throws -> [SQLiteEntry] {
        try query(
            "SELECT seq,id,parent_id,type,timestamp,payload FROM entries WHERE session_id=? ORDER BY seq",
            [.text(sessionID)]
        ) { statement in
            SQLiteEntry(
                sessionID: sessionID, sequence: sqlite3_column_int64(statement, 0), id: Self.text(statement, 1)!,
                parentID: Self.text(statement, 2), type: Self.text(statement, 3)!,
                timestamp: sqlite3_column_int64(statement, 4), payload: try OrderedJSON.decode(Self.text(statement, 5)!)
            )
        }
    }

    public func appendRecord(
        sessionID: String,
        id: String,
        lane: String,
        runID: String?,
        type: String,
        operationKind: String?,
        timestamp: Int64,
        payload: JSONValue,
        lease: WriterLease,
        now: Int64
    ) throws -> SQLiteRecord {
        try transaction {
            _ = try renew(lease, now: now)
            let sequence = try nextSequence(sessionID)
            try execute(
                "INSERT INTO records(session_id,seq,id,lane,run_id,type,op_kind,timestamp,payload) VALUES(?,?,?,?,?,?,?,?,?)",
                [
                    .text(sessionID), .integer(sequence), .text(id), .text(lane),
                    runID.map(Binding.text) ?? .null, .text(type),
                    operationKind.map(Binding.text) ?? .null, .integer(timestamp),
                    .text(OrderedJSON.string(payload)),
                ]
            )
            if type == "usage" {
                let usage = try sqliteUsageStatsDelta(payload)
                try execute(
                    """
                    UPDATE session_stats
                    SET cached_tokens=cached_tokens+?,
                        uncached_tokens=uncached_tokens+?,
                        total_tokens=total_tokens+?,
                        cost_total=cost_total+?
                    WHERE session_id=?
                    """,
                    [
                        .double(usage.cachedTokens), .double(usage.uncachedTokens),
                        .double(usage.totalTokens), .double(usage.costTotal),
                        .text(sessionID),
                    ]
                )
                guard sqlite3_changes(database) == 1 else {
                    throw SQLiteRepositoryError.execute("Missing session statistics")
                }
            }
            return SQLiteRecord(
                sessionID: sessionID,
                sequence: sequence,
                id: id,
                lane: lane,
                runID: runID,
                type: type,
                operationKind: operationKind,
                timestamp: timestamp,
                payload: payload
            )
        }
    }

    public func records(
        sessionID: String,
        lane: String? = nil,
        type: String? = nil
    ) throws -> [SQLiteRecord] {
        var sql = "SELECT seq,id,lane,run_id,type,op_kind,timestamp,payload FROM records WHERE session_id=?"
        var bindings: [Binding] = [.text(sessionID)]
        if let lane {
            sql += " AND lane=?"
            bindings.append(.text(lane))
        }
        if let type {
            sql += " AND type=?"
            bindings.append(.text(type))
        }
        sql += " ORDER BY seq"
        return try query(sql, bindings) { statement in
            SQLiteRecord(
                sessionID: sessionID,
                sequence: sqlite3_column_int64(statement, 0),
                id: Self.text(statement, 1)!,
                lane: Self.text(statement, 2)!,
                runID: Self.text(statement, 3),
                type: Self.text(statement, 4)!,
                operationKind: Self.text(statement, 5),
                timestamp: sqlite3_column_int64(statement, 6),
                payload: try OrderedJSON.decode(Self.text(statement, 7)!)
            )
        }
    }

    public func createLane(
        sessionID: String,
        lane: String,
        leafID: String?,
        lease: WriterLease,
        now: Int64
    ) throws {
        try transaction {
            _ = try renew(lease, now: now)
            if let leafID { try requireEntry(sessionID: sessionID, id: leafID) }
            try execute(
                "INSERT INTO lanes(session_id,lane,leaf_id,open_operation_id) VALUES(?,?,?,NULL)",
                [.text(sessionID), .text(lane), leafID.map(Binding.text) ?? .null]
            )
            let sequence = try nextSequence(sessionID)
            try execute(
                "INSERT INTO lane_moves(session_id,seq,lane,leaf_id) VALUES(?,?,?,?)",
                [
                    .text(sessionID), .integer(sequence), .text(lane),
                    leafID.map(Binding.text) ?? .null,
                ]
            )
        }
    }

    public func setName(
        sessionID: String,
        name: String?,
        lease: WriterLease,
        now: Int64
    ) throws {
        try setFact(
            sessionID: sessionID,
            kind: "name",
            key: nil,
            value: name.map { OrderedJSON.string(.string($0)) },
            lease: lease,
            now: now
        )
    }

    public func name(sessionID: String) throws -> String? {
        let values = try query(
            "SELECT value FROM facts WHERE session_id=? AND kind='name' ORDER BY seq DESC LIMIT 1",
            [.text(sessionID)]
        ) { Self.text($0, 0) }
        guard let encoded = values.first ?? nil,
            case .string(let value) = try OrderedJSON.decode(encoded)
        else {
            return nil
        }
        return value
    }

    public func setLabel(
        sessionID: String,
        entryID: String,
        label: String?,
        lease: WriterLease,
        now: Int64
    ) throws {
        try requireEntry(sessionID: sessionID, id: entryID)
        try setFact(
            sessionID: sessionID,
            kind: "label",
            key: entryID,
            value: label.map { OrderedJSON.string(.string($0)) },
            lease: lease,
            now: now
        )
    }

    public func label(sessionID: String, entryID: String) throws -> String? {
        let values = try query(
            "SELECT value FROM facts WHERE session_id=? AND kind='label' AND key=? ORDER BY seq DESC LIMIT 1",
            [.text(sessionID), .text(entryID)]
        ) { Self.text($0, 0) }
        guard let encoded = values.first ?? nil,
            case .string(let value) = try OrderedJSON.decode(encoded)
        else {
            return nil
        }
        return value
    }

    public func stats(sessionID: String) throws -> SQLiteSessionStats {
        let values = try query(
            "SELECT message_count,cached_tokens,uncached_tokens,total_tokens,cost_total FROM session_stats WHERE session_id=?",
            [.text(sessionID)]
        ) { statement in
            SQLiteSessionStats(
                messageCount: sqlite3_column_int64(statement, 0),
                cachedTokens: sqlite3_column_double(statement, 1),
                uncachedTokens: sqlite3_column_double(statement, 2),
                totalTokens: sqlite3_column_double(statement, 3),
                costTotal: sqlite3_column_double(statement, 4)
            )
        }
        guard let value = values.first else {
            throw SQLiteRepositoryError.execute("Missing session statistics")
        }
        return value
    }

    public func repairBranchCache(sessionID: String) throws {
        try transaction {
            try execute("DELETE FROM branch_entries WHERE session_id=?", [.text(sessionID)])
            try execute("DELETE FROM branch_tips WHERE session_id=?", [.text(sessionID)])
            let values = try entries(sessionID: sessionID)
            for entry in values {
                try updateBranchCache(
                    sessionID: sessionID,
                    entryID: entry.id,
                    parentID: entry.parentID,
                    sequence: entry.sequence,
                    entryType: entry.type,
                    payload: entry.payload
                )
            }
        }
    }

    public func deleteSession(_ sessionID: String) throws {
        try transaction {
            for table in [
                "writer_leases", "branch_tips", "branch_entries", "facts",
                "lane_moves", "records", "lanes", "session_stats",
                "session_sequences", "entries",
            ] {
                try execute(
                    "DELETE FROM \(table) WHERE session_id=?",
                    [.text(sessionID)]
                )
            }
            try execute("DELETE FROM sessions WHERE id=?", [.text(sessionID)])
        }
    }

    public func forkSession(
        sourceID: String,
        destination: SQLiteSessionMetadata,
        scope: SQLiteForkScope
    ) throws {
        try transaction {
            let sourceEntries = try entries(sessionID: sourceID)
            let selected: [SQLiteEntry]
            switch scope {
            case .tree:
                selected = sourceEntries
            case .branch(let requested, let includeTarget):
                let target: String?
                if let requested {
                    target = requested
                } else {
                    target = try mainLeaf(sessionID: sourceID)
                }
                selected =
                    try target.map {
                        try branchPath(
                            entries: sourceEntries,
                            targetID: $0,
                            includeTarget: includeTarget
                        )
                    } ?? []
            }
            try execute(
                "INSERT INTO sessions(id,created_at,cwd,parent_session_id,metadata) VALUES(?,?,?,?,?)",
                [
                    .text(destination.id), .integer(destination.createdAt),
                    .text(destination.cwd),
                    .text(destination.parentSessionID ?? sourceID),
                    destination.metadata.map {
                        .text(OrderedJSON.string($0))
                    } ?? .null,
                ]
            )
            try execute(
                "INSERT INTO session_sequences(session_id,next_seq) VALUES(?,1)",
                [.text(destination.id)]
            )
            try execute(
                "INSERT INTO session_stats(session_id,message_count,cached_tokens,uncached_tokens,total_tokens,cost_total) VALUES(?,0,0,0,0,0)",
                [.text(destination.id)]
            )
            let destinationLanes: [(String, String?)]
            switch scope {
            case .tree:
                destinationLanes = try query(
                    "SELECT lane,leaf_id FROM lanes WHERE session_id=? ORDER BY lane",
                    [.text(sourceID)]
                ) { statement in
                    (Self.text(statement, 0)!, Self.text(statement, 1))
                }
            case .branch:
                destinationLanes = [("main", selected.last?.id)]
            }
            for (lane, leaf) in destinationLanes {
                try execute(
                    "INSERT INTO lanes(session_id,lane,leaf_id,open_operation_id) VALUES(?,?,?,NULL)",
                    [
                        .text(destination.id), .text(lane),
                        leaf.map(Binding.text) ?? .null,
                    ]
                )
            }
            if destinationLanes.isEmpty {
                try execute(
                    "INSERT INTO lanes(session_id,lane,leaf_id,open_operation_id) VALUES(?,'main',NULL,NULL)",
                    [.text(destination.id)]
                )
            }
            var messageCount: Int64 = 0
            for entry in selected {
                let sequence = try nextSequence(destination.id)
                try execute(
                    "INSERT INTO entries(session_id,seq,id,parent_id,type,timestamp,payload) VALUES(?,?,?,?,?,?,?)",
                    [
                        .text(destination.id), .integer(sequence),
                        .text(entry.id),
                        entry.parentID.map(Binding.text) ?? .null,
                        .text(entry.type), .integer(entry.timestamp),
                        .text(OrderedJSON.string(entry.payload)),
                    ]
                )
                try updateBranchCache(
                    sessionID: destination.id,
                    entryID: entry.id,
                    parentID: entry.parentID,
                    sequence: sequence,
                    entryType: entry.type,
                    payload: entry.payload
                )
                if entry.type == "message" { messageCount += 1 }
            }
            try execute(
                "UPDATE session_stats SET message_count=? WHERE session_id=?",
                [.integer(messageCount), .text(destination.id)]
            )
            try copyLatestFacts(
                sourceID: sourceID,
                destinationID: destination.id,
                allowedEntries: Set(selected.map(\.id))
            )
        }
    }

    public func initializeSearch() throws {
        guard !searchInitialized else { return }
        guard let database else { throw SQLiteRepositoryError.open("closed") }
        try transaction {
            let needsRebuild = try !Self.searchIndexExists(database)
            do {
                try Self.execute(database, SQLiteRepositorySchema.searchSchema)
            } catch SQLiteRepositoryError.execute(let message)
                where message.localizedCaseInsensitiveContains("tokenizer")
            {
                try Self.execute(database, SQLiteRepositorySchema.fallbackSearchSchema)
            }
            if needsRebuild { try Self.execute(database, SQLiteRepositorySchema.searchRebuild) }
        }
        searchInitialized = true
    }

    public func search(_ phrase: String, limit: Int = 100) throws -> [(
        sessionID: String, entryID: String, payload: String
    )] {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, limit > 0 else { return [] }
        try initializeSearch()
        let escaped = phrase.replacingOccurrences(of: "\"", with: "\"\"")
        return try query(
            "SELECT e.session_id,e.id,e.payload FROM entries_fts f JOIN entries e ON e.rowid=f.rowid WHERE entries_fts MATCH ? ORDER BY bm25(entries_fts) LIMIT ?",
            [.text("\"\(escaped)\""), .integer(Int64(limit))]
        ) { statement in
            (Self.text(statement, 0)!, Self.text(statement, 1)!, Self.text(statement, 2)!)
        }
    }

    public func integrityCheck() throws -> String {
        try query("PRAGMA integrity_check", []) { Self.text($0, 0)! }.first ?? ""
    }

    func isOnDedicatedStorageExecutor() -> Bool {
        storageExecutor.isCurrent
    }

    private func mainLeaf(sessionID: String) throws -> String? {
        let values = try query(
            "SELECT leaf_id FROM lanes WHERE session_id=? AND lane='main'",
            [.text(sessionID)]
        ) { Self.text($0, 0) }
        return values.first ?? nil
    }

    private func branchPath(
        entries: [SQLiteEntry],
        targetID: String,
        includeTarget: Bool
    ) throws -> [SQLiteEntry] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        guard var current = byID[targetID] else {
            throw SQLiteRepositoryError.execute("Missing fork target: \(targetID)")
        }
        var result: [SQLiteEntry] = includeTarget ? [current] : []
        while let parentID = current.parentID {
            guard let parent = byID[parentID] else {
                throw SQLiteRepositoryError.execute("Broken parent chain: \(parentID)")
            }
            result.append(parent)
            current = parent
        }
        return result.reversed()
    }

    private func copyLatestFacts(
        sourceID: String,
        destinationID: String,
        allowedEntries: Set<String>
    ) throws {
        let facts = try query(
            "SELECT kind,key,value FROM facts WHERE session_id=? ORDER BY seq",
            [.text(sourceID)]
        ) { statement in
            (
                Self.text(statement, 0)!,
                Self.text(statement, 1),
                Self.text(statement, 2)
            )
        }
        var latest: [String: (kind: String, key: String?, value: String?)] = [:]
        for fact in facts {
            let identity = fact.0 + "\u{0}" + (fact.1 ?? "")
            latest[identity] = (fact.0, fact.1, fact.2)
        }
        for fact in latest.values.sorted(by: {
            ($0.kind, $0.key ?? "") < ($1.kind, $1.key ?? "")
        }) {
            if fact.kind == "label",
                let key = fact.key,
                !allowedEntries.contains(key)
            {
                continue
            }
            let sequence = try nextSequence(destinationID)
            try execute(
                "INSERT INTO facts(session_id,seq,kind,key,value) VALUES(?,?,?,?,?)",
                [
                    .text(destinationID), .integer(sequence), .text(fact.kind),
                    fact.key.map(Binding.text) ?? .null,
                    fact.value.map(Binding.text) ?? .null,
                ]
            )
        }
    }

    private func setFact(
        sessionID: String,
        kind: String,
        key: String?,
        value: String?,
        lease: WriterLease,
        now: Int64
    ) throws {
        try transaction {
            _ = try renew(lease, now: now)
            let sequence = try nextSequence(sessionID)
            try execute(
                "INSERT INTO facts(session_id,seq,kind,key,value) VALUES(?,?,?,?,?)",
                [
                    .text(sessionID), .integer(sequence), .text(kind),
                    key.map(Binding.text) ?? .null,
                    value.map(Binding.text) ?? .null,
                ]
            )
        }
    }

    private func requireEntry(sessionID: String, id: String) throws {
        let rows = try query(
            "SELECT 1 FROM entries WHERE session_id=? AND id=? LIMIT 1",
            [.text(sessionID), .text(id)]
        ) { _ in true }
        guard !rows.isEmpty else {
            throw SQLiteRepositoryError.execute("Missing entry: \(id)")
        }
    }

    private func updateBranchCache(
        sessionID: String,
        entryID: String,
        parentID: String?,
        sequence: Int64,
        entryType: String,
        payload: JSONValue
    ) throws {
        let customType: String? = {
            guard entryType == "custom", case .object(let object) = payload,
                case .string(let value)? = object["customType"]
            else {
                return nil
            }
            return value
        }()
        if parentID == nil {
            try insertBranchEntry(
                sessionID: sessionID,
                branchID: entryID,
                entryID: entryID,
                sequence: sequence,
                entryType: entryType,
                customType: customType
            )
            try execute(
                "INSERT INTO branch_tips(session_id,branch_id,tip_id) VALUES(?,?,?)",
                [.text(sessionID), .text(entryID), .text(entryID)]
            )
            return
        }
        let parentID = parentID!
        let tipBranches = try query(
            "SELECT branch_id FROM branch_tips WHERE session_id=? AND tip_id=?",
            [.text(sessionID), .text(parentID)]
        ) { Self.text($0, 0)! }
        if let branchID = tipBranches.first {
            try insertBranchEntry(
                sessionID: sessionID,
                branchID: branchID,
                entryID: entryID,
                sequence: sequence,
                entryType: entryType,
                customType: customType
            )
            try execute(
                "UPDATE branch_tips SET tip_id=? WHERE session_id=? AND branch_id=?",
                [.text(entryID), .text(sessionID), .text(branchID)]
            )
            return
        }
        let parentBranches = try query(
            "SELECT branch_id,entry_seq FROM branch_entries WHERE session_id=? AND entry_id=? ORDER BY branch_id LIMIT 1",
            [.text(sessionID), .text(parentID)]
        ) { (Self.text($0, 0)!, sqlite3_column_int64($0, 1)) }
        guard let (sourceBranch, parentSequence) = parentBranches.first else {
            throw SQLiteRepositoryError.execute("Stale branch cache for parent \(parentID)")
        }
        try execute(
            "INSERT INTO branch_entries(session_id,branch_id,entry_id,entry_seq,entry_type,custom_type) SELECT session_id,?,entry_id,entry_seq,entry_type,custom_type FROM branch_entries WHERE session_id=? AND branch_id=? AND entry_seq<=?",
            [
                .text(entryID), .text(sessionID), .text(sourceBranch),
                .integer(parentSequence),
            ]
        )
        try insertBranchEntry(
            sessionID: sessionID,
            branchID: entryID,
            entryID: entryID,
            sequence: sequence,
            entryType: entryType,
            customType: customType
        )
        try execute(
            "INSERT INTO branch_tips(session_id,branch_id,tip_id) VALUES(?,?,?)",
            [.text(sessionID), .text(entryID), .text(entryID)]
        )
    }

    private func insertBranchEntry(
        sessionID: String,
        branchID: String,
        entryID: String,
        sequence: Int64,
        entryType: String,
        customType: String?
    ) throws {
        try execute(
            "INSERT INTO branch_entries(session_id,branch_id,entry_id,entry_seq,entry_type,custom_type) VALUES(?,?,?,?,?,?)",
            [
                .text(sessionID), .text(branchID), .text(entryID),
                .integer(sequence), .text(entryType),
                customType.map(Binding.text) ?? .null,
            ]
        )
    }

    private func nextSequence(_ sessionID: String) throws -> Int64 {
        let values = try query(
            "UPDATE session_sequences SET next_seq=next_seq+1 WHERE session_id=? RETURNING next_seq-1",
            [.text(sessionID)]
        ) { sqlite3_column_int64($0, 0) }
        guard let value = values.first else { throw SQLiteRepositoryError.execute("Missing session sequence") }
        return value
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE", [])
        do {
            let value = try body()
            try execute("COMMIT", [])
            return value
        } catch {
            try? execute("ROLLBACK", [])
            throw error
        }
    }

    private enum Binding {
        case null
        case integer(Int64)
        case double(Double)
        case text(String)
    }

    private func execute(_ sql: String, _ bindings: [Binding]) throws {
        _ = try query(sql, bindings) { _ in () }
    }

    private func query<T>(_ sql: String, _ bindings: [Binding], row: (OpaquePointer) throws -> T) throws -> [T] {
        guard let database else { throw SQLiteRepositoryError.open("closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SQLiteRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .null: sqlite3_bind_null(statement, index)
            case .integer(let value): sqlite3_bind_int64(statement, index, value)
            case .double(let value): sqlite3_bind_double(statement, index, value)
            case .text(let value): sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            }
        }
        var output: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                output.append(try row(statement))
            } else if result == SQLITE_DONE {
                return output
            } else {
                throw SQLiteRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw SQLiteRepositoryError.execute(message)
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let value = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: value)
    }

    private static func verifyExistingSchema(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='migrations'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement
        else {
            throw SQLiteRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        let hasMigrations = sqlite3_step(statement) == SQLITE_ROW
        sqlite3_finalize(statement)
        guard hasMigrations else { return }
        var migration: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT 1 FROM migrations WHERE id='001_initial.sql'",
                -1,
                &migration,
                nil
            ) == SQLITE_OK, let migration
        else {
            throw SQLiteRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        let applied = sqlite3_step(migration) == SQLITE_ROW
        sqlite3_finalize(migration)
        guard applied else { return }
        var columns: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(entries)", -1, &columns, nil) == SQLITE_OK,
            let columns
        else {
            throw SQLiteRepositoryError.unsupportedSchema
        }
        var timestampIsInteger = false
        var hasParent = false
        while sqlite3_step(columns) == SQLITE_ROW {
            let name = text(columns, 1)
            let type = text(columns, 2)?.uppercased()
            if name == "timestamp" { timestampIsInteger = type == "INTEGER" }
            if name == "parent_id" { hasParent = true }
        }
        sqlite3_finalize(columns)
        guard timestampIsInteger, hasParent else {
            throw SQLiteRepositoryError.unsupportedSchema
        }
    }

    private static func verifyCapabilities(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT sqlite_version()", -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteRepositoryError.unsupportedSQLite("version")
        }
        sqlite3_finalize(statement)
    }

    private static func searchIndexExists(_ database: OpaquePointer) throws -> Bool {
        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='entries_fts'",
                -1,
                &statement,
                nil
            ) == SQLITE_OK, let statement
        else {
            throw SQLiteRepositoryError.execute(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
