import Foundation

nonisolated enum FolderAddressQuery {
    static func changeDirectoryArgument(in input: String) -> String? {
        let parts = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard parts.first == "cd" else { return nil }
        return parts.count == 2 ? unquoted(String(parts[1])) : ""
    }

    static func isLiteralAddress(_ input: String) -> Bool {
        let address = unquoted(input)
        return address.hasPrefix("/") || address == "~" || address.hasPrefix("~/")
            || address.lowercased().hasPrefix("file://")
    }

    /// Returns a directory address for a local path. Files and packages resolve to their parent.
    static func existingFolder(in input: String) -> URL? {
        guard isLiteralAddress(input) else { return nil }
        let address = unquoted(input)
        let url: URL
        if address.lowercased().hasPrefix("file://") {
            guard let fileURL = URL(string: address),
                  fileURL.isFileURL,
                  fileURL.host == nil || fileURL.host == "" || fileURL.host?.lowercased() == "localhost",
                  fileURL.path.hasPrefix("/") else { return nil }
            url = fileURL
        } else {
            url = URL(fileURLWithPath: (address as NSString).expandingTildeInPath)
        }

        let normalized = url.standardizedFileURL
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isFolder) else { return nil }
        if isFolder.boolValue && (try? normalized.resourceValues(forKeys: [.isPackageKey]).isPackage) != true {
            return normalized
        }
        return normalized.deletingLastPathComponent()
    }

    private static func unquoted(_ input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == text.last, first == "\"" || first == "'" {
            return String(text.dropFirst().dropLast())
        }
        return text
    }
}
