//
//  SpotlightBackend.swift
//  lumio-app
//
//  Connects the Spotlight launcher to the Rust core (EngineBridge → bridge/ffi → QueryEngine).
//
//  Flow of a single search:
//  1. `engineQuery(for:)` builds the query string for the core. The Applications and Folders
//     buttons use its a" and d" prefixes. System settings have a `setting:` id.
//  2. The view calls `EngineBridge.search` on a background thread (the core holds the engine read lock).
//  3. `rows(from:for:)` turns the core's results into display rows, then adds the
//     synthesized rows for browser data, URLs, open windows and system commands.
//

import AppKit

struct SpotlightRequest: Equatable {
    var text: String
    /// Browsing a single group (round button or ⌘ plus a number).
    var browse: SpotlightKind?

    var term: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isEmpty: Bool { term.isEmpty && browse == nil }
    var isUnscoped: Bool { browse == nil && !LauncherSearchLogic.hasEngineScope(term) }
    var prioritizesApplications: Bool {
        isUnscoped && LauncherSearchLogic.prioritizesApplications(for: term)
    }
}

/// Query string + count sent to the core. Sendable so it can move to a background thread.
struct SpotlightEngineQuery: Sendable {
    let text: String
    let limit: Int
}

enum SpotlightBackend {
    /// Maximum number of rows shown (same as the legacy launcher).
    nonisolated static let resultLimit = 40
    /// When typing rapidly, wait a short beat; the first keystroke searches immediately.
    static let debounce: Duration = .milliseconds(45)

    private static let settingIDPrefix = "setting:"
    private static let systemSettingsAppPath = "/System/Applications/System Settings.app"

    // MARK: - Query sent to the core

    static func engineQuery(for request: SpotlightRequest) -> SpotlightEngineQuery {
        let term = request.term
        switch request.browse {
        case .app:
            return SpotlightEngineQuery(text: "a\"" + term, limit: resultLimit + 20)
        case .folder:
            return SpotlightEngineQuery(text: "d\"" + term, limit: resultLimit)
        default:
            return SpotlightEngineQuery(text: term, limit: resultLimit)
        }
    }

    // MARK: - Core results → display rows

    static func rows(
        from results: [LauncherResult],
        for request: SpotlightRequest,
        tabs: [BrowserTab] = [],
        windows: [OpenWindow] = []
    ) -> [SpotlightItem] {
        // `> npm run dev`: one row, ⏎ runs it in Terminal. Nothing else is searched.
        if request.browse == nil, request.term.hasPrefix(">") {
            return [runRow(String(request.term.dropFirst()))]
        }
        var candidates = results.compactMap(item(from:))
        for pin in quickRows(for: request).reversed() {
            // Keep the indexed Finder's current display name and metadata when available.
            if pin.kind == .app, let index = candidates.firstIndex(where: { sameApplication($0, pin) }) {
                let app = candidates.remove(at: index)
                candidates.insert(app, at: 0)
                continue
            }
            let app = candidates.firstIndex { $0.kind == .app && $0.name.lowercased() == pin.name.lowercased() }
            candidates.insert(pin, at: app.map { $0 + 1 } ?? 0)
        }
        // What you opened before for text like this goes first (see UsageLearning).
        if request.isUnscoped, !LauncherSearchLogic.isSettingsLandingQuery(request.term) {
            let learned = UsageLearning.shared.picks(for: request.term, limit: 2).map { item in
                candidates.first { sameApplication($0, item) } ?? item
            }
            candidates.insert(contentsOf: learned, at: 0)
        }
        let prioritizeApps = request.prioritizesApplications
        if prioritizeApps {
            candidates = LauncherSearchLogic.applicationsFirst(candidates) { $0.kind == .app }
        }
        var seen = Set<String>()
        var rows: [SpotlightItem] = []
        for item in candidates {
            if let browse = request.browse, item.kind != browse { continue }
            guard seen.insert(dedupeKey(item)).inserted else { continue }
            rows.append(item)
            if rows.count == resultLimit { break }
        }

        // Synthesized rows appear in general searches.
        let term = request.term
        guard request.isUnscoped, !term.isEmpty else { return rows }

        let appEnd = prioritizeApps ? rows.prefix { $0.kind == .app }.count : 0
        func insertionIndex(_ standard: Int, count: Int) -> Int {
            min(max(standard, appEnd), count)
        }

        var leading: [SpotlightItem] = []
        // Cached bookmarks appear after the first applications.
        if term.count >= 3 {
            let marks = bookmarkRows(BrowserBookmarks.search(term, limit: 2, cachedOnly: true))
            rows.insert(contentsOf: marks, at: insertionIndex(4, count: rows.count))
        }
        if LauncherSearchLogic.isLumioSettingsQuery(term) {
            leading.append(SpotlightItem(
                id: lumioSettingsID, name: "Lumio Settings", kind: .setting,
                colors: "#9aa2ad,#5c636e", meta: "Open Lumio's settings  ·  ⌘⇧Space",
                iconPath: Bundle.main.bundlePath, symbol: "gearshape.fill"
            ))
        }
        if let match = EngineBridge.shared.classifyURL(query: term) {
            let row = SpotlightItem(
                id: "url|\(match.url)", name: match.url, kind: .url,
                colors: "#8fb8ff,#3a6fd8", meta: "Open link",
                target: match.url, symbol: "link", favicon: FaviconStore.host(of: match.url)
            )
            // Explicit URLs (with scheme/path) go first; bare domains come
            // after the best result, like the legacy launcher (URLRowPlacement).
            if match.tier == .structural {
                leading.append(row)
            } else {
                rows.insert(row, at: insertionIndex(1, count: rows.count))
            }
        }
        // Open browser tabs matching the text: ⏎ switches to the tab instead of opening a new one.
        let openTabs = tabs.map(item(from:))
        let openURLs = Set(tabs.map(\.url))
        rows.removeAll { $0.kind == .url && openURLs.contains($0.target ?? "") }
        rows.insert(contentsOf: openTabs, at: insertionIndex(1, count: rows.count))
        // Open windows of other apps matching the text: ⏎ switches to the window.
        rows.insert(contentsOf: windows.map(item(from:)), at: insertionIndex(1, count: rows.count))
        // "lock", "sleep", "restart"…: system commands. An exact name leads the list.
        for command in SystemCommands.matching(term).reversed() {
            let row = systemRow(command)
            if SystemCommands.isExact(term, command) {
                leading.append(row)
            } else {
                rows.insert(row, at: insertionIndex(1, count: rows.count))
            }
        }
        // Local search tag hints sit after the best result.
        let rest = SearchTags.split(term)?.rest ?? ""
        let hints = SearchTags.suggestions(for: term).map { hintItem(for: $0, rest: rest) }
        rows.insert(contentsOf: hints, at: insertionIndex(1, count: rows.count))
        return leading + rows
    }

    static func runRow(_ text: String) -> SpotlightItem {
        let command = text.trimmingCharacters(in: .whitespaces)
        return SpotlightItem(
            id: SystemCommands.runPrefix + command, name: command.isEmpty ? "Run a command in Terminal" : command,
            kind: .command, colors: "#a7aeb8,#30363d",
            meta: command.isEmpty ? "Type the command after >" : "⏎ run in Terminal",
            symbol: "terminal.fill", payload: command
        )
    }

    static func systemRow(_ command: SystemCommand) -> SpotlightItem {
        SpotlightItem(
            id: SystemCommands.idPrefix + command.id, name: command.name, kind: .command,
            colors: command.colors, meta: command.detail, symbol: command.symbol, payload: command.id
        )
    }

    static func item(from window: OpenWindow) -> SpotlightItem {
        SpotlightItem(
            id: window.id, name: window.title, kind: .window, colors: "#9aa8ff,#4a4fd6",
            meta: "\(window.appName) · \(window.minimized ? "minimized window" : "open window")",
            iconPath: window.appPath, symbol: "macwindow"
        )
    }

    /// Every tag, for the tag browser (⌥T): name, what to type, what it searches.
    static func tagBrowserRows(_ filter: String) -> [SpotlightItem] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        var seen = Set<String>()
        return SearchTags.all
            .filter { seen.insert($0.name).inserted }
            .filter { needle.isEmpty || $0.keyword.contains(needle) || $0.name.lowercased().contains(needle) }
            .map { tag in
                let what = if tag.folders != nil { "Folders" }
                    else if tag.settingsOnly { "System Settings" }
                    else if tag.windows { "Windows" }
                    else if tag.mode != nil { "Lumio tab" }
                    else { "Browser" }
                return SpotlightItem(
                    id: "taghint|\(tag.keyword)", name: tag.name, kind: .tagHint, colors: tag.colors,
                    meta: "\(tag.keyword) ⇥  ·  \(what)", symbol: tag.symbol, payload: tag.keyword
                )
            }
    }

    /// One core row → display row. nil for launcher kinds not handled yet
    /// (user-declared command blocks).
    static func item(from result: LauncherResult) -> SpotlightItem? {
        let path = result.path
        switch result.kind {
        case .app where result.id.hasPrefix(settingIDPrefix):
            return SpotlightItem(
                id: result.id, name: result.title, kind: .setting,
                meta: "System Settings", target: path,
                iconPath: systemSettingsAppPath, candidateID: result.id
            )
        case .app:
            // Use a symlink's real app icon without Finder's alias arrow.
            let appURL = URL(fileURLWithPath: path)
            guard !BrowserOpening.isBlockedApplication(appURL) else { return nil }
            let iconPath = appURL.resolvingSymlinksInPath().path
            return SpotlightItem(
                id: result.id, name: displayName(forApp: result.title), kind: .app,
                target: path, iconPath: iconPath, candidateID: result.id
            )
        case .folder:
            guard path.hasPrefix("/"), isBrowsableFolder(at: URL(fileURLWithPath: path)) else { return nil }
            return folderRow(path: path, name: result.title, id: result.id, candidateID: result.id)
        case .action, .process:
            return nil
        }
    }

    static let lumioSettingsID = "lumio|settings"

    // MARK: - Browser data and local search tags

    nonisolated static let tabLimit = 4

    static func item(from tab: BrowserTab) -> SpotlightItem {
        SpotlightItem(
            id: tab.id, name: tab.title, kind: .tab,
            colors: "#8fb8ff,#3a6fd8", meta: "\(tab.host) · Open in \(tab.browser.displayName)",
            target: tab.url, iconPath: tab.appPath, symbol: "square.on.square",
            favicon: FaviconStore.host(of: tab.url), tab: tab
        )
    }

    /// "Press Tab" row. `rest` is the text to search inside the local scope.
    static func hintItem(for tag: SearchTag, rest: String = "") -> SpotlightItem {
        SpotlightItem(
            id: "taghint|\(tag.keyword)",
            name: rest.isEmpty ? tag.name : "\(tag.name): “\(rest)”",
            kind: .tagHint, colors: tag.colors,
            meta: rest.isEmpty ? "Press Tab to search \(tag.name)  ·  \(tag.keyword) ⇥"
                : "Press Tab to search \(tag.name) for “\(rest)”",
            symbol: tag.symbol, payload: tag.keyword
        )
    }

    static func bookmarkRows(_ bookmarks: [Bookmark]) -> [SpotlightItem] {
        bookmarks.map { bookmark in
            SpotlightItem(
                id: "bookmark|" + bookmark.url, name: bookmark.title, kind: .url,
                colors: "#ffb36e,#f06a2e", meta: "Bookmark · \(bookmark.folderLine)",
                target: bookmark.url, iconPath: bookmark.appPath, symbol: "bookmark.fill",
                favicon: FaviconStore.host(of: bookmark.url)
            )
        }
    }

    static func historyRows(_ pages: [HistoryPage], colors: String = "#a7aeb8,#5e6670",
                            symbol: String = "clock.arrow.circlepath") -> [SpotlightItem] {
        pages.map { page in
            // The address under the title, like Fluent Search and the browser's own list.
            var address = page.url
            for prefix in ["https://", "http://", "www."] where address.hasPrefix(prefix) {
                address = String(address.dropFirst(prefix.count))
            }
            return SpotlightItem(
                id: "history|" + page.url, name: page.title, kind: .url,
                colors: colors, meta: "\(address)",
                target: page.url, iconPath: page.appPath, symbol: symbol,
                favicon: FaviconStore.host(of: page.url)
            )
        }
    }

    /// What the second pass of a normal search gathers off the main thread.
    nonisolated struct Extras: Sendable {
        var folders: [FolderHit] = []
        var bookmarks: [Bookmark] = []
        var history: [HistoryPage] = []
        var blocked = false
    }

    /// Merges folders and local browser data into the core results.
    static func addingExtras(_ extras: Extras, for request: SpotlightRequest, to rows: [SpotlightItem]) -> [SpotlightItem] {
        var out = addingFolders(extras.folders, term: request.term, to: rows)
        let listed = Set(out.compactMap { $0.target?.lowercased() })
        var seenURLs = Set<String>()
        var browserRows = (bookmarkRows(extras.bookmarks) + historyRows(extras.history))
            .filter { !listed.contains(($0.target ?? "").lowercased()) }
            .filter { seenURLs.insert($0.target ?? $0.id).inserted }
        // Blocked by macOS: say so where the browser rows would have been.
        if extras.blocked, browserRows.isEmpty { browserRows = [blockedRow] }
        // One bookmark and one history page up top when both exist.
        if browserRows.count > 2, let firstHistory = browserRows.firstIndex(where: { $0.id.hasPrefix("history|") }),
           firstHistory > 1
        {
            browserRows.insert(browserRows.remove(at: firstHistory), at: 1)
        }
        let leading = out.prefix(8).lastIndex { [.tab, .tagHint, .url].contains($0.kind) }.map { $0 + 1 } ?? 0
        let appEnd = request.prioritizesApplications
            ? out.lastIndex { $0.kind == .app }.map { $0 + 1 } ?? 0 : 0
        let first = min(max(leading, 4, appEnd), out.count)
        out.insert(contentsOf: browserRows.prefix(2), at: first)
        let later = min(first + min(browserRows.count, 2) + 6, out.count)
        out.insert(contentsOf: browserRows.dropFirst(2), at: later)
        return out
    }

    /// macOS is refusing Lumio access to the browsers' files: say so (⏎ opens the setting)
    /// instead of silently showing no history or bookmarks.
    static var blockedRow: SpotlightItem {
        SpotlightItem(
            id: "browser|blocked", name: "Browser history & bookmarks are blocked by macOS", kind: .setting,
            colors: "#ffb36e,#f06a2e",
            meta: "⏎ open Privacy settings, then turn on Full Disk Access for Lumio",
            target: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            symbol: "lock.fill"
        )
    }

    /// Open tabs and local history for the selected site.
    static func tagRows(tag: SearchTag, tabs: [BrowserTab], history: [HistoryPage]) -> [SpotlightItem] {
        let tabRows = tabs.map(item(from:))
        let openURLs = Set(tabs.map(\.url))
        let historyRows = history.filter { !openURLs.contains($0.url) }.map { page in
            SpotlightItem(
                id: "history|\(page.url)", name: page.title, kind: .url,
                colors: tag.colors, meta: "Visited \(relative(page.lastVisit))",
                target: page.url, iconPath: page.appPath, symbol: tag.symbol,
                favicon: FaviconStore.host(of: page.url)
            )
        }
        return tabRows + historyRows
    }

    /// Open tabs of a tag's site, narrowed by the typed words.
    nonisolated static func tabs(for tag: SearchTag, matching term: String) -> [BrowserTab] {
        let siteTabs = BrowserTabs.shared.snapshot.filter { tag.matches(url: $0.url) }
        let words = term.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return siteTabs }
        return siteTabs.filter { tab in
            let haystack = (tab.title + " " + tab.url).lowercased()
            return words.allSatisfy(haystack.contains)
        }
    }

    /// Completes a local address or lists the live children of a slash-terminated path.
    static func pathFolders(
        for term: String, excluding: [String], within roots: [String] = [], selectedFolder: String? = nil
    ) async -> [SpotlightItem] {
        let literalAddress = FolderAddressQuery.isLiteralAddress(term)
        let browsing = !literalAddress || FolderAddressQuery.requestsChildren(in: term)
        let parentQuery = AppConstants.Launcher.QueryPrefix.folders + String(term.dropLast())
        let selected = selectedFolder.flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : nil
        }
        let hits = await SpotlightQueue.run(skipped: [FolderHit]()) { isCancelled in
            let including: (URL) -> Bool = { folder in
                (roots.isEmpty || FileSearchPaths.isExcluded(folder.path, by: roots))
                    && Self.isBrowsableFolder(at: folder, excluding: excluding)
            }
            let folders: [URL]
            if literalAddress {
                folders = FolderAddressQuery.matchingFolders(
                    in: term, selectedFolder: selected, including: including, isCancelled: isCancelled
                )
            } else {
                guard !isCancelled() else { return [] }
                let parent: String
                if let selected, including(selected) {
                    parent = selected.path
                } else {
                    guard let match = EngineBridge.shared.search(query: parentQuery, limit: Self.resultLimit).first(where: { row in
                        row.kind == .folder && row.path.hasPrefix("/") && including(URL(fileURLWithPath: row.path))
                    }) else { return [] }
                    parent = match.path
                }
                let address = parent.hasSuffix("/") ? parent : parent + "/"
                folders = FolderAddressQuery.immediateSubfolders(in: address, including: including, isCancelled: isCancelled)
            }

            guard !isCancelled() else { return [] }
            var rows = folders.map { folder in
                FolderHit(path: folder.path, name: FileManager.default.displayName(atPath: folder.path), date: nil)
            }
            if browsing {
                rows.sort { first, second in
                    let order = first.name.localizedStandardCompare(second.name)
                    return order == .orderedSame ? first.path < second.path : order == .orderedAscending
                }
            }
            return Array(rows.prefix(Self.resultLimit))
        }
        return hits.map { folderRow(path: $0.path, name: $0.name) }
    }

    nonisolated static func isBrowsableFolder(at typed: URL, excluding: [String] = []) -> Bool {
        guard typed.isFileURL, typed.path.hasPrefix("/") else { return false }
        let normalized = typed.standardizedFileURL
        let resolved = normalized.resolvingSymlinksInPath()
        guard ![normalized, resolved].contains(where: { url in
            url.pathComponents.contains { $0.lowercased().hasSuffix(".app") }
                || FileSearchPaths.isExcluded(url.path, by: excluding)
        }) else { return false }

        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && (try? resolved.resourceValues(forKeys: [.isPackageKey]).isPackage) != true
    }

    static func folderRows(_ hits: [FolderHit]) -> [SpotlightItem] {
        hits.compactMap { hit in
            guard isBrowsableFolder(at: URL(fileURLWithPath: hit.path)) else { return nil }
            return folderRow(path: hit.path, name: hit.name, date: hit.date)
        }
    }

    private static func folderRow(
        path: String, name: String, date: Date? = nil, id: String? = nil, candidateID: String? = nil
    ) -> SpotlightItem {
        let directory = PathDisplay.directory(of: path)
        let meta = date.map { relative($0) + " · " + directory } ?? directory
        return SpotlightItem(
            id: id ?? "folder|" + path, name: name, kind: .folder,
            meta: meta, target: path, iconPath: path, candidateID: candidateID
        )
    }

    private static func addingFolders(_ hits: [FolderHit], term: String, to rows: [SpotlightItem]) -> [SpotlightItem] {
        guard !hits.isEmpty else { return rows }
        let listed = Set(rows.compactMap { $0.target?.lowercased() })
        let fresh = folderRows(hits.filter { !listed.contains($0.path.lowercased()) })
        let words = term.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let needle = words.joined(separator: " ")
        guard !needle.isEmpty else { return rows + fresh }

        // Keep the first result stable and merge the remaining directory matches in their slots.
        let slots = rows.indices.dropFirst().filter { rows[$0].kind == .folder }
        let dates = Dictionary(hits.compactMap { hit in hit.date.map { (hit.path, $0) } }, uniquingKeysWith: max)
        let ranked = (slots.map { rows[$0] } + fresh).enumerated()
            .map { index, row in
                let score = SpotlightFolders.nameScore(row.name.lowercased(), needle: needle, words: words)
                let weight = UsageLearning.shared.weight(forTarget: row.target)
                let date = row.target.flatMap { dates[$0] } ?? .distantPast
                return (row: row, score: score, weight: weight, date: date, index: index)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                if lhs.date != rhs.date { return lhs.date > rhs.date }
                return lhs.index < rhs.index
            }
            .map(\.row)
        var merged = rows
        for (slot, row) in zip(slots, ranked) { merged[slot] = row }
        merged.append(contentsOf: ranked.dropFirst(slots.count))
        return merged
    }

    /// The empty field shows recently used applications.
    static func suggestionRows(apps: [RecentItem]) -> [SpotlightItem] {
        apps.compactMap { app in
            let appURL = URL(fileURLWithPath: app.path)
            guard !BrowserOpening.isBlockedApplication(appURL) else { return nil }
            return SpotlightItem(
                id: "recent|" + app.path, name: app.name, kind: .app,
                target: app.path, iconPath: appURL.resolvingSymlinksInPath().path
            )
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func quickRows(for request: SpotlightRequest) -> [SpotlightItem] {
        typealias QuickFolder = AppConstants.Launcher.QuickFolder
        typealias Finder = AppConstants.Launcher.Finder
        var scope = LauncherSearchLogic.pinnedLookupScope(for: request.term)
        switch request.browse {
        case nil: break
        case .app: scope = scope == .unscoped ? .apps : .disabled
        case .folder: scope = scope == .unscoped ? .folders : .disabled
        default: scope = .disabled
        }
        guard let needle = LauncherSearchLogic.normalizedPinnedLookupQuery(for: request.term, scope: scope)
        else { return [] }

        var rows: [SpotlightItem] = []
        if scope == .unscoped || scope == .folders {
            for entry in QuickFolder.entries {
                let title = entry.title.lowercased()
                guard title.contains(needle) else { continue }
                let path = entry.resolvedPath(homeDirectory: NSHomeDirectory())
                guard isBrowsableFolder(at: URL(fileURLWithPath: path)) else { continue }
                rows.append(SpotlightItem(
                    id: QuickFolder.idPrefix + title, name: entry.title, kind: .folder,
                    meta: entry.subtitle ?? QuickFolder.pinnedSubtitle, target: path, iconPath: path
                ))
            }
        }
        if LauncherSearchLogic.shouldInjectFinder(normalizedQuery: needle, scope: scope) {
            rows.insert(SpotlightItem(
                id: Finder.pinnedResultID, name: "Finder", kind: .app,
                target: Finder.appPath, iconPath: Finder.appPath
            ), at: 0)
        }
        return rows
    }

    private static func sameApplication(_ lhs: SpotlightItem, _ rhs: SpotlightItem) -> Bool {
        guard lhs.kind == .app, rhs.kind == .app else { return false }
        if let id = lhs.candidateID, id == rhs.candidateID { return true }
        if let target = lhs.target, target == rhs.target { return true }
        return lhs.iconPath != nil && lhs.iconPath == rhs.iconPath
    }

    private static func dedupeKey(_ item: SpotlightItem) -> String {
        switch item.kind {
        case .app: "app:" + item.name.lowercased()
        case .folder: "folder:" + (item.target ?? item.id).lowercased()
        default: item.id
        }
    }

    /// Drops the bundle extension from an app's display name.
    private static func displayName(forApp title: String) -> String {
        title.hasSuffix(".app") ? String(title.dropLast(4)) : title
    }

    // MARK: - Actions (⌘K)

    static func actionRows(for item: SpotlightItem, filter: String) -> [SpotlightItem] {
        var actions: [SpotlightAction] = item.kind == .process
            ? [.measureCPU, .killProcess]
            : [.open, .reveal]
        if item.kind == .app, let path = item.target {
            if SpotlightOpener.runningApp(at: path) != nil { actions += [.hideApp, .quitApp] }
            actions.append(.excludeApp)
        }
        let needle = fold(filter.trimmingCharacters(in: .whitespacesAndNewlines))
        return actions
            .filter { needle.isEmpty || fold($0.label).contains(needle) }
            .map { action in
                SpotlightItem(
                    id: "action|\(item.id)|\(action.rawValue)", name: action.label, kind: .cmd,
                    colors: "#a7aeb8,#5e6670", meta: item.name,
                    symbol: action.symbol, action: action
                )
            }
    }

    /// Folds case + diacritics (and đ → d) so "cafe" matches "Café".
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "đ", with: "d")
    }
}
