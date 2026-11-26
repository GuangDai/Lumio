import Foundation

enum LauncherResultKind: String, Codable {
    case app
    case folder
    case process
    /// A row from a user-declared block that has no filesystem target.
    case action
}

/// One search result from the Rust core (see `EngineBridge.search`).
struct LauncherResult: Identifiable {
    let id: String
    let kind: LauncherResultKind
    let title: String
    let subtitle: String?
    let path: String
    var score: Int
    var icon: String? = nil
}
