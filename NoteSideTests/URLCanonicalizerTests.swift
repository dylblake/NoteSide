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
        XCTAssertEqual(id("https://youtu.be/dQw4w9WgXcQ?si=zzz"), a)
    }

    func testYouTubeShortLinksShortsLiveAndMobileShareOneIdentity() {
        let watch = id("https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertEqual(id("https://youtu.be/dQw4w9WgXcQ?t=90"), watch)
        XCTAssertEqual(id("https://www.youtube.com/shorts/dQw4w9WgXcQ"), watch)
        XCTAssertEqual(id("https://www.youtube.com/live/dQw4w9WgXcQ?feature=share"), watch)
        XCTAssertEqual(id("https://m.youtube.com/watch?v=dQw4w9WgXcQ"), watch)
        XCTAssertNotEqual(id("https://youtu.be/AAAAAAAAAAA"), watch)
    }

    func testGoogleDocsAccountSlotDoesNotChangeIdentity() {
        let plain = id("https://docs.google.com/document/d/1AbC/edit")
        XCTAssertEqual(id("https://docs.google.com/document/u/1/d/1AbC/edit?tab=t.0"), plain)
        XCTAssertEqual(plain, "https://docs.google.com/document/d/1AbC")
        // Before: every doc of account u/1 collapsed onto "/document/u/1".
        XCTAssertNotEqual(
            id("https://docs.google.com/document/u/1/d/AAA/edit"),
            id("https://docs.google.com/document/u/1/d/BBB/edit")
        )
        XCTAssertNotEqual(
            id("https://drive.google.com/drive/u/0/folders/AAA"),
            id("https://drive.google.com/drive/u/0/folders/BBB")
        )
    }

    func testGooglePublishedDocsKeepTheirID() {
        XCTAssertNotEqual(
            id("https://docs.google.com/document/d/e/2PACX-AAA/pub"),
            id("https://docs.google.com/document/d/e/2PACX-BBB/pub")
        )
    }

    func testGitHubPullRequestTabsAndRepoCaseShareOneIdentity() {
        let pr = id("https://github.com/Apple/Swift/pull/42")
        XCTAssertEqual(id("https://github.com/apple/swift/pull/42/files?diff=split"), pr)
        XCTAssertEqual(id("https://github.com/apple/swift/pull/42/commits"), pr)
        XCTAssertEqual(pr, "https://github.com/apple/swift/pull/42")
        XCTAssertNotEqual(id("https://github.com/apple/swift/pull/43"), pr)
        XCTAssertEqual(
            id("https://github.com/apple/swift/issues/7#issuecomment-1"),
            "https://github.com/apple/swift/issues/7"
        )
    }

    func testGitHubFilePathsStayDistinct() {
        XCTAssertNotEqual(
            id("https://github.com/apple/swift/blob/main/README.md"),
            id("https://github.com/apple/swift/blob/main/CHANGELOG.md")
        )
    }

    func testLinearIssueSlugAndProjectRenameDoNotChangeIdentity() {
        XCTAssertEqual(
            id("https://linear.app/acme/issue/ENG-123/fix-login-bug"),
            id("https://linear.app/acme/issue/ENG-123/fix-the-login-bug")
        )
        XCTAssertEqual(id("https://linear.app/acme/issue/ENG-123"), "https://linear.app/acme/issue/ENG-123")
        XCTAssertEqual(
            id("https://linear.app/acme/project/q3-launch-0a1b2c3d4e5f/overview"),
            id("https://linear.app/acme/project/fall-launch-0a1b2c3d4e5f/issues")
        )
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
