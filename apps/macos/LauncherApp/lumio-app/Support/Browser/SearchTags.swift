import Foundation

/// A local result filter applied by typing its keyword and pressing Tab.
nonisolated struct SearchTag: Equatable, Sendable {
    let keyword: String
    let name: String
    /// Host used to match local browser tabs and visited pages.
    var domain: String? = nil
    var symbol: String = "magnifyingglass"
    var colors: String = "#8fb8ff,#3a6fd8"
    var folders: FolderScope? = nil
    var bookmarks: BookmarkScope? = nil
    var history = false
    /// The `SpotlightKind` raw value to select in the launcher.
    var mode: String? = nil
    var settingsOnly = false
    var windows = false

    /// Narrows directory search to descendants of the selected folder.
    static func folder(_ path: String) -> SearchTag {
        directory(keyword: "folder:" + path.lowercased(), name: FileManager.default.displayName(atPath: path), roots: [path])
    }

    static func directory(keyword: String, name: String, roots: [String] = [], symbol: String = "folder.fill") -> SearchTag {
        SearchTag(keyword: keyword, name: name, symbol: symbol, colors: "#6cb8f5,#2f7fe0",
                  folders: FolderScope(folders: roots))
    }

    /// Narrows browser results to the selected page's site.
    static func site(_ host: String) -> SearchTag {
        let lower = host.lowercased()
        let domain = lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
        return SearchTag(keyword: "site:" + domain, name: domain, domain: domain, symbol: "globe")
    }

    func matches(url: String) -> Bool {
        guard let domain, let host = URLComponents(string: url)?.host?.lowercased() else { return false }
        return host == domain || host.hasSuffix("." + domain)
    }
}

enum SearchTags {
    private static let folderTags: [SearchTag] = {
        let home = NSHomeDirectory()
        return [
            .directory(keyword: "folders", name: "Folders"),
            .directory(keyword: "folder", name: "Folders"),
            .directory(keyword: "directory", name: "Folders"),
            .directory(keyword: "desktop", name: "Desktop", roots: [home + "/Desktop"]),
            .directory(keyword: "documents", name: "Documents", roots: [home + "/Documents"]),
            .directory(keyword: "downloads", name: "Downloads", roots: [home + "/Downloads"], symbol: "arrow.down.circle.fill"),
            .directory(keyword: "pictures", name: "Pictures", roots: [home + "/Pictures"]),
            .directory(keyword: "music", name: "Music", roots: [home + "/Music"]),
            .directory(keyword: "movies", name: "Movies", roots: [home + "/Movies"]),
            .directory(keyword: "videos", name: "Movies", roots: [home + "/Movies"]),
            .directory(keyword: "icloud", name: "iCloud Drive", roots: [home + "/Library/Mobile Documents/com~apple~CloudDocs"], symbol: "icloud.fill"),
            .directory(keyword: "home", name: "Home", roots: [home], symbol: "house.fill"),
        ]
    }()

    private static let builtIns: [SearchTag] = [
        SearchTag(keyword: "apps", name: "Applications", symbol: "square.grid.2x2.fill",
                  colors: "#a7aeb8,#5e6670", mode: "app"),
        SearchTag(keyword: "app", name: "Applications", symbol: "square.grid.2x2.fill",
                  colors: "#a7aeb8,#5e6670", mode: "app"),
        SearchTag(keyword: "process", name: "Processes", symbol: "cpu",
                  colors: "#a7aeb8,#5e6670", mode: "process"),
        SearchTag(keyword: "settings", name: "Settings", symbol: "gearshape.fill",
                  colors: "#9aa2ad,#5c636e", settingsOnly: true),
        SearchTag(keyword: "windows", name: "Open windows", symbol: "macwindow.on.rectangle",
                  colors: "#9aa8ff,#4a4fd6", windows: true),
        SearchTag(keyword: "window", name: "Open windows", symbol: "macwindow.on.rectangle",
                  colors: "#9aa8ff,#4a4fd6", windows: true),
        SearchTag(keyword: "browser", name: "Browser", symbol: "globe",
                  bookmarks: BookmarkScope(), history: true),
        SearchTag(keyword: "bookmark", name: "Bookmarks", symbol: "bookmark.fill",
                  colors: "#ffb36e,#f06a2e", bookmarks: BookmarkScope()),
        SearchTag(keyword: "bm", name: "Bookmarks", symbol: "bookmark.fill",
                  colors: "#ffb36e,#f06a2e", bookmarks: BookmarkScope()),
        SearchTag(keyword: "history", name: "History", symbol: "clock.arrow.circlepath",
                  colors: "#a7aeb8,#5e6670", history: true),
    ] + folderTags

    private static var cached: [SearchTag]?

    static var all: [SearchTag] {
        if let cached { return cached }

        // Browser bookmarks are warmed in the background when the launcher opens.
        var seen = Set(builtIns.map(\.keyword))
        var tags = builtIns
        for folder in BrowserBookmarks.folderNames(cachedOnly: true) {
            let keyword = compactName(folder)
            guard !keyword.isEmpty, seen.insert(keyword).inserted else { continue }
            tags.append(SearchTag(
                keyword: keyword, name: folder, symbol: "folder.fill",
                colors: "#ffb36e,#f06a2e", bookmarks: BookmarkScope(folder: folder)
            ))
        }
        let drives = ExternalDrives.mounted()
        for drive in drives {
            let keyword = compactName(drive.name)
            guard !keyword.isEmpty, seen.insert(keyword).inserted else { continue }
            tags.append(.directory(keyword: keyword, name: drive.name, roots: [drive.path], symbol: "externaldrive.fill"))
        }
        if !drives.isEmpty, seen.insert("drives").inserted {
            tags.append(.directory(keyword: "drives", name: "External Drives", roots: drives.map(\.path), symbol: "externaldrive.fill"))
        }

        applyFolderConfig(to: &tags)
        cached = tags
        return tags
    }

    static func reload() {
        cached = nil
    }

    static func tag(forKeyword text: String) -> SearchTag? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !key.contains(" ") else { return nil }
        if let tag = all.first(where: { $0.keyword == key }) { return tag }
        guard key.count >= 3 else { return nil }
        return all.first { compactName($0.name) == key }
    }

    private static func compactName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Keeps folder-root assignments such as `search_tag_work=Work|folder:~/Work`.
    private static func applyFolderConfig(to tags: inout [SearchTag]) {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        let values = ConfigFileLines.keyValues(raw)
        let prefix = "search_tag_"
        for key in values.keys.sorted() where key.hasPrefix(prefix) {
            let keyword = String(key.dropFirst(prefix.count)).lowercased()
            guard !keyword.isEmpty, !keyword.contains(where: \.isWhitespace), let value = values[key] else { continue }
            if value.isEmpty {
                tags.removeAll { $0.keyword == keyword }
                continue
            }
            let fields = value.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let folderPrefix = "folder:"
            guard fields.count == 2, !fields[0].isEmpty, fields[1].lowercased().hasPrefix(folderPrefix) else { continue }
            let roots = fields[1].dropFirst(folderPrefix.count).split(separator: ",").map { root in
                (root.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
            }.filter { $0.hasPrefix("/") }
            guard !roots.isEmpty else { continue }
            tags.removeAll { $0.keyword == keyword }
            tags.append(.directory(keyword: keyword, name: fields[0], roots: roots))
        }
    }

    /// Separates a local tag and the text before or after it.
    static func split(_ text: String) -> (tag: SearchTag, rest: String)? {
        let words = text.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if let tag = tag(forKeyword: first) {
            return (tag, words.dropFirst().joined(separator: " "))
        }
        if words.count > 1, let last = words.last, let tag = tag(forKeyword: last) {
            return (tag, words.dropLast().joined(separator: " "))
        }
        return nil
    }

    /// Local tag hints shown as the user types.
    static func suggestions(for text: String, limit: Int = 2) -> [SearchTag] {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, limit > 0 else { return [] }
        if key.contains(" ") { return split(key).map { [$0.tag] } ?? [] }

        let exact = tag(forKeyword: key)
        var tags = exact.map { [$0] } ?? []
        guard key.count >= 2 else { return tags }
        for tag in all where tag.keyword != exact?.keyword && tags.count < limit {
            if tag.name.lowercased().hasPrefix(key) || compactName(tag.name).hasPrefix(key) {
                tags.append(tag)
            }
        }
        return tags
    }
}

nonisolated struct FolderScope: Equatable, Sendable {
    var folders: [String] = []
}

nonisolated struct BookmarkScope: Equatable, Sendable {
    var folder: String? = nil
}
