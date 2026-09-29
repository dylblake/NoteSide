import XCTest
@testable import Remora

@MainActor
final class EditorStateTitleRevealTests: XCTestCase {
    private final class StubTitleGenerator: TitleGenerating {
        var title: String? = "Stub Title"
        func generateTitle(body: String, context: NoteContext) async -> String? { title }
    }

    private func makeEditor(generator: StubTitleGenerator) throws -> (EditorState, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "TitleReveal-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notes = NotesState(store: NoteStore(directoryOverride: directory))
        let editor = EditorState(
            notesState: notes,
            richTextController: RichTextEditorController(),
            contextResolver: ContextResolver(),
            browserPermissions: BrowserPermissionsState(browserURLProvider: BrowserURLProvider()),
            titleGenerator: generator
        )
        return (editor, directory)
    }

    private let context = NoteContext(kind: .application, identifier: "com.example.app", displayName: "Example", secondaryLabel: nil, navigationTarget: nil)

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testGeneratedTitleFillsEmptyFieldAndBumpsRevealToken() async throws {
        let (editor, directory) = try makeEditor(generator: StubTitleGenerator())
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.activeContext = context
        editor.isEditorPresented = true

        XCTAssertEqual(editor.titleGeneration, .idle, "nothing requested yet: no placeholder either")
        editor.generateTitleFromContext(context: context)
        XCTAssertTrue(editor.isGeneratingTitle)
        await waitUntil { editor.titleRevealToken == 1 }

        XCTAssertEqual(editor.editorTitle, "Stub Title")
        XCTAssertEqual(editor.titleRevealToken, 1)
        XCTAssertTrue(editor.isTitleRevealPending, "the field stays hidden until the view starts the fade")
        await waitUntil { !editor.isGeneratingTitle }
        XCTAssertEqual(editor.titleGeneration, .finished)

        editor.finishTitleReveal()
        XCTAssertFalse(editor.isTitleRevealPending)
    }

    /// The field must be hidden while it's still empty, and only then
    /// filled — otherwise the text and the hiding can reach the screen in
    /// different frames and the title flashes in before its fade.
    func testRevealHidesTheFieldBeforeFillingIt() async throws {
        let (editor, directory) = try makeEditor(generator: StubTitleGenerator())
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.activeContext = context
        editor.isEditorPresented = true

        // Fires synchronously, on the main thread, as the field is hidden.
        final class Box: @unchecked Sendable { var title: String? }
        let titleWhenHidden = Box()
        withObservationTracking { _ = editor.isTitleRevealPending } onChange: {
            MainActor.assumeIsolated { titleWhenHidden.title = editor.editorTitle }
        }
        editor.generateTitleFromContext(context: context)
        await waitUntil { editor.titleRevealToken == 1 }

        XCTAssertEqual(titleWhenHidden.title, "", "the title was already in the field when it was hidden")
        XCTAssertEqual(editor.editorTitle, "Stub Title")
    }

    func testTypingDuringTheRevealKeepsTheTypedTitleVisible() async throws {
        let (editor, directory) = try makeEditor(generator: StubTitleGenerator())
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.activeContext = context
        editor.isEditorPresented = true

        // Type in the gap between hiding the field and filling it.
        withObservationTracking { _ = editor.isTitleRevealPending } onChange: {
            MainActor.assumeIsolated { editor.editorTitle = "Mine" }
        }
        editor.generateTitleFromContext(context: context)
        await waitUntil { !editor.isGeneratingTitle && !editor.isTitleRevealPending }

        XCTAssertEqual(editor.editorTitle, "Mine")
        XCTAssertFalse(editor.isTitleRevealPending, "the typed title was left hidden")
        XCTAssertEqual(editor.titleRevealToken, 0)
    }

    func testLoadingANoteClearsAPendingReveal() async throws {
        let (editor, directory) = try makeEditor(generator: StubTitleGenerator())
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.activeContext = context
        editor.isEditorPresented = true
        editor.generateTitleFromContext(context: context)
        await waitUntil { editor.isTitleRevealPending }

        editor.loadEditorState(for: context)
        XCTAssertFalse(editor.isTitleRevealPending)
    }

    func testGeneratorWithNothingToSayFinishesSoPlaceholderCanShow() async throws {
        let generator = StubTitleGenerator()
        generator.title = nil
        let (editor, directory) = try makeEditor(generator: generator)
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.activeContext = context
        editor.isEditorPresented = true
        editor.generateTitleFromContext(context: context)
        await waitUntil { editor.titleGeneration == .finished }
        XCTAssertEqual(editor.editorTitle, "")
        XCTAssertEqual(editor.titleRevealToken, 0)
    }

    func testTypedTitleIsKeptAndNotRevealed() async throws {
        let (editor, directory) = try makeEditor(generator: StubTitleGenerator())
        defer { try? FileManager.default.removeItem(at: directory) }
        editor.activeContext = context
        editor.isEditorPresented = true
        editor.editorTitle = "Mine"

        editor.generateTitleFromContext(context: context)
        await waitUntil { !editor.isGeneratingTitle }

        XCTAssertEqual(editor.editorTitle, "Mine")
        XCTAssertEqual(editor.titleRevealToken, 0)
    }

    func testStoredTitleLoadsWithoutReveal() throws {
        let (editor, directory) = try makeEditor(generator: StubTitleGenerator())
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = ContextNote(id: UUID(), context: context, body: "b", richTextData: nil, createdAt: .now, updatedAt: .now, isPinned: false, title: "Stored")
        editor.notesState.upsert(note)
        editor.loadEditorState(for: context)
        XCTAssertEqual(editor.editorTitle, "Stored")
        XCTAssertEqual(editor.titleRevealToken, 0)
        XCTAssertEqual(editor.titleGeneration, .idle)
    }
}
