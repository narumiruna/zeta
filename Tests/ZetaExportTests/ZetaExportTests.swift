import Foundation
import XCTest

@testable import ZetaExport

final class ZetaExportTests: XCTestCase {
    func testStandaloneHTMLEmbedsDataAndBlocksActiveContent() {
        let html = SessionExporter.standaloneHTML(
            title: "<Title>",
            sessionJSONL: Data("{}\n".utf8),
            renderedTranscript: "<script>alert(1)</script><a href=\"javascript:alert(1)\">x</a>",
            leafID: "a\u{2028}</script>"
        )
        XCTAssertTrue(html.contains("&lt;Title&gt;"))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertFalse(html.contains("href=\"javascript:"))
        XCTAssertFalse(html.contains("a </script>"))
        XCTAssertTrue(html.contains(Data("{}\n".utf8).base64EncodedString()))
    }

    func testStandaloneHTMLEscapesAllTranscriptMarkupIncludingUnquotedHandlers() {
        let transcript =
            #"<img src=x onerror=alert(1)><svg/onload=alert(2)><a href=javascript:alert(3)>link</a><strong>text</strong>"#
        let html = SessionExporter.standaloneHTML(
            title: "Security",
            sessionJSONL: Data(),
            renderedTranscript: transcript
        )

        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.contains("<svg"))
        XCTAssertFalse(html.contains("<a href=javascript:"))
        XCTAssertFalse(html.contains("<strong>text</strong>"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
        XCTAssertTrue(html.contains("&lt;strong&gt;text&lt;/strong&gt;"))
    }

    func testURLAllowList() {
        XCTAssertNotNil(SessionExporter.safeURL("https://example.com"))
        XCTAssertNotNil(SessionExporter.safeURL("mailto:a@example.com"))
        XCTAssertNil(SessionExporter.safeURL("javascript:alert(1)"))
        XCTAssertNil(SessionExporter.safeURL("data:text/html,x"))
    }
}
