import XCTest
@testable import NoteSide

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
        await waitUntil { !editor.isGeneratingTitle }
        XCTAssertEqual(editor.titleGeneration, .finished)
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
