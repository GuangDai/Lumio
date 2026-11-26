import Foundation

enum BackendLogLevel: String, CaseIterable, Codable, Identifiable {
    case error
    case info
    case debug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .error: return "Error"
        case .info: return "Info"
        case .debug: return "Debug"
        }
    }
}

/// Settings edited in the Settings window and saved to the config file.
struct ThemeSettings: Codable, Equatable {
    var fileScanDepth: Int = 4
    var fileScanLimit: Int = 4000
    var lazyIndexingEnabled: Bool = true
    var backendLogLevel: BackendLogLevel = .error
    var launchAtLogin: Bool = true
    /// Tool tabs left out of the pill row and the Tab cycle (`tab_hidden`).
    var hiddenTabs: [String] = []
    /// What each round button of the idle bar opens, in order (`quick_bubbles`).
    var quickBubbles: [String] = QuickBubbles.defaultCodes
    /// Global shortcuts: HotKeyAction raw value → `cmd+shift+v` ("" = off).
    var hotkeys: [String: String] = HotKeyAction.defaultValues

    /// Launcher corner roundness in % (`launcher_corner_radius`): 0 = square, 100 = full pill/circle.
    var launcherCornerRadius: Double = ThemeSettings.defaultCornerRadius
    /// Liquid Glass on macOS 26+ (`liquid_glass_enabled`); off uses the classic blur.
    var liquidGlassEnabled: Bool = true
    static let defaultCornerRadius: Double = 100
    static let cornerRadiusRange: ClosedRange<Double> = 0...100

    /// Corner radius in points for a shape whose shorter side is `side`.
    func cornerRadius(side: CGFloat) -> CGFloat { side / 2 * CGFloat(launcherCornerRadius / 100) }

    static let `default` = ThemeSettings()

    init() {}

    // Missing keys keep their defaults, so a blob saved by an older build still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ThemeSettings()
        fileScanDepth = try c.decodeIfPresent(Int.self, forKey: .fileScanDepth) ?? d.fileScanDepth
        fileScanLimit = try c.decodeIfPresent(Int.self, forKey: .fileScanLimit) ?? d.fileScanLimit
        lazyIndexingEnabled = try c.decodeIfPresent(Bool.self, forKey: .lazyIndexingEnabled) ?? d.lazyIndexingEnabled
        backendLogLevel = try c.decodeIfPresent(BackendLogLevel.self, forKey: .backendLogLevel) ?? d.backendLogLevel
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        hiddenTabs = HiddenTabs.normalized(try c.decodeIfPresent([String].self, forKey: .hiddenTabs) ?? d.hiddenTabs)
        quickBubbles = QuickBubbles.normalized(try c.decodeIfPresent([String].self, forKey: .quickBubbles) ?? d.quickBubbles)
        launcherCornerRadius = min(max(try c.decodeIfPresent(Double.self, forKey: .launcherCornerRadius) ?? d.launcherCornerRadius, Self.cornerRadiusRange.lowerBound), Self.cornerRadiusRange.upperBound)
        liquidGlassEnabled = try c.decodeIfPresent(Bool.self, forKey: .liquidGlassEnabled) ?? d.liquidGlassEnabled
        let savedHotkeys = try c.decodeIfPresent([String: String].self, forKey: .hotkeys) ?? [:]
        hotkeys = d.hotkeys.merging(savedHotkeys.filter { d.hotkeys[$0.key] != nil }) { _, saved in saved }
    }

    /// The shortcut set for `action`; nil when it is off or unreadable.
    func hotKey(for action: HotKeyAction) -> KeyCombo? {
        KeyCombo.parse(hotkeys[action.rawValue] ?? action.defaultValue)
    }
}
