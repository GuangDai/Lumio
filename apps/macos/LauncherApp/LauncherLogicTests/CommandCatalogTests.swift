import XCTest
@testable import LauncherLogic

final class CommandCatalogTests: XCTestCase {
    func testDirectoryAndActiveWindowCommandsCanBeFound() {
        XCTAssertEqual(AppConstants.Launcher.commandCatalog(matching: "cd").map(\.id), ["cd"])
        XCTAssertEqual(AppConstants.Launcher.commandCatalog(matching: "ACTIVE").map(\.id), ["active"])
        XCTAssertEqual(AppConstants.Launcher.commandCatalog(matching: "windows").map(\.id), ["active"])
    }

    func testRemovedKillCommandIsNotListed() {
        XCTAssertFalse(AppConstants.Launcher.commandCatalog.contains { $0.id == "kill" })
        XCTAssertTrue(AppConstants.Launcher.commandCatalog(matching: "kill").isEmpty)
    }

    func testFilteredCommandsKeepTheirCatalogShortcuts() {
        let filtered = AppConstants.Launcher.commandCatalog(matching: "active")
        let index = AppConstants.Launcher.commandCatalog.firstIndex { $0.id == "active" }
        XCTAssertEqual(filtered.first?.shortcut, index.map { "⌘\($0 + 1)" })
    }
}
