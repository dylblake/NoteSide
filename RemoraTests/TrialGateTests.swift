import XCTest
@testable import Remora

/// Once the free trial is used up, an open drawer must not become a way
/// to start new notes: it stays on the note it has rather than following
/// the user onto a page or file that has none.
@MainActor
final class TrialGateTests: XCTestCase {
    private final class StubTitleGenerator: TitleGenerating {
        func generateTitle(body: String, context: NoteContext) async -> String? { nil }
    }

    private let browser = NoteContext(kind: .application, identifier: "com.example.browser", displayName: "Browser", secondaryLabel: nil, navigationTarget: nil)
    private let notedPage = NoteContext(kind: .url, identifier: "https://example.com/noted", displayName: "example.com", secondaryLabel: nil, navigationTarget: nil)
    private let newPage = NoteContext(kind: .url, identifier: "https://example.com/new", displayName: "example.com", secondaryLabel: nil, navigationTarget: nil)

    private func makeEditor() throws -> (EditorState, NotesState, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TrialGate-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    /// The editor as the app wires it past the trial: only contexts that
    /// already have a note are allowed.
    private func exhaustTrial(_ editor: EditorState, _ notes: NotesState) {
        editor.canCreateNote = { notes.note(for: $0) != nil }
    }

    func testOpenDrawerStaysPutWhenTheNewContextWouldBeANewNote() throws {
        let (editor, notes, directory) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: directory) }
        notes.upsert(note(for: browser, body: "browser note"))
        exhaustTrial(editor, notes)

        editor.activeContext = browser
        editor.loadEditorState(for: browser)
        editor.isEditorPresented = true

        editor.applyRefreshedContext(newPage)

        XCTAssertEqual(editor.activeContext?.id, browser.id, "a context with no note must not take over the drawer past the trial")
    }

    func testOpenDrawerStillFollowsToAContextThatHasANote() throws {
        let (editor, notes, directory) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: directory) }
        notes.upsert(note(for: browser, body: "browser note"))
        notes.upsert(note(for: notedPage, body: "page note"))
        exhaustTrial(editor, notes)

        editor.activeContext = browser
        editor.loadEditorState(for: browser)
        editor.isEditorPresented = true

        editor.applyRefreshedContext(notedPage)

        XCTAssertEqual(editor.activeContext?.id, notedPage.id, "existing notes stay reachable past the trial")
    }

    /// The hole that let a sixth note through: the drawer opened on the
    /// browser's own note, then settled on the page as a new one.
    func testLateResolvedContextDoesNotReplaceTheNoteWhenItWouldBeNew() throws {
        let (editor, notes, directory) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: directory) }
        notes.upsert(note(for: browser, body: "browser note"))
        exhaustTrial(editor, notes)

        editor.applyResolvedContextBeforePresenting(browser)
        editor.isEditorPresented = true
        editor.editorAttributedText = NSAttributedString(string: "")

        editor.applyLateResolvedContext(newPage, fallback: browser)

        XCTAssertEqual(editor.activeContext?.id, browser.id)
    }

    func testDrawerFollowsFreelyWhileNotesCanBeCreated() throws {
        let (editor, notes, directory) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: directory) }
        notes.upsert(note(for: browser, body: "browser note"))

        editor.activeContext = browser
        editor.loadEditorState(for: browser)
        editor.isEditorPresented = true

        editor.applyRefreshedContext(newPage)

        XCTAssertEqual(editor.activeContext?.id, newPage.id)
    }

    /// Test and scratch stores count in memory only, so running the
    /// tests can't move the real trial counter.
    func testScratchStoreDoesNotWriteTheTrialCounter() throws {
        let key = "trialNotesCreated"
        let before = UserDefaults.standard.object(forKey: key) as? Int
        let (_, notes, directory) = try makeEditor()
        defer { try? FileManager.default.removeItem(at: directory) }

        let countBefore = notes.trialNotesCreated
        notes.upsert(note(for: browser, body: "one"))
        notes.upsert(note(for: newPage, body: "two"))

        XCTAssertEqual(notes.trialNotesCreated, countBefore + 2, "the count still advances in memory")
        XCTAssertEqual(UserDefaults.standard.object(forKey: key) as? Int, before, "but nothing is written to the preferences")
    }
}
