import Foundation
import XCTest
@testable import LauncherLogic

final class FolderAddressQueryTests: XCTestCase {
    func testChangeDirectoryCommandPreservesPathSegments() {
        XCTAssertEqual(FolderAddressQuery.changeDirectoryArgument(in: "  cd\tD/T  "), "D/T")
        XCTAssertEqual(FolderAddressQuery.changeDirectoryArgument(in: "cd '~/My Projects'"), "~/My Projects")
        XCTAssertEqual(FolderAddressQuery.changeDirectoryArgument(in: "cd '~/My Projects/'"), "~/My Projects/")
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

    func testTrailingSlashRequestsChildrenOnlyForLocalLiteralAddresses() {
        for address in ["/", "/Users/me/Downloads/", "~/", "  '~/My Projects/'  ",
                        "file:///Users/me/Downloads/", "file://localhost/Users/me/Downloads/"] {
            XCTAssertTrue(FolderAddressQuery.requestsChildren(in: address), address)
        }

        for address in ["~", "/Users/me/Downloads", "D/T/", "https://example.com/",
                        "file://example.com/Downloads/", "file:///Users/me/Downloads#bookmark/"] {
            XCTAssertFalse(FolderAddressQuery.requestsChildren(in: address), address)
        }
    }

    func testTrailingSlashListsJustImmediateBrowsableFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let nested = root.appendingPathComponent("Visible", isDirectory: true)
            .appendingPathComponent("Nested", isDirectory: true)
        let hidden = root.appendingPathComponent(".hidden", isDirectory: true)
        let package = root.appendingPathComponent("Example.app", isDirectory: true)
        let file = root.appendingPathComponent("notes.txt")
        for folder in [nested, hidden, package] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data().write(to: file)

        let isBrowsable: (URL) -> Bool = { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            return values?.isDirectory == true && values?.isPackage != true && url.pathExtension != "app"
        }

        let folders = FolderAddressQuery.immediateSubfolders(
            in: root.path + "/", including: isBrowsable, isCancelled: { false }
        )
        XCTAssertEqual(Set(folders.map(\.lastPathComponent)), ["Visible", ".hidden"])

        let filtered = FolderAddressQuery.immediateSubfolders(
            in: root.absoluteString,
            including: { isBrowsable($0) && $0.lastPathComponent != "Visible" },
            isCancelled: { false }
        )
        XCTAssertEqual(filtered.map(\.lastPathComponent), [".hidden"])

        XCTAssertTrue(FolderAddressQuery.immediateSubfolders(
            in: file.path + "/", including: isBrowsable, isCancelled: { false }
        ).isEmpty)
        XCTAssertTrue(FolderAddressQuery.immediateSubfolders(
            in: root.path + "/", including: isBrowsable, isCancelled: { true }
        ).isEmpty)
    }
}
