import XCTest

@testable import LauncherLogic

final class QuickBubblesTests: XCTestCase {
    func testDefaultsAndEmpty() {
        XCTAssertEqual(QuickBubbles.parse(""), QuickBubbles.defaultCodes)
        XCTAssertEqual(QuickBubbles.defaultCodes.count, QuickBubbles.slotCount)
    }

    func testJunkRepeatsAndExtrasAreFixed() {
        XCTAssertEqual(
            QuickBubbles.parse(" Process, bogus, process, app"),
            ["process", "app", "folder", "doc"])
    }

    func testSettingASlotSwapsWhenTaken() {
        let defaults = QuickBubbles.defaultCodes
        XCTAssertEqual(
            QuickBubbles.setting(slot: 0, to: "doc", in: defaults),
            ["doc", "folder", "app", "process"])
        XCTAssertEqual(QuickBubbles.setting(slot: 0, to: "bogus", in: defaults), defaults)
    }

    func testMovingASlot() {
        let defaults = QuickBubbles.defaultCodes
        XCTAssertEqual(
            QuickBubbles.moving(slot: 3, by: -1, in: defaults),
            ["app", "folder", "process", "doc"])
        XCTAssertEqual(QuickBubbles.moving(slot: 0, by: -1, in: defaults), defaults)
    }
}
