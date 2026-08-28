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
}
