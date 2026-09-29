import AppKit
import XCTest
@testable import NoteSide

final class NoteMigrationTests: XCTestCase {
    private func webNote(_ url: String, body: String, updated: TimeInterval, pinned: Bool = false, title: String? = nil, rtf: Bool = true) -> ContextNote {
        let attributed = NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let data = rtf ? try? attributed.data(from: NSRange(location: 0, length: attributed.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) : nil
        return ContextNote(
            id: UUID(),
            context: NoteContext(kind: .url, identifier: url, displayName: "figma.com", secondaryLabel: url, navigationTarget: url),
            body: body,
            richTextData: data,
            createdAt: Date(timeIntervalSince1970: updated - 100),
            updatedAt: Date(timeIntervalSince1970: updated),
            isPinned: pinned,
            title: title
        )
    }

    private let figmaA = "https://www.figma.com/design/v8EbQR4j7Echm4lGGjyz5t/NoteSide?node-id=0-1&p=f&t=wq5U43IxXKgzvR69-0"
    private let figmaB = "https://www.figma.com/design/v8EbQR4j7Echm4lGGjyz5t/NoteSide?node-id=0-1&p=f&t=zYXCrEcJtedRnsMq-0"

    func testDuplicateWebNotesMergeNewestFirst() throws {
        let older = webNote(figmaA, body: "older thoughts", updated: 1_000, pinned: true)
        let newer = webNote(figmaB, body: "newer thoughts", updated: 2_000, title: "Drawer review")
        let unrelated = webNote("https://example.com/", body: "other", updated: 1_500)

        let migrated = NoteMigration.canonicalizeWebIdentifiers([older, unrelated, newer])
        XCTAssertEqual(migrated.count, 2)

        let merged = try XCTUnwrap(migrated.first { $0.context.identifier.contains("figma.com") })
        XCTAssertEqual(merged.id, newer.id, "newest note's id survives")
        XCTAssertEqual(merged.context.identifier, "https://figma.com/design/v8EbQR4j7Echm4lGGjyz5t?node-id=0-1")
        XCTAssertEqual(merged.body, "newer thoughts\n\n\(NoteMigration.mergeDivider)\n\nolder thoughts")
        XCTAssertTrue(merged.isPinned)
        XCTAssertEqual(merged.title, "Drawer review")
        XCTAssertEqual(merged.createdAt, older.createdAt)
        XCTAssertEqual(merged.updatedAt, newer.updatedAt)

        let rtf = try XCTUnwrap(merged.richTextData)
        let restored = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        XCTAssertTrue(restored.string.contains("newer thoughts"))
        XCTAssertTrue(restored.string.contains(NoteMigration.mergeDivider))
        XCTAssertTrue(restored.string.contains("older thoughts"))
    }

    func testSingleNotesAreRewrittenInPlaceAndIdempotent() {
        let note = webNote(figmaA, body: "solo", updated: 10)
        let once = NoteMigration.canonicalizeWebIdentifiers([note])
        XCTAssertEqual(once.count, 1)
        XCTAssertEqual(once[0].id, note.id)
        XCTAssertEqual(once[0].body, "solo")
        XCTAssertEqual(once[0].context.secondaryLabel, "https://figma.com/design/v8EbQR4j7Echm4lGGjyz5t?node-id=0-1")

        let twice = NoteMigration.canonicalizeWebIdentifiers(once)
        XCTAssertEqual(twice[0].context, once[0].context)
    }

    func testFileAndAppNotesUntouched() {
        let file = ContextNote(
            id: UUID(),
            context: NoteContext(kind: .file, identifier: "/tmp/a.txt", displayName: "a.txt", secondaryLabel: "/tmp/a.txt", navigationTarget: nil),
            body: "f", richTextData: nil, createdAt: .now, updatedAt: .now, isPinned: false, title: nil
        )
        let app = ContextNote(
            id: UUID(),
            context: NoteContext(kind: .application, identifier: "com.apple.finder", displayName: "Finder", secondaryLabel: nil, navigationTarget: nil),
            body: "a", richTextData: nil, createdAt: .now, updatedAt: .now, isPinned: false, title: nil
        )
        let migrated = NoteMigration.canonicalizeWebIdentifiers([file, app])
        XCTAssertEqual(migrated.map(\.context), [file.context, app.context])
    }

    // MARK: Store integration

    private func temporaryStoreDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "NoteMigrationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func testStoreMigratesVersionOneFileAndRewritesAsVersionTwo() throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        struct V1: Encodable { let version: Int; let notes: [ContextNote] }
        let notes = [webNote(figmaA, body: "one", updated: 1), webNote(figmaB, body: "two", updated: 2)]
        try encoder.encode(V1(version: 1, notes: notes)).write(to: directory.appending(path: "notes.json"))

        let store = NoteStore(directoryOverride: directory)
        let loaded = store.loadNotes()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].body, "two\n\n\(NoteMigration.mergeDivider)\n\none")

        let rewritten = try Data(contentsOf: directory.appending(path: "notes.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
        XCTAssertEqual((json["notes"] as? [Any])?.count, 1)

        // Second load is a no-op read of the v2 file.
        XCTAssertEqual(NoteStore(directoryOverride: directory).loadNotes().count, 1)
    }

    func testStoreMigratesLegacyBareArray() throws {
        let directory = temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([webNote(figmaA, body: "legacy", updated: 1)]).write(to: directory.appending(path: "notes.json"))

        let loaded = NoteStore(directoryOverride: directory).loadNotes()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].context.identifier, "https://figma.com/design/v8EbQR4j7Echm4lGGjyz5t?node-id=0-1")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "notes.json"))) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 2)
    }
}
