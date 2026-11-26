import CoreServices
import Foundation

nonisolated struct FolderHit: Equatable, Sendable {
    let path: String
    let name: String
    let date: Date?
}

/// Plugged-in drives (external SSDs, USB sticks, SD cards, other partitions) that folder search
/// covers next to the home folder. Each drive's own Spotlight index answers, so there is
/// nothing to build and no file-count limit; a drive Spotlight does not index (some network
/// or freshly formatted disks) simply returns nothing.
nonisolated enum ExternalDrives {
    static let configKey = "search_external_drives"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var enabled = true
    nonisolated(unsafe) private static var cache: (at: Date, volumes: [(name: String, path: String)])?

    /// Set from the config (`search_external_drives`, default on) when the launcher opens.
    static var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    /// Mounted local volumes other than the startup disk, e.g. ("T7", "/Volumes/T7").
    static func mounted() -> [(name: String, path: String)] {
        lock.lock()
        if let cache, Date().timeIntervalSince(cache.at) < 5 { lock.unlock(); return cache.volumes }
        lock.unlock()
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsBrowsableKey, .volumeNameKey, .volumeIsRootFileSystemKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes: [(String, String)] = urls.compactMap { url in
            guard url.path.hasPrefix("/Volumes/"),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsBrowsable == true,
                  values.volumeIsRootFileSystem != true
            else { return nil }
            // The startup disk also appears under /Volumes as a link to "/".
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { return nil }
            return (values.volumeName ?? url.lastPathComponent, url.path)
        }
        lock.lock(); cache = (Date(), volumes); lock.unlock()
        return volumes
    }

    /// Paths to add to folder search (empty when turned off or nothing is plugged in).
    static var searchPaths: [String] { isEnabled ? mounted().map(\.path) : [] }
}

/// Directory name matches from the system index, supplementing Lumio's folder index.
nonisolated enum SpotlightFolders {
    static func search(term: String, scope: FolderScope?, limit: Int, excluding skippedFolders: [String]) async -> [FolderHit] {
        guard limit > 0 else { return [] }
        return await SpotlightQueue.run(skipped: []) { isCancelled in
            blockingSearch(term: term, scope: scope, limit: limit, excluding: skippedFolders, isCancelled: isCancelled)
        }
    }

    private static func blockingSearch(
        term: String, scope: FolderScope?, limit: Int, excluding skippedFolders: [String], isCancelled: () -> Bool
    ) -> [FolderHit] {
        let words = term.lowercased().split(whereSeparator: { $0.isWhitespace })
            .map { clean(String($0)) }.filter { !$0.isEmpty }
        let home = NSHomeDirectory()
        let scopedFolders = scope?.folders ?? []
        let broad = scopedFolders.isEmpty
        let roots = (broad ? [home] + ExternalDrives.searchPaths : scopedFolders)
            .filter { !FileSearchPaths.isExcluded($0, by: skippedFolders) }
        guard !roots.isEmpty else { return [] }

        var conditions = ["kMDItemContentType == \"public.folder\""]
        conditions += words.map { "kMDItemFSName == \"*\($0)*\"cd" }
        let browsing = words.isEmpty
        if browsing {
            conditions.append(broad
                ? "kMDItemLastUsedDate >= $time.today(-60)"
                : "(kMDItemLastUsedDate >= $time.today(-60) || kMDItemDateAdded >= $time.today(-60)"
                    + " || kMDItemContentModificationDate >= $time.today(-60))")
        }

        let queryLimit = 250
        var hits = run(conditions, scopes: roots, max: queryLimit)
        guard !isCancelled() else { return [] }
        if browsing, hits.isEmpty, !broad {
            hits = run(Array(conditions.dropLast()), scopes: roots, max: queryLimit)
        } else if !browsing, hits.count >= queryLimit {
            // Spotlight may omit recent folders when the first result set exceeds its limit.
            let recent = conditions + ["(kMDItemContentModificationDate >= $time.today(-45)"
                + " || kMDItemLastUsedDate >= $time.today(-45))"]
            let seen = Set(hits.map(\.path))
            hits += run(recent, scopes: roots, max: queryLimit).filter { !seen.contains($0.path) }
        }
        guard !isCancelled() else { return [] }

        let needle = words.joined(separator: " ")
        return hits
            .filter { !FileSearchPaths.isExcluded($0.path, by: skippedFolders) }
            .map { ($0, nameScore($0.name.lowercased(), needle: needle, words: words)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return (lhs.0.date ?? .distantPast) > (rhs.0.date ?? .distantPast)
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func run(_ conditions: [String], scopes: [String], max: Int) -> [FolderHit] {
        let dateAttributes: [CFString] = [kMDItemLastUsedDate, kMDItemDateAdded, kMDItemContentModificationDate]
        let predicate = conditions.joined(separator: " && ") as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate, nil, dateAttributes as CFArray) else { return [] }
        MDQuerySetSearchScope(query, scopes as CFArray, 0)
        MDQuerySetMaxCount(query, max)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        defer { MDQueryStop(query) }

        var folders: [FolderHit] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }

            // Recheck the live path in case a folder was removed or replaced since indexing.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let dates = dateAttributes.compactMap { attribute -> Date? in
                guard let raw = MDQueryGetAttributeValueOfResultAtIndex(query, attribute, index) else { return nil }
                return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue() as? Date
            }
            folders.append(FolderHit(
                path: path, name: (path as NSString).lastPathComponent, date: dates.max()
            ))
        }
        return folders
    }

    /// Exact folder name, then a prefix match, then word or substring matches.
    static func nameScore(_ name: String, needle: String, words: [String]) -> Int {
        guard !needle.isEmpty else { return 0 }
        if name == needle { return 5 }
        if name.hasPrefix(needle) { return 4 }
        let separators = CharacterSet(charactersIn: " -_.()[]")
        let nameWords = name.components(separatedBy: separators).filter { !$0.isEmpty }
        if words.allSatisfy({ word in nameWords.contains { $0.hasPrefix(word) } }) { return 3 }
        if name.contains(needle) { return 2 }
        return 1
    }

    /// Removes wildcard and escape characters before inserting a word into the Spotlight predicate.
    private static func clean(_ word: String) -> String {
        word.filter { $0 != "\"" && $0 != "*" && $0 != "\\" && $0 != "?" }
    }
}
