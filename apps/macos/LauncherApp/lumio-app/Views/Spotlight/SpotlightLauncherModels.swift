import Foundation

// Data types for the Spotlight launcher. Real results come from the Rust core via
// SpotlightBackend; SpotlightData is now just sample data for the motion lab.

enum SpotlightKind: String, CaseIterable, Identifiable {
    case app, folder, doc, setting, url, web, cmd
    /// An open browser tab (⏎ switches to it) and the "press Tab to search YouTube" hint row.
    case tab, tagHint
    /// An open window of any app (⏎ switches to it).
    case window
    // Modes carried over from the legacy launcher (prefix / command).
    case prefix, command, process, help
    var id: String { rawValue }

    var label: String {
        switch self {
        case .app: "Applications"
        case .folder: "Folders"
        case .doc: "Documents"
        case .setting: "Settings"
        case .url: "Links"
        case .web: "Web"
        case .cmd: "Actions"
        case .tab: "Tabs"
        case .tagHint: "Search Tags"
        case .window: "Windows"
        case .prefix: "Prefixes"
        case .command: "Commands"
        case .process: "Processes"
        case .help: "Help"
        }
    }

    /// Filter pill a row belongs to. System Settings rows have no pill of their own:
    /// they sit under Applications.
    var pillGroup: SpotlightKind {
        switch self {
        case .setting: .app
        case .tagHint: .web
        default: self
        }
    }

    /// SF Symbol of the idle bar's round button for this feature.
    var quickIcon: String {
        switch self {
        case .app: "square.grid.2x2"
        case .folder: "folder"
        case .doc: "doc.text"
        case .process: "cpu"
        default: "circle"
        }
    }

    var isDocument: Bool { self == .doc }
}

/// What can be done with an item when you open its actions (⌘K).
enum SpotlightAction: String {
    case open, reveal, openInEditor, openInTerminal, moveToTrash, emptyTrash
    case hideApp, quitApp, excludeApp
    // Process rows (ps").
    case measureCPU, killProcess

    var label: String {
        switch self {
        case .open: "Open"
        case .reveal: "Show in \(FileManagerApp.name)"
        case .openInEditor: "Open in Editor  ⌘E"
        case .openInTerminal: "Open in Terminal  ⌘T"
        case .moveToTrash: "Move to Trash  ⌘D"
        case .emptyTrash: "Empty Trash  ⌘D"
        case .hideApp: "Hide App"
        case .quitApp: "Quit App"
        case .excludeApp: "Hide from Results  ⌘⇧H"
        case .measureCPU: "Measure CPU"
        case .killProcess: "Force Quit"
        }
    }

    var symbol: String {
        switch self {
        case .open: "arrow.up.forward.app"
        case .reveal: "folder"
        case .openInEditor: "pencil"
        case .openInTerminal: "terminal"
        case .moveToTrash: "trash"
        case .emptyTrash: "trash.slash"
        case .hideApp: "eye.slash"
        case .quitApp: "xmark.circle"
        case .excludeApp: "nosign"
        case .measureCPU: "gauge.with.dots.needle.50percent"
        case .killProcess: "xmark.octagon"
        }
    }
}

struct SpotlightItem: Identifiable, Equatable {
    let id: String
    let name: String
    let kind: SpotlightKind
    /// "c1,c2" — gradient background of the icon tile when there is no real icon.
    var colors: String = "#9aa2ad,#5c636e"
    var glyph: String? = nil
    var meta: String? = nil
    var rank: Int = 0
    var score: Double = 0
    /// Target to open: an app/file/folder path, or a URL
    /// (`x-apple.systempreferences:…`, `https:…`).
    var target: String? = nil
    /// Load the real icon from this path (NSWorkspace). nil = draw a colored tile.
    var iconPath: String? = nil
    /// SF Symbol drawn on the colored tile when there is no real icon.
    var symbol: String? = nil
    /// Candidate id in the core, used to record usage. nil for synthesized rows.
    var candidateID: String? = nil
    /// Action row (⌘K actions mode).
    var action: SpotlightAction? = nil
    /// Process (ps" / :kill).
    var pid: Int32? = nil
    /// Value supplied by the row, such as a command ID or tag keyword.
    var payload: String? = nil
    /// Site whose real icon to draw ("youtube.com"); falls back to `iconPath`, then the tile.
    var favicon: String? = nil
    /// Open browser tab (kind == .tab).
    var tab: BrowserTab? = nil
    /// A real file or folder on disk (not a URL scheme), the target of editor/terminal/trash.
    var isFileTarget: Bool {
        (kind.isDocument || kind == .folder) && target?.hasPrefix("/") == true
    }

    /// Has an actions view (⌘K).
    var supportsActions: Bool {
        if kind == .process { return pid != nil }
        return (kind == .app || kind.isDocument || kind == .folder) && target != nil
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Fields of a `SpotlightItem` a row draws or acts on. `SpotlightItem.==` compares ids only (it
/// identifies rows), which would hide a renamed row from the diff.
extension SpotlightItem {
    func sameRowContent(as other: SpotlightItem) -> Bool {
        id == other.id && name == other.name && kind == other.kind && colors == other.colors
            && glyph == other.glyph && meta == other.meta
            && iconPath == other.iconPath && symbol == other.symbol && pid == other.pid
            && payload == other.payload
            && target == other.target && candidateID == other.candidateID
            && favicon == other.favicon && tab?.url == other.tab?.url
    }
}

// MARK: - Sample data (motion lab / Preview only)

enum SpotlightData {
    static let items: [SpotlightItem] = [
        .app("Flux.app", "#ffd166,#f0733d", "☀", 9),
        .app("Finder.app", "#7ac6ff,#2b7ae0", "☺", 8),
        .app("Figma.app", "#f06a6a,#7a5af5", nil, 6),
        .app("Find My.app", "#5fd97a,#1f9d4d", "◎", 4),
        .app("FaceTime.app", "#6ee07a,#1fa34a", "▣", 4),
        .app("Freeform.app", "#5fe3e8,#1a7f9c", "〜", 3),
        .app("File Manager.app", "#8fa4bd,#5b6c82", nil, 2),
        .app("Safari.app", "#79d0ff,#1f6fd0", "◍", 7),
        .folder("Documents", "Users ▸ Documents", 5),
        .folder("Downloads", "Users ▸ Downloads", 6),
        .doc("Q3 Report.pdf", "Documents ▸ Reports", "📕", 4),
        .setting("Wi‑Fi", "System Settings"),
    ]
}

private extension SpotlightItem {
    static func app(_ name: String, _ c: String, _ glyph: String?, _ rank: Int) -> Self {
        SpotlightItem(id: "app|\(name)", name: name, kind: .app, colors: c, glyph: glyph, rank: rank)
    }
    static func folder(_ name: String, _ path: String, _ rank: Int) -> Self {
        SpotlightItem(id: "folder|\(name)", name: name, kind: .folder, colors: "#6cb8f5,#2f7fe0", glyph: "📁", meta: path, rank: rank)
    }
    static func doc(_ name: String, _ path: String, _ glyph: String, _ rank: Int) -> Self {
        SpotlightItem(id: "doc|\(name)", name: name, kind: .doc, colors: "#dfe3ea,#b6bdc9", glyph: glyph, meta: path, rank: rank)
    }
    static func setting(_ name: String, _ meta: String) -> Self {
        SpotlightItem(id: "setting|\(name)", name: name, kind: .setting, colors: "#9aa2ad,#5c636e", glyph: "⚙️", meta: meta)
    }
}
