import XCTest

@testable import LauncherLogic

final class HiddenTabsTests: XCTestCase {
    func testParsingKeepsOnlyKnownUniqueTabs() {
        XCTAssertEqual(HiddenTabs.parse(""), [])
        XCTAssertEqual(HiddenTabs.parse(" Process , bogus,process"), ["process"])
    }

    func testSavedValueRoundTrips() {
        XCTAssertEqual(HiddenTabs.render(HiddenTabs.parse("process")), "process")
    }

    func testChangingVisibility() {
        XCTAssertEqual(HiddenTabs.setting("process", shown: false, in: []), ["process"])
        XCTAssertEqual(HiddenTabs.setting("process", shown: true, in: ["process"]), [])
        XCTAssertEqual(HiddenTabs.setting("bogus", shown: false, in: []), [])
    }
}
