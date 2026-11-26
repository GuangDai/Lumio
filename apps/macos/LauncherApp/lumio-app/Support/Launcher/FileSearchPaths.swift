import Foundation

nonisolated enum FileSearchPaths {
    /// True when the path is an excluded folder or a descendant.
    /// The folders are standardized absolute paths from the config or folder picker.
    static func isExcluded(_ path: String, by folders: [String]) -> Bool {
        guard !folders.isEmpty, path.hasPrefix("/") else { return false }
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        return folders.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}
