//
//  PanelMotionUITests.swift
//  RemoraUITests
//
//  Opens and closes the note drawer through the DEBUG remote-toggle hook
//  (it stands in for the hotkey) and checks the frame-by-frame motion
//  trace the app records (`PanelMotionTrace`, one sample per screen
//  refresh, read from the presentation layer). The drawer must start
//  moving on the keypress, stay opaque, move one way without lurching or
//  creeping, and reverse continuously when interrupted.
//

import AppKit
import XCTest

final class PanelMotionUITests: XCTestCase {
    private var app: XCUIApplication!
    private var storeDirectory: URL!
    private var traceURL: URL!

    /// Fastest the panel may move, in panel widths per second. A natural
    /// slide peaks near 6–9; the quint and iOS-sheet curves that read as a
    /// pop-then-drift reach 13–24.
    private let maxSpeed = 11.0
    /// Longest wait from the call to the first frame that shows movement
    /// (~3½ frames at 60Hz; a keypress-to-motion delay you'd feel is well
    /// past it).
    private let maxStartLatency = 0.06

    override func setUpWithError() throws {
        continueAfterFailure = false
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            throw XCTSkip("Reduce Motion replaces the slide with a fade")
        }

        let scratch = FileManager.default.temporaryDirectory
        storeDirectory = scratch.appending(path: "RemoraUITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        traceURL = scratch.appending(path: "RemoraMotion-\(UUID().uuidString).jsonl")

        app = XCUIApplication()
        app.launchEnvironment["UITEST_STORE_DIRECTORY"] = storeDirectory.path
        app.launchEnvironment["UITEST_REMOTE_TOGGLE"] = "1"
        app.launchEnvironment["REMORA_MOTION_TRACE"] = traceURL.path
        app.launchEnvironment["REMORA_PANE_WIDTH"] = "640"
        // Skip the host app's selection read: its ⌘C fallback can take the
        // whole pre-open budget, and a reopen then can't land mid-close.
        app.launchEnvironment["UITEST_SELECTION_TEXT"] = "motion"
        app.launchArguments += [
            "-hasCompletedOnboarding", "YES",
            "-trialNotesCreated", "0",
            "-autoTitleEnabled", "NO"
        ]
        app.launch()
        // Let launch-time work settle so it doesn't land mid-slide.
        Thread.sleep(forTimeInterval: 1)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let storeDirectory { try? FileManager.default.removeItem(at: storeDirectory) }
        if let traceURL { try? FileManager.default.removeItem(at: traceURL) }
    }

    // MARK: Tests

    func testOpenStartsOnTheKeypressAndSlidesInNaturally() throws {
        // The first open after launch lays out and draws the editor for the
        // first time; hold it to a looser bound.
        toggle()
        let cold = try waitForEvents(["presented"])
        let coldPresent = try XCTUnwrap(cold.first { $0.event == "present" })
        let coldMoving = try XCTUnwrap(cold.first { $0.event == "frame" && $0.t > coldPresent.t && $0.offset < coldPresent.width - 0.5 })
        XCTAssertLessThanOrEqual(coldMoving.t - coldPresent.t, 0.1, "the first open took \(Int((coldMoving.t - coldPresent.t) * 1000))ms to start moving")

        // Every open after that: the full bar.
        toggle()
        _ = try waitForEvents(["presented", "dismissed"])
        toggle()
        let trace = try waitForEvents(["presented", "dismissed", "presented"])

        let hotkey = try XCTUnwrap(trace.last { $0.event == "hotkey" })
        let present = try XCTUnwrap(trace.last { $0.event == "present" })
        XCTAssertLessThanOrEqual(present.t - hotkey.t, 0.1, "the drawer waited \(Int((present.t - hotkey.t) * 1000))ms after the hotkey before sliding in")

        try assertNaturalSlide(in: trace, from: "present", to: "presented", startOffset: present.width, endOffset: 0)

        // Key from its first visible frame: a non-key window draws its glass
        // in the lighter, disabled-looking inactive style.
        let firstVisible = try XCTUnwrap(trace.first { $0.event == "frame" && $0.t > present.t && $0.offset < present.width - 0.5 })
        XCTAssertTrue(firstVisible.key, "the drawer was on screen before it was key, so it looked inactive")
    }

    func testFollowingToAnotherDisplaySlidesInThere() throws {
        guard NSScreen.screens.count > 1 else { throw XCTSkip("needs a second display") }
        toggle()
        _ = try waitForEvents(["presented"])
        moveToOtherDisplay()
        let trace = try waitForEvents(["presented", "presented"])

        let move = try XCTUnwrap(trace.last { $0.event == "move" })
        let present = try XCTUnwrap(trace.last { $0.event == "present" })
        XCTAssertNotEqual(move.screenX, present.screenX, "the drawer didn't change displays")

        // It settles on the new display invisibly first: a window that has
        // just changed displays shows its settled content, not its
        // animations, for its first ~200ms there — slide straight away and
        // it jumps into place.
        XCTAssertGreaterThanOrEqual(present.t - move.t, 0.2, "the slide started before the new display could show it")
        let settling = trace.filter { $0.event == "frame" && $0.t > move.t && $0.t < present.t && $0.visible }
        for sample in settling {
            XCTAssertEqual(sample.alpha, 0, accuracy: 0.001, "the drawer showed on the new display before it slid in")
        }

        // Then the same slide as an open.
        try assertNaturalSlide(in: trace, from: "present", to: "presented", startOffset: present.width, endOffset: 0)
    }

    func testCloseStartsOnTheKeypressAndSlidesOutNaturally() throws {
        // Several cycles: whether a first-frame lurch shows depends on where
        // the commit lands against the display refresh, so one close can
        // pass by luck.
        var expected: [String] = []
        for _ in 0..<3 {
            toggle()
            expected.append("presented")
            _ = try waitForEvents(expected)
            toggle()
            expected.append("dismissed")
            let trace = try waitForEvents(expected)

            let dismiss = try XCTUnwrap(trace.last { $0.event == "dismiss" })
            let hotkey = try XCTUnwrap(trace.last { $0.event == "hotkey" })
            XCTAssertLessThanOrEqual(dismiss.t - hotkey.t, 0.05, "the close waited on other work before moving")

            try assertNaturalSlide(in: trace, from: "dismiss", to: "dismissed", startOffset: 0, endOffset: dismiss.width)
        }
    }

    func testReopeningWhileClosingReversesFromWhereItIs() throws {
        toggle()
        _ = try waitForEvents(["presented"])
        toggle()
        try waitForEvent("dismiss", count: 1)
        toggle()
        let trace = try waitForEvents(["presented", "presented"])
        XCTAssertFalse(trace.contains { $0.event == "dismissed" }, "the close finished before the reopen landed; the test didn't exercise a reversal")

        let window = frames(in: trace, after: try XCTUnwrap(trace.first { $0.event == "dismiss" }), through: try XCTUnwrap(trace.last { $0.event == "presented" }))
        assertOpaque(window)
        assertSpeedLimit(window)
        // Out, then straight back in: one turning point, no restart from off-screen.
        let peak = try XCTUnwrap(window.indices.max { window[$0].offset < window[$1].offset })
        XCTAssertLessThan(window[peak].offset, window[peak].width - 1, "the reopen jumped the panel fully off-screen instead of reversing")
        assertMonotonic(Array(window[...peak]), increasing: true)
        assertMonotonic(Array(window[peak...]), increasing: false)
        XCTAssertLessThanOrEqual(try XCTUnwrap(trace.last { $0.event == "presented" }).offset, 1)
    }

    func testClosingWhileOpeningReversesFromWhereItIs() throws {
        toggle()
        try waitForEvent("present", count: 1)
        Thread.sleep(forTimeInterval: 0.1)
        toggle()
        let trace = try waitForEvents(["dismissed"])
        XCTAssertFalse(trace.contains { $0.event == "presented" }, "the open finished before the close landed; the test didn't exercise a reversal")

        let window = frames(in: trace, after: try XCTUnwrap(trace.first { $0.event == "present" }), through: try XCTUnwrap(trace.last { $0.event == "dismissed" }))
        assertOpaque(window)
        assertSpeedLimit(window)
        let turn = try XCTUnwrap(window.indices.min { window[$0].offset < window[$1].offset })
        XCTAssertGreaterThan(window[turn].offset, 1, "the close didn't start until the open had finished")
        assertMonotonic(Array(window[...turn]), increasing: false)
        assertMonotonic(Array(window[turn...]), increasing: true)
    }

    // MARK: Checks

    /// One uninterrupted slide between two trace events.
    private func assertNaturalSlide(
        in trace: [Sample],
        from startEvent: String,
        to endEvent: String,
        startOffset: Double,
        endOffset: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let start = try XCTUnwrap(trace.last { $0.event == startEvent }, file: file, line: line)
        let end = try XCTUnwrap(trace.last { $0.event == endEvent }, file: file, line: line)
        let slide = frames(in: trace, after: start, through: end)
        XCTAssertGreaterThanOrEqual(slide.count, 8, "too few frames to judge the slide", file: file, line: line)
        let travel = endOffset - startOffset

        // Starts on the call: the first moving frame follows within ~3 frames.
        let firstMoving = try XCTUnwrap(slide.first { abs($0.offset - startOffset) > 0.5 }, "the panel never moved", file: file, line: line)
        XCTAssertLessThanOrEqual(firstMoving.t - start.t, maxStartLatency, "the first moving frame came \(Int((firstMoving.t - start.t) * 1000))ms after the call", file: file, line: line)

        assertOpaque(slide, file: file, line: line)
        assertMonotonic(slide, increasing: travel > 0, file: file, line: line)
        assertSpeedLimit(slide, file: file, line: line)

        // Doesn't creep: 90% of the travel isn't done before half the slide.
        let duration = end.t - start.t
        let at90 = try XCTUnwrap(slide.first { abs($0.offset - startOffset) >= 0.9 * abs(travel) }, file: file, line: line)
        XCTAssertGreaterThanOrEqual((at90.t - start.t) / duration, 0.5, "90% of the slide was done in the first \(Int((at90.t - start.t) / duration * 100))% of it — the rest is a creep", file: file, line: line)

        // Finishes, and on time.
        XCTAssertLessThanOrEqual(duration, 0.45, "the slide took \(Int(duration * 1000))ms", file: file, line: line)
        let settled = slide.last(where: { $0.event == "frame" })?.offset ?? end.offset
        XCTAssertEqual(settled, endOffset, accuracy: 2, "the slide didn't reach its end", file: file, line: line)
    }

    private func assertOpaque(_ samples: [Sample], file: StaticString = #filePath, line: UInt = #line) {
        for sample in samples where sample.event == "frame" {
            XCTAssertGreaterThanOrEqual(sample.alpha, 0.999, "the panel faded while moving (alpha \(sample.alpha))", file: file, line: line)
        }
    }

    private func assertMonotonic(_ samples: [Sample], increasing: Bool, file: StaticString = #filePath, line: UInt = #line) {
        for (a, b) in zip(samples, samples.dropFirst()) {
            let delta = b.offset - a.offset
            XCTAssertGreaterThanOrEqual(increasing ? delta : -delta, -0.5, "the panel moved backwards (\(a.offset) → \(b.offset))", file: file, line: line)
        }
    }

    /// Distance per display frame, not per second: the presentation value
    /// moves in whole-frame steps while display-link callbacks land a few
    /// milliseconds early or late, so dividing by the raw gap would inflate
    /// the speed. Each gap is rounded to a whole number of refreshes (the
    /// median gap is the refresh interval).
    private func assertSpeedLimit(_ samples: [Sample], file: StaticString = #filePath, line: UInt = #line) {
        let moving = samples.filter { $0.event == "frame" }
        let gaps = zip(moving, moving.dropFirst()).map { $1.t - $0.t }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return }
        let refresh = gaps[gaps.count / 2]
        for (a, b) in zip(moving, moving.dropFirst()) where b.t > a.t {
            let frames = max(1, ((b.t - a.t) / refresh).rounded())
            let perFrame = abs(b.offset - a.offset) / frames
            let limit = maxSpeed * refresh * a.width
            XCTAssertLessThanOrEqual(perFrame, limit, "the panel lurched: \(Int(perFrame))pt in one frame (limit \(Int(limit))pt)", file: file, line: line)
        }
    }

    // MARK: Trace

    private struct Sample {
        let t: Double
        let event: String
        let offset: Double
        let alpha: Double
        let width: Double
        let key: Bool
        let visible: Bool
        let screenX: Double
    }

    private func toggle() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.remora.uitest.toggleQuickNote"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func moveToOtherDisplay() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.remora.uitest.moveDrawerToOtherScreen"),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func readTrace() -> [Sample] {
        guard let text = try? String(contentsOf: traceURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let t = object["t"] as? Double,
                  let event = object["event"] as? String else { return nil }
            return Sample(
                t: t,
                event: event,
                offset: object["offset"] as? Double ?? 0,
                alpha: object["alpha"] as? Double ?? 1,
                width: object["width"] as? Double ?? 0,
                key: object["key"] as? Bool ?? false,
                visible: object["visible"] as? Bool ?? false,
                screenX: object["screenX"] as? Double ?? -1
            )
        }
    }

    /// Waits until the trace's completion events (`presented` / `dismissed`)
    /// match `events`, in order.
    private func waitForEvents(_ events: [String], timeout: TimeInterval = 5) throws -> [Sample] {
        let deadline = Date().addingTimeInterval(timeout)
        var trace: [Sample] = []
        while Date() < deadline {
            trace = readTrace()
            let completions = trace.map(\.event).filter { $0 == "presented" || $0 == "dismissed" }
            if completions == events { return trace }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTFail("expected \(events), got \(trace.map(\.event).filter { $0 != "frame" })")
        return trace
    }

    /// Waits until `event` has been recorded `count` times.
    private func waitForEvent(_ event: String, count: Int, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readTrace().filter({ $0.event == event }).count >= count { return }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTFail("\(event) never happened")
    }

    /// Frame samples after `start`, through `end` (inclusive of `end`).
    private func frames(in trace: [Sample], after start: Sample, through end: Sample) -> [Sample] {
        trace.filter { $0.event == "frame" && $0.t > start.t && $0.t <= end.t } + [end]
    }
}
