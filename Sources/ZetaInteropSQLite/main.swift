import Foundation
import ZetaCore
import ZetaSessionSQLite

@main
enum InteropSQLite {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: zeta-interop-sqlite <database>\n".utf8))
            exit(2)
        }
        do {
            let repository = try SQLiteSessionRepository(
                url: URL(fileURLWithPath: CommandLine.arguments[1])
            )
            let lease = try await repository.acquireLease(
                sessionID: "session-fixture",
                ownerID: "swift-interop",
                now: 1_700_000_000_100
            )
            let existing = try await repository.entries(sessionID: "session-fixture")
            _ = try await repository.append(
                sessionID: "session-fixture",
                id: "entry-swift",
                parentID: existing.last?.id,
                type: "custom",
                timestamp: 1_700_000_000_101,
                payload: ["customType": "interop", "runtime": "swift"],
                lease: lease,
                now: 1_700_000_000_101
            )
            let integrity = try await repository.integrityCheck()
            let entries = try await repository.entries(sessionID: "session-fixture")
            print("{\"entries\":\(entries.count),\"integrity\":\"\(integrity)\"}")
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            exit(1)
        }
    }
}
