//
//  NoteSideUITests.swift
//  NoteSideUITests
//

import XCTest

final class NoteSideUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// NoteSide is a menu-bar-only (LSUIElement) app with no Dock icon or
    /// main window, so `.runningForeground` never happens here — background
    /// is the expected running state.
    func testAppLaunches() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertNotEqual(app.state, .notRunning)
    }

    func testStatusItemExists() throws {
        let app = XCUIApplication()
        app.launch()

        let statusItem = app.statusItems["NoteSide"]
        XCTAssertTrue(statusItem.waitForExistence(timeout: 5), "Menu bar status item did not appear")
    }

    /// Drives the All Notes panel directly via the UITEST_LAUNCH_ACTION hook
    /// (see AppState.performUITestLaunchAction) rather than clicking the
    /// status item — SwiftUI's MenuBarExtra(.window) popover doesn't reliably
    /// surface itself to the accessibility tree under XCUITest.
    func testAllNotesWindowOpens() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "allNotes"
        app.launch()

        XCTAssertTrue(app.staticTexts["All Notes"].waitForExistence(timeout: 5), "All Notes panel did not open")
    }

    func testOnboardingWindowOpens() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "onboarding"
        app.launch()

        XCTAssertTrue(app.staticTexts["NoteSide"].waitForExistence(timeout: 5), "Onboarding window did not open")
    }

    /// Permissions & Setup shows one summary row per capability, with the
    /// per-app detail folded behind disclosures.
    func testPermissionsWindowShowsSummaryRowsWithFoldedDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "onboarding"
        app.launch()

        XCTAssertTrue(app.staticTexts["How it works"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Permissions"].exists)
        for title in ["Accessibility", "Finder & Xcode", "Voice Dictation"] {
            XCTAssertTrue(app.staticTexts[title].firstMatch.exists, "\(title) summary row missing")
        }

        let dictationDisclosure = app.descendants(matching: .any).matching(identifier: "dictationDetailsDisclosure").firstMatch
        XCTAssertTrue(dictationDisclosure.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Try a Note"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Done"].firstMatch.exists || app.buttons["Get Started"].firstMatch.exists)
    }
}
