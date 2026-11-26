import AppKit
import Foundation

/// Where `open -a Name` would find a bundle: the same roots `open` itself
/// searches, plus a bundle-id lookup for a name that is one.
enum AppBundleLocator {
    private nonisolated static let roots = [
        "/Applications",
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    static func bundlePath(forAppNamed name: String) -> String? {
        let bundleName = name.hasSuffix(".app") ? name : name + ".app"
        for root in roots {
            let candidate = root + "/" + bundleName
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: name)?
            .path
    }

    nonisolated struct Application: Identifiable, Sendable {
        let name: String
        let bundleName: String
        let path: String

        var id: String { AppExcludeWriter.normalize(bundleName) }

        func matches(_ query: String) -> Bool {
            query.isEmpty || name.localizedStandardContains(query) || bundleName.localizedStandardContains(query)
        }
    }

    /// Lists apps independently of the index so hidden apps can still be selected and restored.
    nonisolated static func installedApplications(additionalRoots: [String], depth: Int) -> [Application] {
        let searchRoots = additionalRoots + roots + [
            "/System/Library/CoreServices/Applications",
            "/System/Library/CoreServices/Finder.app/Contents/Applications",
        ]
        var seenRoots = Set<String>()
        var applications: [String: Application] = [:]
        let manager = FileManager.default

        func add(_ bundle: URL) {
            guard let app = application(at: bundle), applications[app.id] == nil else { return }
            applications[app.id] = app
        }

        for path in searchRoots {
            guard !Task.isCancelled else { break }
            let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            guard seenRoots.insert(root.path).inserted else { continue }
            if root.pathExtension.lowercased() == "app" {
                add(root)
                continue
            }
            guard let descendants = manager.enumerator(at: root, includingPropertiesForKeys: nil,
                                                       options: [.skipsPackageDescendants]) else { continue }
            for case let location as URL in descendants {
                guard !Task.isCancelled else { break }
                if location.pathExtension.lowercased() == "app" {
                    descendants.skipDescendants()
                    add(location)
                } else if descendants.level >= depth {
                    descendants.skipDescendants()
                }
            }
        }

        // These user-facing apps can live next to system helpers or inside a bundle.
        for path in [
            "/System/Library/CoreServices/Finder.app",
            "/System/Library/CoreServices/Siri.app",
            "/System/Library/CoreServices/Time Machine.app",
            "/System/Library/CoreServices/VoiceOver.app/Contents/Resources/VoiceOver Utility.app",
        ] {
            add(URL(fileURLWithPath: path))
        }

        return applications.values.sorted { left, right in
            let order = left.name.localizedStandardCompare(right.name)
            return order == .orderedSame ? left.id < right.id : order == .orderedAscending
        }
    }

    nonisolated static func application(at url: URL) -> Application? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard url.isFileURL, url.pathExtension.lowercased() == "app",
              manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              !BrowserOpening.isBlockedApplication(url) else { return nil }
        let bundleName = url.deletingPathExtension().lastPathComponent
        let displayName = manager.displayName(atPath: url.path)
        let name = displayName == url.lastPathComponent ? bundleName : displayName
        return Application(name: name, bundleName: bundleName, path: url.path)
    }
}
