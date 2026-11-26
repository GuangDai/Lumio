import AppKit
import SwiftUI

extension ThemeSettingsView {
    // MARK: - Preset values (one tap instead of a slider / number field)

    /// Depth 1...12, limit 500...50_000. Balanced matches the app defaults.
    private var indexingScopePresets: [(title: String, depth: Int, limit: Int)] {
        [
            (title: "Fast", depth: 2, limit: 1000),
            (title: "Balanced", depth: 4, limit: 8000),
            (title: "Thorough", depth: 8, limit: 15000),
            // The deepest search and largest folder index.
            (title: "Everything", depth: 12, limit: 50000),
        ]
    }

    var settingsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical, showsIndicators: false) {
                // One page at a time, picked in the sidebar.
                VStack(alignment: .leading, spacing: 8) {
                    switch selectedPane {
                    case .general: generalSection
                    case .search: searchSection
                    case .appearance: appearanceSection
                    case .indexing: indexingSection
                    case .shortcuts: shortcutsSection
                    case .tabs: tabsSection
                    }
                }
                .padding(.bottom, 8)
            }
            .onAppear { syncIndexingInputsFromSettings() }
            .onChange(of: settings.folderScanDepth) { _, _ in
                folderScanDepthInput = String(settings.folderScanDepth)
            }
            .onChange(of: settings.folderScanLimit) { _, _ in
                folderScanLimitInput = String(settings.folderScanLimit)
            }

            Text(HintText.Settings.advancedApply)
                .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                .foregroundStyle(themeStore.mutedTextColor())
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsSectionTitle("Launcher")
        SettingsCard {
            SettingsRow("Corner radius", icon: "square.dashed", detail: "0% is square, 100% is fully round") {
                HStack(spacing: 10) {
                    Slider(value: $settings.launcherCornerRadius, in: ThemeSettings.cornerRadiusRange, step: 1)
                        .controlSize(.small)
                        .frame(width: 180)
                    Text("\(Int(settings.launcherCornerRadius))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 1), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
            }
        }
    }

    @ViewBuilder
    private var indexingSection: some View {
        SettingsSectionTitle("Status")
        SettingsCard {
            IndexStatusRows()
        }
        SettingsSectionTitle("How much to index")
        SettingsCard {
            SettingsRow("Scan scope", icon: "scope", detail: "Choose how deeply and how many folders Lumio scans") {
                presetButtons(
                    options: indexingScopePresets.map { $0.title },
                    selected: indexingScopePresets.firstIndex(where: {
                        $0.depth == settings.folderScanDepth && $0.limit == settings.folderScanLimit
                    }),
                    onPick: {
                        settings.folderScanDepth = indexingScopePresets[$0].depth
                        settings.folderScanLimit = indexingScopePresets[$0].limit
                        folderScanDepthError = nil
                        folderScanLimitError = nil
                        syncIndexingInputsFromSettings()
                    }
                )
            }
            SettingsDivider()
            SettingsToggleRow(
                "Lazy indexing", icon: "arrow.triangle.2.circlepath",
                detail: "Refresh the index when the launcher opens after folder or app changes",
                isOn: $settings.lazyIndexingEnabled
            )
            SettingsDivider()
            SettingsRow(
                "Folder scan depth", icon: "arrow.down.to.line",
                detail: folderScanDepthError ?? "How many directory levels to index (\(AppConstants.FolderScan.minDepth)-\(AppConstants.FolderScan.maxDepth))"
            ) {
                TextField("4", text: $folderScanDepthInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: folderScanDepthInput) { _, value in
                        folderScanDepthInput = sanitizedNumericInput(value)
                        if let parsed = Int(folderScanDepthInput) {
                            if parsed >= AppConstants.FolderScan.minDepth && parsed <= AppConstants.FolderScan.maxDepth {
                                settings.folderScanDepth = parsed
                                folderScanDepthError = nil
                            } else {
                                folderScanDepthError = "Must be \(AppConstants.FolderScan.minDepth)-\(AppConstants.FolderScan.maxDepth)"
                            }
                        }
                    }
            }
            SettingsDivider()
            SettingsRow(
                "Folder scan limit", icon: "number",
                detail: folderScanLimitError ?? "Max folders indexed per refresh"
            ) {
                TextField("8000", text: $folderScanLimitInput)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .onChange(of: folderScanLimitInput) { _, value in
                        folderScanLimitInput = sanitizedNumericInput(value)
                        if let parsed = Int(folderScanLimitInput) {
                            if parsed >= AppConstants.FolderScan.minLimit && parsed <= AppConstants.FolderScan.maxLimit {
                                settings.folderScanLimit = parsed
                                folderScanLimitError = nil
                            } else {
                                folderScanLimitError = "Must be \(AppConstants.FolderScan.minLimit)-\(AppConstants.FolderScan.maxLimit)"
                            }
                        }
                    }
            }
        }
        SettingsSectionTitle("Folders")
        SettingsCard {
            SettingsRow("Extra scan folders", icon: "folder.badge.plus", detail: extraScanDirectoryMessage ?? "Index these folders too") {
                Button("Add Folder…") { selectExtraScanDirectory() }
            } below: {
                pathChips(themeStore.extraFolderScanRoots) { path in
                    themeStore.removeExtraFolderScanRoot(path)
                    extraScanDirectoryMessage = nil
                }
            }
            SettingsDivider()
            SettingsRow("Skipped folders", icon: "folder.badge.minus", detail: "Never index anything inside these") {
                Button("Add Folder…") { selectExcludedFolderPath() }
            } below: {
                pathChips(themeStore.excludedFolderPaths) { path in
                    themeStore.removeExcludedFolderPath(path)
                }
            }
        }
    }

    @ViewBuilder
    private var shortcutsSection: some View {
        SettingsSectionTitle("Keyboard")
        ShortcutSettingsSection(settings: $settings)
    }

    @ViewBuilder
    private var tabsSection: some View {
        let processCode = SpotlightKind.process.rawValue
        SettingsSectionTitle("Launcher tabs")
        SettingsCard {
            SettingsToggleRow(
                "Show Processes tab", icon: "rectangle.3.group",
                detail: "Include Processes in the tab row and tab cycle",
                isOn: Binding(
                    get: { !settings.hiddenTabs.contains(processCode) },
                    set: { settings.hiddenTabs = HiddenTabs.setting(processCode, shown: $0, in: settings.hiddenTabs) }
                )
            )
        }
        SettingsSectionTitle("Round buttons")
        SettingsCard {
            quickBubblesRow
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        SettingsSectionTitle("About")
        SettingsCard {
            AppUpdateStatusView(themeStore: themeStore)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        SettingsSectionTitle("Startup")
        SettingsCard {
            SettingsToggleRow(
                "Launch at login", icon: "power",
                detail: "Start Lumio automatically when you sign in",
                isOn: $settings.launchAtLogin
            )
        }
        SettingsSectionTitle("Permissions")
        SettingsCard {
            AccessibilityStatusRow()
        }
        SettingsSectionTitle("Advanced")
        SettingsCard {
            SettingsRow("Log level", icon: "doc.text.magnifyingglass", detail: "Error only by default; use Info or Debug for troubleshooting") {
                presetButtons(
                    options: BackendLogLevel.allCases.map { $0.title },
                    selected: BackendLogLevel.allCases.firstIndex(of: settings.backendLogLevel),
                    onPick: { settings.backendLogLevel = BackendLogLevel.allCases[$0] }
                )
            }
            SettingsDivider()
            SettingsRow(
                "Config file", icon: "doc.badge.gearshape",
                detail: freshConfigMessage ?? "Replace the config file with a fresh default one"
            ) {
                Button("Create Fresh Config…") {
                    showFreshConfigConfirm = true
                    freshConfigMessage = nil
                }
            }
        }
    }

    /// Search page: what the launcher shows and where it looks. These apply at once (no Save).
    @ViewBuilder
    private var searchSection: some View {
        SettingsSectionTitle("Results")
        SettingsCard {
            LauncherSuggestionRows()
            SettingsDivider()
            KeepSearchSettingsRow()
            SettingsDivider()
            LearningSettingsRow()
            SettingsDivider()
            HiddenApplicationSettingsRow()
        }
        SettingsSectionTitle("Folders")
        SettingsCard {
            FileManagerSettingsRow()
            SettingsDivider()
            TerminalSettingsSection()
            SettingsDivider()
            ExternalDrivesSettingsRow()
        }
    }

    /// Removable path chips under a folder row; nothing when the list is empty.
    @ViewBuilder
    private func pathChips(_ paths: [String], onRemove: @escaping (String) -> Void) -> some View {
        if !paths.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 6) {
                            Text(path)
                                .lineLimit(1)
                            Button {
                                withAnimation(Motion.Insert.animation) { onRemove(path) }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .regular))
                        .foregroundStyle(themeStore.secondaryTextColor())
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(themeStore.liftColor(opacity: 0.1), in: Capsule())
                        .transition(Motion.Insert.transition)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The idle bar's round buttons: what each one opens (menu) and their order (arrows).
    var quickBubblesRow: some View {
        let slots = QuickBubbles.normalized(settings.quickBubbles)
        return SettingsRow(
            "Round buttons", icon: "circle.grid.2x2",
            detail: "What the buttons beside the empty search bar open, in order (⌘1–⌘\(slots.count))"
        ) {
            if slots != QuickBubbles.defaultCodes {
                Button("Reset") {
                    settings.quickBubbles = QuickBubbles.defaultCodes
                }
            }
        } below: {
            HStack(spacing: 8) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, code in
                    quickBubbleChip(slot: index, code: code, isLast: index == slots.count - 1)
                }
            }
        }
    }

    private func quickBubbleChip(slot: Int, code: String, isLast: Bool) -> some View {
        let kind = SpotlightKind(rawValue: code)
        return HStack(spacing: 4) {
            quickBubbleArrow("chevron.left", disabled: slot == 0) {
                settings.quickBubbles = QuickBubbles.moving(slot: slot, by: -1, in: settings.quickBubbles)
            }
            Menu {
                ForEach(QuickBubbles.choices, id: \.self) { choice in
                    let option = SpotlightKind(rawValue: choice)
                    Button {
                        settings.quickBubbles = QuickBubbles.setting(slot: slot, to: choice, in: settings.quickBubbles)
                    } label: {
                        Label(option?.label ?? choice, systemImage: choice == code ? "checkmark" : (option?.quickIcon ?? "circle"))
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: kind?.quickIcon ?? "circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(kind?.label ?? code)
                        .lineLimit(1)
                        .font(themeStore.uiFont(size: CGFloat(AppConstants.ThemeUI.fontSize - 2), weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(themeStore.secondaryTextColor())
                }
                .foregroundStyle(themeStore.fontColor())
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("⌘\(slot + 1): \(kind?.label ?? code) (click to change)")
            quickBubbleArrow("chevron.right", disabled: isLast) {
                settings.quickBubbles = QuickBubbles.moving(slot: slot, by: 1, in: settings.quickBubbles)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            themeStore.liftColor(opacity: Self.activeFillOpacity),
            in: RoundedRectangle(cornerRadius: themeStore.controlRadius, style: .continuous)
        )
    }

    private func quickBubbleArrow(_ symbol: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(themeStore.secondaryTextColor())
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.3 : 1)
    }

    func selectExcludedFolderPath() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(Motion.Insert.animation) {
                themeStore.addExcludedFolderPath(url: url)
            }
        }
    }

    func selectExtraScanDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            withAnimation(Motion.Insert.animation) {
                if let error = themeStore.addExtraFolderScanRoot(url: url) {
                    extraScanDirectoryMessage = error.message
                } else {
                    extraScanDirectoryMessage = nil
                }
            }
        }
    }

    func syncIndexingInputsFromSettings() {
        folderScanDepthInput = String(settings.folderScanDepth)
        folderScanLimitInput = String(settings.folderScanLimit)
    }

    func sanitizedNumericInput(_ value: String) -> String {
        String(value.filter(\.isNumber))
    }

    func applyFolderScanDepthInput() {
        guard let parsed = Int(folderScanDepthInput), parsed > 0 else {
            folderScanDepthInput = String(settings.folderScanDepth)
            return
        }
        settings.folderScanDepth = min(max(1, parsed), 12)
        folderScanDepthInput = String(settings.folderScanDepth)
    }

    func applyFolderScanLimitInput() {
        guard let parsed = Int(folderScanLimitInput), parsed > 0 else {
            folderScanLimitInput = String(settings.folderScanLimit)
            return
        }
        settings.folderScanLimit = min(max(500, parsed), 50_000)
        folderScanLimitInput = String(settings.folderScanLimit)
    }

    func runFreshConfigReset() {
        let ok = themeStore.regenerateFreshConfigFile()
        syncIndexingInputsFromSettings()
        freshConfigMessage = ok ? "Fresh config created" : "Failed to recreate config"
        if ok {
            NotificationCenter.default.post(name: .lookReloadConfigRequested, object: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            freshConfigMessage = nil
        }
    }

    /// A typed value outside its range: Save stays off until it is fixed.
    var hasInputError: Bool {
        folderScanDepthError != nil || folderScanLimitError != nil
    }
}

/// "Open folders in": Finder or any third-party file manager on this Mac. Writes
/// `file_manager=` to the config; used by ⏎ on folders, ⌘F and "Show in …".
struct FileManagerSettingsRow: View {
    @State private var choice = FileManagerApp.choice
    @State private var options = FileManagerApp.options()

    var body: some View {
        SettingsRow(
            "Open folders in", icon: "folder",
            detail: "Open folders or reveal an app. Automatic follows the system file viewer"
        ) {
            Picker("Open folders in", selection: Binding(
                get: { options.first { $0.value.caseInsensitiveCompare(choice) == .orderedSame }?.value ?? "auto" },
                set: { value in
                    if FileManagerApp.setChoice(value) { choice = value }
                }
            )) {
                ForEach(options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .onAppear {
            choice = FileManagerApp.choice
            options = FileManagerApp.options()
        }
    }
}

/// Reads and writes single `key=value` lines of ~/.lumio/config for the settings below
/// (the rest of the file is left exactly as it is), then asks the launcher to reload.
enum LauncherConfigFile {
    static func value(_ key: String) -> String? {
        let raw = (try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8)) ?? ""
        return ConfigFileLines.keyValues(raw)[key]
    }

    @discardableResult
    static func set(_ key: String, to value: String) -> Bool {
        let path = ConfigPathResolver.resolvedPath()
        let raw = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        var lines = ConfigFileLines.parse(raw)
        ConfigFileLines.upsert(&lines, key: key, value: value)
        do {
            try ConfigFileLines.render(lines).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return false
        }
        NotificationCenter.default.post(name: .lookReloadConfigRequested, object: nil)
        return true
    }
}

/// Plugged-in drives in folder search, with the drives connected right now named in the row.
struct ExternalDrivesSettingsRow: View {
    @State private var externalDrives = ExternalDrives.isEnabled
    @State private var driveNames: [String] = []

    /// "Connected now: T7, Backup" so it is obvious what the switch covers.
    private var drivesDetail: String {
        let base = "Find folders on plugged-in SSDs, USB sticks and SD cards, with nothing to set up. "
        return base + (driveNames.isEmpty ? "No drive is connected right now"
            : "Connected now: " + driveNames.joined(separator: ", "))
    }

    var body: some View {
        SettingsToggleRow(
            "Search external drives", icon: "externaldrive",
            detail: drivesDetail,
            isOn: Binding(
                get: { externalDrives },
                set: { value in
                    if LauncherConfigFile.set(ExternalDrives.configKey, to: value ? "true" : "false") {
                        externalDrives = value
                        ExternalDrives.isEnabled = value
                    }
                }
            )
        )
        .onAppear {
            externalDrives = LauncherConfigFile.value(ExternalDrives.configKey).map {
                !["false", "0", "no", "off"].contains($0.lowercased())
            } ?? true
            driveNames = ExternalDrives.mounted().map(\.name)
        }
    }
}

/// Recently used app suggestions for the empty search field.
struct LauncherSuggestionRows: View {
    @State private var suggestionsOnOpen = RecentItems.isEnabled

    var body: some View {
        SettingsToggleRow(
            "Suggestions when empty", icon: "sparkles",
            detail: "Show recently used apps before you type",
            isOn: Binding(
                get: { suggestionsOnOpen },
                set: { value in
                    if LauncherConfigFile.set(RecentItems.configKey, to: value ? "true" : "false") {
                        suggestionsOnOpen = value
                    }
                }
            )
        )
        .onAppear {
            suggestionsOnOpen = RecentItems.isEnabled
        }
    }
}

/// Settings ▸ Indexing ▸ Status: what the index holds, when it was updated, and Rebuild.
struct IndexStatusRows: View {
    @State private var stats: IndexStats?
    @State private var rebuilding = false
    @State private var outcome: String?

    private var countsLine: String {
        guard let stats else { return "Reading the index…" }
        guard stats.apps + stats.folders > 0 else { return "The index is empty. Press Rebuild" }
        var line = "\(stats.folders.formatted()) folders and \(stats.apps.formatted()) apps"
        if let updated = stats.updated {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            line += ". Updated \(formatter.localizedString(for: updated, relativeTo: Date()))"
        }
        return line
    }

    private var spotlightLine: String {
        switch stats?.spotlightOn {
        case true?: "On. Search indexed folders in your home directory, iCloud Drive and connected drives"
        case false?: "Off. Folder search uses Lumio's own index"
        case nil: stats == nil ? "Checking…" : "Couldn't check"
        }
    }

    var body: some View {
        SettingsRow("Lumio's index", icon: "square.stack.3d.up", detail: outcome ?? countsLine) {
            Button(rebuilding ? "Rebuilding…" : "Rebuild") { rebuild() }
                .disabled(rebuilding)
        }
        SettingsDivider()
        SettingsRow("macOS Spotlight index", icon: "magnifyingglass.circle", detail: spotlightLine) {
            EmptyView()
        }
        .task { await load() }
    }

    private func load() async {
        stats = await Task.detached(priority: .userInitiated) { IndexStats.read() }.value
    }

    /// Walks every indexed folder again and replaces the index (the same work a config
    /// reload does), then shows the new counts.
    private func rebuild() {
        rebuilding = true
        outcome = "Scanning your folders…"
        Task { @MainActor in
            let started = Date()
            let ok = await EngineBridge.shared.reloadConfigInBackground()
            await load()
            rebuilding = false
            let seconds = Date().timeIntervalSince(started)
            let count = stats.map { $0.apps + $0.folders } ?? 0
            outcome = ok
                ? "Rebuilt in \(String(format: "%.1f", seconds)) s: \(count.formatted()) items"
                : "The rebuild failed. Lumio keeps using the previous index"
        }
    }
}

/// Whether the Accessibility permission works, is off, or has gone stale (switch on, macOS
/// ignoring it), with a button that opens the dialog explaining it and offering the fix.
struct AccessibilityStatusRow: View {
    @State private var state: AccessibilityAccess.State?

    private var line: String {
        switch state {
        case nil: "Checking…"
        case .working?: "Working. Used for window search"
        case .off(listed: true)?: "Off. Lumio is in the macOS list, but its switch is off"
        case .off(listed: false)?: "Off. Window search requires this permission"
        case .stale(.allowedButRefused)?: "Stale: allowed, but macOS refuses Lumio until it is reopened"
        case .stale(.switchOnButIgnored)?: "Stale: the switch is on in System Settings, but macOS is ignoring it"
        case .stale(.workedBefore)?: "Probably stale: it worked before and has stopped"
        }
    }

    private var icon: String {
        switch state {
        case .working?: "checkmark.shield"
        case .stale?: "exclamationmark.shield"
        default: "shield"
        }
    }

    var body: some View {
        SettingsRow("Accessibility", icon: icon, detail: line) {
            Button(buttonTitle) { AccessibilityDoctor.shared.showStatus() }
                .fixedSize()
        }
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: AccessibilityDoctor.changed)) { _ in reload() }
        // Coming back from System Settings: the switch may have been flipped.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private var buttonTitle: String {
        switch state {
        case .stale?: "Fix…"
        case .off?: "Turn On…"
        default: "Check"
        }
    }

    private func reload() {
        AccessibilityDoctor.shared.check { state = $0 }
    }
}

/// How long the launcher keeps its previous search after hiding.
struct KeepSearchSettingsRow: View {
    @State private var seconds = KeepSearchSettingsRow.current()

    private static let choices: [(label: String, seconds: Int)] = [
        ("Off", 0), ("5 seconds", 5), ("30 seconds", 30), ("2 minutes", 120), ("5 minutes", 300),
        ("Always", AppConstants.Launcher.QueryRetention.never),
    ]

    private static func current() -> Int {
        guard let raw = LauncherConfigFile.value(AppConstants.Launcher.QueryRetention.configKey) else {
            return AppConstants.Launcher.QueryRetention.defaultSeconds
        }
        return QueryRetentionPolicy.resolveSeconds(from: [AppConstants.Launcher.QueryRetention.configKey: raw])
    }

    var body: some View {
        SettingsRow(
            "Keep last search", icon: "clock.arrow.circlepath",
            detail: "Close the launcher and reopen it within this time to find your text and tags still there, selected so typing replaces them"
        ) {
            Picker("Keep last search", selection: Binding(
                get: { seconds },
                set: { value in
                    if LauncherConfigFile.set(AppConstants.Launcher.QueryRetention.configKey, to: String(value)) {
                        seconds = value
                    }
                }
            )) {
                ForEach(Self.choices, id: \.seconds) { choice in
                    Text(choice.label).tag(choice.seconds)
                }
                // A number written by hand in the config file.
                if !Self.choices.contains(where: { $0.seconds == seconds }) {
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .onAppear { seconds = Self.current() }
    }
}

/// What Lumio has learned from your picks, with a button to forget it (Fluent's
/// "Reset learning data").
struct LearningSettingsRow: View {
    @State private var count = UsageLearning.shared.count

    var body: some View {
        SettingsRow(
            "Learned results", icon: "brain",
            detail: "Lumio remembers what you open for each search and offers it first. "
                + (count == 0 ? "Nothing learned yet" : "\(count) results remembered")
        ) {
            Button("Reset") {
                UsageLearning.shared.reset()
                count = 0
            }
            .disabled(count == 0)
        }
        .onAppear { count = UsageLearning.shared.count }
    }
}
