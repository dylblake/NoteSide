import XCTest
@testable import Remora

/// Choosing the window under the pointer from a window-server snapshot.
final class PointerWindowLocatorTests: XCTestCase {
    private typealias Window = PointerWindowLocator.Window

    private let own: pid_t = 100
    private let front: pid_t = 200
    private let other: pid_t = 300

    // Two displays side by side: the left one 0...1080, the right one from 1080.
    private func window(_ pid: pid_t, x: CGFloat, y: CGFloat = 0, width: CGFloat = 800, height: CGFloat = 600, layer: Int = 0, alpha: Double = 1) -> Window {
        Window(ownerPID: pid, layer: layer, bounds: CGRect(x: x, y: y, width: width, height: height), alpha: alpha)
    }

    func testPicksTheTopmostOrdinaryWindowUnderThePointer() {
        let windows = [
            window(other, x: 1200),            // in front, on the right display
            window(front, x: 1300),            // behind it, overlapping
            window(front, x: 0)                // the front app's window on the left display
        ]
        let decision = PointerWindowLocator.decide(windows: windows, pointer: CGPoint(x: 1400, y: 300), frontmostPID: front, ownPID: own)
        XCTAssertEqual(decision.windowUnderPointer, windows[0])
        XCTAssertEqual(decision.frontmostWindow, windows[1], "the front app's first ordinary window, in the window server's order")
    }

    func testIgnoresRemoraItselfMenusOverlaysAndTinyWindows() {
        let windows = [
            window(own, x: 1100, width: 440, height: 1000),           // the drawer itself
            window(other, x: 1100, layer: 25),                         // a menu bar or status window
            window(other, x: 1100, alpha: 0),                          // invisible
            window(other, x: 1300, width: 80, height: 40),             // a tooltip
            window(other, x: 1150)                                     // the real one
        ]
        let decision = PointerWindowLocator.decide(windows: windows, pointer: CGPoint(x: 1320, y: 20), frontmostPID: front, ownPID: own)
        XCTAssertEqual(decision.windowUnderPointer, windows[4])
        XCTAssertNil(decision.frontmostWindow, "the front app has nothing ordinary on screen")
    }

    func testNothingUnderThePointerIsNil() {
        let windows = [window(front, x: 0), window(other, x: 1200)]
        let decision = PointerWindowLocator.decide(windows: windows, pointer: CGPoint(x: 2100, y: 900), frontmostPID: front, ownPID: own)
        XCTAssertNil(decision.windowUnderPointer)
        XCTAssertEqual(decision.frontmostWindow, windows[0])
    }

    func testTheFrontAppsOwnWindowUnderThePointerCountsToo() {
        // The same app with a second window on the other display: it is
        // the target, and the caller only has to raise it, not activate.
        let windows = [window(front, x: 1200), window(front, x: 0)]
        let decision = PointerWindowLocator.decide(windows: windows, pointer: CGPoint(x: 1300, y: 100), frontmostPID: front, ownPID: own)
        XCTAssertEqual(decision.windowUnderPointer, windows[0])
        XCTAssertEqual(decision.frontmostWindow, windows[0])
    }
}
