import XCTest
@testable import NoteSide

/// The drawer takes key status only once the host has handed over its
/// selection (a ⌘C is ignored by an app that isn't key) — and must not wait
/// out the whole read to do it, or it slides in looking inactive (a non-key
/// window's glass is lighter).
final class SelectionReaderHostKeyTests: XCTestCase {
    func testChromiumAndElectronAppsGoStraightToCopy() throws {
        XCTAssertTrue(SelectionReader.readsThroughCopy(bundleIdentifier: "com.google.Chrome", bundleURL: nil))
        XCTAssertTrue(SelectionReader.readsThroughCopy(bundleIdentifier: "company.thebrowser.Browser", bundleURL: nil), "Arc is Chromium")
        XCTAssertFalse(SelectionReader.readsThroughCopy(bundleIdentifier: "com.apple.Safari", bundleURL: nil))
        XCTAssertFalse(SelectionReader.readsThroughCopy(bundleIdentifier: "com.apple.TextEdit", bundleURL: nil))
        XCTAssertFalse(SelectionReader.readsThroughCopy(bundleIdentifier: nil, bundleURL: nil))

        // Electron apps are recognised by the framework they ship.
        let electronApp = FileManager.default.temporaryDirectory.appending(path: "Electron-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: electronApp) }
        let nativeApp = FileManager.default.temporaryDirectory.appending(path: "Native-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: nativeApp) }
        try FileManager.default.createDirectory(at: electronApp.appending(path: "Contents/Frameworks/Electron Framework.framework"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nativeApp.appending(path: "Contents/Frameworks"), withIntermediateDirectories: true)
        XCTAssertTrue(SelectionReader.readsThroughCopy(bundleIdentifier: "com.tinyspeck.slackmacgap", bundleURL: electronApp))
        XCTAssertFalse(SelectionReader.readsThroughCopy(bundleIdentifier: "com.openai.chat", bundleURL: nativeApp))
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
