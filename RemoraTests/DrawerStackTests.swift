import XCTest
@testable import Remora

/// The state behind the note drawer and All Notes working as one stack.
@MainActor
final class DrawerStackTests: XCTestCase {
    private final class StubTitleGenerator: TitleGenerating {
        func generateTitle(body: String, context: NoteContext) async -> String? { nil }
    }

    private let pickedPage = NoteContext(kind: .url, identifier: "https://example.com/picked", displayName: "example.com", secondaryLabel: nil, navigationTarget: nil)
    private let passingApp = NoteContext(kind: .application, identifier: "com.example.passing", displayName: "Passing", secondaryLabel: nil, navigationTarget: nil)

    private func makeState() throws -> (EditorState, NotesState, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DrawerStack-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notes = NotesState(store: NoteStore(directoryOverride: directory))
        let editor = EditorState(
            notesState: notes,
            richTextController: RichTextEditorController(),
            contextResolver: ContextResolver(),
            browserPermissions: BrowserPermissionsState(browserURLProvider: BrowserURLProvider()),
            titleGenerator: StubTitleGenerator(),
            isAutoTitleEnabled: { false }
        )
        return (editor, notes, directory)
    }

    private func note(for context: NoteContext, body: String) -> ContextNote {
        ContextNote(id: UUID(), context: context, body: body, richTextData: nil, createdAt: .now, updatedAt: .now, isPinned: false, title: nil)
    }

    /// A note picked in the list takes over the open drawer before its
    /// page has come forward. The apps that pass through the front on the
    /// way must not pull the drawer off it.
    func testFrozenDrawerHoldsThePickedNoteWhileOtherAppsComeForward() throws {
        let (editor, notes, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let picked = note(for: pickedPage, body: "picked")
        notes.upsert(picked)

        editor.activeContext = pickedPage
        editor.loadEditorState(for: picked)
        editor.isEditorPresented = true
        editor.isContextFrozen = true

        editor.applyRefreshedContext(passingApp)
        XCTAssertEqual(editor.activeContext?.id, pickedPage.id, "the drawer followed an app that was only passing through")

        editor.isContextFrozen = false
        editor.applyRefreshedContext(passingApp)
        XCTAssertEqual(editor.activeContext?.id, passingApp.id, "once released, the drawer follows again")
    }

    /// The list can delete the note that is open in the drawer; whoever
    /// owns the drawer has to hear about it, or closing the drawer saves
    /// the note straight back.
    func testDeletingNotesReportsWhichOnesWent() throws {
        let (_, notes, directory) = try makeState()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = note(for: pickedPage, body: "one")
        let second = note(for: passingApp, body: "two")
        notes.upsert(first)
        notes.upsert(second)

        var reported: [[UUID]] = []
        notes.onNotesDeleted = { reported.append($0.map(\.id)) }

        notes.delete(first)
        XCTAssertEqual(reported, [[first.id]])

        notes.selectedNoteIDs = [second.id]
        notes.deleteSelectedNotes()
        XCTAssertEqual(reported.last, [second.id])
        XCTAssertTrue(notes.notes.isEmpty)
    }
}
