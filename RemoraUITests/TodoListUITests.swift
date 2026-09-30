//
//  TodoListUITests.swift
//  RemoraUITests
//
//  The To-Do list at the top of All Notes: pinned notes as one-line rows
//  in a stored order, reordered by dragging and removed by unpinning.
//

import XCTest

final class TodoListUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeDirectory: URL!

    private let ids = [
        "AAAAAAAA-1111-1111-1111-111111111111",
        "BBBBBBBB-2222-2222-2222-222222222222",
        "CCCCCCCC-3333-3333-3333-333333333333"
    ]

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
        app.launchEnvironment["REMORA_DISABLE_FAVICONS"] = "1"
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

    /// Three pinned notes in a stored order (Alpha, Bravo, Charlie) that
    /// is the reverse of their recency, plus one unpinned note.
    private func seedStore() throws {
        func note(id: String, title: String, hour: Int, pinned: Bool) -> String {
            """
            {
              "id": "\(id)",
              "context": {
                "kind": "application",
                "identifier": "com.example.\(title.lowercased())",
                "displayName": "Example App"
              },
              "body": "\(title) first line",
              "createdAt": "2026-09-29T10:00:00Z",
              "updatedAt": "2026-09-29T1\(hour):00:00Z",
              "isPinned": \(pinned),
              "title": "\(title)"
            }
            """
        }
        let json = """
        {
          "version": 3,
          "todoOrder": ["\(ids[0])", "\(ids[1])", "\(ids[2])"],
          "notes": [
            \(note(id: ids[0], title: "Alpha", hour: 1, pinned: true)),
            \(note(id: ids[1], title: "Bravo", hour: 2, pinned: true)),
            \(note(id: ids[2], title: "Charlie", hour: 3, pinned: true)),
            \(note(id: "DDDDDDDD-4444-4444-4444-444444444444", title: "Delta", hour: 4, pinned: false))
          ]
        }
        """
        try json.write(to: storeDirectory.appending(path: "notes.json"), atomically: true, encoding: .utf8)
    }

    // MARK: Helpers

    private var rows: [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: "todoRow").allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    private func row(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "todoRow")
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private var rowTitles: [String] {
        rows.map { String($0.label.prefix { $0 != "," }) }
    }

    private func header(count: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "To-Do, \(count) notes")).firstMatch
    }

    private func waitForRowTitles(_ expected: [String], timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if rowTitles == expected { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        return rowTitles == expected
    }

    private func storedOrder() throws -> [String] {
        let data = try Data(contentsOf: storeDirectory.appending(path: "notes.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (json["todoOrder"] as? [String]) ?? []
    }

    // MARK: Tests

    func testPinnedNotesShowAsACountedListInStoredOrder() throws {
        XCTAssertTrue(row("Alpha").waitForExistence(timeout: 5), "To-Do rows missing\n\(app.debugDescription.prefix(2500))")
        XCTAssertTrue(header(count: 3).exists, "header should read To-Do with a count of 3")
        XCTAssertEqual(rowTitles, ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(row("Alpha").label, "Alpha, Alpha first line")
        // The unpinned note stays a tile below, under its own heading and
        // with no per-app section.
        XCTAssertTrue(app.staticTexts["Delta"].firstMatch.exists)
        let notesHeading = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Notes, 1 note")).firstMatch
        XCTAssertTrue(notesHeading.exists, "the grid should be headed Notes with a count")
        XCTAssertFalse(app.staticTexts["Apps"].exists, "notes are no longer grouped into sections")
    }

    func testDraggingARowReordersAndPersists() throws {
        XCTAssertTrue(row("Alpha").waitForExistence(timeout: 5))

        row("Alpha").press(forDuration: 0.3, thenDragTo: row("Charlie"))

        XCTAssertTrue(waitForRowTitles(["Bravo", "Charlie", "Alpha"]), "got \(rowTitles)")
        XCTAssertTrue(app.staticTexts["All Notes"].exists, "a drag must not open the note")

        // Saves are debounced.
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(try storedOrder(), [ids[1], ids[2], ids[0]])
    }

    func testRemovingFromToDoMovesTheNoteBackToTheTiles() throws {
        XCTAssertTrue(row("Bravo").waitForExistence(timeout: 5))

        row("Bravo").rightClick()
        let remove = app.menuItems["Remove from To-Do"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.click()

        XCTAssertTrue(waitForRowTitles(["Alpha", "Charlie"]), "got \(rowTitles)")
        XCTAssertTrue(header(count: 2).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Bravo"].firstMatch.waitForExistence(timeout: 3), "Bravo should be a tile now")
    }
}
