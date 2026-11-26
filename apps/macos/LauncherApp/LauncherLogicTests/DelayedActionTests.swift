import XCTest
@testable import LauncherLogic

@MainActor
final class DelayedActionTests: XCTestCase {
    private let delay = Duration.milliseconds(40)

    func testRunsAfterTheDelay() async {
        let action = DelayedAction()
        defer { action.cancel() }
        var ran = 0
        let clock = ContinuousClock()
        let start = clock.now
        let pending = action.schedule(after: delay) { ran += 1 }
        XCTAssertEqual(ran, 0)
        await pending.value
        XCTAssertEqual(ran, 1)
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), delay)
    }

    func testCancelBeforeTheDelayPreventsIt() async {
        let action = DelayedAction()
        var ran = 0
        let pending = action.schedule(after: delay) { ran += 1 }
        action.cancel()
        await pending.value
        XCTAssertEqual(ran, 0)
    }

    func testRescheduleReplacesThePendingAction() async {
        let action = DelayedAction()
        defer { action.cancel() }
        var first = 0
        var second = 0
        let replaced = action.schedule(after: delay) { first += 1 }
        let pending = action.schedule(after: delay) { second += 1 }
        await replaced.value
        await pending.value
        XCTAssertEqual(first, 0)
        XCTAssertEqual(second, 1)
    }

    func testAFalseConditionAtWakeUpDropsTheAction() async {
        let action = DelayedAction()
        defer { action.cancel() }
        var visible = false
        var ran = 0
        let pending = action.schedule(after: delay, if: { !visible }) { ran += 1 }
        visible = true
        await pending.value
        XCTAssertEqual(ran, 0)
    }
}
