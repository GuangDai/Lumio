import Foundation

/// The round buttons that split off the idle launcher bar: which feature each of the fixed
/// slots opens, in order, saved as `quick_bubbles=app,folder,doc,process`.
/// Codes are `SpotlightKind` raw values. Pure logic, so it is unit tested (LauncherLogicTests).
nonisolated enum QuickBubbles {
    static let configKey = "quick_bubbles"

    static let defaultCodes = ["app", "folder", "doc", "process"]
    static let choices = defaultCodes
    static let slotCount = defaultCodes.count

    /// Drops unknown and repeated codes, then fills remaining slots from the default order.
    static func normalized(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        let valid = codes
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { choices.contains($0) && seen.insert($0).inserted }
        return valid + defaultCodes.filter { !seen.contains($0) }
    }

    static func parse(_ raw: String) -> [String] {
        normalized(raw.split(separator: ",").map(String.init))
    }

    static func render(_ codes: [String]) -> String {
        normalized(codes).joined(separator: ",")
    }

    /// Swaps the feature at `slot` with the slot currently assigned to `code`.
    static func setting(slot: Int, to code: String, in codes: [String]) -> [String] {
        var out = normalized(codes)
        guard out.indices.contains(slot), let other = out.firstIndex(of: code) else { return out }
        out.swapAt(slot, other)
        return out
    }

    /// Slot `slot` moved `offset` places (-1 = left), clamped at both ends.
    static func moving(slot: Int, by offset: Int, in codes: [String]) -> [String] {
        var out = normalized(codes)
        guard out.indices.contains(slot) else { return out }
        let to = min(max(slot + offset, 0), out.count - 1)
        out.swapAt(slot, to)
        return out
    }
}
