//
//  NoteEditorUITests.swift
//  NoteSideUITests
//
//  Drives the floating note editor through XCUITest: the formatting
//  toolbar, keyboard shortcuts, lists, tables and text size.
//

import XCTest

final class NoteEditorUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Every run gets an empty scratch store so real notes are never
        // touched and the trial limit can't interfere. Launch arguments
        // populate NSArgumentDomain, overriding persisted defaults without
        // writing to them.
        storeDirectory = FileManager.default.temporaryDirectory
            .appending(path: "NoteSideUITests-\(UUID().uuidString)", directoryHint: .isDirectory)

        app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "quickNote"
        app.launchEnvironment["UITEST_STORE_DIRECTORY"] = storeDirectory.path
        // The drawer follows the frontmost app's display; on a narrow one
        // the toolbar folds into an overflow menu. Pin the width so the
        // full toolbar is always present.
        app.launchEnvironment["NOTESIDE_PANE_WIDTH"] = "640"
        app.launchArguments += [
            "-hasCompletedOnboarding", "YES",
            "-autoTitleEnabled", "NO",
            "-editorTextZoom", "1"
        ]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    // MARK: Helpers

    private var editor: XCUIElement {
        app.textViews["noteEditorTextView"].firstMatch
    }

    private func openEditor() -> XCUIElement {
        let textView = editor
        XCTAssertTrue(textView.waitForExistence(timeout: 8), "Note editor did not open")
        textView.click()
        return textView
    }

    private func button(_ identifier: String) -> XCUIElement {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(identifier) not found\n\(app.debugDescription.prefix(1500))")
        return element
    }

    private func editorText() -> String {
        (editor.value as? String) ?? ""
    }

    private func waitForEditorText(_ predicate: @escaping (String) -> Bool, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(editorText()) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return predicate(editorText())
    }

    // MARK: Tests

    func testEditorOpensWithToolbarAndFocusedTextView() throws {
        let textView = openEditor()
        XCTAssertTrue(app.descendants(matching: .any)["formattingToolbar"].firstMatch.exists)
        for identifier in ["formatBold", "formatItalic", "formatUnderline", "formatStrikethrough",
                           "formatBulletedList", "formatNumberedList", "formatTable", "formatStyleMenu"] {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists, "\(identifier) missing")
        }
        // Text size is keyboard-only, and quoting happens on open.
        for identifier in ["formatTextSize", "formatQuote"] {
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists, "\(identifier) should not be in the toolbar")
        }
        XCTAssertTrue(app.textFields["noteTitleField"].firstMatch.exists)

        textView.typeText("hello")
        XCTAssertTrue(waitForEditorText { $0.contains("hello") })
    }

    func testBoldButtonReflectsAndAppliesState() throws {
        let textView = openEditor()
        let bold = button("formatBold")
        XCTAssertEqual(bold.value as? String, "Off")

        bold.click()
        XCTAssertEqual(bold.value as? String, "On", "toggle should report the new typing state")
        textView.click()
        textView.typeText("bold")
        XCTAssertTrue(waitForEditorText { $0.contains("bold") })

        // ⌘B from the keyboard toggles it back off.
        textView.typeKey("b", modifierFlags: .command)
        XCTAssertEqual(bold.value as? String, "Off")
    }

    func testBulletedListButtonInsertsMarkerAndReturnContinuesList() throws {
        let textView = openEditor()
        button("formatBulletedList").click()
        XCTAssertTrue(waitForEditorText { $0.hasPrefix("•\t") })

        textView.click()
        textView.typeText("first\nsecond")
        XCTAssertTrue(waitForEditorText { $0 == "•\tfirst\n•\tsecond" }, "got: \(editorText().debugDescription)")

        // Return on an empty item ends the list.
        textView.typeText("\n\n")
        XCTAssertTrue(waitForEditorText { $0 == "•\tfirst\n•\tsecond\n" }, "got: \(editorText().debugDescription)")
    }

    func testNumberedListRenumbersAndIndentsWithTab() throws {
        let textView = openEditor()
        textView.typeText("one\ntwo")
        textView.typeKey("a", modifierFlags: .command)
        button("formatNumberedList").click()
        XCTAssertTrue(waitForEditorText { $0 == "1.\tone\n2.\ttwo" }, "got: \(editorText().debugDescription)")

        // Caret into "two" and indent with Tab: becomes a nested "a." item.
        textView.typeKey(.downArrow, modifierFlags: [])
        textView.typeKey(.end, modifierFlags: .command)
        textView.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(waitForEditorText { $0 == "1.\tone\na.\ttwo" }, "got: \(editorText().debugDescription)")

        textView.typeKey(.tab, modifierFlags: .shift)
        XCTAssertTrue(waitForEditorText { $0 == "1.\tone\n2.\ttwo" }, "got: \(editorText().debugDescription)")
    }

    func testDashSpaceAutoStartsList() throws {
        let textView = openEditor()
        textView.typeText("- item")
        XCTAssertTrue(waitForEditorText { $0 == "•\titem" }, "got: \(editorText().debugDescription)")
    }

    func testStyleMenuAppliesHeadingAndShortcutReturnsToBody() throws {
        let textView = openEditor()
        textView.typeText("Section")

        // SwiftUI menus surface their accessibility label as `title`.
        let styleMenu = button("formatStyleMenu")
        XCTAssertTrue(styleMenu.title.contains("Body"), "style menu shows \(styleMenu.title)")
        styleMenu.click()
        let heading = app.menuItems["Heading"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 3))
        heading.click()

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !styleMenu.title.contains("Heading") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(styleMenu.title.contains("Heading"), "style menu shows \(styleMenu.title)")

        // ⇧⌘B is Body, mirroring Notes.
        textView.click()
        textView.typeKey("b", modifierFlags: [.command, .shift])
        let bodyDeadline = Date().addingTimeInterval(3)
        while Date() < bodyDeadline, !styleMenu.title.contains("Body") {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(styleMenu.title.contains("Body"), "style menu shows \(styleMenu.title)")
    }

    func testTableButtonInsertsTableAndTabMovesBetweenCells() throws {
        let textView = openEditor()
        button("formatTable").click()
        XCTAssertTrue(waitForEditorText { $0.filter { $0 == "\n" }.count >= 4 }, "expected 2×2 cells plus exit paragraph, got: \(editorText().debugDescription)")

        // Inside the table the same control becomes the table menu.
        let tableMenu = button("formatTable")
        XCTAssertTrue(tableMenu.title.contains("row 1 of 2, column 1 of 2"), "table menu shows \(tableMenu.title)")

        textView.typeText("A")
        textView.typeKey(.tab, modifierFlags: [])
        textView.typeText("B")
        XCTAssertTrue(waitForEditorText { $0.hasPrefix("A\nB\n") }, "got: \(editorText().debugDescription)")
    }

    func testTableMenuAddsAndRemovesRowsAndColumns() throws {
        let textView = openEditor()
        button("formatTable").click()
        XCTAssertTrue(waitForEditorText { $0.filter { $0 == "\n" }.count == 5 }, "2×2 + exit paragraph, got: \(editorText().debugDescription)")
        textView.typeText("A")

        func choose(_ item: String) {
            button("formatTable").click()
            let menuItem = app.menuItems[item].firstMatch
            XCTAssertTrue(menuItem.waitForExistence(timeout: 3), "\(item) missing from table menu")
            menuItem.click()
        }

        choose("Add Column After")
        XCTAssertTrue(waitForEditorText { $0.filter { $0 == "\n" }.count == 7 }, "2×3 + exit, got: \(editorText().debugDescription)")
        XCTAssertTrue(button("formatTable").title.contains("column 2 of 3"))

        choose("Add Row Below")
        XCTAssertTrue(waitForEditorText { $0.filter { $0 == "\n" }.count == 10 }, "3×3 + exit, got: \(editorText().debugDescription)")
        XCTAssertTrue(button("formatTable").title.contains("row 2 of 3"))

        choose("Delete Column")
        XCTAssertTrue(waitForEditorText { $0.filter { $0 == "\n" }.count == 7 }, "3×2 + exit, got: \(editorText().debugDescription)")

        choose("Delete Table")
        XCTAssertTrue(waitForEditorText { $0 == "\n" }, "got: \(editorText().debugDescription)")
        XCTAssertTrue(button("formatTable").label.contains("Insert Table"), "control reverts to insert")
    }

    /// Right-click in a cell offers the same edits.
    func testTableContextMenuOffersEdits() throws {
        let textView = openEditor()
        button("formatTable").click()
        XCTAssertTrue(waitForEditorText { $0.filter { $0 == "\n" }.count == 5 })
        // Right-click moves the caret, so aim at the first cell rather than
        // the (empty) middle of the text view.
        textView.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.02)).rightClick()
        let tableItem = app.menuItems["Table"].firstMatch
        XCTAssertTrue(tableItem.waitForExistence(timeout: 3), "context menu lacks a Table submenu")
        tableItem.hover()
        let addRow = app.menuItems["Add Row Below"].firstMatch
        XCTAssertTrue(addRow.waitForExistence(timeout: 3))
        addRow.click()
        XCTAssertTrue(waitForEditorText { $0.filter { $0 == "\n" }.count == 7 }, "3×2 + exit, got: \(editorText().debugDescription)")
    }

    /// A selection in the host app becomes a quoted passage when the drawer
    /// opens.
    func testSelectionBecomesQuotedPassage() throws {
        app.terminate()
        app.launchEnvironment["UITEST_SELECTION_TEXT"] = "the quick brown fox"
        app.launch()
        let textView = editor
        XCTAssertTrue(textView.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForEditorText { $0.hasPrefix("\u{201C}the quick brown fox\u{201D}\n") }, "got: \(editorText().debugDescription)")

        // Clicking activates NoteSide; the note must stay put.
        textView.click()
        textView.typeKey(.downArrow, modifierFlags: .command)  // end of document: the Body line under the quote
        textView.typeText("my thought")
        XCTAssertTrue(waitForEditorText { $0.contains("my thought") && $0.hasPrefix("\u{201C}") }, "note kept after activation: \(editorText().debugDescription)")
    }

    /// A second capture on the same context appends to the existing note
    /// instead of replacing it.
    func testSecondCaptureAppendsToExistingNote() throws {
        app.terminate()
        app.launchEnvironment["UITEST_SELECTION_TEXT"] = "first passage"
        app.launch()
        var textView = editor
        XCTAssertTrue(textView.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForEditorText { $0.hasPrefix("\u{201C}first passage\u{201D}") })
        textView.click()
        textView.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(textView.waitForNonExistence(timeout: 5))

        app.terminate()
        app.launchEnvironment["UITEST_SELECTION_TEXT"] = "second passage"
        app.launch()
        textView = editor
        XCTAssertTrue(textView.waitForExistence(timeout: 8))
        // The passage lands moments after the drawer starts sliding in.
        XCTAssertTrue(waitForEditorText({ $0.contains("first passage") && $0.contains("second passage") }, timeout: 1), "got: \(editorText().debugDescription)")
        XCTAssertTrue(editorText().range(of: "first passage")!.lowerBound < editorText().range(of: "second passage")!.lowerBound)
    }

    func testEscapeSavesNoteAndItAppearsInAllNotes() throws {
        let textView = openEditor()
        textView.typeText("Persisted body text")
        let title = app.textFields["noteTitleField"].firstMatch
        title.click()
        title.typeText("UITest Title")
        XCTAssertEqual(title.value as? String, "UITest Title")
        textView.click()
        textView.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(textView.waitForNonExistence(timeout: 5), "Escape should dismiss the drawer")

        // The note store is flushed on dismiss; reopen the app on the
        // same scratch store and look for the note in All Notes.
        app.terminate()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "allNotes"
        app.launch()
        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 8))
        let stored = (try? String(contentsOf: storeDirectory.appending(path: "notes.json"), encoding: .utf8)) ?? "<no notes.json>"
        XCTAssertTrue(app.staticTexts["UITest Title"].firstMatch.waitForExistence(timeout: 5), "saved note should be listed; store=\(stored.prefix(600))")
    }
}
