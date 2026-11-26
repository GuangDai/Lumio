import AppKit
import SwiftUI

// The panel stays within a fixed window frame while its contents animate.

struct SpotlightQuickItem: Identifiable {
    let kind: SpotlightKind
    let icon: String
    let label: String
    var id: SpotlightKind { kind }
}

struct SpotlightLauncherView: View {
    private typealias Metric = SpotlightSpec.Metric

    /// The idle bar's round buttons, as picked in Settings → Tabs (`quick_bubbles`).
    static var quickItems: [SpotlightQuickItem] {
        QuickBubbles.normalized(ThemeStore.shared.settings.quickBubbles)
            .compactMap(SpotlightKind.init(rawValue:))
            .map { SpotlightQuickItem(kind: $0, icon: $0.quickIcon, label: $0.label) }
    }

    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themeStore = ThemeStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Selection bar that slides between rows (matchedGeometryEffect).
    @Namespace private var selectionSpace

    // Search
    @State private var query = ""
    /// The text the rows on screen were found for (set with them in `publish`).
    @State private var shownQuery = ""
    /// Results currently shown. When the panel collapses, keep the old list so it fades
    /// out with the panel instead of vanishing first.
    /// `all` + `filter` and what the body derives from them, computed once per change
    /// instead of on every read (`results` alone is read ~40 times per render).
    @State private var list = SpotlightResultList()
    private var all: [SpotlightItem] {
        get { list.all }
        nonmutating set { list.all = newValue }
    }
    /// The sorted list for the sort menu, kept until the rows or the mode change.
    @State private var sortMemo = SortedResultsMemo()
    @State private var sel = 0
    /// Keeps the selection when publishing additional results for the same search.
    @State private var keepSelOnPublish: Int?
    private var filter: SpotlightKind? {
        get { list.filter }
        nonmutating set { list.filter = newValue }
    }
    /// Item whose actions are being viewed (⌘K).
    @State private var scope: SpotlightItem?
    /// Query before opening actions — restored on exit.
    @State private var scopeReturnQuery = ""
    /// Non-nil while the selected application's details page is open.
    @State private var selectedPreviewActionID: String?
    /// Text left in the field when the launcher was dismissed; restored on the next open.
    @State private var keptQuery = ""
    /// Tab open when the launcher was dismissed; reopened with `keptQuery`.
    @State private var keptBrowse: SpotlightKind?
    /// Active tag when the launcher was dismissed; restored with `keptQuery`.
    @State private var keptTag: SearchTag?
    /// A search was just brought back: select its text once the field has it, so typing replaces it.
    @State private var restoredQuery: String?
    /// How the list is ordered (footer button / ⌥S). Back to Default on every fresh open.
    @State private var sortMode: ResultSort = .relevance
    /// The tag browser (⌥T) runs as a command: a chip, a filter field and a list.
    private static let tagsCommand = "tags"
    private static let windowsBlockedRow = "windows|blocked"
    @State private var browse: SpotlightKind?
    @State private var tag: SearchTag?
    /// Recently used apps and pins are on screen.
    @State private var showingSuggestions = false
    /// `suggestions_on_open` in the config, read on each open.
    @State private var suggestionsEnabled = false
    /// Pinned results: listed first when the search field is empty.
    @ObservedObject private var pins = PinStore.shared
    /// Bundle paths of the apps running when the launcher opened (a dot marks their rows).
    @State private var runningApps: Set<String> = []
    @State private var scrollTarget: String?
    @State private var scrollWraps = false
    /// The core search in flight (nil = results already match the input).
    @State private var searchTask: Task<Void, Never>?
    /// Directory and browser matches added after the primary results.
    @State private var extrasTask: Task<Void, Never>?
    /// Enter pressed before results for the latest text arrived: open as soon as they do.
    @State private var activateWhenReady = false

    // Presentation
    /// Launcher is open (or opening). Set synchronously, not animated.
    @State private var isOpen = false
    @State private var dismissing = false
    @State private var shownScale = false
    @State private var shownAlpha = false
    @State private var launching = false
    @State private var expanded = false
    @State private var idle = false
    /// Round button Tab has moved to while idle (Enter opens it). nil = the field.
    @State private var quickFocus: Int?
    @State private var panelHeight = SpotlightSpec.Metric.barHeight
    /// Delay for the next height animation (see SpotlightMotion.expandAfterMerge).
    @State private var resizeDelay: Double = 0
    /// When the quick buttons started moving back into the bar.
    @State private var mergeStartedAt = Date.distantPast
    @State private var introUntil = Date.distantPast
    @State private var toastMsg: String?
    @State private var mouseGate = MouseGate()

    @StateObject private var processModel = ProcessFinderModel()
    /// Command currently open (`:kill`, `:emptytrash`, `:help`). nil = normal search.
    @State private var activeCommand: String?
    /// ⌘/ reopens the most recently used command, like the legacy launcher.
    @State private var lastCommand = SpotlightCommands.kill
    /// :kill — the first Enter only "arms" this process; the second Enter kills it.
    @State private var armedKillPID: Int32?
    /// Destructive actions (Move to Trash, Empty Trash, Hide from Results) need a second Enter:
    /// the key of the armed one.
    @State private var armedConfirm: String?
    /// :emptytrash — item count read when the command opens.
    @State private var trashCount: Int?
    /// Clear the kept search when hidden longer than `query_retention_seconds`.
    @State private var hiddenAt: Date?
    @State private var retentionSeconds = AppConstants.Launcher.QueryRetention.defaultSeconds
    @State private var keyMonitor = SpotlightKeyMonitor()

    @State private var idleTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?
    @State private var hiddenTrim = DelayedAction()
    @State private var toastTask: Task<Void, Never>?
    @State private var pidToRestore: pid_t?
    @FocusState private var isFocused: Bool

    // MARK: - Derived

    private var results: [SpotlightItem] {
        guard sortMode != .relevance, scope == nil, activeCommand == nil, !inProcessTab else { return list.results }
        return sortMemo.sorted(list, by: sortMode)
    }

    /// Pills for the groups present in the results (see `SpotlightResultList.kinds`).
    private var kinds: [SpotlightKind] { list.kinds }

    private var inProcessTab: Bool { browse == .process }

    private var isFinderPage: Bool {
        selectedPreviewActionID != nil && scope.map(Self.isFinder) == true
    }

    private var showsFinderResults: Bool {
        isFinderPage && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsActionDetails: Bool {
        selectedPreviewActionID != nil && !showsFinderResults
    }

    private var panelWidth: CGFloat { idle ? Metric.idleWidth : Metric.panelWidth }

    /// Keeps the actions pane usable even with just one or two results.
    private var rowSlots: Int { max(results.count, Metric.minRowsWithPreview) }

    /// Width of the list column; the rest of the panel is the preview.
    private let listPaneWidth: CGFloat = 300

    /// Item shown in the preview pane: the item whose actions are being viewed, otherwise the selected row.
    private var previewItem: SpotlightItem? {
        let selected = sel < results.count ? results[sel] : nil
        return showsFinderResults ? selected : scope ?? selected
    }

    private var targetPanelHeight: CGFloat {
        Metric.barHeight + (expanded ? SpotlightSpec.lowerHeight(rows: rowSlots) : 0)
    }

    /// Home: the empty field, showing pinned items and then suggestions as the usual list.
    private var isHome: Bool {
        showingSuggestions && query.isEmpty && browse == nil && tag == nil && scope == nil
            && activeCommand == nil
    }

    private var chipLabel: String? {
        scope?.name ?? activeCommand.map { $0 == Self.tagsCommand ? "Tags" : ":" + $0 }
            ?? (tag == nil ? browse?.label : nil)
    }

    /// Changes when the actions scope or the search tag changes.
    private var chipKey: String { "\(scope?.id ?? "")|\(tag?.keyword ?? "")" }

    private var placeholder: String {
        if isFinderPage { return "Find a folder or enter a path" }
        if let scope { return "Actions for \(scope.name)" }
        if activeCommand == Self.tagsCommand { return "Find a tag, then ⏎" }
        if let activeCommand { return SpotlightCommands.placeholder(for: activeCommand) }
        if let tag { return "Search \(tag.name)" }
        if let browse { return "Search in \(browse.label)" }
        return "Lumio Search"
    }

    private var introActive: Bool { !reduceMotion && Date() < introUntil }
    private var isDark: Bool { colorScheme == .dark }
    private var palette: SpotlightPalette { .of(colorScheme) }
    private var panelShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: themeStore.settings.cornerRadius(side: Metric.barHeight), style: .continuous)
    }

    /// Open pop springs vertically only; the width stays fixed. The launch zoom stays uniform.
    private var clusterScaleX: CGFloat {
        if reduceMotion { return 1 }
        return launching ? SpotlightMotion.launchScale : 1
    }

    private var clusterScaleY: CGFloat {
        if reduceMotion { return 1 }
        if launching { return SpotlightMotion.launchScale }
        return shownScale ? 1 : SpotlightMotion.appearScale
    }

    private var clusterOffset: CGFloat {
        reduceMotion || shownScale || launching ? 0 : SpotlightMotion.appearOffsetY
    }

    /// Reduce motion: every animation becomes a short fade.
    private func motion(_ animation: Animation) -> Animation {
        reduceMotion ? SpotlightMotion.reduced : animation
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Clicking outside the launcher closes it.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { point in
                    if !clusterContains(point) { hide() }
                }

            VStack(alignment: .leading, spacing: 14) {
                cluster
                    .scaleEffect(x: clusterScaleX, y: clusterScaleY, anchor: UnitPoint(x: 0.5, y: 0.3))
                    .offset(y: clusterOffset)
                    .opacity(shownAlpha ? 1 : 0)
                toastView
            }
            .padding(.leading, SpotlightWindowSizing.margin)
            .padding(.top, SpotlightWindowSizing.margin)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(modeHooks)
        .onChange(of: idle) { _, isIdle in
            if !isIdle { quickFocus = nil }
        }
        .onChange(of: query) {
            quickFocus = nil
            sel = 0
            filter = nil
            // Typed more after Enter: that Enter belonged to the old text, drop it.
            activateWhenReady = false
            refresh()
        }
        // Entering / leaving actions (⌘K) or a search tag (⇥ / ⌫) re-runs the search.
        .onChange(of: chipKey) { refresh() }
        .onChange(of: browse) {
            sel = 0
            filter = nil
            refresh()
        }
        .onChange(of: filter) { sel = 0 }
        .onChange(of: sel) { armedConfirm = nil }
        .onChange(of: targetPanelHeight) { _, height in
            // Panel height animates SEPARATELY: result rows change instantly, only the
            // bottom edge of the glass slides to its new position.
            let delay = resizeDelay
            resizeDelay = 0
            withAnimation(motion(SpotlightMotion.resize).delay(delay)) { panelHeight = height }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookToggleWindowRequested)) { _ in
            toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookHideLauncherRequested)) { _ in
            hide()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookOpenTabRequested)) { note in
            guard let raw = note.object as? String else { return }
            if raw.hasPrefix(HotKeyAction.tagPrefix) {
                openTagFromHotKey(String(raw.dropFirst(HotKeyAction.tagPrefix.count)))
            } else if let tab = SpotlightKind(rawValue: raw) {
                openFromHotKey(tab)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookActivateLauncherRequested)) { _ in
            show()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hide(restore: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookReloadConfigRequested)) { _ in
            reloadConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: .lookRefocusInputRequested)) { _ in
            if isOpen { focusField() }
        }
        // `lumio <mode>` arriving while this instance is already up.
        .onReceive(DistributedNotificationCenter.default().publisher(for: LaunchModes.deliveryNotification)) { note in
            if let text = note.object as? String { applyLaunchQuery(text) }
        }
        .onAppear {
            keyMonitor.start { handleKey($0) }
            loadRetention()
            // A cold `lumio <mode>`: this process launched to serve it.
            if let pending = LaunchModes.pendingQuery {
                LaunchModes.pendingQuery = nil
                DispatchQueue.main.async { applyLaunchQuery(pending) }
            }
        }
    }

    /// Hooks for the legacy launcher modes, split out of `body` so the compiler
    /// can type-check it.
    private var modeHooks: SpotlightModeHooks {
        SpotlightModeHooks(
            activeCommand: activeCommand,
            previewID: previewItem?.id,
            processModel: processModel,
            onCommandChange: { refresh() },
            onPreviewChange: {
                armedKillPID = nil
                armedConfirm = nil
                // Processes: load details (memory, user, command line) on selection.
                if let item = previewItem, item.kind == .process, let pid = item.pid {
                    processModel.loadDetail(pid: pid)
                }
            },
            // Rebuild the rows when the process snapshot arrives.
            onProcesses: {
                if activeCommand == SpotlightCommands.kill || (scope == nil && activeCommand == nil && inProcessTab) {
                    refresh()
                }
            }
        )
    }

    // MARK: - Panel and quick buttons

    private var cluster: some View {
        HStack(alignment: .top, spacing: Metric.quickGap) {
            panel
            if idle {
                ForEach(Array(Self.quickItems.enumerated()), id: \.element.id) { index, item in
                    quickButton(item, index: index)
                }
            }
        }
    }

    private var panel: some View {
        // Keep the lower panel laid out at full width while the search bar changes width.
        VStack(alignment: .leading, spacing: 0) {
            searchBar
            lower
                .frame(width: Metric.panelWidth)
        }
        .frame(width: panelWidth, height: panelHeight, alignment: .topLeading)
        .clipShape(panelShape)
        .contentShape(panelShape)
        .spotlightSurface(panelShape, isDark: isDark)
    }

    private func quickButton(_ item: SpotlightQuickItem, index: Int) -> some View {
        let focused = quickFocus == index
        let shape = RoundedRectangle(cornerRadius: themeStore.settings.cornerRadius(side: Metric.quickSize), style: .continuous)
        return Button {
            quickFocus = nil
            toggleBrowse(item.kind)
        } label: {
            Image(systemName: item.icon)
                .font(.system(size: 21, weight: focused ? .semibold : .regular))
                .foregroundStyle(browse == item.kind || focused ? HierarchicalShapeStyle.primary : .secondary)
                .modifier(SpotlightPopIn(animation: reduceMotion ? nil : motion(SpotlightMotion.quickIcon(index))))
                .frame(width: Metric.quickSize, height: Metric.quickSize)
                .contentShape(shape)
                // Tab focus (idle only): a soft fill + ring, like the selected row.
                .background(shape.fill(palette.pillOn).opacity(focused ? 1 : 0))
                .overlay(shape.strokeBorder(Color.primary.opacity(focused ? 0.35 : 0), lineWidth: 1.5))
                .scaleEffect(focused ? 1.06 : 1)
                .animation(motion(SpotlightMotion.chip), value: focused)
        }
        .buttonStyle(.plain)
        .spotlightSurface(shape, isDark: isDark)
        .help("\(item.label)  ⌘\(index + 1)")
        .accessibilityLabel(item.label)
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 15) {
            Image(systemName: showsActionDetails && !isFinderPage ? "ellipsis.circle" : "magnifyingglass")
                .font(.system(size: Metric.searchIconSize, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)

            if let chipLabel {
                Text(chipLabel)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(palette.pillOn, in: Capsule())
                    // The chip takes its space immediately while the text slides gradually, so the two have to
                    // be out of step or the text would overlap the chip: on enter, wait for the text to slide away
                    // before showing; on exit, dissolve quickly before the text comes back.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .leading)
                            .combined(with: .opacity)
                            .animation(motion(SpotlightMotion.chip).delay(0.1)),
                        removal: .opacity.animation(.easeOut(duration: 0.08))
                    ))
            }

            if scope == nil, activeCommand == nil, let tag {
                HStack(spacing: 5) {
                    Image(systemName: tag.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(tag.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(palette.pillOn, in: Capsule())
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.6, anchor: .leading)
                        .combined(with: .opacity)
                        .animation(motion(SpotlightMotion.chip).delay(0.1)),
                    removal: .opacity.animation(.easeOut(duration: 0.08))
                ))
            }

            // The legacy launcher's input field: the caret SLIDES to its new position while typing (still
            // while typing, blinking when paused) instead of jumping per character.
            // Enter goes through onSubmit (respecting an input method that is committing text); other
            // navigation keys: see handleKey (local key monitor).
            if showsActionDetails, !isFinderPage {
                Spacer(minLength: 0)
            } else {
                SmoothCaretTextField(
                    text: $query,
                    placeholder: placeholder,
                    isFocused: $isFocused,
                    font: .systemFont(ofSize: Metric.queryFontSize),
                    onSubmit: { activate() }
                )
                .frame(maxWidth: .infinity)
            }

            // What Tab would do right now ("press TAB to search in Bookmarks"), like Fluent Search.
            if let tabHint {
                // fixedSize: the text field is greedy and would otherwise squeeze this to nothing.
                Text(tabHint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, Metric.barPadding)
        .frame(height: Metric.barHeight)
    }

    // MARK: - Lower part (always built; the panel clips it to the animating height)

    private var lower: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
                .padding(.horizontal, 14)
            resultsArea
            footer
                .frame(height: Metric.footerHeight)
        }
        .frame(height: SpotlightSpec.lowerHeight(rows: rowSlots), alignment: .top)
        .opacity(expanded ? 1 : 0)
        .animation(motion(expanded ? SpotlightMotion.contentIn : SpotlightMotion.contentOut), value: expanded)
        .allowsHitTesting(expanded)
    }

    /// Filter pills, then the list on the left and the preview on the right.
    @ViewBuilder
    private var resultsArea: some View {
        if showsActionDetails {
            previewPane
                .frame(height: Metric.pillsHeight + SpotlightSpec.listHeight(rows: rowSlots))
                .padding(.top, Metric.lowerTopInset)
        } else {
            pillsRow
                .frame(height: Metric.pillsHeight)
                .padding(.top, Metric.lowerTopInset)
            HStack(spacing: 0) {
                listView
                    .frame(width: listPaneWidth)
                Rectangle()
                    .fill(palette.divider)
                    .frame(width: 1)
                    .padding(.vertical, 8)
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: SpotlightSpec.listHeight(rows: rowSlots))
        }
    }

    /// Right half of the panel: preview of the selected row (or the item whose actions are open).
    private var previewPane: some View {
        ZStack(alignment: .topLeading) {
            if let item = previewItem {
                SpotlightPreviewView(
                    item: item,
                    chips: previewChips(for: item),
                    actions: previewActions(for: item),
                    selectedActionID: showsActionDetails ? selectedPreviewActionID : nil,
                    processDetail: item.pid.flatMap { processModel.details[$0] },
                    processCPU: item.pid.flatMap { processModel.cpu[$0] },
                    measuringCPU: item.pid.map { processModel.measuringCPU.contains($0) } ?? false
                )
                .id(item.id)
            }
        }
        // Changing rows swaps the preview content IMMEDIATELY (like the legacy launcher): cross-fading
        // two selections makes their text overlap. The sliding selection bar is enough.
        .animation(nil, value: previewItem?.id)
    }

    private var pillsRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Metric.pillGap) {
                    pillButton(label: "All", active: filter == nil && !inProcessTab) {
                        if inProcessTab { leaveProcessTab() } else { filter = nil }
                    }
                        .id(Self.allPillID)
                    ForEach(kinds) { kind in
                        pillButton(label: kind.label, active: filter == kind) {
                            filter = (filter == kind) ? nil : kind
                        }
                        .id(kind.rawValue)
                    }
                    if processTabVisible || inProcessTab {
                        pillButton(label: SpotlightKind.process.label, active: inProcessTab) {
                            toggleBrowse(.process)
                        }
                        .id(SpotlightKind.process.rawValue)
                    }
                }
                .padding(.horizontal, 14)
            }
            // Tab can land on a pill that is scrolled out of view: bring it in.
            .onChange(of: filter) { _, kind in
                withAnimation(motion(SpotlightMotion.chip)) {
                    proxy.scrollTo(kind?.rawValue ?? Self.allPillID)
                }
            }
            .onChange(of: browse) { _, tab in
                let id = tab == .process ? SpotlightKind.process.rawValue : Self.allPillID
                withAnimation(motion(SpotlightMotion.chip)) {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private static let allPillID = "pill-all"

    private var processTabVisible: Bool {
        !themeStore.settings.hiddenTabs.contains(SpotlightKind.process.rawValue)
    }

    /// Tab / Shift+Tab cycles through the result filters and the Processes tab.
    private func cycleFilter(_ step: Int) {
        // Only the group pills the user can actually see. With the field emptied the panel is
        // collapsed but `all` still holds the old results (kept so they fade out), and their
        // groups would otherwise be invisible stops: Tab seemed to do nothing for a few presses.
        let groups = expanded && !inProcessTab ? kinds : []
        var options: [SpotlightKind?] = [nil] + groups
        if processTabVisible { options.append(.process) }
        let current = inProcessTab ? (options.firstIndex(of: browse) ?? 0) : (options.firstIndex(of: filter) ?? 0)
        let next = options[(current + step + options.count) % options.count]
        if next == .process {
            filter = nil
            withAnimation(motion(SpotlightMotion.chip)) { scope = nil; tag = nil; browse = .process }
        } else {
            if inProcessTab { leaveProcessTab() }
            filter = next
        }
    }

    /// Opens a tab with text in the field (for example, from `lumio <mode>`).
    private func openTab(_ tab: SpotlightKind?, text: String) {
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            selectedPreviewActionID = nil
            activeCommand = nil
            filter = nil
            tag = nil
            browse = tab
        }
        query = text
        focusField()
    }

    private func leaveProcessTab() {
        withAnimation(motion(SpotlightMotion.chip)) { browse = nil }
    }

    private func pillButton(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            focusField()
        } label: {
            Text(label)
                .font(.system(size: 14.5, weight: active ? .medium : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(active ? palette.pillOn : palette.pill, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var listView: some View {
        Group {
            if results.isEmpty {
                Text("No results for “\(shownQuery)”.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                resultRow(item, selected: index == sel)
                                    .modifier(SpotlightDragSource(item: item))
                                    .id(item.id)
                                    .modifier(SpotlightRiseIn(
                                        animation: introActive ? motion(SpotlightMotion.rowRise(index)) : nil
                                    ))
                                    .transition(SpotlightMotion.rowSwap)
                                    .onTapGesture {
                                        // Mouse click: open exactly the row being seen, no waiting.
                                        sel = index
                                        run(item)
                                    }
                                    .onHover { hovering in
                                        // Ignore hovers caused by the list changing under a stationary
                                        // pointer — only accept them when the mouse actually moves.
                                        if hovering, mouseGate.moved(), sel != index {
                                            withAnimation(motion(SpotlightMotion.selectionGlide)) { sel = index }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, Metric.listInsetTop)
                        .padding(.bottom, Metric.listInsetBottom)
                    }
                    .spotlightThinScroller(isDark: isDark)
                    .onChange(of: scrollTarget) { _, target in
                        // Scroll along with the selection bar, in step with its slide.
                        guard let target else { return }
                        if scrollWraps {
                            // Top <-> bottom: jump, so rows sliding under a still pointer can't steal the selection.
                            mouseGate.reset()
                            proxy.scrollTo(target, anchor: sel == 0 ? .top : .bottom)
                        } else {
                            withAnimation(motion(SpotlightMotion.selectionGlide)) { proxy.scrollTo(target) }
                        }
                    }
                }
            }
        }
    }

    /// The row skips drawing its body when its inputs stay the same.
    private func resultRow(_ item: SpotlightItem, selected: Bool) -> some View {
        SpotlightRow(
            item: item,
            selected: selected,
            armed: armedKillPID != nil && item.pid == armedKillPID,
            running: item.kind == .app && (item.iconPath ?? item.target).map(runningApps.contains) == true,
            highlight: highlightWords(for: item),
            palette: palette,
            reduceMotion: reduceMotion,
            namespace: selectionSpace
        )
        .equatable()
    }

    /// Typed words to show in bold in `item`'s title (Fluent Search-style).
    private func highlightWords(for item: SpotlightItem) -> [String] {
        guard scope == nil, activeCommand == nil,
              [.app, .folder, .url, .tab, .setting].contains(item.kind)
        else { return [] }
        // The text these rows were found for, not the live field: a keystroke then leaves the
        // rows alone (they skip their body) until its own results land, and stale rows never
        // bold letters they don't match.
        return shownQuery.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            // Settings, one click away (also ⌘⇧Space), pinned to the leading edge of the footer.
            FooterIconButton(symbol: "gearshape", help: "Lumio Settings  ⌘⇧Space") { openSettings() }
            // One line only: when the bar is crowded the hint is cut, never wrapped.
            Text(footerHint)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
            Text(selectedPreviewActionID == nil ? "esc close" : "esc back")
                .fixedSize()
            Spacer(minLength: 8)
            if !showsActionDetails, !results.isEmpty {
                Text("\(results.count) \(results.count == 1 ? "result" : "results")")
                    .fixedSize()
            }
            if !showsActionDetails, sortMode != .relevance {
                Text("by \(sortMode.label.lowercased())")
                    .fixedSize()
            }
            if !showsActionDetails {
                FooterIconButton(symbol: "arrow.up.arrow.down", help: "Sort results  ⌥S") { showSortMenu() }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 18)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(palette.divider)
                .frame(height: 1)
        }
    }

    private var footerHint: String {
        if showsActionDetails { return "↑↓ choose action   ⏎ run" }
        if showsFinderResults { return "↑↓ select   ⏎ open in Finder   ⌘T open in Terminal" }
        if scope != nil { return "↑↓ select   ⏎ run action" }
        if tag != nil { return "↑↓ select   ⏎ open   ⌫ leave tag" }
        if showingSuggestions, query.isEmpty, browse == nil {
            return "Recent   ↑↓ select   ⏎ open   ⌥T all tags"
        }
        switch activeCommand {
        case Self.tagsCommand: return "↑↓ select   ⏎ use tag   ⌫ leave"
        case SpotlightCommands.kill: return "⏎ select, ⏎ again to force quit"
        case SpotlightCommands.emptyTrash: return "⏎ twice to empty   esc cancel"
        default: break
        }
        let mode = browse.map { SpotlightMode.forTab($0, query: query) ?? .search } ?? SpotlightMode.parse(query)
        return "↑↓ select   " + mode.footerHint
    }

    // MARK: - Toast

    @ViewBuilder
    private var toastView: some View {
        if let toastMsg {
            Text(toastMsg)
                .font(.system(size: 14.5, weight: .medium))
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .spotlightSurface(Capsule(), isDark: isDark)
                .frame(width: Metric.panelWidth)
                .transition(.offset(y: -12).combined(with: .opacity))
        }
    }

    private func toast(_ msg: String) {
        withAnimation(motion(SpotlightMotion.toast)) { toastMsg = msg }
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1900))
            guard !Task.isCancelled else { return }
            withAnimation(motion(SpotlightMotion.toast)) { toastMsg = nil }
        }
    }

    // MARK: - Search + state

    /// Text / browsed group / action mode changed: search again. The list changes WITHOUT
    /// animation (like a native list); only the panel expand/collapse and glass droplets move.
    private func refresh() {
        searchTask?.cancel()
        searchTask = nil
        extrasTask?.cancel()
        extrasTask = nil
        // Bring the quick buttons back into the bar as soon as there is input.
        pokeIdle()

        if selectedPreviewActionID != nil {
            showingSuggestions = false
            if showsFinderResults {
                refreshResults(SpotlightRequest(text: query, browse: .folder))
            } else if !expanded {
                setExpanded(true)
            }
            return
        }
        if let scope {
            publish(SpotlightBackend.actionRows(for: scope, filter: query))
            return
        }
        if let activeCommand {
            switch activeCommand {
            case SpotlightCommands.kill: publish(SpotlightModeRows.killTargets(processModel, term: query))
            case SpotlightCommands.emptyTrash: publish(SpotlightModeRows.emptyTrash(itemCount: trashCount))
            case SpotlightCommands.help: publish(SpotlightModeRows.help(query))
            case Self.tagsCommand: publish(SpotlightBackend.tagBrowserRows(query))
            default: publish([])
            }
            return
        }
        let launch = SpotlightMode.tab(fromLaunchQuery: query)
        if browse == nil, tag == nil, let argument = FolderAddressQuery.changeDirectoryArgument(in: query) {
            if argument.isEmpty {
                publish([SpotlightItem(
                    id: "cd|hint", name: "Type a directory after cd", kind: .help,
                    colors: "#a7aeb8,#5e6670", symbol: "folder"
                )])
            } else {
                refreshResults(SpotlightRequest(text: argument, browse: .folder))
            }
            return
        }
        if let tag {
            refreshTag(tag)
            return
        }
        if let browse, let mode = SpotlightMode.forTab(browse, query: query) {
            _ = refreshMode(mode)
            return
        }
        if browse == nil, refreshMode(SpotlightMode.parse(query)) { return }

        let request = launch.tab == .folder && browse == nil
            ? SpotlightRequest(text: launch.text, browse: .folder)
            : SpotlightRequest(text: query, browse: browse)
        guard !request.isEmpty else {
            if suggestionsEnabled, isOpen {
                refreshSuggestions()
                return
            }
            // Empty field: collapse the panel. `all` is kept so the list fades out with the panel.
            activateWhenReady = false
            showingSuggestions = false
            if expanded { setExpanded(false) }
            return
        }
        showingSuggestions = false
        refreshResults(request)
    }

    private func refreshResults(_ request: SpotlightRequest) {
        showingSuggestions = false
        let term = request.term
        let allowsFolders = request.browse == nil || request.browse == .folder
        let excludedFolders = themeStore.excludedFolderPaths
        if allowsFolders, FolderAddressQuery.isLiteralAddress(term) {
            publish(SpotlightBackend.directFolder(for: term, excluding: excludedFolders).map { [$0] } ?? [])
            return
        }
        // First keystroke searches immediately; further typing waits a short beat.
        let debounce: Duration = expanded ? SpotlightBackend.debounce : .zero
        searchTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            // Explicit web addresses stay directly openable; other slash-separated input
            // goes unchanged to the directory matcher.
            let relativePath = allowsFolders && term.contains("/") && !term.hasPrefix(">")
                && !term.lowercased().hasPrefix(AppConstants.Launcher.QueryPrefix.apps)
                && (request.browse == .folder || EngineBridge.shared.classifyURL(query: term) == nil)
            let coreRequest = relativePath ? SpotlightRequest(text: term, browse: .folder) : request
            let engineQuery = SpotlightBackend.engineQuery(for: coreRequest)
            let wantsBrowserRows = coreRequest.browse == nil && term.count >= 2
            let wantsBookmarks = wantsBrowserRows && term.count >= 3 && !term.hasPrefix(">")
            let wantsFolders = allowsFolders && !relativePath && !term.contains("/") && !term.contains("\"")
                && !term.hasPrefix(">") && (coreRequest.browse == .folder || term.count >= 3)
            let lookup: Task<SpotlightBackend.Extras, Never>? = wantsBookmarks || wantsFolders
                ? Task.detached(priority: .userInitiated) {
                    let bookmarks = wantsBookmarks ? BrowserBookmarks.search(term, limit: 2) : []
                    let history = wantsBookmarks ? BrowserHistory.search(term, limit: 3) : []
                    let folders = wantsFolders ? await SpotlightFolders.search(
                        term: term, scope: nil, limit: 25, excluding: excludedFolders
                    ) : []
                    return SpotlightBackend.Extras(
                        folders: folders, bookmarks: bookmarks, history: history,
                        blocked: wantsBookmarks && BrowserHistory.isBlocked()
                    )
                } : nil
            let (found, tabs, windows) = await Task.detached(priority: .userInitiated) {
                let found = EngineBridge.shared.search(query: engineQuery.text, limit: engineQuery.limit)
                let tabs = wantsBrowserRows
                    ? BrowserTabs.shared.search(term, limit: SpotlightBackend.tabLimit)
                    : []
                let windows = wantsBrowserRows && term.count >= 3
                    ? OpenWindows.shared.search(term, limit: 3, skipping: { BrowserTabs.isBrowser(appPath: $0) })
                    : []
                return (found, tabs, windows)
            }.value
            guard !Task.isCancelled else {
                lookup?.cancel()
                return
            }
            let initial = SpotlightBackend.rows(from: found, for: coreRequest, tabs: tabs, windows: windows)
            if coreRequest.browse == .folder, let lookup {
                let extras = await withTaskCancellationHandler {
                    await lookup.value
                } onCancel: {
                    lookup.cancel()
                }
                guard !Task.isCancelled else { return }
                searchTask = nil
                publish(SpotlightBackend.addingExtras(extras, term: term, to: initial))
                return
            }
            searchTask = nil
            publish(initial)
            guard let lookup, !dismissing else {
                lookup?.cancel()
                return
            }
            extrasTask = Task { @MainActor in
                await withTaskCancellationHandler {
                    let extras = await lookup.value
                    guard !Task.isCancelled else { return }
                    republish(SpotlightBackend.addingExtras(extras, term: term, to: all))
                    extrasTask = nil
                } onCancel: {
                    lookup.cancel()
                }
            }
        }
    }

    /// Closes the launcher and opens the Settings window.
    private func openSettings() {
        hide(restore: false)
        SettingsWindowController.shared.show()
    }

    /// Replaces the rows of the SAME search with a fuller list, keeping the selection where it is.
    private func republish(_ rows: [SpotlightItem]) {
        guard rows.map(\.id) != all.map(\.id) || rows.map(\.meta) != all.map(\.meta) else { return }
        keepSelOnPublish = sel
        publish(rows)
        keepSelOnPublish = nil
    }

    /// Show the local results for the active tag.
    private func refreshTag(_ tag: SearchTag) {
        showingSuggestions = false
        if tag.folders?.folders.isEmpty == true {
            refreshResults(SpotlightRequest(text: query, browse: .folder))
            return
        }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let debounce: Duration = expanded ? SpotlightBackend.debounce : .zero
        let excludedFolders = themeStore.excludedFolderPaths
        searchTask = Task { @MainActor in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
                guard !Task.isCancelled else { return }
            }
            if let folderScope = tag.folders {
                let rows: [SpotlightItem]
                if FolderAddressQuery.isLiteralAddress(term) {
                    rows = SpotlightBackend.directFolder(for: term, excluding: excludedFolders).map { [$0] } ?? []
                } else if term.contains("/") {
                    let request = SpotlightRequest(text: term, browse: .folder)
                    let engineQuery = SpotlightBackend.engineQuery(for: request)
                    let found = await Task.detached(priority: .userInitiated) {
                        EngineBridge.shared.search(query: engineQuery.text, limit: engineQuery.limit)
                    }.value
                    rows = SpotlightBackend.rows(from: found, for: request).filter { item in
                        guard let path = item.target else { return false }
                        return folderScope.folders.isEmpty || folderScope.folders.contains { scopePath in
                            let prefix = (scopePath as NSString).standardizingPath
                            return path != prefix && path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
                        }
                    }
                } else {
                    let folders = await SpotlightFolders.search(
                        term: term, scope: folderScope, limit: SpotlightBackend.resultLimit, excluding: excludedFolders
                    )
                    rows = SpotlightBackend.folderRows(folders)
                }
                guard !Task.isCancelled else { return }
                searchTask = nil
                publish(rows)
                return
            }
            if tag.windows {
                // `windows` ⇥: every open window, or the ones matching the text.
                searchTask = nil
                guard OpenWindows.isTrusted else {
                    // Off or stale? Word the row for what was last found, then look again.
                    let stale: Bool = if case .stale = AccessibilityDoctor.shared.lastState { true } else { false }
                    publish([SpotlightItem(
                        id: Self.windowsBlockedRow,
                        name: stale ? "The Accessibility permission has gone stale"
                            : "Window search needs the Accessibility permission",
                        kind: .setting, colors: stale ? "#ff8a80,#d6453a" : "#ffb36e,#f06a2e",
                        meta: stale ? "⏎ see what happened and reset it" : "⏎ check it and turn it on for Lumio",
                        target: OpenWindows.settingsURL, symbol: stale ? "exclamationmark.lock.fill" : "lock.fill"
                    )])
                    if AccessibilityDoctor.shared.lastState == nil {
                        AccessibilityDoctor.shared.check { _ in
                            if isOpen, !dismissing, self.tag?.windows == true { refresh() }
                        }
                    }
                    return
                }
                let rows = OpenWindows.shared.search(term, limit: SpotlightBackend.resultLimit)
                    .map(SpotlightBackend.item(from:))
                publish(rows.isEmpty ? [SpotlightItem(
                    id: "tag|empty", name: term.isEmpty ? "No open windows found" : "No window matches “\(term)”",
                    kind: .help, colors: "#a7aeb8,#5e6670", meta: tag.name, symbol: tag.symbol
                )] : rows)
                return
            }
            if tag.settingsOnly {
                // `settings` ⇥: System Settings panes (they live among the apps in the core).
                let found = await Task.detached(priority: .userInitiated) {
                    EngineBridge.shared.search(query: "a\"" + term, limit: 120)
                }.value
                guard !Task.isCancelled else { return }
                searchTask = nil
                let rows = found.compactMap(SpotlightBackend.item(from:)).filter { $0.kind == .setting }
                publish(rows.isEmpty ? [SpotlightItem(
                    id: "tag|empty", name: term.isEmpty ? "Type to find a setting" : "No settings match “\(term)”",
                    kind: .help, colors: "#a7aeb8,#5e6670", meta: tag.name, symbol: tag.symbol
                )] : rows)
                return
            }
            if tag.bookmarks != nil || tag.history {
                // `bookmark` ⇥ / a bookmark folder's tag: bookmarks, folder order when empty.
                // `history` ⇥: the whole history, most visited and recent first. `browser` ⇥: both.
                let scope = tag.bookmarks
                let wantsHistory = tag.history
                let (bookmarks, pages) = await Task.detached(priority: .userInitiated) {
                    (scope.map { BrowserBookmarks.search(term, folder: $0.folder, limit: SpotlightBackend.resultLimit) } ?? [],
                     wantsHistory ? BrowserHistory.search(term.isEmpty ? "http" : term, limit: 30) : [])
                }.value
                guard !Task.isCancelled else { return }
                searchTask = nil
                let listed = Set(bookmarks.map(\.url))
                let rows = SpotlightBackend.bookmarkRows(bookmarks)
                    + SpotlightBackend.historyRows(pages.filter { !listed.contains($0.url) })
                if rows.isEmpty, BrowserHistory.isBlocked() {
                    publish([SpotlightBackend.blockedRow])
                    return
                }
                publish(rows.isEmpty ? [SpotlightItem(
                    id: "tag|empty", name: term.isEmpty ? "Nothing found in your browsers" : "Nothing matches “\(term)”",
                    kind: .help, colors: "#a7aeb8,#5e6670",
                    meta: "Chrome, Edge, Brave, Arc and Vivaldi", symbol: tag.symbol
                )] : rows)
                return
            }
            let (tabs, history) = await Task.detached(priority: .userInitiated) {
                (SpotlightBackend.tabs(for: tag, matching: term),
                 BrowserHistory.recent(for: tag, matching: term, limit: 12))
            }.value
            guard !Task.isCancelled else { return }
            searchTask = nil
            publish(SpotlightBackend.tagRows(tag: tag, tabs: tabs, history: history))
        }
    }

    /// Empty field: recently used apps and pins, so ⏎ can open a result
    /// before you type. Off with `suggestions_on_open=false`.
    private func refreshSuggestions() {
        searchTask = Task { @MainActor in
            let recent = await RecentItems.recent(limit: 5)
            guard !Task.isCancelled else { return }
            searchTask = nil
            // Your pins first, then what you use most, without repeating a pinned item.
            let pinned = pins.items.filter { item in
                guard let target = item.target, target.hasPrefix("/") else { return true }
                if item.kind == .folder {
                    return SpotlightBackend.isBrowsableFolder(at: URL(fileURLWithPath: target),
                                                            excluding: themeStore.excludedFolderPaths)
                }
                return FileManager.default.fileExists(atPath: target)
            }
            let pinnedTargets = Set(pinned.compactMap { $0.target?.lowercased() })
            let suggested = SpotlightBackend.suggestionRows(apps: recent)
                .filter { !pinnedTargets.contains(($0.target ?? "").lowercased()) }
            let rows = pinned + suggested
            guard !rows.isEmpty else {
                showingSuggestions = false
                if expanded { setExpanded(false) }
                return
            }
            showingSuggestions = true
            publish(rows)
        }
    }

    /// Selects a tag from an exact keyword, a hint, or the current result.
    private func tagCandidate(keyword: String? = nil) -> (tag: SearchTag, rest: String)? {
        guard scope == nil, activeCommand == nil, !inProcessTab, tag == nil else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let keyword, let named = SearchTags.tag(forKeyword: keyword) {
            let split = SearchTags.split(trimmed)
            return (named, split?.tag.keyword == named.keyword ? split?.rest ?? "" : "")
        }
        guard !trimmed.isEmpty else { return nil }
        if let split = SearchTags.split(trimmed) { return split }
        if expanded, sel < results.count, results[sel].kind == .tagHint,
           let hint = results[sel].payload,
           let named = SearchTags.tag(forKeyword: hint)
        {
            return (named, "")
        }
        if expanded, sel < results.count, let context = Self.contextTag(for: results[sel]) {
            return (context, "")
        }
        return nil
    }

    /// The local browser results associated with the selected item.
    private static func contextTag(for item: SpotlightItem) -> SearchTag? {
        switch item.kind {
        case .folder:
            return item.target.map(SearchTag.folder)
        case .tab, .url:
            guard let target = item.tab?.url ?? item.target,
                  let host = URLComponents(string: target)?.host, target.hasPrefix("http")
            else { return nil }
            return .site(host)
        default:
            return nil
        }
    }

    private static func isFinder(_ item: SpotlightItem) -> Bool {
        item.kind == .app && item.target == AppConstants.Launcher.Finder.appPath
    }

    private var tabHint: String? {
        guard expanded, isOpen, scope == nil else { return nil }
        if let item = previewItem, Self.isFinder(item) { return "press TAB for Finder" }
        if let candidate = tagCandidate() {
            var name = candidate.tag.name
            if name.count > 24 { name = String(name.prefix(23)) + "…" }
            if candidate.tag.mode != nil { return "press TAB for \(name)" }
            return "press TAB to filter by \(name)"
        }
        if let item = previewItem, item.kind == .app, !previewActions(for: item).isEmpty {
            return "press TAB for details"
        }
        return nil
    }

    /// Tab (or ⏎ on a hint row): lock the tag in as a chip. False when nothing applies.
    private func enterTag(keyword: String? = nil) -> Bool {
        guard let (found, rest) = tagCandidate(keyword: keyword) else { return false }
        // A launcher tab is opened directly.
        if let raw = found.mode, let kind = SpotlightKind(rawValue: raw) {
            openTab(kind, text: rest)
            return true
        }
        lockTag(found, rest: rest)
        return true
    }

    private func lockTag(_ found: SearchTag, rest: String) {
        withAnimation(motion(SpotlightMotion.chip)) {
            filter = nil
            browse = nil
            scope = nil
            selectedPreviewActionID = nil
            tag = found
        }
        query = rest
        if found.domain != nil {
            BrowserTabs.shared.refresh(minInterval: 0.5) {
                if isOpen, !dismissing, tag != nil { refresh() }
            }
        }
        focusField()
    }

    // MARK: - Quick actions

    private func pinAction(for item: SpotlightItem) -> PreviewAction {
        let pinned = pins.isPinned(item)
        return PreviewAction(
            id: "pin", label: pinned ? "Unpin from Home" : "Pin to Home",
            symbol: pinned ? "pin.slash" : "pin", shortcut: "⌘⇧P"
        ) { toggleHomePin(item) }
    }

    /// ⌘⇧P / Pin action: keeps the result on the Home screen.
    private func toggleHomePin(_ item: SpotlightItem) {
        switch pins.toggle(item) {
        case true?: toast("Pinned \(item.name) to Home")
        case false?:
            toast("Unpinned \(item.name)")
            if isHome { refresh() }
        case nil: toast("This result can't be pinned")
        }
    }

    /// Tag chips for the detail card, like Fluent Search's: click one to narrow to it.
    private func previewChips(for item: SpotlightItem) -> [PreviewChip] {
        guard scope == nil || selectedPreviewActionID != nil, activeCommand == nil else { return [] }
        func lock(_ tag: SearchTag?) {
            if let tag { lockTag(tag, rest: "") }
        }
        switch item.kind {
        case .folder:
            guard let path = item.target else { return [] }
            return [PreviewChip(id: "folder", label: "Subfolders", symbol: "folder") { lock(.folder(path)) }]
        case .url, .tab:
            guard let link = item.tab?.url ?? item.target, let host = URLComponents(string: link)?.host else { return [] }
            var chips = [PreviewChip(id: "site", label: FaviconStore.normalize(host), symbol: "globe") { lock(.site(host)) }]
            if item.id.hasPrefix("bookmark|") {
                chips.append(PreviewChip(id: "bookmark", label: "bookmark", symbol: "bookmark") {
                    lock(SearchTags.tag(forKeyword: "bookmark"))
                })
            } else {
                chips.append(PreviewChip(id: "history", label: "history", symbol: "clock.arrow.circlepath") {
                    lock(SearchTags.tag(forKeyword: "history"))
                })
            }
            chips.append(PreviewChip(id: "browser", label: "browser", symbol: "star") {
                lock(SearchTags.tag(forKeyword: "browser"))
            })
            return chips
        case .app:
            return [PreviewChip(id: "apps", label: "apps", symbol: "square.grid.2x2") {
                openTab(.app, text: "")
            }]
        default:
            return []
        }
    }

    /// The actions listed in the preview pane for `item`, like Fluent Search's result actions:
    /// the first is what ⏎ does.
    private func previewActions(for item: SpotlightItem) -> [PreviewAction] {
        guard scope == nil || selectedPreviewActionID != nil, activeCommand == nil else { return [] }
        let manager = FileManagerApp.name
        func finish(_ outcome: SpotlightOpener.Outcome) {
            switch outcome {
            case .launched: hide(restore: false, launched: true)
            case .message(let text): toast(text)
            }
        }
        switch item.kind {
        case .app:
            guard let path = item.target, path.hasPrefix("/"),
                  !BrowserOpening.isBlockedApplication(URL(fileURLWithPath: path)) else { return [] }
            let running = PreviewFacts.isRunning(path)
            var list = [PreviewAction(
                id: "open", label: running ? "Switch to App" : "Open",
                symbol: running ? "arrow.left.arrow.right" : "arrow.up.forward.app", shortcut: "⏎"
            ) { run(item) }]
            list.append(PreviewAction(id: "new", label: "Open New Instance", symbol: "plus.rectangle.on.rectangle") {
                let config = NSWorkspace.OpenConfiguration()
                config.createsNewApplicationInstance = true
                config.activates = true
                NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { _, _ in }
                hide(restore: false, launched: true)
            })
            list.append(PreviewAction(id: "reveal", label: "Show in \(manager)", symbol: "folder", shortcut: "⌘F") {
                finish(SpotlightOpener.perform(.reveal, on: item))
            })
            if running {
                list.append(PreviewAction(id: "hide", label: "Hide", symbol: "eye.slash") {
                    finish(SpotlightOpener.perform(.hideApp, on: item))
                })
                list.append(PreviewAction(id: "quit", label: "Quit", symbol: "xmark.circle") {
                    SpotlightOpener.runningApp(at: path)?.terminate()
                    toast("Quit \(item.name)")
                })
                list.append(PreviewAction(id: "kill", label: "Force Quit", symbol: "xmark.octagon") {
                    SpotlightOpener.runningApp(at: path)?.forceTerminate()
                    toast("Force quit \(item.name)")
                })
            }
            list.append(pinAction(for: item))
            if PreviewFacts.canUninstall(path) {
                list.append(PreviewAction(id: "uninstall", label: "Uninstall…", symbol: "trash") {
                    if SpotlightOpener.runningApp(at: path) != nil {
                        toast("Quit \(item.name) first, then uninstall it")
                        return
                    }
                    confirm("uninstall|\(path)", prompt: "Click Uninstall again to move \(item.name) to the Trash") {
                        moveToTrash(item, path: path)
                    }
                })
            }
            return list

        case .window:
            return [
                PreviewAction(id: "open", label: "Switch to Window", symbol: "macwindow", shortcut: "⏎") { run(item) },
                PreviewAction(id: "close", label: "Close Window", symbol: "xmark.rectangle") {
                    if OpenWindows.shared.close(id: item.id) {
                        toast("Closed \(item.name)")
                        all.removeAll { $0.id == item.id }
                        sel = min(sel, max(results.count - 1, 0))
                    } else {
                        toast("Couldn't close that window")
                    }
                },
            ]

        case .folder:
            guard let path = item.target else { return [] }
            return [
                PreviewAction(
                    id: "open", label: opensInFinder(for: query) ? "Open in Finder" : "Open Folder",
                    symbol: "folder", shortcut: "⏎"
                ) { run(item) },
                PreviewAction(id: "terminal", label: "Open in Terminal", symbol: "terminal", shortcut: "⌘T") {
                    openFolderInTerminal(path)
                },
                PreviewAction(id: "reveal", label: "Show in \(manager)", symbol: "arrow.up.forward.app", shortcut: "⌘F") {
                    finish(SpotlightOpener.perform(.reveal, on: item))
                },
                PreviewAction(id: "subfolders", label: "Browse Subfolders", symbol: "folder.badge.plus", shortcut: "⇥") {
                    lockTag(.folder(path), rest: "")
                },
                pinAction(for: item),
            ]

        case .url, .tab:
            guard let link = item.tab?.url ?? item.target, link.hasPrefix("http") else { return [] }
            var list = [PreviewAction(
                id: "open", label: item.kind == .tab ? "Switch to Tab" : "Open",
                symbol: item.kind == .tab ? "arrow.left.arrow.right" : "arrow.up.forward.app", shortcut: "⏎"
            ) { run(item) }]
            // Fluent's "Search" (Ctrl+E): put the address back in the field to edit or re-search it.
            list.append(PreviewAction(id: "edit", label: "Edit in Search Field", symbol: "pencil") {
                query = link
                focusField()
            })
            if PinStore.target(of: item) != nil { list.append(pinAction(for: item)) }
            if let host = URLComponents(string: link)?.host, tag == nil {
                list.append(PreviewAction(id: "site", label: "Filter Browsed Pages", symbol: "globe", shortcut: "⇥") {
                    lockTag(.site(host), rest: "")
                })
            }
            return list

        default:
            return []
        }
    }

    /// Tool tabs / commands. `false` = the typed text is a normal search, so refresh continues down to the core.
    private func refreshMode(_ mode: SpotlightMode) -> Bool {
        switch mode {
        case .search:
            return false
        case .commandMenu(let filter):
            // `:kill chrome` (with a space) goes straight into the command, like the legacy launcher.
            if let trigger = SpotlightCommands.inlineTrigger(filter) {
                enterCommand(trigger.id, args: trigger.args)
            } else {
                publish(SpotlightModeRows.commandMenu(filter))
            }
        case .process(let term):
            processModel.loadSnapshotIfNeeded()
            publish(SpotlightModeRows.processes(processModel, term: term))
        }
        return true
    }

    /// Enters a command (`:kill`, `:emptytrash`, `:help`). The text after the command name becomes its argument.
    private func enterCommand(_ id: String, args: String = "") {
        scopeReturnQuery = ""
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            selectedPreviewActionID = nil
            browse = nil
            activeCommand = id
            query = args
        }
        lastCommand = id
        switch id {
        case SpotlightCommands.kill: processModel.refreshSnapshot()
        case SpotlightCommands.emptyTrash: trashCount = TrashService.itemCount()
        default: break
        }
        focusField()
    }

    /// ⌘/ — like the legacy launcher: reopen the most recent command, or exit the open one.
    private func toggleCommandMode() {
        if activeCommand != nil { exitChip() } else { enterCommand(lastCommand) }
    }

    /// :kill — the first Enter only selects (so a slip doesn't kill the wrong thing), the second one kills.
    private func confirmKill(_ item: SpotlightItem) {
        guard let pid = item.pid else { return }
        if armedKillPID == pid {
            armedKillPID = nil
            killProcess(item)
        } else {
            armedKillPID = pid
            toast("⏎ again to force quit \(item.name)")
        }
    }

    private func killProcess(_ item: SpotlightItem) {
        guard let pid = item.pid else { return }
        switch processModel.kill(pid: pid) {
        case .success:
            toast("Force quit \(item.name)")
        case .failure(let error):
            toast("Couldn't quit \(item.name): \(error.message)")
        }
    }

    /// Destructive actions run on the second Enter (same key) so a slip doesn't delete anything.
    private func confirm(_ key: String, prompt: String, perform: () -> Void) {
        if armedConfirm == key {
            armedConfirm = nil
            perform()
        } else {
            armedConfirm = key
            toast(prompt)
        }
    }

    /// Actions that need launcher state for confirmation.
    private func performLocal(_ action: SpotlightAction, on item: SpotlightItem) -> Bool {
        switch action {
        case .moveToTrash:
            guard item.kind == .app, let path = item.target, PreviewFacts.canUninstall(path) else { return true }
            guard SpotlightOpener.runningApp(at: path) == nil else {
                toast("Quit \(item.name) first, then uninstall it")
                return true
            }
            confirm("trash|\(path)", prompt: "⏎ again to move \(item.name) to the Trash") {
                moveToTrash(item, path: path)
            }
        case .emptyTrash:
            confirm("emptytrash", prompt: "⏎ again to empty the Trash — this can't be undone") {
                emptyTrash()
            }
        case .excludeApp:
            confirm("exclude|\(item.id)", prompt: "⏎ again to hide \(item.name) from results") {
                excludeApp(item)
            }
        default:
            return false
        }
        return true
    }

    private func hideSelectedApp() {
        guard let item = previewItem, item.kind == .app, item.target != nil else {
            toast("Select an app to hide")
            return
        }
        _ = performLocal(.excludeApp, on: item)
    }

    private func moveToTrash(_ item: SpotlightItem, path: String) {
        Task { @MainActor in
            if let error = await TrashService.moveToTrash(path) {
                toast("Couldn't trash \(item.name): \(error)")
                return
            }
            toast("Moved \(item.name) to Trash")
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
            if scope?.id == item.id { exitChip() }
            all.removeAll { $0.id == item.id }
            sel = min(sel, max(results.count - 1, 0))
        }
    }

    private func openFolderInTerminal(_ path: String) {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard SpotlightBackend.isBrowsableFolder(at: url, excluding: themeStore.excludedFolderPaths),
              FileManagerApp.openInTerminal(path) else {
            toast("Couldn't open this folder in Terminal")
            return
        }
        hide(restore: false, launched: true)
    }

    private func emptyTrash() {
        Task { @MainActor in
            if let error = await TrashService.emptyTrash() {
                toast(error)
                return
            }
            toast("Trash emptied")
            if activeCommand == SpotlightCommands.emptyTrash { exitChip() }
        }
    }

    private func excludeApp(_ item: SpotlightItem) {
        switch AppExcludeWriter.append(item.name) {
        case .writeFailed:
            toast("Couldn't update the config file")
        case .alreadyExcluded:
            toast("\(item.name) is already hidden")
        case .added:
            if scope?.id == item.id { exitChip() }
            // The reload re-walks the index (seconds): never on the main thread.
            Task { @MainActor in
                let ok = await EngineBridge.shared.reloadConfigInBackground()
                guard isOpen, !dismissing else { return }
                toast(ok ? "Hid \(item.name) from results" : "Saved, but reloading the config failed")
                refresh()
            }
        }
    }

    /// ⌘⇧; / the Settings button: re-read the config file.
    private func reloadConfig() {
        let result = ThemeStore.shared.reloadFromConfig()
        loadRetention()
        SearchTags.reload()
        FileManagerApp.reload()
        suggestionsEnabled = RecentItems.isEnabled
        // Rebuild the app index off the main thread.
        Task { @MainActor in
            let backendReloaded = await EngineBridge.shared.reloadConfigInBackground()
            guard isOpen, !dismissing else { return }
            if !backendReloaded {
                toast("Config reload failed")
            } else if !result.warnings.isEmpty {
                toast(result.warnings.joined(separator: ", "))
            } else {
                toast("Config reloaded")
            }
            refresh()
        }
    }

    private func loadRetention() {
        guard let raw = try? String(contentsOfFile: ConfigPathResolver.resolvedPath(), encoding: .utf8) else {
            retentionSeconds = AppConstants.Launcher.QueryRetention.defaultSeconds
            return
        }
        retentionSeconds = QueryRetentionPolicy.resolveSeconds(from: ConfigFileLines.keyValues(raw))
    }

    /// A launch mode such as `lumio apps`: open straight into that query.
    private func applyLaunchQuery(_ text: String) {
        show()
        let launch = SpotlightMode.tab(fromLaunchQuery: text)
        openTab(launch.tab, text: launch.text)
    }

    /// A tab's global shortcut (Settings ▸ Shortcuts): open the launcher straight on that tab, or
    /// close it when that tab is already in front.
    private func openFromHotKey(_ tab: SpotlightKind) {
        if isOpen, !dismissing, NSApp.isActive, browse == tab, scope == nil, activeCommand == nil {
            hide()
            return
        }
        show()
        openTab(tab, text: "")
    }

    /// A tag's global shortcut (Settings ▸ Shortcuts): open the launcher already inside that
    /// tag, or close it when that tag is what is showing. `browse` opens the tag browser.
    private func openTagFromHotKey(_ keyword: String) {
        let wantsBrowser = keyword == "browse"
        let showing = wantsBrowser ? activeCommand == Self.tagsCommand : tag?.keyword == keyword
        if isOpen, !dismissing, NSApp.isActive, showing, scope == nil {
            hide()
            return
        }
        // A hotkey asks for this tag: don't bring back the search from last time.
        keptQuery = ""
        keptTag = nil
        keptBrowse = nil
        show()
        if wantsBrowser {
            openTagBrowser()
            return
        }
        guard let found = SearchTags.tag(forKeyword: keyword) else {
            toast("There is no tag named \(keyword)")
            return
        }
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            selectedPreviewActionID = nil
            activeCommand = nil
            browse = nil
            filter = nil
            tag = found
        }
        query = ""
        focusField()
    }

    /// ⌥T: every search tag in one list; type to filter, ⏎ or ⇥ to use one.
    private func openTagBrowser() {
        withAnimation(motion(SpotlightMotion.chip)) { tag = nil }
        enterCommand(Self.tagsCommand)
    }

    private func setSort(_ mode: ResultSort) {
        sortMode = mode
        sel = 0
        toast(mode == .relevance ? "Default order" : "Sorted by \(mode.label.lowercased())")
    }

    /// The footer's sort button: Fluent Search's "Sort by" menu.
    private func showSortMenu() {
        let menu = NSMenu()
        for mode in ResultSort.allCases {
            let entry = MenuActionTarget.item(mode.label) { setSort(mode) }
            entry.state = mode == sortMode ? .on : .off
            menu.addItem(entry)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// Shows the results. Expands the panel if it isn't already.
    private func publish(_ rows: [SpotlightItem]) {
        // The first results after the panel opens rise in one by one (SpotlightRiseIn). Later
        // ones, while typing, swap with a short spring: rows that stay slide to their new place,
        // new rows fade in, dropped rows vanish. Swapping instantly made the list flicker.
        var swap = Transaction()
        if expanded, !introActive, !reduceMotion {
            swap.animation = SpotlightMotion.typingSwap
        } else {
            swap.disablesAnimations = true
        }
        withTransaction(swap) {
            all = rows
            shownQuery = query
            sel = keepSelOnPublish.map { min($0, max(0, rows.count - 1)) } ?? 0
        }
        if !expanded { setExpanded(true) }
        if activateWhenReady {
            activateWhenReady = false
            activate()
        }
    }

    private func setExpanded(_ open: Bool) {
        if open {
            // The quick buttons are still merging into the bar: wait for the bar to grow before dropping
            // the panel, so results fall straight down instead of sweeping diagonally.
            let sinceMerge = Date().timeIntervalSince(mergeStartedAt)
            let delay = reduceMotion ? 0 : max(0, SpotlightMotion.expandAfterMerge - sinceMerge)
            resizeDelay = delay
            introUntil = Date().addingTimeInterval(SpotlightMotion.introWindow + delay)
        }
        withAnimation(motion(SpotlightMotion.resize)) { expanded = open }
    }

    /// Show the quick buttons after the search bar has been idle.
    private func pokeIdle() {
        idleTask?.cancel()
        // Suggestions fill the empty field instead of the round buttons (Fluent-style).
        let canIdle = isOpen && !dismissing && query.isEmpty && scope == nil && browse == nil
            && activeCommand == nil && tag == nil && !suggestionsEnabled
        guard canIdle else {
            if idle {
                mergeStartedAt = Date()
                withAnimation(motion(SpotlightMotion.merge)) { idle = false }
            }
            return
        }
        guard !idle else { return }
        idleTask = Task { @MainActor in
            try? await Task.sleep(for: SpotlightMotion.idleDelay)
            guard !Task.isCancelled, isOpen, !dismissing,
                  query.isEmpty, scope == nil, browse == nil, activeCommand == nil, tag == nil,
                  !suggestionsEnabled
            else { return }
            withAnimation(motion(SpotlightMotion.morph)) { idle = true }
        }
    }

    private func move(_ delta: Int) {
        if showsActionDetails, let item = scope, let selectedPreviewActionID {
            let actions = previewActions(for: item)
            guard !actions.isEmpty else { return }
            let current = actions.firstIndex(where: { $0.id == selectedPreviewActionID }) ?? 0
            self.selectedPreviewActionID = actions[(current + delta + actions.count) % actions.count].id
            return
        }
        guard expanded, !results.isEmpty else { return }
        // The selection bar SLIDES to the new row (like the legacy launcher) instead of jumping.
        let next = (sel + delta + results.count) % results.count
        let wrapped = abs(next - sel) > 1
        withAnimation(motion(SpotlightMotion.selectionGlide)) { sel = next }
        scrollWraps = wrapped
        scrollTarget = results[sel].id
    }

    /// Enter.
    private func activate() {
        if showsActionDetails, let item = scope, let selectedPreviewActionID {
            let actions = previewActions(for: item)
            (actions.first { $0.id == selectedPreviewActionID } ?? actions.first)?.run()
            return
        }
        // Idle with a round button focused by Tab: open that one.
        if idle, let index = quickFocus, Self.quickItems.indices.contains(index) {
            quickFocus = nil
            toggleBrowse(Self.quickItems[index].kind)
            return
        }
        // Results for the latest text haven't arrived: wait, then open, so we don't open a stale row.
        if searchTask != nil {
            activateWhenReady = true
            return
        }
        guard expanded, sel < results.count else { return }
        run(results[sel])
    }

    /// Opens a row (or runs its action when in actions mode).
    private func run(_ item: SpotlightItem) {
        if item.id == SpotlightBackend.lumioSettingsID {
            openSettings()
            return
        }
        if item.id == Self.windowsBlockedRow {
            // Says whether the permission is off or stale, and offers the fix that fits.
            hide(restore: false)
            AccessibilityDoctor.shared.showStatus()
            return
        }
        if item.id.hasPrefix(SystemCommands.idPrefix), let id = item.payload {
            if id == SystemCommands.emptyTrash {
                enterCommand(SpotlightCommands.emptyTrash)
            } else if let problem = SystemCommands.run(id) {
                toast(problem)
            } else {
                hide(restore: false)
            }
            return
        }
        if item.id.hasPrefix(SystemCommands.runPrefix) {
            if let problem = SystemCommands.runInTerminal(item.payload ?? "") {
                toast(problem)
            } else {
                hide(restore: false, launched: true)
            }
            return
        }
        if item.kind == .window {
            if OpenWindows.shared.activate(id: item.id) {
                hide(restore: false, launched: true)
            } else {
                toast("That window is no longer open")
                all.removeAll { $0.id == item.id }
            }
            return
        }
        if item.kind == .tagHint, activeCommand == Self.tagsCommand {
            // Picked in the tag browser: leave the browser and lock the tag.
            guard let picked = item.payload.flatMap(SearchTags.tag(forKeyword:)) else { return }
            if let raw = picked.mode, let kind = SpotlightKind(rawValue: raw) {
                openTab(kind, text: "")
            } else {
                withAnimation(motion(SpotlightMotion.chip)) { activeCommand = nil }
                lockTag(picked, rest: "")
            }
            return
        }
        switch item.kind {
        case .prefix:
            // Like the legacy launcher: picking a prefix fills it into the field, then you type the keyword.
            query = item.payload ?? ""
            focusField()
            return
        case .command:
            if item.payload == SpotlightCommands.emptyTrash, activeCommand == SpotlightCommands.emptyTrash {
                confirm("emptytrash", prompt: "⏎ again to empty the Trash — this can't be undone") {
                    emptyTrash()
                }
            } else if let id = item.payload {
                enterCommand(id)
            }
            return
        case .help:
            return
        case .tagHint:
            _ = enterTag(keyword: item.payload)
            return
        case .process:
            guard let pid = item.pid else { return }
            if activeCommand == SpotlightCommands.kill {
                confirmKill(item)
            } else {
                processModel.measureCPU(pid: pid)  // ps": Enter measures CPU, like the legacy launcher
            }
            return
        default:
            break
        }
        if let action = item.action, let scope, scope.kind == .process {
            switch action {
            case .measureCPU:
                if let pid = scope.pid { processModel.measureCPU(pid: pid) }
            case .killProcess:
                killProcess(scope)
                exitChip()
            default:
                break
            }
            return
        }
        if let action = item.action, let scope, performLocal(action, on: scope) {
            return
        }
        let outcome = if let action = item.action, let scope {
            if action == .open && scope.kind == .folder && opensInFinder(for: scopeReturnQuery) {
                SpotlightOpener.open(scope, inFinder: true)
            } else {
                SpotlightOpener.perform(action, on: scope)
            }
        } else {
            SpotlightOpener.open(item, inFinder: item.kind == .folder && opensInFinder(for: query))
        }
        switch outcome {
        case .launched:
            // Learn the pick for this text (normal searches only): it comes first next time.
            if item.action == nil, tag == nil, browse == nil {
                UsageLearning.shared.record(item, query: showsActionDetails ? scopeReturnQuery : query)
            }
            // The just-opened app comes to the front by itself: don't return focus to the previous app.
            hide(restore: false, launched: true)
        case .message(let text):
            toast(text)
        }
    }

    private func opensInFinder(for text: String) -> Bool {
        isFinderPage || (browse == nil && tag == nil && FolderAddressQuery.changeDirectoryArgument(in: text) != nil)
    }

    /// Opens the selected application's details and usable actions as a separate page.
    @discardableResult
    private func enterActionPage() -> Bool {
        guard expanded, scope == nil, activeCommand == nil,
              sel < results.count, results[sel].kind == .app else { return false }
        let item = results[sel]
        guard let firstAction = previewActions(for: item).first else { return false }
        scopeReturnQuery = query
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = item
            selectedPreviewActionID = firstAction.id
            query = ""
        }
        if Self.isFinder(item) { focusField() }
        return true
    }

    /// ⌘K: view the actions of the selected row.
    private func enterScope() {
        guard scope == nil, sel < results.count else { return }
        let item = results[sel]
        guard item.supportsActions else { return }
        scopeReturnQuery = query
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = item
            query = ""
        }
        focusField()
    }

    private func toggleBrowse(_ kind: SpotlightKind) {
        withAnimation(motion(SpotlightMotion.chip)) {
            scope = nil
            selectedPreviewActionID = nil
            browse = (browse == kind) ? nil : kind
            if browse != nil { tag = nil }
        }
        focusField()
    }

    /// Remove the chip: exit actions (restoring the typed text) or exit the browsed group.
    private func exitChip() {
        withAnimation(motion(SpotlightMotion.chip)) {
            if scope != nil {
                scope = nil
                selectedPreviewActionID = nil
                query = scopeReturnQuery
                scopeReturnQuery = ""
            } else if activeCommand != nil {
                activeCommand = nil
                query = ""
            } else if tag != nil {
                tag = nil
                query = ""
            } else {
                browse = nil
            }
        }
        focusField()
    }

    /// Escape closes the launcher from any tab or search.
    /// ⌫ on an empty field still leaves the mode without closing.
    private func handleEscape() {
        if selectedPreviewActionID != nil {
            exitChip()
            return
        }
        // Esc first drops the Tab focus on a round button, then closes.
        if quickFocus != nil {
            quickFocus = nil
            return
        }
        hide()
    }

    /// ⌫ on an empty field: remove the scope chip. Returns `false` so the key goes back to the field.
    private func handleDelete() -> Bool {
        guard query.isEmpty, browse != nil || scope != nil || activeCommand != nil || tag != nil else { return false }
        exitChip()
        return true
    }

    /// Navigation keys, called from SpotlightKeyMonitor. `true` = handled.
    private func handleKey(_ event: NSEvent) -> Bool {
        typealias KeyCode = AppConstants.Launcher.KeyCode
        guard isOpen, !dismissing, event.window is LauncherPanelWindow else { return false }
        // The input method has uncommitted text: the key belongs to the input method.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() {
            return false
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // The details page handles Enter even when the search field is hidden.
        if showsActionDetails, flags.isEmpty,
           event.keyCode == KeyCode.returnKey || event.keyCode == KeyCode.keypadEnter {
            activate()
            return true
        }

        switch event.keyCode {
        case KeyCode.escape:
            handleEscape()
            return true
        case KeyCode.arrowUp where !flags.contains(.shift):
            move(-1)
            return true
        case KeyCode.arrowDown where !flags.contains(.shift):
            move(1)
            return true
        case KeyCode.tab where activeCommand == Self.tagsCommand:
            // Tag browser: Tab picks the selected tag, like ⏎.
            if sel < results.count { run(results[sel]) }
            return true
        case KeyCode.tab:
            if selectedPreviewActionID != nil {
                exitChip()
                return true
            }
            if !flags.contains(.shift), let item = previewItem, Self.isFinder(item), enterActionPage() {
                return true
            }
            if !flags.contains(.shift), enterTag() { return true }
            if !flags.contains(.shift), enterActionPage() { return true }
            // Idle (the round buttons are out): Tab walks field → buttons → field, Enter opens one.
            if idle, query.isEmpty {
                let stops = Self.quickItems.count + 1  // + the field itself
                let current = quickFocus.map { $0 + 1 } ?? 0
                let next = (current + (flags.contains(.shift) ? -1 : 1) + stops) % stops
                quickFocus = next == 0 ? nil : next - 1
                return true
            }
            // A primary Tab only enters a real scope when a result is selected.
            if !flags.contains(.shift), expanded, sel < results.count { return true }
            cycleFilter(flags.contains(.shift) ? -1 : 1)
            return true
        case Self.backspaceKeyCode where flags.isEmpty:
            return handleDelete()
        default:
            break
        }

        if flags == .control, key == "n" || key == "p" {
            move(key == "n" ? 1 : -1)
            return true
        }
        // ⌥S: switch between relevance and name order.
        if flags == .option, event.keyCode == 1 {
            let modes = ResultSort.allCases
            setSort(modes[((modes.firstIndex(of: sortMode) ?? 0) + 1) % modes.count])
            return true
        }
        // ⌥T: browse every search tag (Fluent's Alt+T).
        if flags == .option, event.keyCode == 17 {
            if activeCommand == Self.tagsCommand { exitChip() } else { openTagBrowser() }
            return true
        }
        // ⌘K / ⌃K — view the actions of the selected row (Tab now cycles the filter pills).
        if flags == .command || flags == .control, key == "k" {
            enterScope()
            return true
        }
        // ⌘⇧P: pin / unpin the selected result to Home.
        if flags == [.command, .shift], key == "p", let item = previewItem {
            toggleHomePin(item)
            return true
        }
        if flags == .command, key == "/" {
            toggleCommandMode()
            return true
        }
        if flags == .command, key == "h" {
            enterCommand(SpotlightCommands.help)
            return true
        }
        if flags == [.command, .shift], key == "h" {
            hideSelectedApp()
            return true
        }
        if flags == .command, key == "t", let item = previewItem, item.kind == .folder, let path = item.target {
            openFolderInTerminal(path)
            return true
        }
        // ⌘F — show the selected item in Finder (like the legacy launcher).
        if flags == .command, key == "f", let item = previewItem,
           [.app, .folder].contains(item.kind), item.target?.hasPrefix("/") == true
        {
            switch SpotlightOpener.perform(.reveal, on: item) {
            case .launched: hide(restore: false, launched: true)
            case .message(let text): toast(text)
            }
            return true
        }
        if flags == .command, let digit = Int(key) {
            // Inside a command / command menu: ⌘N picks the Nth command, like the legacy launcher.
            let commands = SpotlightCommands.catalog
            var inCommands = activeCommand != nil
            if case .commandMenu = SpotlightMode.parse(query) { inCommands = true }
            if inCommands, commands.indices.contains(digit - 1) {
                enterCommand(commands[digit - 1].id)
                return true
            }
            if Self.quickItems.indices.contains(digit - 1) {
                toggleBrowse(Self.quickItems[digit - 1].kind)
                return true
            }
        }
        return false
    }

    private static let backspaceKeyCode: UInt16 = 51

    /// Whether the click point (in root coordinates) is on the glass cluster.
    private func clusterContains(_ point: CGPoint) -> Bool {
        let quicks = idle
            ? CGFloat(Metric.quickCount) * (Metric.quickSize + Metric.quickGap)
            : 0
        let rect = CGRect(
            x: SpotlightWindowSizing.margin,
            y: SpotlightWindowSizing.margin,
            width: panelWidth + quicks,
            height: panelHeight
        )
        return rect.contains(point)
    }

    /// Back to a brand-new state, no animation (the window is already hidden).
    private func resetState() {
        var plain = Transaction()
        plain.disablesAnimations = true
        withTransaction(plain) {
            idleTask?.cancel()
            toastTask?.cancel()
            searchTask?.cancel()
            searchTask = nil
            extrasTask?.cancel()
            extrasTask = nil
            activateWhenReady = false
            query = ""
            shownQuery = ""
            all = []
            sel = 0
            filter = nil
            sortMode = .relevance
            scope = nil
            selectedPreviewActionID = nil
            scopeReturnQuery = ""
            browse = nil
            tag = nil
            showingSuggestions = false
            expanded = false
            idle = false
            quickFocus = nil
            launching = false
            toastMsg = nil
            resizeDelay = 0
            activeCommand = nil
            armedKillPID = nil
            armedConfirm = nil
            trashCount = nil
            panelHeight = Metric.barHeight
        }
    }

    // MARK: - Window

    private func launcherWindow() -> NSWindow? {
        NSApp.windows.first { $0 is LauncherPanelWindow }
    }

    private func toggle() {
        if isOpen, !dismissing, NSApp.isActive {
            hide()
            return
        }
        show()
    }

    private func show() {
        guard let window = launcherWindow() else { return }
        // Reopened mid-close: reverse from where it is, don't rebuild.
        let reentering = dismissing
        dismissTask?.cancel()
        dismissTask = nil
        dismissing = false
        hiddenTrim.cancel()

        if pidToRestore == nil,
           let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            pidToRestore = front.processIdentifier
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)

        if isOpen, !reentering {
            // Already open (e.g. an echo from applicationDidBecomeActive): just refocus.
            window.makeKeyAndOrderFront(nil)
            focusField()
            return
        }

        isOpen = true
        if !reentering {
            // Like the legacy launcher: each open asks the core to refresh the index in the background
            // (the first time it also loads the engine from SQLite) — run in the background so animation isn't delayed.
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
            // Snapshot the open browser tabs now, so they're ready by the first keystroke.
            BrowserTabs.shared.refresh {
                if isOpen, !dismissing, tag != nil || !query.isEmpty { refresh() }
            }
            // Open windows of other apps, for window rows and the `windows` tag.
            OpenWindows.shared.refresh {
                if isOpen, !dismissing, tag?.windows == true { refresh() }
            }
            // The permission worked and macOS now says no: find out whether it went stale.
            AccessibilityDoctor.shared.noticeIfLost()
            suggestionsEnabled = RecentItems.isEnabled
            // Which apps are running, for the dot on their rows.
            runningApps = Set(NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.resolvingSymlinksInPath().path })
            // Pick up new bookmark folders off the main thread,
            // so the first keystroke never waits on the browsers' files.
            Task.detached(priority: .utility) {
                BrowserBookmarks.warm()
                await MainActor.run { SearchTags.reload() }
            }
            // Fresh open: go to the hidden state WITHOUT animation, position the window, and only then
            // animate on the next tick — the two states must be in two transactions.
            resetState()
            // Bring back the search from last time (sets the query after the reset, so it re-runs).
            // A plain search expires after `query_retention_seconds`; tabs keep their query.
            if keptBrowse == nil,
               QueryRetentionPolicy.shouldClear(hiddenAt: hiddenAt, seconds: retentionSeconds) {
                keptQuery = ""
                keptTag = nil
            }
            hiddenAt = nil
            if let tab = keptBrowse {
                browse = tab
                keptBrowse = nil
            }
            // Restore the tag before the text so the query runs in the right scope.
            tag = keptTag
            keptTag = nil
            restoredQuery = nil
            if !keptQuery.isEmpty {
                query = keptQuery
                if browse == nil { restoredQuery = keptQuery }
                keptQuery = ""
            }
            var plain = Transaction()
            plain.disablesAnimations = true
            withTransaction(plain) {
                shownScale = false
                shownAlpha = false
            }
            let screen = SpotlightWindowSizing.screenForCursor() ?? window.screen ?? NSScreen.main
            if let screen {
                window.setFrame(SpotlightWindowSizing.frame(on: screen), display: false)
            }
            mouseGate.reset()
        }
        window.hasShadow = false
        window.makeKeyAndOrderFront(nil)
        focusField()

        DispatchQueue.main.async {
            withAnimation(motion(SpotlightMotion.appear)) {
                shownScale = true
                launching = false
            }
            withAnimation(motion(SpotlightMotion.appearFade)) { shownAlpha = true }
            pokeIdle()
            // Empty field on open: show the suggestions.
            // A restored tag with no text: list what is in the tag again.
            if !reentering, query.isEmpty, browse == nil, suggestionsEnabled || tag != nil { refresh() }
        }
    }

    /// `launched`: closing because an item was just opened (slight zoom + dissolve) instead of collapsing.
    private func hide(restore: Bool = true, launched: Bool = false) {
        guard isOpen, !dismissing, let window = launcherWindow() else { return }
        dismissing = true
        idleTask?.cancel()
        isFocused = false

        if launched {
            withAnimation(motion(SpotlightMotion.launch)) {
                launching = true
                shownAlpha = false
            }
        } else {
            withAnimation(motion(SpotlightMotion.dismiss)) {
                shownScale = false
                shownAlpha = false
            }
        }

        // Return focus to the previous app immediately, without waiting for the fade.
        if restore, let pid = pidToRestore,
           let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated
        {
            app.activate()
        }
        pidToRestore = nil

        // Dismissed (not launched) from a plain search or a tab: remember it for the next open.
        let keepable = !launched && scope == nil && activeCommand == nil
        keptBrowse = keepable ? browse : nil
        keptQuery = keepable ? query : ""
        keptTag = keepable && browse == nil ? tag : nil

        let seconds = launched ? SpotlightMotion.launchSeconds : SpotlightMotion.dismissSeconds
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000) + 20))
            guard !Task.isCancelled else { return }
            window.orderOut(nil)
            hiddenAt = Date()
            isOpen = false
            dismissing = false
            resetState()
            processModel.invalidate()
            // Hidden: drop the caches that are only there for speed on screen, but only once
            // the launcher has stayed hidden a while (show() cancels this; the condition
            // re-checks on wake-up so a reopen can never be purged under).
            hiddenTrim.schedule(after: MemoryTrim.hiddenTrimDelay, if: { !isOpen && !dismissing }) {
                await MemoryTrim.releaseCaches()
            }
        }
    }

    private func focusField() {
        isFocused = true
        // On the first open the window hasn't become key yet: set the first responder directly and
        // retry for a few beats, like the legacy launcher's focus recovery.
        for delay in [0.0, 0.05, 0.12] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard isOpen, !dismissing, let window = launcherWindow(),
                      let field = Self.caretField(in: window.contentView)
                else { return }
                if field.currentEditor() == nil { window.makeFirstResponder(field) }
                // Last beat: the field holds the restored search by now. Select it, unless
                // the user has already typed over it.
                if delay == 0.12, let restored = restoredQuery {
                    restoredQuery = nil
                    if query == restored, field.stringValue == restored {
                        field.currentEditor()?.selectAll(nil)
                    }
                }
            }
        }
    }

    private static func caretField(in view: NSView?) -> CaretTextField? {
        guard let view else { return nil }
        if let field = view as? CaretTextField { return field }
        for child in view.subviews {
            if let field = caretField(in: child) { return field }
        }
        return nil
    }
}

// MARK: - Small effects

/// Result row rises + fades in. `animation == nil`: show immediately, no effect.
private struct SpotlightRiseIn: ViewModifier {
    let animation: Animation?
    @State private var shown: Bool

    init(animation: Animation?) {
        self.animation = animation
        _shown = State(initialValue: animation == nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : SpotlightMotion.rowRiseOffset)
            .scaleEffect(shown ? 1 : 0.985, anchor: .top)
            .onAppear {
                guard !shown, let animation else { return }
                DispatchQueue.main.async {
                    withAnimation(animation) { shown = true }
                }
            }
    }
}

/// Icon in a round button pops out slightly after the glass droplet.
private struct SpotlightPopIn: ViewModifier {
    let animation: Animation?
    @State private var shown: Bool

    init(animation: Animation?) {
        self.animation = animation
        _shown = State(initialValue: animation == nil)
    }

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.5)
            .onAppear {
                guard !shown, let animation else { return }
                DispatchQueue.main.async {
                    withAnimation(animation) { shown = true }
                }
            }
    }
}

/// Only let hover change the selected row when the mouse actually moves. Not
/// @Observable: a mouse position change doesn't need to redraw anything.
private final class MouseGate {
    private var last = NSEvent.mouseLocation

    func reset() { last = NSEvent.mouseLocation }

    func moved() -> Bool {
        let now = NSEvent.mouseLocation
        defer { last = now }
        return now != last
    }
}

// MARK: - Tile (gradient + glyph like .tile in the HTML)
// Shared with SpotlightField (motion lab) — so not private.

struct SpotlightTile: View {
    let item: SpotlightItem
    let size: CGFloat

    @ObservedObject private var favicons = FaviconStore.shared

    var body: some View {
        if let host = item.favicon, let icon = favicons.image(for: host) {
            // The site's own icon (YouTube, Drive…), on a soft plate so dark icons stay visible.
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.14)
                // White plate, or a dark one under a white icon (ChatGPT), so it never vanishes.
                .background(
                    favicons.isLight(host) ? Color(white: 0.13).opacity(0.95) : Color.white.opacity(0.92),
                    in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                )
                .frame(width: size, height: size)
        } else if let image = realImage {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            colorTile
        }
    }

    /// Real icon for an app or process. Cached: NSWorkspace returns a new image on every call; without caching the
    /// icon flickers on every keystroke.
    private var realImage: NSImage? {
        if item.kind == .process, let pid = item.pid {
            return RowIconCache.image(key: "pid:\(pid)") {
                RowIconCache.rasterized(LauncherProcessFeature.icon(forPID: pid), points: RowIconCache.iconPoints)
            }
        }
        return item.iconPath.map { RowIconCache.icon(forFile: $0) }
    }

    /// Colored tile for rows without an app or site icon.
    private var colorTile: some View {
        let pair = item.colors.split(separator: ",").map(String.init)
        let c1 = Color(hex: pair.first ?? "#9aa2ad")
        let c2 = Color(hex: pair.dropFirst().first ?? "#5c636e")
        return ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.28), radius: 1, y: 1)
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(item.glyph ?? String(item.name.replacingOccurrences(of: ".app", with: "").prefix(1)).uppercased())
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Hook that watches the state of the legacy launcher modes (see `modeHooks`).
private struct SpotlightModeHooks: ViewModifier {
    let activeCommand: String?
    let previewID: String?
    @ObservedObject var processModel: ProcessFinderModel
    let onCommandChange: () -> Void
    let onPreviewChange: () -> Void
    let onProcesses: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: activeCommand) { onCommandChange() }
            .onChange(of: previewID) { onPreviewChange() }
            .onReceive(processModel.$candidates) { _ in onProcesses() }
    }
}

/// The rows the launcher holds, the pill filter, and what the view derives from them.
/// Derived values are refreshed when `all` or `filter` change, not on every read.
struct SpotlightResultList {
    var all: [SpotlightItem] = [] {
        didSet { derive() }
    }
    var filter: SpotlightKind? {
        didSet { if filter != oldValue { derive() } }
    }
    /// `all` narrowed to the selected pill group.
    private(set) var results: [SpotlightItem] = []
    /// Pills for the groups present in the current search. Processes has its own tab.
    private(set) var kinds: [SpotlightKind] = []

    /// Goes up whenever `results` changes, so a cache built from it knows when to rebuild.
    private(set) var version = 0

    private mutating func derive() {
        version &+= 1
        if let filter {
            results = all.filter { $0.kind.pillGroup == filter }
        } else {
            results = all
        }
        var seen: [SpotlightKind] = []
        for item in all {
            let group = item.kind.pillGroup
            if group != .process, !seen.contains(group) { seen.append(group) }
        }
        kinds = seen
    }
}

/// Caches the sorted rows until the results or the sort order changes.
final class SortedResultsMemo {
    private var version = -1
    private var mode = ResultSort.relevance
    private var rows: [SpotlightItem] = []

    func sorted(_ list: SpotlightResultList, by mode: ResultSort) -> [SpotlightItem] {
        if version == list.version, self.mode == mode { return rows }
        rows = ResultSort.sorted(list.results, by: mode)
        version = list.version
        self.mode = mode
        return rows
    }
}

/// Lets an application, folder or link be dragged out of the launcher.
private struct SpotlightDragSource: ViewModifier {
    let item: SpotlightItem

    func body(content: Content) -> some View {
        if let url = Self.fileURL(item) {
            content.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
        } else if let link = Self.link(item) {
            content.onDrag { NSItemProvider(object: link as NSURL) }
        } else {
            content
        }
    }

    private static func fileURL(_ item: SpotlightItem) -> URL? {
        guard [.app, .folder].contains(item.kind),
              let path = item.target, path.hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func link(_ item: SpotlightItem) -> URL? {
        guard [.url, .tab].contains(item.kind),
              let target = item.tab?.url ?? item.target, target.hasPrefix("http")
        else { return nil }
        return URL(string: target)
    }
}

/// A small icon button for the launcher footer, brighter under the pointer.
private struct FooterIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 24, height: 22)
                .background(Color.primary.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Runs a closure when its menu item is chosen (for the Open With menu). The item keeps it
/// alive through `representedObject`.
private final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() { handler() }

    /// A menu item titled `title` that runs `handler`.
    static func item(_ title: String, handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(handler: handler)
        let item = NSMenuItem(title: title, action: #selector(fire), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}
