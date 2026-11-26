import AppKit

/// The application that handles the launcher's "Open in Terminal" action.
enum TerminalApp: String, CaseIterable {
    case terminal = "com.apple.Terminal"
    case ghostty = "com.mitchellh.ghostty"

    private static let configKey = "terminal_app"

    var name: String {
        switch self {
        case .terminal: "Terminal"
        case .ghostty: "Ghostty"
        }
    }

    static var choice: TerminalApp {
        let path = ConfigPathResolver.resolvedPath()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let value = ConfigFileLines.keyValues(raw)[configKey]
        else { return .terminal }
        return TerminalApp(rawValue: value) ?? .terminal
    }

    static func options() -> [(value: TerminalApp, label: String)] {
        let selected = choice
        return allCases.compactMap { app in
            if app == .terminal || app.applicationURL != nil {
                return (app, app.name)
            }
            return app == selected ? (app, "\(app.name) (not installed)") : nil
        }
    }

    static func setChoice(_ app: TerminalApp) -> Bool {
        let path = ConfigPathResolver.resolvedPath()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var lines = ConfigFileLines.parse(raw)
        ConfigFileLines.upsert(&lines, key: configKey, value: app.rawValue)
        do {
            try ConfigFileLines.render(lines).write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Sends a directory URL to the terminal, which opens a session in that directory.
    static func openFolder(_ folder: URL) async -> Bool {
        var isDirectory: ObjCBool = false
        guard folder.isFileURL,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return false }

        let selected = choice
        if await selected.open(folder) { return true }
        guard selected != .terminal else { return false }
        return await TerminalApp.terminal.open(folder)
    }

    private var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue)
    }

    private func open(_ folder: URL) async -> Bool {
        guard let applicationURL else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([folder], withApplicationAt: applicationURL, configuration: config) { app, error in
                continuation.resume(returning: app != nil && error == nil)
            }
        }
    }
}
