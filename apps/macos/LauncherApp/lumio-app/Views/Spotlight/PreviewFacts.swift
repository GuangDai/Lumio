import AppKit

/// Cached results used to choose which app actions to show.
enum PreviewFacts {
    /// Plenty for one session of browsing. Past this the cache starts over.
    private static let limit = 400

    private static var uninstallable: [String: Bool] = [:]
    private static var running: [String: Bool] = [:]
    private static var runningStamp = Date.distantPast

    /// The app lives in /Applications or ~/Applications, and is not Lumio itself.
    static func canUninstall(_ path: String) -> Bool {
        if let known = uninstallable[path] { return known }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let home = NSHomeDirectory() + "/Applications/"
        let result = (real.hasPrefix("/Applications/") || real.hasPrefix(home))
            && real != Bundle.main.bundleURL.resolvingSymlinksInPath().path
        if uninstallable.count >= limit { uninstallable.removeAll(keepingCapacity: true) }
        uninstallable[path] = result
        return result
    }

    /// Whether the app at `path` is running. Only decides a label ("Open" or "Switch to App")
    /// and which actions are listed. The actions look the app up again when clicked, so an
    /// answer up to a second old is fine.
    static func isRunning(_ path: String) -> Bool {
        let now = Date()
        if now.timeIntervalSince(runningStamp) > 1 {
            running.removeAll(keepingCapacity: true)
            runningStamp = now
        }
        if let known = running[path] { return known }
        let result = SpotlightOpener.runningApp(at: path) != nil
        running[path] = result
        return result
    }

    static func purge() {
        uninstallable.removeAll()
        running.removeAll()
    }
}
