import XCTest
@testable import Remora

/// The To-Do list: pinned notes in an order the user drags them into,
/// stored alongside the notes.
@MainActor
final class TodoOrderTests: XCTestCase {
    private func note(_ name: String, pinned: Bool, updated: TimeInterval = 0) -> ContextNote {
        ContextNote(
            id: UUID(),
            context: NoteContext(
                kind: .application,
                identifier: "com.example.\(name)",
                displayName: name,
                secondaryLabel: nil,
                navigationTarget: nil
            ),
            body: name,
            richTextData: nil,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: updated),
            isPinned: pinned,
            title: name
        )
    }

    private func makeState() throws -> (NotesState, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TodoOrder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (NotesState(store: NoteStore(directoryOverride: directory)), directory)
    }

    private func todoTitles(_ state: NotesState) -> [String] {
        state.noteSections
            .first { $0.id == NoteSectionBuilder.todoSectionID }?
            .notes.compactMap(\.title) ?? []
    }

    // MARK: reconciledTodoOrder

    func testReconcileDropsUnpinnedAndAppendsNewPinsNewestFirst() {
        let kept = note("kept", pinned: true)
        let unpinned = note("unpinned", pinned: false)
        let older = note("older", pinned: true, updated: 1)
        let newer = note("newer", pinned: true, updated: 2)
        let deleted = UUID()

        let order = NotesState.reconciledTodoOrder(
            [deleted, unpinned.id, kept.id, kept.id],
            notes: [older, kept, unpinned, newer]
        )

        XCTAssertEqual(order, [kept.id, newer.id, older.id])
    }

    // MARK: Section

    func testSectionFollowsOrderAndPutsUnorderedNotesLast() {
        let a = note("a", pinned: true, updated: 3)
        let b = note("b", pinned: true, updated: 2)
        let c = note("c", pinned: true, updated: 1)
        let tile = note("tile", pinned: false)

        let sections = NoteSectionBuilder.build(from: [a, b, c, tile], todoOrder: [c.id, a.id])
        let todo = sections.first { $0.id == NoteSectionBuilder.todoSectionID }

        XCTAssertEqual(todo?.title, "To-Do")
        XCTAssertEqual(todo?.notes.map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(sections.map(\.id), [NoteSectionBuilder.todoSectionID, NoteSectionBuilder.notesSectionID])
        XCTAssertEqual(sections.last?.notes.map(\.id), [tile.id])
    }

    // MARK: NotesState

    func testPinningAppendsToTheEndAndUnpinningRemoves() throws {
        let (state, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = note("first", pinned: true)
        let second = note("second", pinned: false)
        state.upsert(first)
        state.upsert(second)
        XCTAssertEqual(todoTitles(state), ["first"])

        state.togglePin(second)
        XCTAssertEqual(todoTitles(state), ["first", "second"])
        XCTAssertEqual(state.todoCount, 2)

        state.togglePin(try XCTUnwrap(state.note(for: first.context)))
        XCTAssertEqual(todoTitles(state), ["second"])
        XCTAssertEqual(state.todoOrder, [second.id])
    }

    func testReorderPersistsAcrossReload() throws {
        let (state, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notes = ["a", "b", "c"].map { note($0, pinned: true) }
        notes.forEach(state.upsert)
        XCTAssertEqual(todoTitles(state), ["a", "b", "c"])

        state.reorderTodo(visibleOrder: [notes[2].id, notes[0].id, notes[1].id])
        XCTAssertEqual(todoTitles(state), ["c", "a", "b"])

        state.flush()
        let reloaded = NotesState(store: NoteStore(directoryOverride: directory))
        XCTAssertEqual(todoTitles(reloaded), ["c", "a", "b"])
    }

    /// With a search hiding some rows, the visible ones swap among the
    /// slots they already held; hidden rows keep their place.
    func testReorderingAFilteredListLeavesHiddenRowsInPlace() throws {
        let (state, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notes = ["a", "b", "c", "d"].map { note($0, pinned: true) }
        notes.forEach(state.upsert)

        state.reorderTodo(visibleOrder: [notes[3].id, notes[0].id])
        XCTAssertEqual(state.todoOrder, [notes[3].id, notes[1].id, notes[2].id, notes[0].id])
    }

    func testReorderIgnoresIDsThatAreNotOnTheList() throws {
        let (state, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }

        let notes = ["a", "b"].map { note($0, pinned: true) }
        notes.forEach(state.upsert)

        state.reorderTodo(visibleOrder: [notes[1].id, UUID()])
        XCTAssertEqual(state.todoOrder, notes.map(\.id))
    }

    func testFilesWithoutAnOrderStillLoad() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TodoOrder-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        struct Legacy: Encodable { let version: Int; let notes: [ContextNote] }
        let notes = [note("old", pinned: true, updated: 1), note("new", pinned: true, updated: 2)]
        try encoder.encode(Legacy(version: 3, notes: notes)).write(to: directory.appending(path: "notes.json"))

        let state = NotesState(store: NoteStore(directoryOverride: directory))
        XCTAssertEqual(todoTitles(state), ["new", "old"])
    }
}
