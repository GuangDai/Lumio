import Foundation

nonisolated enum FolderAddressQuery {
    private static let partialParentLimit = 16

    static func changeDirectoryArgument(in input: String) -> String? {
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.first?.lowercased() == ":" + AppConstants.Launcher.Command.changeDirectory else { return nil }
        return parts.count == 2 ? unquoted(String(parts[1])) : ""
    }

    static func isLiteralAddress(_ input: String) -> Bool {
        isLiteralPath(unquoted(input))
    }

    static func requestsChildren(in input: String) -> Bool {
        let address = unquoted(input)
        guard address.hasSuffix("/"), isLiteralPath(address) else { return false }
        guard address.lowercased().hasPrefix("file://") else { return true }
        guard let url = literalURL(address) else { return false }
        return url.query == nil && url.fragment == nil
    }

    /// Lists one level. The caller applies the same browsing policy to the parent and every entry.
    static func immediateSubfolders(
        in input: String, including: (URL) -> Bool, isCancelled: () -> Bool
    ) -> [URL] {
        guard !isCancelled(), requestsChildren(in: input),
              let parent = literalURL(unquoted(input))?.standardizedFileURL else { return [] }
        return subfolders(of: parent, including: including, isCancelled: isCancelled)
    }

    /// Completes each path component among direct child folders. An exact address takes precedence.
    static func matchingFolders(
        in input: String, selectedFolder: URL? = nil, including: (URL) -> Bool, isCancelled: () -> Bool
    ) -> [URL] {
        let address = unquoted(input)
        guard !isCancelled(), let literal = literalURL(address) else { return [] }
        let path = literal.standardizedFileURL
        let browse = requestsChildren(in: input)

        if !browse, let existing = existingFolder(in: input) {
            return including(existing) ? [existing] : []
        }
        guard literal.query == nil, literal.fragment == nil else { return [] }

        if browse, FileManager.default.fileExists(atPath: path.path) {
            return subfolders(of: path, including: including, isCancelled: isCancelled)
        }
        if browse, let selectedFolder, including(selectedFolder) {
            return subfolders(of: selectedFolder, including: including, isCancelled: isCancelled)
        }

        let matches = complete(path, including: including, isCancelled: isCancelled)
        guard browse, let parent = matches.first else { return matches }
        return subfolders(of: parent, including: including, isCancelled: isCancelled)
    }

    private static func subfolders(
        of parent: URL, including: (URL) -> Bool, isCancelled: () -> Bool
    ) -> [URL] {
        guard !isCancelled(), including(parent), let entries = directoryEntries(in: parent) else { return [] }

        var folders: [URL] = []
        for entry in entries {
            guard !isCancelled() else { return [] }
            if including(entry) { folders.append(entry) }
        }
        return folders
    }

    private static func directoryEntries(in parent: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
    }

    private static func complete(
        _ path: URL, including: (URL) -> Bool, isCancelled: () -> Bool
    ) -> [URL] {
        let components = path.path.split(separator: "/").map(String.init)
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        guard !components.isEmpty, including(root) else { return [] }

        var parents = [(folder: root, score: 0)]
        for (index, component) in components.enumerated() {
            let needle = folded(component)
            var matches: [(folder: URL, score: Int)] = []
            for parent in parents {
                guard !isCancelled() else { return [] }
                let exact = parent.folder.appendingPathComponent(component, isDirectory: true)
                if including(exact) {
                    matches.append((exact, parent.score + 3))
                    continue
                }
                guard let children = directoryEntries(in: parent.folder) else { continue }
                for child in children {
                    guard !isCancelled() else { return [] }
                    if let score = completionScore(folded(child.lastPathComponent), needle: needle), including(child) {
                        matches.append((child, parent.score + score))
                    }
                }
            }
            guard !matches.isEmpty else { return [] }
            matches.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                let order = $0.folder.path.localizedStandardCompare($1.folder.path)
                return order == .orderedSame ? $0.folder.path < $1.folder.path : order == .orderedAscending
            }
            parents = index + 1 == components.count ? matches : Array(matches.prefix(partialParentLimit))
        }
        return isCancelled() ? [] : parents.map(\.folder)
    }

    private static func folded(_ component: String) -> String {
        component.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func completionScore(_ name: String, needle: String) -> Int? {
        if name == needle { return 3 }
        if name.hasPrefix(needle) { return 2 }
        var remaining = needle[...]
        for character in name where remaining.first == character {
            remaining.removeFirst()
            if remaining.isEmpty { return 1 }
        }
        return nil
    }

    /// Returns a directory address for a local path. Files and packages resolve to their parent.
    static func existingFolder(in input: String) -> URL? {
        guard let normalized = literalURL(unquoted(input))?.standardizedFileURL else { return nil }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue && (try? normalized.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
            return normalized
        }
        return normalized.deletingLastPathComponent()
    }

    private static func isLiteralPath(_ address: String) -> Bool {
        address.hasPrefix("/") || address == "~" || address.hasPrefix("~/")
            || address.lowercased().hasPrefix("file://")
    }

    private static func literalURL(_ address: String) -> URL? {
        guard isLiteralPath(address) else { return nil }
        if address.lowercased().hasPrefix("file://") {
            guard let fileURL = URL(string: address),
                  fileURL.isFileURL,
                  fileURL.host == nil || fileURL.host == "" || fileURL.host?.lowercased() == "localhost",
                  fileURL.path.hasPrefix("/") else { return nil }
            return fileURL
        }
        return URL(fileURLWithPath: (address as NSString).expandingTildeInPath)
    }

    private static func unquoted(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
