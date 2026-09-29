import XCTest
@testable import Remora

final class PassageLinkTests: XCTestCase {
    private let page = URL(string: "https://www.example.com/article?id=7&utm_source=x#old-anchor")!

    func testShortSelectionBecomesSingleRangeOnCanonicalPage() throws {
        let url = try XCTUnwrap(PassageLink.textFragmentURL(page: page, selection: "the quick brown fox"))
        XCTAssertEqual(url.absoluteString, "https://example.com/article?id=7#:~:text=the%20quick%20brown%20fox")
        XCTAssertTrue(PassageLink.isTextFragment(url))
    }

    func testLongSelectionUsesStartAndEndTerms() throws {
        let words = (1...20).map { "w\($0)" }.joined(separator: " ")
        let url = try XCTUnwrap(PassageLink.textFragmentURL(page: page, selection: words))
        XCTAssertEqual(url.fragment(percentEncoded: true), ":~:text=w1%20w2%20w3%20w4%20w5,w16%20w17%20w18%20w19%20w20")
    }

    func testDirectiveSyntaxCharactersAreEscaped() {
        XCTAssertEqual(PassageLink.encode("cost-benefit, R&D 100%"), "cost%2Dbenefit%2C%20R%26D%20100%25")
    }

    func testWhitespaceCollapsesAndEmptyIsNil() throws {
        XCTAssertNil(PassageLink.textFragmentURL(page: page, selection: "   \n "))
        let url = try XCTUnwrap(PassageLink.textFragmentURL(page: page, selection: "  two\n words  "))
        XCTAssertEqual(url.fragment(percentEncoded: true), ":~:text=two%20words")
    }

    func testNonWebPagesGetNoLink() {
        XCTAssertNil(PassageLink.textFragmentURL(page: URL(string: "file:///Users/me/doc.txt")!, selection: "hello"))
        let passage = Passage(text: "hello", sourceURL: nil)
        XCTAssertNil(passage.link)
        XCTAssertEqual(passage.text, "hello")
    }

    func testPassagePreviewTruncatesToEightWords() {
        let passage = Passage(text: "one two three four five six seven eight nine ten", sourceURL: nil)
        XCTAssertEqual(passage.preview, "one two three four five six seven eight…")
        XCTAssertEqual(Passage(text: "short one", sourceURL: nil).preview, "short one")
    }

    func testSelectionNormalizationCapsLength() throws {
        let long = String(repeating: "a", count: SelectionReader.maximumLength + 50)
        let normalized = try XCTUnwrap(SelectionReader.normalized(long))
        XCTAssertEqual(normalized.count, SelectionReader.maximumLength + 1)
        XCTAssertTrue(normalized.hasSuffix("…"))
        XCTAssertNil(SelectionReader.normalized(" \t\n"))
    }
}
