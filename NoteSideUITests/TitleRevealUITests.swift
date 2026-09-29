//
//  TitleRevealUITests.swift
//  NoteSideUITests
//
//  An automatic title should simply not be there, then fade in when it's
//  ready: no "Title" placeholder waiting to be replaced, no flash of the
//  finished title before the fade, no fade-out-and-back-in. Uses a stub
//  generator (`UITEST_GENERATED_TITLE`, answers after 2.5s) and the motion
//  trace (`PanelMotionTrace`), which samples the title field's on-screen
//  opacity every frame.
//

import AppKit
import XCTest

final class TitleRevealUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeDirectory: URL!
    private var traceURL: URL!
    private let generatedTitle = "Trip planning notes"

    override func setUpWithError() throws {
        continueAfterFailure = false
        let scratch = FileManager.default.temporaryDirectory
        storeDirectory = scratch.appending(path: "NoteSideUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        traceURL = scratch.appending(path: "NoteSideTitle-\(UUID().uuidString).jsonl")

        app = XCUIApplication()
        app.launchEnvironment["UITEST_LAUNCH_ACTION"] = "quickNote"
        app.launchEnvironment["UITEST_STORE_DIRECTORY"] = storeDirectory.path
        app.launchEnvironment["UITEST_GENERATED_TITLE"] = generatedTitle
        // Long enough to check the waiting state after launch.
        app.launchEnvironment["UITEST_GENERATED_TITLE_DELAY_MS"] = "2500"
        app.launchEnvironment["NOTESIDE_MOTION_TRACE"] = traceURL.path
        app.launchEnvironment["NOTESIDE_PANE_WIDTH"] = "640"
        app.launchArguments += ["-hasCompletedOnboarding", "YES", "-editorTextZoom", "1"]
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let storeDirectory { try? FileManager.default.removeItem(at: storeDirectory) }
        if let traceURL { try? FileManager.default.removeItem(at: traceURL) }
    }

    private var titleField: XCUIElement {
        app.textFields["noteTitleField"].firstMatch
    }

    func testTitleIsAbsentUntilReadyThenFadesIn() throws {
        app.launchArguments += ["-autoTitleEnabled", "YES"]
        app.launch()
        XCTAssertTrue(titleField.waitForExistence(timeout: 8))

        // Waiting (the stub answers 2.5s after it's asked): an empty field
        // with no placeholder to be replaced.
        XCTAssertEqual(titleField.value as? String ?? "", "")
        XCTAssertNotEqual(titleField.placeholderValue, "Title", "\"Title\" showed while the automatic title was on its way")

        // Wait on the trace, not the accessibility tree: every AX query runs
        // on the app's main thread, which also drives the fade.
        let deadline = Date().addingTimeInterval(5)
        while !traceContains("titleArrived"), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(titleField.value as? String, generatedTitle)

        // Arrival, frame by frame, as composited.
        let samples = titleSamples()
        let first = try XCTUnwrap(samples.first, "the trace never saw the title in the field")
        XCTAssertLessThanOrEqual(first.alpha, 0.05, "the title flashed in at \(first.alpha) opacity before its fade")

        for (a, b) in zip(samples, samples.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.alpha, a.alpha - 0.02, "the title dimmed during its reveal (\(a.alpha) → \(b.alpha))")
        }

        let fading = samples.filter { $0.alpha > 0.05 && $0.alpha < 0.95 }
        XCTAssertGreaterThanOrEqual(fading.count, 4, "the title snapped in instead of fading")
        let visible = try XCTUnwrap(samples.first { $0.alpha > 0.05 })
        let settled = try XCTUnwrap(samples.first { $0.alpha >= 0.99 }, "the title never became fully visible")
        let fade = settled.t - visible.t
        XCTAssert((0.15...0.6).contains(fade), "the fade took \(Int(fade * 1000))ms")
        XCTAssertLessThanOrEqual(visible.t - first.t, 0.05, "the title sat hidden for \(Int((visible.t - first.t) * 1000))ms before fading in")
    }

    func testPlaceholderShowsWhenAutomaticTitlesAreOff() {
        app.launchArguments += ["-autoTitleEnabled", "NO"]
        app.launch()
        XCTAssertTrue(titleField.waitForExistence(timeout: 8))
        XCTAssertEqual(titleField.placeholderValue, "Title")
    }

    // MARK: Trace

    private struct TitleSample {
        let t: Double
        let alpha: Double
    }

    private func traceContains(_ event: String) -> Bool {
        (try? String(contentsOf: traceURL, encoding: .utf8))?.contains("\"event\":\"\(event)\"") ?? false
    }

    /// Frames in which the title field holds the generated title.
    private func titleSamples() -> [TitleSample] {
        guard let text = try? String(contentsOf: traceURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["event"] as? String == "frame",
                  object["title"] as? String == generatedTitle,
                  let t = object["t"] as? Double,
                  let alpha = object["titleAlpha"] as? Double else { return nil }
            return TitleSample(t: t, alpha: alpha)
        }
    }
}
