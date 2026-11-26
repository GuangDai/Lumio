import Foundation

/// Manages `app_exclude_names` in the config file shared with the search index.
enum AppExcludeWriter {
    enum Result {
        case added
        case alreadyExcluded
        case writeFailed
    }

    static func append(_ appName: String) -> Result {
        guard !normalize(appName).isEmpty,
              let update = updateNames(adding: [appName], removing: []) else {
            return .writeFailed
        }
        return update.changed ? .added : .alreadyExcluded
    }

    static func excludedNames() -> [String]? {
        configValues().map { ConfigFileLines.parseList($0[key] ?? "") }
    }

    static func appScanSettings() -> (roots: [String], depth: Int) {
        let values = configValues() ?? [:]
        let roots = ConfigFileLines.parseList(values["app_scan_roots"] ?? "")
        let depth = Int(values["app_scan_depth"] ?? "") ?? 3
        return (roots, depth > 0 ? depth : 3)
    }

    /// Apply only the changes made in the picker, preserving names added elsewhere while it was open.
    static func save(_ selected: [String], replacing original: [String]) -> [String]? {
        let originalKeys = Set(original.map(normalize))
        let selectedKeys = Set(selected.map(normalize))
        let additions = selected.filter { !originalKeys.contains(normalize($0)) }
        return updateNames(adding: additions, removing: originalKeys.subtracting(selectedKeys))?.names
    }

    private static func configValues() -> [String: String]? {
        let raw = try? String(contentsOf: configURL, encoding: .utf8)
        return raw.map { ConfigFileLines.keyValues($0) }
    }

    /// Mirrors the case and suffix normalization used for exclusions in the Rust index.
    nonisolated static func normalize(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".app") { name.removeLast(4) }
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func updateNames(adding additions: [String], removing keys: Set<String>) -> (names: [String], changed: Bool)? {
        let path = configURL
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        let original = ConfigFileLines.parseList(ConfigFileLines.keyValues(raw)[key] ?? "")
        var names = original.filter { !keys.contains(normalize($0)) }
        var seen = Set(names.map(normalize))
        for addition in additions {
            let name = addition.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = normalize(name)
            if !normalized.isEmpty, seen.insert(normalized).inserted {
                names.append(name)
            }
        }
        guard names != original else { return (names, false) }

        let line = "\(key)=\(ConfigFileLines.renderList(names))"
        // Refuse values the line-based config would truncate or split on read.
        guard ConfigFileLines.parseList(ConfigFileLines.keyValues(line)[key] ?? "") == names else { return nil }
        var lines = ConfigFileLines.parse(raw)
        if let index = lines.lastIndex(where: { ConfigFileLines.keyValues($0)[key] != nil }) {
            lines[index] = line
        } else {
            lines.append(line)
        }
        do {
            try ConfigFileLines.render(lines).write(to: path, atomically: true, encoding: .utf8)
            return (names, true)
        } catch {
            return nil
        }
    }

    private static var configURL: URL { URL(fileURLWithPath: ConfigPathResolver.resolvedPath()) }
    private static let key = "app_exclude_names"
}
