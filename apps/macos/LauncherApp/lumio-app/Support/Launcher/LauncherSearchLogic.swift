import Foundation

enum LauncherPinnedLookupScope: Equatable {
    case unscoped
    case apps
    case folders
    case disabled
}

enum LauncherSearchLogic {
    static func hasEngineScope(_ query: String) -> Bool {
        pinnedLookupScope(for: query) != .unscoped
    }

    static func prioritizesApplications(for query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        guard !normalized.isEmpty, !normalized.hasPrefix(">") else { return false }

        // Keep this in step with looks_like_settings_query in the Rust engine.
        if normalized.contains("设置") || normalized.contains("設定") { return false }
        return !normalized.split(whereSeparator: \.isWhitespace).contains { word in
            ["setting", "settings", "preference", "preferences"].contains(String(word))
        }
    }

    static func isSettingsLandingQuery(_ query: String) -> Bool {
        // Match the Rust landing-query list so learned results cannot displace System Settings.
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["setting", "settings", "system settings", "preference", "preferences", "system preferences",
                "设置", "系统设置", "系统偏好设置", "設定", "系統設定", "系統偏好設定"].contains(normalized)
    }

    static func isLumioSettingsQuery(_ query: String) -> Bool {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["lumio settings", "lumio preferences", "lumio 设置", "lumio 設定", "lumio设置", "lumio設定"]
            .contains(normalized)
    }

    /// Keep relevance and learned ordering within the applications and other results.
    static func applicationsFirst<Row>(_ rows: [Row], isApplication: (Row) -> Bool) -> [Row] {
        rows.filter(isApplication) + rows.filter { !isApplication($0) }
    }

    static func pinnedLookupScope(for query: String) -> LauncherPinnedLookupScope {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.apps) {
            return .apps
        }
        if normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.folders) {
            return .folders
        }
        if normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.settings) {
            return .disabled
        }
        return .unscoped
    }

    static func normalizedPinnedLookupQuery(
        for query: String,
        scope: LauncherPinnedLookupScope
    ) -> String? {
        var normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if scope == .apps, normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.apps) {
            normalized = String(normalized.dropFirst(AppConstants.Launcher.QueryPrefix.apps.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else if scope == .folders, normalized.hasPrefix(AppConstants.Launcher.QueryPrefix.folders) {
            normalized = String(normalized.dropFirst(AppConstants.Launcher.QueryPrefix.folders.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if scope == .disabled || normalized.isEmpty {
            return nil
        }

        return normalized
    }

    static func shouldInjectFinder(
        normalizedQuery: String?,
        scope: LauncherPinnedLookupScope
    ) -> Bool {
        guard scope == .unscoped || scope == .apps else { return false }
        guard let normalized = normalizedQuery else { return false }

        let finderName = AppConstants.Launcher.Finder.appName
        return normalized.contains(finderName)
            || (finderName.hasPrefix(normalized)
                && normalized.count >= AppConstants.Launcher.Finder.minPrefixMatchLength)
    }
}
