import XCTest
@testable import Remora

final class TagSuggestionTests: XCTestCase {
    private func note(_ body: String) -> ContextNote {
        ContextNote(
            id: UUID(),
            context: NoteContext(
                kind: .application,
                identifier: "com.example.app",
                displayName: "Example",
                secondaryLabel: nil,
                navigationTarget: nil
            ),
            body: body,
            richTextData: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func summaries(_ names: [String]) -> [TagSummary] {
        names.map { TagSummary(name: $0, count: 1) }
    }

    // MARK: aggregateTags

    func testAggregateCountsAcrossNotesAndSortsByCountThenName() {
        let tags = NotesState.aggregateTags([
            note("#beta and #alpha"),
            note("#beta again"),
            note("#gamma #beta"),
            note("no tags")
        ])
        XCTAssertEqual(tags.map(\.name), ["beta", "alpha", "gamma"])
        XCTAssertEqual(tags.map(\.count), [3, 1, 1])
    }

    func testAggregateCountsARepeatedTagOncePerNote() {
        let tags = NotesState.aggregateTags([note("#todo #todo #TODO")])
        XCTAssertEqual(tags, [TagSummary(name: "todo", count: 1)])
    }

    func testAggregateOfNoNotesIsEmpty() {
        XCTAssertTrue(NotesState.aggregateTags([]).isEmpty)
    }

    // MARK: tagSuggestions

    func testEmptyQueryAndBareHashOfferEveryTag() {
        let tags = summaries(["hello", "help", "world"])
        XCTAssertEqual(NotesState.tagSuggestions(tags: tags, query: ""), tags)
        XCTAssertEqual(NotesState.tagSuggestions(tags: tags, query: "#"), tags)
        XCTAssertEqual(NotesState.tagSuggestions(tags: tags, query: "  "), tags)
    }

    func testPrefixMatchesComeBeforeSubstringMatches() {
        let tags = summaries(["shell", "hello", "help", "world"])
        XCTAssertEqual(
            NotesState.tagSuggestions(tags: tags, query: "#he").map(\.name),
            ["hello", "help", "shell"]
        )
    }

    func testMatchingIsCaseInsensitive() {
        let tags = summaries(["hello"])
        XCTAssertEqual(NotesState.tagSuggestions(tags: tags, query: "#HE").map(\.name), ["hello"])
    }

    func testPlainTextQuerySuggestsNothing() {
        let tags = summaries(["hello"])
        XCTAssertTrue(NotesState.tagSuggestions(tags: tags, query: "hello").isEmpty)
    }

    func testQueryWithTrailingWordsSuggestsNothing() {
        let tags = summaries(["hello"])
        XCTAssertTrue(NotesState.tagSuggestions(tags: tags, query: "#hello foo").isEmpty)
    }

    func testNoMatchIsEmpty() {
        let tags = summaries(["hello"])
        XCTAssertTrue(NotesState.tagSuggestions(tags: tags, query: "#zzz").isEmpty)
    }
}
