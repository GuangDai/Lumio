import XCTest
@testable import LauncherLogic

final class LauncherSearchLogicTests: XCTestCase {
    func testApplicationOrderingKeepsOtherResultsAfterAllApps() {
        let rows = ["Folder", "App B", "Browser tab", "App A", "Settings pane"]
        let ordered = LauncherSearchLogic.applicationsFirst(rows) { $0.hasPrefix("App ") }
        XCTAssertEqual(ordered, ["App B", "App A", "Folder", "Browser tab", "Settings pane"])
    }

    func testSettingsIntentRequiresExplicitQueryTerms() {
        XCTAssertTrue(LauncherSearchLogic.prioritizesApplications(for: "moni"))
        XCTAssertTrue(LauncherSearchLogic.prioritizesApplications(for: "display"))
        XCTAssertTrue(LauncherSearchLogic.prioritizesApplications(for: "net"))
        XCTAssertFalse(LauncherSearchLogic.prioritizesApplications(for: "Privacy Settings"))
        XCTAssertFalse(LauncherSearchLogic.prioritizesApplications(for: "系统设置"))
        XCTAssertTrue(LauncherSearchLogic.isSettingsLandingQuery(" Settings "))
        XCTAssertFalse(LauncherSearchLogic.isSettingsLandingQuery("privacy settings"))
        XCTAssertFalse(LauncherSearchLogic.isLumioSettingsQuery("settings"))
        XCTAssertFalse(LauncherSearchLogic.isLumioSettingsQuery("lumio"))
        XCTAssertTrue(LauncherSearchLogic.isLumioSettingsQuery("Lumio Settings"))
        XCTAssertTrue(LauncherSearchLogic.isLumioSettingsQuery("lumio 设置"))
        XCTAssertTrue(LauncherSearchLogic.hasEngineScope("s\"network"))
    }

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
