import Foundation
import ZetaCore

public let currentHarnessSessionVersion = 4

public struct HarnessSessionHeader: Sendable, Equatable {
    public var id: String
    public var createdAt: Int64
    public var cwd: String
    public var parentSessionID: String?
    public var legacyParentSessionPath: String?
    public var metadata: JSONValue?

    public init(
        id: String,
        createdAt: Int64,
        cwd: String,
        parentSessionID: String? = nil,
        legacyParentSessionPath: String? = nil,
        metadata: JSONValue? = nil
    ) throws {
        guard !id.isEmpty, createdAt >= 0, !cwd.isEmpty,
            !(parentSessionID != nil && legacyParentSessionPath != nil)
        else {
            throw HarnessSessionError.invalidHeader
        }
        self.id = id
        self.createdAt = createdAt
        self.cwd = cwd
        self.parentSessionID = parentSessionID
        self.legacyParentSessionPath = legacyParentSessionPath
        self.metadata = metadata
    }

    public var json: JSONValue {
        var object: OrderedJSONObject = [
            "kind": "header",
            "version": .number(JSONNumber(currentHarnessSessionVersion)),
            "id": .string(id),
            "createdAt": .number(JSONNumber(createdAt)),
            "cwd": .string(cwd),
        ]
        if let parentSessionID { object["parentSessionId"] = .string(parentSessionID) }
        if let legacyParentSessionPath {
            object["legacyParentSessionPath"] = .string(legacyParentSessionPath)
        }
        if let metadata { object["metadata"] = metadata }
        return .object(object)
    }

    public static func decode(_ value: JSONValue) throws -> HarnessSessionHeader {
        var reader = try StrictObjectReader(value)
        try requireLiteral(reader.required("kind"), "header")
        guard
            try StrictValue.safeInteger(reader.required("version"), minimum: 0)
                == currentHarnessSessionVersion
        else {
            throw HarnessSessionError.unsupportedVersion
        }
        let id = try StrictValue.string(reader.required("id"), nonempty: true)
        let created = try StrictValue.safeInteger(reader.required("createdAt"), minimum: 0)
        let cwd = try StrictValue.string(reader.required("cwd"), nonempty: true)
        let parent = try reader.optional("parentSessionId").map {
            try StrictValue.string($0, nonempty: true)
        }
        let legacy = try reader.optional("legacyParentSessionPath").map {
            try StrictValue.string($0, nonempty: true)
        }
        let metadata = reader.optional("metadata")
        try reader.finish()
        return try HarnessSessionHeader(
            id: id,
            createdAt: created,
            cwd: cwd,
            parentSessionID: parent,
            legacyParentSessionPath: legacy,
            metadata: metadata
        )
    }
}

public struct HarnessEntry: Sendable, Equatable {
    public var id: String
    public var sequence: Int64
    public var parentID: String?
    public var type: String
    public var timestamp: Int64
    public var fields: OrderedJSONObject
}

public struct HarnessRecord: Sendable, Equatable {
    public var id: String
    public var sequence: Int64
    public var lane: String
    public var type: String
    public var timestamp: Int64
    public var fields: OrderedJSONObject
}

public enum HarnessMutation: Sendable, Equatable {
    case entry(lane: String?, HarnessEntry)
    case record(HarnessRecord)
    case lane(sequence: Int64, lane: String, leafID: String?)
    case name(sequence: Int64, value: String?)
    case label(sequence: Int64, targetID: String, value: String?)

    public var sequence: Int64 {
        switch self {
        case .entry(_, let value): value.sequence
        case .record(let value): value.sequence
        case .lane(let sequence, _, _), .name(let sequence, _), .label(let sequence, _, _):
            sequence
        }
    }

    public var json: JSONValue {
        switch self {
        case .entry(let lane, let entry):
            var object = entry.fields
            object["kind"] = "entry"
            if let lane { object["lane"] = .string(lane) }
            object["id"] = .string(entry.id)
            object["seq"] = .number(JSONNumber(entry.sequence))
            object["parentId"] = entry.parentID.map(JSONValue.string) ?? .null
            object["type"] = .string(entry.type)
            object["timestamp"] = .number(JSONNumber(entry.timestamp))
            return .object(object)
        case .record(let record):
            var object = record.fields
            object["kind"] = "record"
            object["id"] = .string(record.id)
            object["seq"] = .number(JSONNumber(record.sequence))
            object["lane"] = .string(record.lane)
            object["type"] = .string(record.type)
            object["timestamp"] = .number(JSONNumber(record.timestamp))
            return .object(object)
        case .lane(let sequence, let lane, let leafID):
            return [
                "kind": "lane",
                "seq": .number(JSONNumber(sequence)),
                "lane": .string(lane),
                "leafId": leafID.map(JSONValue.string) ?? .null,
            ]
        case .name(let sequence, let value):
            var object: OrderedJSONObject = [
                "kind": "fact",
                "seq": .number(JSONNumber(sequence)),
                "fact": "name",
            ]
            if let value { object["name"] = .string(value) }
            return .object(object)
        case .label(let sequence, let targetID, let value):
            var object: OrderedJSONObject = [
                "kind": "fact",
                "seq": .number(JSONNumber(sequence)),
                "fact": "label",
                "targetId": .string(targetID),
            ]
            if let value { object["label"] = .string(value) }
            return .object(object)
        }
    }

    public static func decode(_ value: JSONValue) throws -> HarnessMutation {
        guard case .object(var object) = value else {
            throw HarnessSessionError.invalidMutation
        }
        let kind = try takeString("kind", from: &object)
        let sequence = try takeSequence(from: &object)
        switch kind {
        case "entry":
            let lane = try takeOptionalString("lane", from: &object)
            let id = try takeString("id", from: &object)
            let parent = try takeNullableString("parentId", from: &object)
            let type = try takeString("type", from: &object)
            guard HarnessEntryType.all.contains(type) else {
                throw HarnessSessionError.invalidMutation
            }
            let timestamp = try takeTimestamp(from: &object)
            return .entry(
                lane: lane,
                HarnessEntry(
                    id: id,
                    sequence: sequence,
                    parentID: parent,
                    type: type,
                    timestamp: timestamp,
                    fields: object
                )
            )
        case "record":
            let id = try takeString("id", from: &object)
            let lane = try takeString("lane", from: &object)
            let type = try takeString("type", from: &object)
            guard HarnessRecordType.all.contains(type) else {
                throw HarnessSessionError.invalidMutation
            }
            let timestamp = try takeTimestamp(from: &object)
            if type == "operation_started" {
                guard case .object(let intent)? = object["intent"],
                    case .string(let operation)? = intent["kind"],
                    ["run", "compaction", "navigation"].contains(operation)
                else {
                    throw HarnessSessionError.invalidMutation
                }
            }
            return .record(
                HarnessRecord(
                    id: id,
                    sequence: sequence,
                    lane: lane,
                    type: type,
                    timestamp: timestamp,
                    fields: object
                )
            )
        case "lane":
            return .lane(
                sequence: sequence,
                lane: try takeString("lane", from: &object),
                leafID: try takeNullableString("leafId", from: &object)
            )
        case "fact":
            let fact = try takeString("fact", from: &object)
            if fact == "name" {
                return .name(
                    sequence: sequence,
                    value: try takeOptionalString("name", from: &object)
                )
            }
            if fact == "label" {
                return .label(
                    sequence: sequence,
                    targetID: try takeString("targetId", from: &object),
                    value: try takeOptionalString("label", from: &object)
                )
            }
            throw HarnessSessionError.invalidMutation
        default:
            throw HarnessSessionError.invalidMutation
        }
    }
}

public enum HarnessEntryType {
    public static let all: Set<String> = [
        "message", "model_change", "thinking_level_change", "active_tools_change",
        "compaction", "branch_summary", "custom",
    ]
}

public enum HarnessRecordType {
    public static let all: Set<String> = [
        "operation_started", "abort_requested", "operation_finished", "step_attempt",
        "tool_started", "queue_enqueued", "queue_cancelled", "write_deferred", "usage",
    ]
}

public enum HarnessSessionError: Error, LocalizedError, Sendable {
    case invalidHeader
    case unsupportedVersion
    case invalidMutation
    case nonconsecutiveSequence
    case duplicateID
    case missingLane
    case missingEntry
    case operationAlreadyOpen

    public var errorDescription: String? {
        switch self {
        case .invalidHeader: "Harness session header is invalid"
        case .unsupportedVersion: "Harness session version is unsupported"
        case .invalidMutation: "Harness session mutation is invalid"
        case .nonconsecutiveSequence: "Harness session sequence is not consecutive"
        case .duplicateID: "Harness entry or record id already exists"
        case .missingLane: "Harness lane does not exist"
        case .missingEntry: "Harness entry does not exist"
        case .operationAlreadyOpen: "Harness lane already has an open operation"
        }
    }
}

public actor HarnessSessionStorage {
    public let header: HarnessSessionHeader
    private var mutations: [HarnessMutation] = []
    private var entries: [String: HarnessEntry] = [:]
    private var records: [HarnessRecord] = []
    private var lanes: [String: String?] = ["main": nil]
    private var name: String?
    private var labels: [String: String] = [:]

    public init(header: HarnessSessionHeader) {
        self.header = header
    }

    public func apply(_ mutation: HarnessMutation) throws {
        guard mutation.sequence == Int64(mutations.count + 1) else {
            throw HarnessSessionError.nonconsecutiveSequence
        }
        switch mutation {
        case .entry(let lane, let entry):
            guard entries[entry.id] == nil,
                !records.contains(where: { $0.id == entry.id })
            else {
                throw HarnessSessionError.duplicateID
            }
            if let parent = entry.parentID, entries[parent] == nil {
                throw HarnessSessionError.missingEntry
            }
            if let lane {
                guard lanes.keys.contains(lane) else { throw HarnessSessionError.missingLane }
                lanes[lane] = entry.id
            }
            entries[entry.id] = entry
        case .record(let record):
            guard entries[record.id] == nil,
                !records.contains(where: { $0.id == record.id }),
                lanes.keys.contains(record.lane)
            else {
                throw HarnessSessionError.duplicateID
            }
            if record.type == "operation_started",
                !openOperations(lane: record.lane).isEmpty
            {
                throw HarnessSessionError.operationAlreadyOpen
            }
            records.append(record)
        case .lane(_, let lane, let leafID):
            if let leafID, entries[leafID] == nil { throw HarnessSessionError.missingEntry }
            lanes[lane] = leafID
        case .name(_, let value):
            name = value
        case .label(_, let targetID, let value):
            guard entries[targetID] != nil else { throw HarnessSessionError.missingEntry }
            labels[targetID] = value
        }
        mutations.append(mutation)
    }

    public func allMutations(after sequence: Int64 = 0, limit: Int? = nil) -> [HarnessMutation] {
        let filtered = mutations.filter { $0.sequence > sequence }
        return limit.map { Array(filtered.prefix($0)) } ?? filtered
    }

    public func entry(_ id: String) -> HarnessEntry? { entries[id] }
    public func lane(_ lane: String) -> String? { lanes[lane] ?? nil }
    public func sessionName() -> String? { name }
    public func label(_ id: String) -> String? { labels[id] }

    public func findEntries(
        type: String? = nil,
        newestFirst: Bool = true,
        afterSequence: Int64? = nil,
        limit: Int? = nil
    ) -> [HarnessEntry] {
        var values = entries.values.filter { entry in
            (type == nil || entry.type == type)
                && (afterSequence == nil || entry.sequence > afterSequence!)
        }.sorted { newestFirst ? $0.sequence > $1.sequence : $0.sequence < $1.sequence }
        if let limit { values = Array(values.prefix(limit)) }
        return values
    }

    public func branch(start: String) throws -> [HarnessEntry] {
        guard var current = entries[start] else { throw HarnessSessionError.missingEntry }
        var result = [current]
        while let parent = current.parentID {
            guard let entry = entries[parent] else { throw HarnessSessionError.missingEntry }
            result.append(entry)
            current = entry
        }
        return result
    }

    public func findRecords(
        lane: String? = nil,
        type: String? = nil,
        runID: String? = nil,
        newestFirst: Bool = true,
        afterSequence: Int64? = nil,
        limit: Int? = nil
    ) -> [HarnessRecord] {
        var values = records.filter { record in
            guard lane == nil || record.lane == lane,
                type == nil || record.type == type,
                afterSequence == nil || record.sequence > afterSequence!
            else {
                return false
            }
            if let runID {
                if record.type == "operation_started" { return record.id == runID }
                return record.fields["runId"] == .string(runID)
            }
            return true
        }.sorted { newestFirst ? $0.sequence > $1.sequence : $0.sequence < $1.sequence }
        if let limit { values = Array(values.prefix(limit)) }
        return values
    }

    public func openOperations(lane: String) -> [HarnessRecord] {
        let finished = Set(
            records.compactMap { record -> String? in
                guard record.type == "operation_finished",
                    case .string(let runID)? = record.fields["runId"]
                else {
                    return nil
                }
                return runID
            })
        return records.filter {
            $0.lane == lane && $0.type == "operation_started" && !finished.contains($0.id)
        }.sorted { $0.sequence > $1.sequence }
    }

    public func encodeJSONL() -> Data {
        var data = OrderedJSON.encode(header.json)
        data.append(0x0A)
        for mutation in mutations {
            data.append(OrderedJSON.encode(mutation.json))
            data.append(0x0A)
        }
        return data
    }

    public static func decodeJSONL(_ data: Data) async throws -> HarnessSessionStorage {
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard !lines.isEmpty else { throw HarnessSessionError.invalidHeader }
        let header = try HarnessSessionHeader.decode(OrderedJSON.decode(Data(lines.removeFirst())))
        let storage = HarnessSessionStorage(header: header)
        let hasTornTail = data.last != 0x0A
        for (index, line) in lines.enumerated() {
            let value: JSONValue
            do {
                value = try OrderedJSON.decode(Data(line))
            } catch {
                if hasTornTail, index == lines.count - 1 { break }
                throw error
            }
            let mutation = try HarnessMutation.decode(value)
            try await storage.apply(mutation)
        }
        return storage
    }
}

private func requireLiteral(_ value: JSONValue, _ expected: String) throws {
    guard value == .string(expected) else { throw HarnessSessionError.invalidHeader }
}

private func takeString(
    _ key: String,
    from object: inout OrderedJSONObject
) throws -> String {
    guard case .string(let value)? = object[key] else {
        throw HarnessSessionError.invalidMutation
    }
    object[key] = nil
    return value
}

private func takeOptionalString(
    _ key: String,
    from object: inout OrderedJSONObject
) throws -> String? {
    guard let value = object[key] else { return nil }
    guard case .string(let string) = value else { throw HarnessSessionError.invalidMutation }
    object[key] = nil
    return string
}

private func takeNullableString(
    _ key: String,
    from object: inout OrderedJSONObject
) throws -> String? {
    guard let value = object[key] else { throw HarnessSessionError.invalidMutation }
    object[key] = nil
    switch value {
    case .null: return nil
    case .string(let string): return string
    default: throw HarnessSessionError.invalidMutation
    }
}

private func takeSequence(from object: inout OrderedJSONObject) throws -> Int64 {
    guard let value = object["seq"] else { throw HarnessSessionError.invalidMutation }
    object["seq"] = nil
    return try StrictValue.safeInteger(value, minimum: 1)
}

private func takeTimestamp(from object: inout OrderedJSONObject) throws -> Int64 {
    guard let value = object["timestamp"] else { throw HarnessSessionError.invalidMutation }
    object["timestamp"] = nil
    return try StrictValue.safeInteger(value, minimum: 0)
}
