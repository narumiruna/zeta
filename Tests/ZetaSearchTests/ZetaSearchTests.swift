import XCTest

@testable import ZetaSearch

final class ZetaSearchTests: XCTestCase {
    func testFilteringSnippetLimitAndStableIdentity() async throws {
        let sources = ArraySearchSources([
            (
                "s1",
                [
                    SearchDocument(
                        sessionID: "s1",
                        entryID: "e1",
                        entryType: "message",
                        text: "The Needle is here",
                        label: "bookmark"
                    ),
                    SearchDocument(
                        sessionID: "s1",
                        entryID: "e2",
                        entryType: "custom",
                        text: "needle custom"
                    ),
                ]
            )
        ])
        let stream = SessionSearch.scan(
            sources,
            query: "needle",
            options: SessionSearchOptions(entryTypes: ["message"], limit: 1)
        )
        var hits: [SessionSearchHit] = []
        for try await hit in stream { hits.append(hit) }
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].sessionID, "s1")
        XCTAssertEqual(hits[0].entryID, "e1")
    }

    func testCaseInsensitiveUnicodeMatchUsesOriginalStringIndexes() async throws {
        let text = "İİİİ before NEEDLE after"
        let sources = ArraySearchSources([
            (
                "unicode",
                [
                    SearchDocument(
                        sessionID: "unicode",
                        entryID: "entry",
                        entryType: "message",
                        text: text
                    )
                ]
            )
        ])
        var hits: [SessionSearchHit] = []

        for try await hit in SessionSearch.scan(
            sources,
            query: "needle",
            options: SessionSearchOptions(limit: 1, snippetCharacters: 14)
        ) {
            hits.append(hit)
        }

        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].snippet.contains("NEEDLE"))
        XCTAssertTrue(text.contains(hits[0].snippet))
    }

    func testDuplicateSessionsFailFast() async {
        let sources = ArraySearchSources([
            ("s", []),
            ("s", []),
        ])
        do {
            for try await _ in SessionSearch.scan(sources, query: "x") {}
            XCTFail("Expected duplicate failure")
        } catch SessionSearchError.duplicateSessionID("s") {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testBlankAndEmptyFiltersReturnNothing() async throws {
        let sources = ArraySearchSources([
            (
                "s",
                [SearchDocument(sessionID: "s", entryID: "e", entryType: "message", text: "x")]
            )
        ])
        var hits = 0
        for try await _ in SessionSearch.scan(
            sources,
            query: "x",
            options: SessionSearchOptions(entryTypes: [], limit: 10)
        ) {
            hits += 1
        }
        XCTAssertEqual(hits, 0)
    }
}
