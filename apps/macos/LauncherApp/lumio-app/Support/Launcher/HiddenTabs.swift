import Foundation

/// Only the Processes tab can be hidden. It can still be opened with a shortcut or search tag.
nonisolated enum HiddenTabs {
    static let configKey = "tab_hidden"
    private static let process = "process"

    static func normalized(_ codes: [String]) -> [String] {
        let processHidden = codes.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == process
        }
        return processHidden ? [process] : []
    }

    static func parse(_ raw: String) -> [String] {
        normalized(raw.split(separator: ",").map(String.init))
    }

    static func render(_ codes: [String]) -> String {
        normalized(codes).joined(separator: ",")
    }

    static func setting(_ code: String, shown: Bool, in codes: [String]) -> [String] {
        guard code == process else { return normalized(codes) }
        return shown ? [] : [process]
    }
}
