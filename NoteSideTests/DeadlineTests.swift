import XCTest
@testable import NoteSide

final class DeadlineTests: XCTestCase {
    func testValueArrivesInTime() async {
        let task = Task { () -> Int in
            try? await Task.sleep(for: .milliseconds(20))
            return 7
        }
        let value = await Deadline.value(of: task, until: .now + .milliseconds(500))
        XCTAssertEqual(value, 7)
    }

    func testMissedDeadlineReturnsNilAndTaskKeepsRunning() async {
        let task = Task { () -> String in
            try? await Task.sleep(for: .milliseconds(150))
            return "late"
        }
        let value = await Deadline.value(of: task, until: .now + .milliseconds(30))
        XCTAssertNil(value)
        let eventual = await task.value
        XCTAssertEqual(eventual, "late", "the underlying work is not cancelled by the deadline")
    }

    func testAlreadyFinishedTaskReturnsImmediately() async {
        let task = Task { 1 }
        _ = await task.value
        let value = await Deadline.value(of: task, until: .now + .milliseconds(1))
        XCTAssertEqual(value, 1)
    }
}
