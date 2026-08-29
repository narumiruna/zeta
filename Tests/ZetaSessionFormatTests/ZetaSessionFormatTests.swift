import Foundation
import XCTest

@testable import ZetaSessionFormat

final class ZetaSessionFormatTests: XCTestCase {
    func testDetectsEveryCurrentFormatWithoutMutation() throws {
        let coding = Data(#"{"type":"session","version":3}"#.utf8)
        let harness = Data(#"{"kind":"header","version":4}"#.utf8)
        let sqlite = Data("SQLite format 3\0payload".utf8)
        XCTAssertEqual(SessionFormatDetector.detect(data: coding), .codingAgent(version: 3))
        XCTAssertEqual(SessionFormatDetector.detect(data: harness), .harness(version: 4))
        XCTAssertEqual(SessionFormatDetector.detect(data: sqlite), .sqlite)
        XCTAssertEqual(SessionFormatDetector.detect(data: Data("bad".utf8)), .unknown)
        let before = coding
        XCTAssertThrowsError(
            try SessionFormatDetector.require(.harness(version: 4), data: coding)
        )
        XCTAssertEqual(coding, before)
    }

    func testDetectFileReadsLongJSONLHeadersThroughFirstNewline() throws {
        let padding = String(repeating: "a", count: 5_000)
        let cases: [([String: Any], SessionFileFormat)] = [
            (["type": "session", "version": 3, "cwd": padding], .codingAgent(version: 3)),
            (["kind": "header", "version": 4, "metadata": ["note": padding]], .harness(version: 4)),
        ]

        for (object, expected) in cases {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            XCTAssertGreaterThan(data.count, 4_096)
            data.append(0x0A)
            data.append(Data("not part of the header".utf8))
            let file = try temporaryFile(containing: data)

            XCTAssertEqual(try SessionFormatDetector.detect(file: file), expected)
        }
    }

    func testDetectFileRejectsUnterminatedOversizedHeader() throws {
        var data = Data(#"{"type":"session","cwd":""#.utf8)
        data.append(
            Data(
                repeating: 0x61,
                count: SessionFormatDetector.maximumHeaderBytes
            )
        )
        let file = try temporaryFile(containing: data)

        XCTAssertEqual(try SessionFormatDetector.detect(file: file), .unknown)
    }

    private func temporaryFile(containing data: Data) throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeta-session-format-\(UUID().uuidString)")
        try data.write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        return file
    }
}
