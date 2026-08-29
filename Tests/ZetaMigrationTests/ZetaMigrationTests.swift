import Foundation
import XCTest

@testable import ZetaMigration

final class ZetaMigrationTests: XCTestCase {
    func testMigrationIsIdempotentAndPreservesBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("pi")
        let destination = root.appendingPathComponent("zeta")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("extensions"),
            withIntermediateDirectories: true
        )
        try Data(#"{"theme":"dark"}"#.utf8)
            .write(to: source.appendingPathComponent("settings.json"))
        try Data("export default {}".utf8)
            .write(to: source.appendingPathComponent("extensions/legacy.ts"))
        let migrator = PiMigrator(source: source, destination: destination)
        let first = try migrator.migrate()
        XCTAssertEqual(first.copied, ["settings.json"])
        XCTAssertEqual(first.warnings.count, 1)
        let second = try migrator.migrate()
        XCTAssertTrue(second.skipped.contains("settings.json"))
        XCTAssertEqual(
            try Data(contentsOf: source.appendingPathComponent("settings.json")),
            try Data(contentsOf: destination.appendingPathComponent("settings.json"))
        )
    }

    func testSourceCannotAlsoBeDestination() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let settings = source.appendingPathComponent("settings.json")
        let original = Data(#"{"theme":"unchanged"}"#.utf8)
        try original.write(to: settings)

        XCTAssertThrowsError(try PiMigrator(source: source, destination: source).migrate()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Migration source and destination must be different directories"
            )
        }
        XCTAssertEqual(try Data(contentsOf: settings), original)
    }

    func testInvalidInputRollsBackDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("pi")
        let destination = root.appendingPathComponent("zeta")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(#"{"theme":"new"}"#.utf8)
            .write(to: source.appendingPathComponent("settings.json"))
        try Data("not-json".utf8)
            .write(to: source.appendingPathComponent("auth.json"))
        let original = Data(#"{"theme":"old"}"#.utf8)
        try original.write(to: destination.appendingPathComponent("settings.json"))
        XCTAssertThrowsError(try PiMigrator(source: source, destination: destination).migrate())
        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent("settings.json")),
            original
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
    }
}
