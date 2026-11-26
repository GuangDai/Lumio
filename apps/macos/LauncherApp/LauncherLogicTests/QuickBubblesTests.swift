import XCTest

@testable import LauncherLogic

final class QuickBubblesTests: XCTestCase {
    func testDefaultsAndEmpty() {
        XCTAssertEqual(QuickBubbles.parse(""), QuickBubbles.defaultCodes)
        XCTAssertEqual(QuickBubbles.defaultCodes.count, QuickBubbles.slotCount)
    }

    func testJunkRepeatsAndExtrasAreFixed() {
        XCTAssertEqual(
            QuickBubbles.parse(" doc, Process, bogus, process, app, folder"),
            ["process", "app", "folder"])
    }

    func testSettingASlotSwapsWhenTaken() {
        let defaults = QuickBubbles.defaultCodes
        XCTAssertEqual(
            QuickBubbles.setting(slot: 0, to: "process", in: defaults),
            ["process", "folder", "app"])
        XCTAssertEqual(QuickBubbles.setting(slot: 0, to: "bogus", in: defaults), defaults)
    }

    func testMovingASlot() {
        let defaults = QuickBubbles.defaultCodes
        XCTAssertEqual(
            QuickBubbles.moving(slot: 2, by: -1, in: defaults),
            ["app", "process", "folder"])
        XCTAssertEqual(QuickBubbles.moving(slot: 0, by: -1, in: defaults), defaults)
    }
}
