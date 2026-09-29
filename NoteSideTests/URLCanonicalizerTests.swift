import XCTest
@testable import NoteSide

final class URLCanonicalizerTests: XCTestCase {
    private func id(_ string: String) -> String {
        URLCanonicalizer.canonicalIdentifier(for: URL(string: string)!)
    }

    func testFigmaSessionTokenAndSlugDoNotChangeIdentity() {
        let a = id("https://www.figma.com/design/v8EbQR4j7Echm4lGGjyz5t/NoteSide?node-id=0-1&p=f&t=wq5U43IxXKgzvR69-0")
        let b = id("https://www.figma.com/design/v8EbQR4j7Echm4lGGjyz5t/NoteSide?node-id=0-1&p=f&t=zYXCrEcJtedRnsMq-0")
        let renamed = id("https://www.figma.com/design/v8EbQR4j7Echm4lGGjyz5t/NoteSide-v2?node-id=0-1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, renamed)
        XCTAssertEqual(a, "https://figma.com/design/v8EbQR4j7Echm4lGGjyz5t?node-id=0-1")
    }

    func testFigmaNodeChangesIdentity() {
        XCTAssertNotEqual(
            id("https://www.figma.com/design/KEY/Name?node-id=0-1"),
            id("https://www.figma.com/design/KEY/Name?node-id=12-7")
        )
    }

    func testTrackingParametersStrippedOnUnknownHosts() {
        let clean = id("https://example.com/article?id=42")
        XCTAssertEqual(id("https://example.com/article?id=42&utm_source=x&utm_medium=y&fbclid=abc&gclid=1"), clean)
        XCTAssertEqual(clean, "https://example.com/article?id=42")
    }

    func testQueryOrderAndCaseInsensitiveHost() {
        XCTAssertEqual(
            id("HTTPS://Example.COM:443/a?b=2&a=1"),
            id("https://www.example.com/a?a=1&b=2")
        )
    }

    func testNonTrackingQueryIsKeptOnUnknownHosts() {
        XCTAssertNotEqual(id("https://shop.example/item?sku=1"), id("https://shop.example/item?sku=2"))
    }

    func testYouTubeKeepsVideoDropsTimestampAndShareSuffix() {
        let a = id("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s&si=abcdef&list=PL123")
        XCTAssertEqual(a, "https://youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(id("https://youtu.be/dQw4w9WgXcQ?si=zzz"), "https://youtu.be/dQw4w9WgXcQ")
    }

    func testGmailKeepsFragmentOtherHostsDropIt() {
        // Trailing slashes are normalised away everywhere; the fragment is what identifies the message.
        XCTAssertEqual(id("https://mail.google.com/mail/u/0/#inbox/FMfcgz"), "https://mail.google.com/mail/u/0#inbox/FMfcgz")
        XCTAssertNotEqual(id("https://mail.google.com/mail/u/0/#inbox/AAA"), id("https://mail.google.com/mail/u/0/#inbox/BBB"))
        XCTAssertEqual(id("https://example.com/doc#section-2"), "https://example.com/doc")
    }

    func testGoogleDocsIgnoresEditSuffixAndQuery() {
        XCTAssertEqual(
            id("https://docs.google.com/document/d/1AbC/edit?usp=sharing&tab=t.0"),
            id("https://docs.google.com/document/d/1AbC/view")
        )
    }

    func testNotionUsesTrailingPageID() {
        let hex = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(
            id("https://www.notion.so/team/Roadmap-\(hex)?v=1"),
            id("https://notion.so/team/Renamed-Roadmap-\(hex)")
        )
    }

    func testNavigationURLKeepsInPageAnchorButNotTextFragment() {
        let anchor = URLCanonicalizer.navigationURL(for: URL(string: "https://example.com/doc?utm_source=x#section-2")!)
        XCTAssertEqual(anchor.absoluteString, "https://example.com/doc#section-2")
        let passage = URLCanonicalizer.navigationURL(for: URL(string: "https://example.com/doc#:~:text=hello")!)
        XCTAssertEqual(passage.absoluteString, "https://example.com/doc")
    }

    func testEmptyPathBecomesRootAndDefaultPortDropped() {
        XCTAssertEqual(id("http://example.com:80"), "http://example.com/")
    }

    func testNonHTTPURLsPassThrough() {
        XCTAssertEqual(id("file:///Users/me/notes.txt"), "file:///Users/me/notes.txt")
    }
}
