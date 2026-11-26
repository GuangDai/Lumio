import XCTest
@testable import LauncherLogic

final class LauncherSearchLogicTests: XCTestCase {
    func testPinnedScopeDetection() {
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "finder"), .unscoped)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "a\"finder"), .apps)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "f\"report"), .unscoped)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "d\"doc"), .folders)
        XCTAssertEqual(LauncherSearchLogic.pinnedLookupScope(for: "c\"note"), .unscoped)
    }

    func testNormalizedPinnedQueryRespectsScope() {
        XCTAssertEqual(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "a\" Finder ", scope: .apps),
            "finder"
        )
        XCTAssertEqual(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "d\" Documents ", scope: .folders),
            "documents"
        )
        XCTAssertNil(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "finder", scope: .disabled)
        )
        XCTAssertNil(
            LauncherSearchLogic.normalizedPinnedLookupQuery(for: "   ", scope: .unscoped)
        )
    }

    func testFinderInjectionOnlyForAllowedScopes() {
        XCTAssertTrue(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "find", scope: .unscoped))
        XCTAssertTrue(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "finder", scope: .apps))
        XCTAssertFalse(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "finder", scope: .folders))
        XCTAssertFalse(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: "fi", scope: .unscoped))
        XCTAssertFalse(LauncherSearchLogic.shouldInjectFinder(normalizedQuery: nil, scope: .apps))
    }
}
