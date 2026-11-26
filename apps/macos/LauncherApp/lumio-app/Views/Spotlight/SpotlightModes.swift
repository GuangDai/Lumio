//
//  SpotlightModes.swift
//  lumio-app
//
import Foundation

enum SpotlightMode: Equatable {
    case search
    case commandMenu(filter: String)
    case process(term: String)

    /// Typed text outside a tool tab: only `:` (commands) is special.
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
        case .search: "⏎ open   ⇥ filter   ⌘K actions"
        case .commandMenu: "⏎ enter command"
        case .process: "⏎ measure CPU   ⌘K actions"
        }
    }
}

/// Commands (`:kill`, `:emptytrash`, `:help`).
enum SpotlightCommands {
    static let kill = AppConstants.Launcher.Command.kill
    static let emptyTrash = AppConstants.Launcher.Command.emptyTrash
    static let help = AppConstants.Launcher.Command.help

    static var catalog: [AppCommand] { AppConstants.Launcher.commandCatalog }

    static func placeholder(for id: String) -> String {
        switch id {
        case kill: "Name, PID or port"
        case emptyTrash: "⏎ empty the Trash"
        case help: "Filter help"
        default: id
        }
    }

    static func detail(for command: AppCommand) -> String {
        switch command.id {
        case kill: "Force quit an app / process by name, PID or port"
        default: command.detail
        }
    }

    /// `:kill chrome` (with a space) goes straight into the command with the rest as its argument.
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
        AppConstants.Launcher.commandCatalog(matching: filter).enumerated().map { index, command in
            SpotlightItem(
                id: "command|\(command.id)", name: ":\(command.id)", kind: .command,
                colors: "#8fb8ff,#3a6fd8", meta: "\(SpotlightCommands.detail(for: command))  ⌘\(index + 1)",
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

    /// `:kill` — running apps first, then processes; same ranking as the legacy launcher.
    static func killTargets(_ model: ProcessFinderModel, term: String) -> [SpotlightItem] {
        KillCommand.suggestions(searchTerm: term, processes: model.candidates).map { candidate in
            SpotlightItem(
                id: "kill|\(candidate.pid)", name: candidate.displayName, kind: .process,
                meta: "PID \(candidate.pid)", pid: candidate.pid
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
        let commands = AppConstants.Launcher.commandCatalog.map { (":" + $0.id, SpotlightCommands.detail(for: $0)) }
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
        ("⇥ / ⇧⇥", "Next / previous filter"),
        ("⌘1 … ⌘\(QuickBubbles.slotCount)", "Open a launcher quick button"),
        ("⌘D", "Move to Trash · Empty Trash on the Trash pin"),
        ("⌘H", "This help"),
        ("⌘⇧H", "Hide the selected app from results"),
        ("⌘/", "Open the last command"),
        ("⌘⇧,", "Settings"),
        ("Esc", "Close"),
    ]
}
