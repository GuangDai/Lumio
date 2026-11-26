import Foundation

nonisolated enum FolderAddressQuery {
    static func changeDirectoryArgument(in input: String) -> String? {
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.first == "cd" else { return nil }
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
              let parent = literalURL(unquoted(input))?.standardizedFileURL,
              including(parent),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: parent, includingPropertiesForKeys: nil
              ) else { return [] }

        var folders: [URL] = []
        for entry in entries {
            guard !isCancelled() else { return [] }
            if including(entry) { folders.append(entry) }
        }
        return folders
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
