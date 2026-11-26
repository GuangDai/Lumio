import Foundation
import XCTest
@testable import LauncherLogic

final class FolderAddressQueryTests: XCTestCase {
    func testChangeDirectoryCommandPreservesPathSegments() {
        XCTAssertEqual(FolderAddressQuery.changeDirectoryArgument(in: "  cd\tD/T  "), "D/T")
        XCTAssertEqual(FolderAddressQuery.changeDirectoryArgument(in: "cd '~/My Projects'"), "~/My Projects")
        XCTAssertEqual(FolderAddressQuery.changeDirectoryArgument(in: "cd"), "")
        XCTAssertNil(FolderAddressQuery.changeDirectoryArgument(in: "cdrive"))
    }

    func testRecognizesLocalAddressSyntaxSeparatelyFromFolderQueries() {
        XCTAssertTrue(FolderAddressQuery.isLiteralAddress("\"~/Library/My Projects\""))
        XCTAssertTrue(FolderAddressQuery.isLiteralAddress("file:///Users/me/.config"))
        XCTAssertTrue(FolderAddressQuery.isLiteralAddress("/missing/folder"))
        XCTAssertFalse(FolderAddressQuery.isLiteralAddress("D/T"))
        XCTAssertFalse(FolderAddressQuery.isLiteralAddress("https://example.com"))
    }

    func testLocalAddressesResolveToDirectories() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .standardizedFileURL
        let folder = root.appendingPathComponent(".Library Projects", isDirectory: true)
        let file = folder.appendingPathComponent("index.txt")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try Data().write(to: file)

        XCTAssertEqual(FolderAddressQuery.existingFolder(in: folder.path)?.path, folder.path)
        XCTAssertEqual(FolderAddressQuery.existingFolder(in: "\"\(file.path)\"")?.path, folder.path)
        XCTAssertEqual(FolderAddressQuery.existingFolder(in: file.absoluteString)?.path, folder.path)
        XCTAssertEqual(FolderAddressQuery.existingFolder(in: "~")?.path, fm.homeDirectoryForCurrentUser.path)
        XCTAssertNil(FolderAddressQuery.existingFolder(in: folder.appendingPathComponent("missing").path))
        XCTAssertNil(FolderAddressQuery.existingFolder(in: "https://example.com/index.txt"))
        XCTAssertNil(FolderAddressQuery.existingFolder(in: "file://example.com/etc/"))
        XCTAssertNil(FolderAddressQuery.existingFolder(in: "D/T"))
    }
}
