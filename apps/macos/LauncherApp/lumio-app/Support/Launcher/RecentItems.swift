import CoreServices
import Foundation

nonisolated struct RecentItem: Equatable, Sendable {
    let path: String
    let name: String
    let lastUsed: Date
}

/// Suggestions for the empty field, ranked by how frequently and recently each app was opened.
nonisolated enum RecentItems {
    static let configKey = "suggestions_on_open"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (at: Date, items: [RecentItem])?
    private static let cacheSeconds: TimeInterval = 20

    @MainActor static var isEnabled: Bool {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        guard let value = ConfigFileLines.keyValues(raw)[configKey]?.lowercased() else { return false }
        return !["false", "0", "no", "off"].contains(value)
    }

    static func recent(limit: Int) async -> [RecentItem] {
        guard limit > 0, !Task.isCancelled else { return [] }
        if let apps = cached() { return Array(apps.prefix(limit)) }
        let apps = await SpotlightQueue.run(skipped: []) { _ in cached() ?? gather() }
        return Array(apps.prefix(limit))
    }

    private static func cached() -> [RecentItem]? {
        lock.withLock {
            guard let cache, Date().timeIntervalSince(cache.at) < cacheSeconds else { return nil }
            return cache.items
        }
    }

    /// Runs on SpotlightQueue and searches only application bundles in app directories.
    private static func gather() -> [RecentItem] {
        let predicate = "kMDItemContentType == 'com.apple.application-bundle' && kMDItemLastUsedDate >= $time.today(-30)"
        let usedDates = "kMDItemUsedDates" as CFString
        let attributes = [kMDItemLastUsedDate, kMDItemDateAdded, usedDates] as CFArray
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, attributes) else { return [] }
        let directories = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        MDQuerySetSearchScope(query, directories as CFArray, 0)
        MDQuerySetMaxCount(query, 400)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }

        func value(_ attribute: CFString, _ index: CFIndex) -> AnyObject? {
            guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
        }

        let ownBundle = Bundle.main.bundlePath
        var ranked: [(app: RecentItem, score: Double)] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String,
                  path != ownBundle, !path.contains("/Contents/"),
                  !BrowserOpening.isBlockedApplication(URL(fileURLWithPath: path)) else { continue }
            let added = value(kMDItemDateAdded, index) as? Date
            guard let date = (value(kMDItemLastUsedDate, index) as? Date) ?? added else { continue }

            let filename = (path as NSString).lastPathComponent
            let name = filename.hasSuffix(".app") ? String(filename.dropLast(4)) : filename
            let app = RecentItem(path: path, name: name, lastUsed: date)
            let days = (value(usedDates, index) as? [Date]) ?? []
            let uses = days.suffix(30) + [date]
            let score = uses.reduce(0.0) { score, use in
                let age = max(0, -use.timeIntervalSinceNow / 86_400)
                return score + pow(0.5, age / 4)
            }
            ranked.append((app, score))
        }
        let apps = ranked.sorted {
            $0.score == $1.score ? $0.app.lastUsed > $1.app.lastUsed : $0.score > $1.score
        }.map(\.app)
        lock.withLock { cache = (Date(), apps) }
        return apps
    }
}
