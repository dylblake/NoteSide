//
//  AllNotesSearchUITests.swift
//  RemoraUITests
//
//  The tag suggestions under the All Notes search field: shown on focus,
//  narrowed by a `#` query, hidden for plain-text queries, and picking one
//  filters the notes.
//

import XCTest

final class AllNotesSearchUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "RemoraUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        try seedStore()

        app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "allNotes"
        app.launchEnvironment["UITEST_STORE_DIRECTORY"] = storeDirectory.path
        app.launchEnvironment["REMORA_PANE_WIDTH"] = "640"
        app.launchArguments += [
            "-hasCompletedOnboarding", "YES",
            "-trialNotesCreated", "0",
            "-autoTitleEnabled", "NO"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 8), "All Notes panel did not open")
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    // MARK: Seed

    /// Writes a version-3 `notes.json` the app loads without migration.
    /// Each note needs a distinct context identifier: the in-memory index
    /// is keyed by context id.
    private func seedStore() throws {
        func note(id: String, title: String, body: String, context: String) -> String {
            """
            {
              "id": "\(id)",
              "context": {
                "kind": "application",
                "identifier": "\(context)",
                "displayName": "Example App"
              },
              "body": "\(body)",
              "createdAt": "2026-09-29T10:00:00Z",
              "updatedAt": "2026-09-29T10:00:00Z",
              "isPinned": false,
              "title": "\(title)"
            }
            """
        }
        let json = """
        {
          "version": 3,
          "notes": [
            \(note(id: "11111111-1111-1111-1111-111111111111", title: "Tagged Note", body: "Say #hello world", context: "com.example.one")),
            \(note(id: "22222222-2222-2222-2222-222222222222", title: "Work Note", body: "#work items", context: "com.example.two")),
            \(note(id: "33333333-3333-3333-3333-333333333333", title: "Plain Note", body: "nothing tagged here", context: "com.example.three"))
          ]
        }
        """
        try json.write(to: storeDirectory.appending(path: "notes.json"), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private var searchField: XCUIElement {
        let container = app.descendants(matching: .any).matching(identifier: "allNotesSearchField").firstMatch
        let inner = container.textFields.firstMatch
        if inner.exists { return inner }
        return app.textFields.firstMatch
    }

    private func suggestion(_ tag: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "tagSuggestion-\(tag)").firstMatch
    }

    /// The field's value follows SwiftUI state a beat after a pick.
    private func waitForFieldValue(_ field: XCUIElement, _ expected: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (field.value as? String) == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (field.value as? String) == expected
    }

    private func focusSearchField() -> XCUIElement {
        let field = searchField
        XCTAssertTrue(field.waitForExistence(timeout: 5), "search field not found\n\(app.debugDescription.prefix(1500))")
        field.click()
        return field
    }

    // MARK: Tests

    func testFocusingSearchShowsEveryTagAndPickingOneFilters() throws {
        XCTAssertTrue(app.staticTexts["Plain Note"].firstMatch.waitForExistence(timeout: 5))

        let field = focusSearchField()

        XCTAssertTrue(suggestion("hello").waitForExistence(timeout: 5), "tags should appear on focus\n\(app.debugDescription.prefix(2000))")
        XCTAssertTrue(suggestion("work").exists)

        suggestion("hello").click()

        XCTAssertTrue(app.staticTexts["Plain Note"].firstMatch.waitForNonExistence(timeout: 5), "picking #hello should filter out untagged notes")
        XCTAssertTrue(app.staticTexts["Tagged Note"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Work Note"].firstMatch.exists)
        XCTAssertTrue(waitForFieldValue(field, "#hello"), "field should read #hello, got \(String(describing: field.value))")
        XCTAssertTrue(suggestion("hello").waitForNonExistence(timeout: 3), "list should close after a pick")
    }

    func testTypingNarrowsSuggestionsAndPlainTextHidesThem() throws {
        let field = focusSearchField()
        XCTAssertTrue(suggestion("work").waitForExistence(timeout: 5))

        field.typeText("#he")
        XCTAssertTrue(suggestion("work").waitForNonExistence(timeout: 3), "#he should drop #work")
        XCTAssertTrue(suggestion("hello").exists)

        // Plain text is a body search, not a tag search: no suggestions.
        field.typeKey("a", modifierFlags: .command)
        field.typeText("nothing")
        XCTAssertTrue(suggestion("hello").waitForNonExistence(timeout: 3), "plain text should hide the suggestions")
        XCTAssertTrue(app.staticTexts["Plain Note"].firstMatch.waitForExistence(timeout: 5))
    }

    func testEscapeClosesSuggestionsFirstThenThePanel() throws {
        let field = focusSearchField()
        XCTAssertTrue(suggestion("hello").waitForExistence(timeout: 5))

        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(suggestion("hello").waitForNonExistence(timeout: 3), "first Escape should only close the list")
        XCTAssertTrue(app.staticTexts["All Notes"].exists, "panel should still be open")

        field.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["All Notes"].waitForNonExistence(timeout: 5), "second Escape should dismiss the panel")
    }

    func testArrowKeysAndReturnPickAHighlightedTag() throws {
        let field = focusSearchField()
        XCTAssertTrue(suggestion("hello").waitForExistence(timeout: 5))

        // Most-used first, ties alphabetical: hello, work.
        field.typeKey(.downArrow, modifierFlags: [])
        field.typeKey(.downArrow, modifierFlags: [])
        field.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(waitForFieldValue(field, "#work"), "field should read #work, got \(String(describing: field.value))")
        XCTAssertTrue(app.staticTexts["Work Note"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Tagged Note"].firstMatch.waitForNonExistence(timeout: 5))
    }
}
