//
//  SpotlightModes.swift
//  lumio-app
//
import Foundation

enum SpotlightMode: Equatable {
    case search
    case commandMenu(filter: String)
    case process(term: String)

    /// Opens the command menu for text beginning with `:`.
    static func parse(_ query: String) -> SpotlightMode {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(":") { return .commandMenu(filter: String(trimmed.dropFirst())) }
        return .search
    }

    /// The mode a tool tab runs with the typed text. nil = not a tool tab with its own rows.
    static func forTab(_ tab: SpotlightKind, query: String) -> SpotlightMode? {
        guard tab == .process else { return nil }
        return .process(term: query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `lumio <mode>` still sends a prefixed query (from core): turn it into a tab + text.
    static func tab(fromLaunchQuery text: String) -> (tab: SpotlightKind?, text: String) {
        typealias P = AppConstants.Launcher.QueryPrefix
        let table: [(String, SpotlightKind)] = [
            (P.process, .process),
            (P.apps, .app), (P.folders, .folder),
        ]
        let lower = text.lowercased()
        for (prefix, tab) in table where lower.hasPrefix(prefix) {
            return (tab, String(text.dropFirst(prefix.count)))
        }
        return (nil, text)
    }

    /// Key hint in the panel footer for this mode.
    var footerHint: String {
        switch self {
        case .search: "⏎ open   ⇥ details or scope   ⌘K actions"
        case .commandMenu: "⏎ enter command"
        case .process: "⏎ measure CPU   ⌘K actions"
        }
    }
}

/// Commands (`:cd`, `:active`, `:emptytrash`, `:help`).
enum SpotlightCommands {
    static let changeDirectory = AppConstants.Launcher.Command.changeDirectory
    static let activeWindows = AppConstants.Launcher.Command.activeWindows
    static let emptyTrash = AppConstants.Launcher.Command.emptyTrash
    static let help = AppConstants.Launcher.Command.help

    static var catalog: [AppCommand] { AppConstants.Launcher.commandCatalog }

    static func placeholder(for id: String) -> String {
        catalog.first { $0.id == id }?.placeholder ?? id
    }

    /// A command followed by whitespace opens with the rest as its argument.
    static func inlineTrigger(_ filter: String) -> (id: String, args: String)? {
        guard let space = filter.firstIndex(where: \.isWhitespace) else { return nil }
        let id = filter[..<space].lowercased()
        guard catalog.contains(where: { $0.id == id }) else { return nil }
        return (id, String(filter[filter.index(after: space)...]))
    }
}

/// Builds the rows for each mode.
enum SpotlightModeRows {
    static func commandMenu(_ filter: String) -> [SpotlightItem] {
        AppConstants.Launcher.commandCatalog(matching: filter).map { command in
            SpotlightItem(
                id: "command|\(command.id)", name: ":\(command.id)", kind: .command,
                colors: "#8fb8ff,#3a6fd8", meta: "\(command.detail)  \(command.shortcut)",
                symbol: command.symbolName, payload: command.id
            )
        }
    }

    static func processes(_ model: ProcessFinderModel, term: String) -> [SpotlightItem] {
        let lowered = term.lowercased()
        let ranked = model.ranked(term: term) { title in
            EngineBridge.shared.fuzzyScore(query: lowered, title: title)
        }
        return ranked.prefix(AppConstants.Launcher.Process.resultLimit).map { candidate in
            var meta = "PID \(candidate.pid)"
            if !candidate.ports.isEmpty {
                meta += " · " + candidate.ports.map { ":\($0)" }.joined(separator: " ")
            }
            return SpotlightItem(
                id: "process|\(candidate.pid)",
                name: candidate.name.isEmpty ? "Process \(candidate.pid)" : candidate.name,
                kind: .process, meta: meta, pid: candidate.pid
            )
        }
    }

    /// `:emptytrash` — one row; the first Enter asks, the second empties.
    static func emptyTrash(itemCount: Int?) -> [SpotlightItem] {
        let detail = itemCount.map(DeleteTargetLogic.emptyTrashDetail(itemCount:)) ?? "Deleted permanently"
        return [SpotlightItem(
            id: "command|emptytrash", name: "Empty Trash", kind: .command,
            colors: "#ff8a80,#d6453a", meta: detail, symbol: "trash.slash",
            payload: SpotlightCommands.emptyTrash
        )]
    }

    /// `:help` — prefixes, commands and keyboard shortcuts of this launcher.
    static func help(_ filter: String) -> [SpotlightItem] {
        let processTab = ("Processes tab", "Find and force quit running processes")
        let commands = AppConstants.Launcher.commandCatalog.map { command in
            let label = command.id == SpotlightCommands.changeDirectory ? "\(command.id) <folder>" : command.id
            return (":" + label, command.detail)
        }
        let entries = [processTab] + commands + helpShortcuts + [("⌘F", "Show in \(FileManagerApp.name)")]
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries
            .filter { needle.isEmpty || $0.0.lowercased().contains(needle) || $0.1.lowercased().contains(needle) }
            .map { key, detail in
                SpotlightItem(
                    id: "help|\(key)", name: key, kind: .help,
                    colors: "#a7aeb8,#5e6670", meta: detail, symbol: "keyboard"
                )
            }
    }

    private static let helpShortcuts: [(String, String)] = [
        ("⌘K", "Actions for the selected row"),
        ("⇥", "Open app or folder details, or use a search tag"),
        ("⇧⇥", "Go back from details or select the previous filter"),
        ("⌘1 … ⌘\(QuickBubbles.slotCount)", "Open a launcher quick button"),
        ("⌘T", "Open the selected folder in Terminal"),
        ("⌘H", "This help"),
        ("⌘⇧H", "Hide the selected app from results"),
        ("⌘/", "Open the last command"),
        ("⌘⇧Space", "Settings"),
        ("Esc", "Go back from details or close"),
    ]
}
