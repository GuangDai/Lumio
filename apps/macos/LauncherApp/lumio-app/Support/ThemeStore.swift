import AppKit
import Combine
import Foundation
import ServiceManagement

/// App settings kept in the config file (`~/.lumio/config`) and edited in Settings:
/// folder indexing, logging, shortcuts, and launch at login.
final class ThemeStore: ObservableObject {
    // Shared so AppDelegate (which hosts ContentView in an AppKit window), the
    // Settings window and the launcher use the same store.
    static let shared = ThemeStore()

    @Published var settings: ThemeSettings {
        didSet {
            save()
            if oldValue.hotkeys != settings.hotkeys {
                NotificationCenter.default.post(name: .lookHotKeysChanged, object: nil)
            }
        }
    }

    @Published private(set) var excludedApplicationNames: Set<String> = []
    @Published private(set) var excludedFolderPaths: [String] = []
    @Published private(set) var folderScanRoots: [String] = []
    @Published private(set) var extraFolderScanRoots: [String] = []

    enum AddExtraScanRootError: Error {
        case notDirectory
        case alreadyIncluded
        case overlapsExistingRoot(String)
        case riskySystemRoot

        var message: String {
            switch self {
            case .notDirectory:
                return "Please select a directory"
            case .alreadyIncluded:
                return "Directory is already covered by scan roots"
            case let .overlapsExistingRoot(path):
                return "Overlaps with existing root: \(path)"
            case .riskySystemRoot:
                return "Refusing risky system root (/, /System, /Library, /private)"
            }
        }
    }

    private let defaultsKey = "lumio.theme.settings"

    init() {
        Self.ensureDefaultConfigFileExists(at: Self.configPath())
        Self.migrateLegacyDefaults(key: defaultsKey)
        settings = Self.loadThemeSettings(from: UserDefaults.standard.data(forKey: defaultsKey))
        applyOverridesFromConfigFile()
        _ = applyLaunchAtLoginSetting()
    }

    /// The bundle id used to be `noah-code.Lumio`, so theme settings saved before
    /// the rename live in that domain. Copy them over once so they survive.
    private static func migrateLegacyDefaults(key: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil,
            let bundleID = Bundle.main.bundleIdentifier,
            bundleID.hasPrefix("com.cavaldos.Lumio"),
            let legacy = UserDefaults(
                suiteName: bundleID.replacingOccurrences(of: "com.cavaldos.Lumio", with: "noah-code.Lumio")),
            let data = legacy.data(forKey: key)
        else { return }
        defaults.set(data, forKey: key)
    }

    struct ConfigReloadResult {
        let warnings: [String]
    }

    func reloadFromConfig() -> ConfigReloadResult {
        let configPath = Self.configPath()
        Self.ensureDefaultConfigFileExists(at: configPath)

        var warnings: [String] = []
        if let raw = try? String(contentsOf: configPath, encoding: .utf8) {
            let values = Self.configValues(raw)
            if let value = values["folder_scan_depth"], let parsed = Int(value),
               !(AppConstants.FolderScan.minDepth...AppConstants.FolderScan.maxDepth).contains(parsed)
            {
                warnings.append("folder_scan_depth=\(value) invalid (must be \(AppConstants.FolderScan.minDepth)-\(AppConstants.FolderScan.maxDepth))")
            }
            if let value = values["folder_scan_limit"], let parsed = Int(value),
               !(AppConstants.FolderScan.minLimit...AppConstants.FolderScan.maxLimit).contains(parsed)
            {
                warnings.append("folder_scan_limit=\(value) invalid (must be \(AppConstants.FolderScan.minLimit)-\(AppConstants.FolderScan.maxLimit))")
            }
        }

        applyOverridesFromConfigFile()
        _ = applyLaunchAtLoginSetting()
        return ConfigReloadResult(warnings: warnings)
    }

    func saveCurrentConfigToFile() -> Bool {
        let path = Self.configPath()
        Self.ensureDefaultConfigFileExists(at: path)

        // A failed read must not fall through to an empty parse: saving on top of
        // nothing would drop every other setting, comment and blank line in the file.
        guard let raw = try? String(contentsOf: path, encoding: .utf8) else {
            return false
        }
        var lines = ConfigFileLines.parse(raw)
        ConfigFileLines.upsert(&lines, key: "folder_scan_depth", value: String(settings.folderScanDepth))
        ConfigFileLines.upsert(&lines, key: "folder_scan_limit", value: String(settings.folderScanLimit))
        ConfigFileLines.upsert(&lines, key: "lazy_indexing_enabled", value: settings.lazyIndexingEnabled ? "true" : "false")
        ConfigFileLines.upsert(&lines, key: "folder_exclude_paths", value: ConfigFileLines.renderList(excludedFolderPaths))
        ConfigFileLines.upsert(&lines, key: "folder_scan_extra_roots", value: ConfigFileLines.renderList(extraFolderScanRoots))
        ConfigFileLines.upsert(&lines, key: "backend_log_level", value: settings.backendLogLevel.rawValue)
        ConfigFileLines.upsert(&lines, key: "launcher_corner_radius", value: String(Int(settings.launcherCornerRadius.rounded())))
        ConfigFileLines.upsert(&lines, key: "launch_at_login", value: settings.launchAtLogin ? "true" : "false")
        ConfigFileLines.upsert(&lines, key: HiddenTabs.configKey, value: HiddenTabs.render(settings.hiddenTabs))
        ConfigFileLines.upsert(&lines, key: QuickBubbles.configKey, value: QuickBubbles.render(settings.quickBubbles))
        for action in HotKeyAction.allCases {
            ConfigFileLines.upsert(&lines, key: action.configKey, value: settings.hotKey(for: action)?.configValue ?? "")
        }

        do {
            try ConfigFileLines.render(lines).write(to: path, atomically: true, encoding: .utf8)
            _ = applyLaunchAtLoginSetting()
            return true
        } catch {
            return false
        }
    }

    func regenerateFreshConfigFile() -> Bool {
        let path = Self.configPath()
        if FileManager.default.fileExists(atPath: path.path) {
            do {
                try FileManager.default.removeItem(at: path)
            } catch {
                return false
            }
        }

        Self.ensureDefaultConfigFileExists(at: path)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return false
        }

        settings = .default
        applyOverridesFromConfigFile()
        _ = applyLaunchAtLoginSetting()
        return true
    }

    func addExcludedFolderPath(url: URL) {
        let normalizedPath = normalizeExcludedFolderPath(url.path)
        guard !normalizedPath.isEmpty else {
            return
        }
        if excludedFolderPaths.contains(normalizedPath) {
            return
        }
        excludedFolderPaths.append(normalizedPath)
        excludedFolderPaths.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func removeExcludedFolderPath(_ path: String) {
        let normalizedPath = normalizeExcludedFolderPath(path)
        excludedFolderPaths.removeAll { $0 == normalizedPath }
    }

    @discardableResult
    func addExtraFolderScanRoot(url: URL) -> AddExtraScanRootError? {
        let normalizedPath = normalizeFolderScanRootPath(url.path)
        guard !normalizedPath.isEmpty else {
            return .notDirectory
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: normalizedPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .notDirectory
        }

        if isRiskyRoot(normalizedPath) {
            return .riskySystemRoot
        }

        // A nested explicit root can reach farther than its parent scan's depth limit.
        if folderScanRoots.contains(where: { pathContains(normalizedPath, $0) }) {
            return .alreadyIncluded
        }

        if let overlap = extraFolderScanRoots.first(where: { pathContains($0, normalizedPath) || pathContains(normalizedPath, $0) }) {
            return .overlapsExistingRoot(overlap)
        }

        extraFolderScanRoots.append(normalizedPath)
        extraFolderScanRoots.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return nil
    }

    func removeExtraFolderScanRoot(_ path: String) {
        let normalizedPath = normalizeFolderScanRootPath(path)
        extraFolderScanRoots.removeAll { $0 == normalizedPath }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// Invalid values are ignored and the current ones kept, so a broken line never
    /// stops the app. Old `ui_*` theme keys are left in the file and ignored.
    private func applyOverridesFromConfigFile() {
        guard let raw = try? String(contentsOf: Self.configPath(), encoding: .utf8) else {
            return
        }

        excludedFolderPaths = []
        folderScanRoots = defaultFolderScanRoots()
        extraFolderScanRoots = []

        let values = Self.configValues(raw)
        let excludedApps = ConfigFileLines.parseList(values["app_exclude_names"] ?? "")
            .map(AppExcludeWriter.normalize)
        excludedApplicationNames = Set(excludedApps.filter { !$0.isEmpty })

        for (key, value) in values {
            switch key {
            case "folder_scan_depth":
                if let parsed = parsePositiveInt(value) { settings.folderScanDepth = parsed }
            case "folder_scan_limit":
                if let parsed = parsePositiveInt(value) { settings.folderScanLimit = parsed }
            case "lazy_indexing_enabled":
                if let parsed = parseBool(value) { settings.lazyIndexingEnabled = parsed }
            case "folder_exclude_paths":
                excludedFolderPaths = parseExcludedFolderPaths(value)
            case "folder_scan_roots":
                let parsed = parseFolderScanRootPaths(value)
                if !parsed.isEmpty { folderScanRoots = parsed }
            case "folder_scan_extra_roots":
                extraFolderScanRoots = parseFolderScanRootPaths(value)
            case "backend_log_level":
                if let parsed = parseBackendLogLevel(value) { settings.backendLogLevel = parsed }
            case "launcher_corner_radius":
                if let parsed = Double(value.trimmingCharacters(in: .whitespaces)) {
                    settings.launcherCornerRadius = min(max(parsed, ThemeSettings.cornerRadiusRange.lowerBound), ThemeSettings.cornerRadiusRange.upperBound)
                }
            case "launch_at_login":
                if let parsed = parseBool(value) { settings.launchAtLogin = parsed }
            case HiddenTabs.configKey:
                settings.hiddenTabs = HiddenTabs.parse(value)
            case QuickBubbles.configKey:
                settings.quickBubbles = QuickBubbles.parse(value)
            default:
                // hotkey_<action>: empty = off; a value that doesn't parse is ignored like any bad line.
                guard let action = HotKeyAction.named(configKey: key) else { continue }
                if value.isEmpty {
                    settings.hotkeys[action.rawValue] = ""
                } else if let combo = KeyCombo.parse(value) {
                    settings.hotkeys[action.rawValue] = combo.configValue
                }
            }
        }
    }

    private static func configValues(_ raw: String) -> [String: String] {
        var values = ConfigFileLines.keyValues(raw)
        let folderKeys = ["folder_scan_roots", "folder_scan_extra_roots", "folder_scan_depth",
                          "folder_scan_limit", "folder_exclude_paths"]
        for key in folderKeys where values[key] == nil {
            values[key] = values["file_" + String(key.dropFirst("folder_".count))]
        }
        return values
    }

    private static func configPath() -> URL {
        URL(fileURLWithPath: ConfigPathResolver.resolvedPath())
    }

    /// Writes the default config when there is none, and otherwise undoes the damage
    /// left by builds that duplicated their own section header on every save. Runs at
    /// launch and on reload, so an affected config heals without the user having to go
    /// and save something.
    ///
    /// A config that does not carry the damage is left byte-identical, not merely
    /// equivalent: rewriting it would reformat a layout the user chose, and would bump
    /// the mtime and wake the config watcher on every launch.
    private static func ensureDefaultConfigFileExists(at path: URL) {
        guard FileManager.default.fileExists(atPath: path.path) else {
            try? defaultConfigContents.write(to: path, atomically: true, encoding: .utf8)
            return
        }

        guard let raw = try? String(contentsOf: path, encoding: .utf8),
              let repaired = ConfigFileLines.repairingLegacyDamage(raw)
        else {
            return
        }

        try? repaired.write(to: path, atomically: true, encoding: .utf8)
    }

    private func parsePositiveInt(_ value: String) -> Int? {
        guard let parsed = Int(value), parsed > 0 else {
            return nil
        }
        return parsed
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private func parseBackendLogLevel(_ value: String) -> BackendLogLevel? {
        BackendLogLevel(rawValue: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func parseExcludedFolderPaths(_ value: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for token in ConfigFileLines.parseList(value) {
            let normalized = normalizeExcludedFolderPath(token)
            if normalized.isEmpty || seen.contains(normalized) {
                continue
            }
            seen.insert(normalized)
            paths.append(normalized)
        }
        return paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func normalizeExcludedFolderPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        let expanded = expandConfigLikePath(trimmed)
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func parseFolderScanRootPaths(_ value: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for token in ConfigFileLines.parseList(value) {
            let normalized = normalizeFolderScanRootPath(token)
            if normalized.isEmpty || seen.contains(normalized) {
                continue
            }
            seen.insert(normalized)
            paths.append(normalized)
        }
        return paths.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func normalizeFolderScanRootPath(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ""
        }
        let expanded = expandConfigLikePath(trimmed)
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    private func defaultFolderScanRoots() -> [String] {
        let home = NSHomeDirectory()
        let defaults = ["Desktop", "Documents", "Downloads", "Library"]
        return defaults.map { URL(fileURLWithPath: home).appendingPathComponent($0).standardizedFileURL.path } + [home]
    }

    private func isRiskyRoot(_ path: String) -> Bool {
        let riskyRoots = ["/", "/System", "/Library", "/private"]
        return riskyRoots.contains(where: { $0 == path })
    }

    private func pathContains(_ candidateRoot: String, _ path: String) -> Bool {
        let root = URL(fileURLWithPath: candidateRoot).standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        if root == target {
            return true
        }
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        return target.hasPrefix(normalizedRoot)
    }

    private func expandConfigLikePath(_ value: String) -> String {
        let home = NSHomeDirectory()
        if value == "~" {
            return home
        }
        if value.hasPrefix("~/") {
            let relative = value.dropFirst(2)
            return home + "/" + relative
        }
        if value.hasPrefix("/") {
            return value
        }
        return home + "/" + value
    }

    private static let defaultConfigContents = """
# lumio configuration
# Generated on first launch. Edit values and press Cmd+Shift+; to reload.

# Backend indexing
app_scan_roots=/Applications,/System/Applications,/System/Applications/Utilities,/System/Library/CoreServices/Applications,/System/Library/CoreServices/Finder.app/Contents/Applications
app_scan_depth=3
app_exclude_paths=
app_exclude_names=
folder_scan_roots=Desktop,Documents,Downloads,Library,~/
folder_scan_extra_roots=
folder_scan_depth=4
folder_scan_limit=8000
folder_exclude_paths=
lazy_indexing_enabled=true
backend_log_level=error
launch_at_login=true
# Hide the Processes tab by setting tab_hidden=process. Its shortcut and search tag still open it.
tab_hidden=
# Shortcuts: hotkey_<action>=cmd+shift+v (modifiers: cmd, opt, ctrl, shift; empty = off).
# Global actions: launcher, settings, process (Processes), and search tag shortcuts
hotkey_launcher=opt+space
hotkey_settings=cmd+shift+space
skip_dir_names=node_modules,target,build,dist,applications,old firefox data,deriveddata,pods,vendor,out,coverage,tmp,cache,venv

# Search aliases (apps + System Settings). Format: alias_<keyword>=Term1|Term2|Term3
alias_note=Notion|Obsidian|Notes|Apple Notes|Bear|Logseq
alias_code=Visual Studio Code|VSCode|Cursor|Windsurf|IntelliJ IDEA|PyCharm|WebStorm|Neovim|Xcode|Zed
alias_term=Terminal|iTerm|iTerm2|Ghostty|WezTerm|Alacritty|Kitty|Warp
alias_chat=Slack|Discord|Telegram|Messages
alias_music=Spotify|Apple Music|Music
alias_brow=Arc|Google Chrome|Chrome|Firefox|Brave
"""

    private static func loadThemeSettings(from data: Data?) -> ThemeSettings {
        guard let data else { return .default }
        // Older blobs carry theme keys too; JSONDecoder ignores keys it doesn't know.
        return (try? JSONDecoder().decode(ThemeSettings.self, from: data)) ?? .default
    }

    private func applyLaunchAtLoginSetting() -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if settings.launchAtLogin {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                return true
            } catch {
                return false
            }
        }

        return false
    }
}
