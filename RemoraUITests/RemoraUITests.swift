//
//  RemoraUITests.swift
//  RemoraUITests
//

import XCTest

final class RemoraUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Remora is a menu-bar-only (LSUIElement) app with no Dock icon or
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

        let statusItem = app.statusItems["Remora"]
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

        XCTAssertTrue(app.images["remoraWordmark"].firstMatch.waitForExistence(timeout: 5), "Setup window did not open")
    }

    /// First run is one page: both steps are there from the start, with
    /// nothing to page through.
    func testFirstRunIsOnePage() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasCompletedOnboarding", "NO"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Allow Accessibility"].firstMatch.waitForExistence(timeout: 5), "First-run window did not open")
        XCTAssertTrue(app.staticTexts["Take your first note"].firstMatch.exists, "Both steps should be on one page")
        XCTAssertTrue(app.buttons["Start Taking Notes"].firstMatch.exists)
        XCTAssertFalse(app.buttons["Continue"].exists, "First run should have no pages to step through")
        XCTAssertFalse(app.buttons["Back"].exists)
    }

    /// The license window is where the trial ends, so it has to offer a way
    /// to buy as well as a field for the key. The button isn't tapped: it
    /// opens the website's checkout in the browser. The window only opens
    /// unlicensed, so a stored key is overridden with one that won't verify.
    func testLicenseWindowOffersPurchase() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "license"
        app.launchArguments += ["-com.remora.license-key", "invalid"]
        app.launch()

        XCTAssertTrue(app.textFields["licenseKeyField"].waitForExistence(timeout: 5), "License window did not open")
        XCTAssertTrue(app.buttons["buyLicenseButton"].exists, "License window has no Buy button")
    }

    /// Setup shows one summary row per capability with its per-app
    /// detail listed beneath it: nothing to expand before the needed
    /// permissions are visible.
    func testPermissionsWindowShowsDetailWithoutExpanding() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "onboarding"
        app.launch()

        XCTAssertTrue(app.staticTexts["How it works"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Permissions"].exists)
        for title in ["Accessibility", "Finder & Xcode", "Voice Dictation"] {
            XCTAssertTrue(app.staticTexts[title].firstMatch.exists, "\(title) summary row missing")
        }

        for title in ["Microphone", "Speech Recognition"] {
            XCTAssertTrue(app.staticTexts[title].firstMatch.exists, "\(title) detail row should be visible without expanding")
        }
        XCTAssertEqual(app.disclosureTriangles.count, 0, "Setup should have nothing to expand")
        XCTAssertTrue(app.buttons["Try a Note"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Done"].firstMatch.exists || app.buttons["Get Started"].firstMatch.exists)
    }
}
