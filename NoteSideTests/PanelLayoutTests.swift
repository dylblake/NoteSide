import XCTest
@testable import NoteSide

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
}
