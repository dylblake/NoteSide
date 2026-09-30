import XCTest
@testable import Remora

final class OpenContextLocatorTests: XCTestCase {
    private typealias Tab = OpenContextLocator.TabLocation

    // MARK: parseTabList

    func testParsesRowsAndSkipsMalformedOnes() {
        let text = """
        1\t1\thttps://example.com/a
        1\t2\thttps://example.com/b
        2\t1\t
        garbage line
        x\t1\thttps://example.com/c

        """
        XCTAssertEqual(OpenContextLocator.parseTabList(text), [
            Tab(window: 1, tab: 1, url: "https://example.com/a"),
            Tab(window: 1, tab: 2, url: "https://example.com/b"),
            Tab(window: 2, tab: 1, url: "")
        ])
    }

    func testParsesCarriageReturnsAndTrailingWhitespace() {
        let text = "1\t1\thttps://example.com/a \r\n1\t2\thttps://example.com/b"
        XCTAssertEqual(OpenContextLocator.parseTabList(text).map(\.url), [
            "https://example.com/a", "https://example.com/b"
        ])
    }

    func testEmptyListingParsesToNothing() {
        XCTAssertTrue(OpenContextLocator.parseTabList("").isEmpty)
    }

    // MARK: matchingTab

    func testMatchesAfterCanonicalisation() {
        let identifier = URLCanonicalizer.canonicalIdentifier(for: URL(string: "https://example.com/article?id=42")!)
        let tabs = [
            Tab(window: 1, tab: 1, url: "https://example.com/other"),
            Tab(window: 2, tab: 3, url: "https://www.example.com/article?utm_source=x&id=42"),
            Tab(window: 2, tab: 4, url: "https://example.com/article?id=42")
        ]
        XCTAssertEqual(OpenContextLocator.matchingTab(in: tabs, identifier: identifier), tabs[1])
    }

    func testMatchesFigmaAcrossSessionTokens() {
        let identifier = URLCanonicalizer.canonicalIdentifier(
            for: URL(string: "https://www.figma.com/design/KEY/Name?node-id=0-1&t=abc-0")!
        )
        let tabs = [Tab(window: 1, tab: 1, url: "https://www.figma.com/design/KEY/Renamed?node-id=0-1&t=zzz-0")]
        XCTAssertEqual(OpenContextLocator.matchingTab(in: tabs, identifier: identifier), tabs[0])
    }

    func testNoMatchAndUnparseableURLs() {
        let tabs = [Tab(window: 1, tab: 1, url: ""), Tab(window: 1, tab: 2, url: "https://example.com/x")]
        XCTAssertNil(OpenContextLocator.matchingTab(in: tabs, identifier: "https://example.com/y"))
    }

    // MARK: documentMatches

    func testDocumentMatchesFileURLStringAndBarePath() {
        let folder = URL(fileURLWithPath: "/Users/x/Desktop")
        XCTAssertTrue(OpenContextLocator.documentMatches("file:///Users/x/Desktop/", fileURL: folder))
        XCTAssertTrue(OpenContextLocator.documentMatches("/Users/x/Desktop", fileURL: folder))
        XCTAssertFalse(OpenContextLocator.documentMatches("file:///Users/x/Documents/", fileURL: folder))
    }

    func testDocumentMatchesPercentEncodedSpaces() {
        let file = URL(fileURLWithPath: "/Users/x/My Notes/todo.md")
        XCTAssertTrue(OpenContextLocator.documentMatches("file:///Users/x/My%20Notes/todo.md", fileURL: file))
    }

    // MARK: AppleScript sources

    func testAppleScriptLiteralEscapesQuotesAndBackslashes() {
        XCTAssertEqual(OpenContextLocator.appleScriptLiteral(#"a "b" \c"#), #""a \"b\" \\c""#)
    }

    func testFinderScriptEmbedsEscapedPath() {
        let script = OpenContextLocator.finderRevealScript(folderPath: "/Users/x/Say \"hi\"")
        XCTAssertTrue(script.contains(#"set targetPath to "/Users/x/Say \"hi\"/""#), script)
        XCTAssertTrue(script.contains("repeat with i from 1 to (count of Finder windows)"))
        XCTAssertTrue(script.contains("(target of Finder window i) as alias"))

        // A trailing slash is normalised to exactly one.
        let slashed = OpenContextLocator.finderRevealScript(folderPath: "/Users/x/Desktop/")
        XCTAssertTrue(slashed.contains(#"set targetPath to "/Users/x/Desktop/""#), slashed)
    }

    func testSelectTabScriptUsesEachFamilysVerb() {
        let chromium = OpenContextLocator.selectTabScript(family: .chromium, bundleID: "com.google.Chrome", window: 2, tab: 5)
        XCTAssertTrue(chromium.contains("set active tab index of window 2 to 5"))

        let safari = OpenContextLocator.selectTabScript(family: .safari, bundleID: "com.apple.Safari", window: 1, tab: 3)
        XCTAssertTrue(safari.contains("set current tab of window 1 to tab 3 of window 1"))

        let arc = OpenContextLocator.selectTabScript(family: .arc, bundleID: "company.thebrowser.Browser", window: 1, tab: 2)
        XCTAssertTrue(arc.contains("tell tab 2 to select"))
    }

    func testEnumerateScriptAvoidsTheTabConstant() {
        let script = OpenContextLocator.enumerateTabsScript(bundleID: "com.apple.Safari")
        XCTAssertTrue(script.contains("character id 9"))
        XCTAssertTrue(script.contains("URL of tabs of window w"))
        XCTAssertFalse(script.contains("& tab &"))
    }
}
