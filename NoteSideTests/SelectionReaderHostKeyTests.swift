import XCTest
@testable import NoteSide

/// The drawer takes key status only once a Chromium host has handled its
/// ⌘C — and must not wait out the whole read to do it, or it slides in
/// looking inactive (a non-key window's glass is lighter).
final class SelectionReaderHostKeyTests: XCTestCase {
    func testOnlyChromiumHostsMustStayKey() {
        XCTAssertTrue(SelectionReader.hostMustStayKey("com.google.Chrome"))
        XCTAssertTrue(SelectionReader.hostMustStayKey("company.thebrowser.Browser"), "Arc is Chromium")
        XCTAssertTrue(SelectionReader.hostMustStayKey("com.brave.Browser"))
        XCTAssertFalse(SelectionReader.hostMustStayKey("com.apple.Safari"))
        XCTAssertFalse(SelectionReader.hostMustStayKey("com.apple.TextEdit"))
        XCTAssertFalse(SelectionReader.hostMustStayKey(nil))
    }

    func testHostIsFreedEarlyWhenNothingIsSelected() {
        var polls = 0
        var hostDoneAtPoll: Int?
        let changed = SelectionReader.waitForCopy(
            changed: { false },
            wait: { polls += 1 },
            onHostDone: { hostDoneAtPoll = polls }
        )
        XCTAssertFalse(changed)
        XCTAssertEqual(hostDoneAtPoll, 3, "freed after 15ms, not after the 400ms read")
        XCTAssertEqual(polls, 80, "the read itself still waits for a slow copy")
    }

    func testHostIsFreedTheMomentTheCopyLands() {
        var polls = 0
        var hostDoneCount = 0
        var hostDoneAtPoll: Int?
        let changed = SelectionReader.waitForCopy(
            changed: { polls >= 2 },
            wait: { polls += 1 },
            onHostDone: { hostDoneCount += 1; hostDoneAtPoll = polls }
        )
        XCTAssertTrue(changed)
        XCTAssertEqual(hostDoneAtPoll, 2)
        XCTAssertEqual(hostDoneCount, 1)
    }

    func testHostIsFreedExactlyOnce() {
        var hostDoneCount = 0
        _ = SelectionReader.waitForCopy(changed: { false }, wait: {}, onHostDone: { hostDoneCount += 1 })
        XCTAssertEqual(hostDoneCount, 1)
        _ = SelectionReader.waitForCopy(changed: { false }, wait: {}, hostPolls: 50, maxPolls: 5, onHostDone: { hostDoneCount += 1 })
        XCTAssertEqual(hostDoneCount, 2, "freed even if the read gives up before the grace period")
    }
}
