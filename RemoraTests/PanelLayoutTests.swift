import XCTest
@testable import Remora

final class PanelLayoutTests: XCTestCase {
    func testEditorPaneIsClampedOnNarrowAndWideScreens() {
        XCTAssertEqual(PanelLayout.editorPaneWidth(forScreenWidth: 1080), 440, "portrait display: minimum, not a third")
        XCTAssertEqual(PanelLayout.editorPaneWidth(forScreenWidth: 1440), 480)
        XCTAssertEqual(PanelLayout.editorPaneWidth(forScreenWidth: 1920), 640)
        XCTAssertEqual(PanelLayout.editorPaneWidth(forScreenWidth: 3440), 640, "ultra-wide: capped")
    }

    func testAllNotesPaneIsClamped() {
        XCTAssertEqual(PanelLayout.allNotesPaneWidth(forScreenWidth: 1080), 540)
        XCTAssertEqual(PanelLayout.allNotesPaneWidth(forScreenWidth: 1512), 680)
        XCTAssertEqual(PanelLayout.allNotesPaneWidth(forScreenWidth: 3440), 960)
    }

    func testPaneNeverCoversMoreThanMostOfATinyScreen() {
        XCTAssertLessThanOrEqual(PanelLayout.editorPaneWidth(forScreenWidth: 400), 340)
        XCTAssertLessThanOrEqual(PanelLayout.allNotesPaneWidth(forScreenWidth: 400), 340)
    }

    // MARK: The stack (All Notes beside the note drawer)

    /// The drawer's frame on a display: its pane width, at the right edge.
    private func editorFrame(in visibleFrame: NSRect) -> NSRect {
        let width = PanelLayout.editorPaneWidth(forScreenWidth: visibleFrame.width)
        return NSRect(x: visibleFrame.maxX - width, y: visibleFrame.minY, width: width, height: visibleFrame.height)
    }

    private func stackedFrame(in visibleFrame: NSRect) -> NSRect? {
        PanelLayout.stackedAllNotesFrame(editorFrame: editorFrame(in: visibleFrame), visibleFrame: visibleFrame)
    }

    func testStackedListTucksUnderTheDrawerAndKeepsItsContentWidth() throws {
        for screenWidth: CGFloat in [1080, 1440, 1920, 2560] {
            let visible = NSRect(x: 0, y: 0, width: screenWidth, height: 1000)
            let editor = editorFrame(in: visible)
            let list = try XCTUnwrap(stackedFrame(in: visible), "\(screenWidth)pt should fit the pair")

            XCTAssertEqual(list.maxX, editor.minX + PanelLayout.stackTuck, "\(screenWidth)pt: the list's window ends under the drawer")
            XCTAssertEqual(list.minY, editor.minY)
            XCTAssertEqual(list.height, editor.height)
            XCTAssertGreaterThanOrEqual(list.minX, visible.minX, "\(screenWidth)pt: the list stays on the display")

            // What shows beside the drawer is as wide as the list's content
            // when it is alone: the part under the drawer is extra.
            let alone = PanelLayout.allNotesPaneWidth(forScreenWidth: screenWidth)
            XCTAssertEqual(list.width, alone + PanelLayout.stackedContentInset, "\(screenWidth)pt")
        }
    }

    func testStackedFramesOnTheOwnersDisplays() {
        XCTAssertEqual(
            stackedFrame(in: NSRect(x: 0, y: 0, width: 1080, height: 1890)),
            NSRect(x: 120, y: 0, width: 600, height: 1890),
            "portrait display: 440pt drawer, list from 120 to 720"
        )
        XCTAssertEqual(
            stackedFrame(in: NSRect(x: 1080, y: 0, width: 1920, height: 1050)),
            NSRect(x: 1516, y: 0, width: 924, height: 1050),
            "a display that doesn't start at zero keeps its origin"
        )
    }

    func testLapHidesTheListsRoundedCorners() {
        XCTAssertGreaterThanOrEqual(PanelLayout.stackLap, CornerRadius.panel, "a lap shorter than the corner radius leaves a notch where the two sheets' corners cross")
    }

    func testStackedListShrinksToFitAndGivesUpWhenTooNarrow() throws {
        // Room for the drawer but not for the full list: it narrows.
        let tight = NSRect(x: 0, y: 0, width: 900, height: 800)
        let list = try XCTUnwrap(stackedFrame(in: tight))
        XCTAssertGreaterThan(list.minX, tight.minX, "leaves a margin at the display's edge")
        XCTAssertLessThan(list.width, PanelLayout.allNotesPaneWidth(forScreenWidth: 900) + PanelLayout.stackedContentInset)

        // Too narrow to browse beside a note: the caller swaps the panels.
        XCTAssertNil(stackedFrame(in: NSRect(x: 0, y: 0, width: 800, height: 800)))
    }
}
