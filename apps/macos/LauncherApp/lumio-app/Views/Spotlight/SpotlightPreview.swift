//
//  SpotlightPreview.swift
//  lumio-app
//
import AppKit
import SwiftUI

/// One quick action in the preview pane (Open, Show in Finder, Quit…), like Fluent Search's
/// result actions. The launcher builds them; the pane only draws and triggers them.
struct PreviewAction: Identifiable {
    let id: String
    let label: String
    let symbol: String
    var shortcut: String? = nil
    let run: () -> Void
}

/// A chip for narrowing the search to a local result category.
struct PreviewChip: Identifiable {
    let id: String
    let label: String
    var symbol: String? = nil
    let run: () -> Void
}

struct SpotlightPreviewView: View {
    let item: SpotlightItem
    /// Tag chips for this result.
    var chips: [PreviewChip] = []
    var actions: [PreviewAction] = []
    var selectedActionID: String? = nil
    /// ps" / :kill — process details (loaded on selection) and CPU (measured on Enter).
    var processDetail: ProcessDetail? = nil
    var processCPU: Double? = nil
    var measuringCPU = false
    @State private var info = Info()

    /// Extra info read from disk when a row is selected.
    struct Info {
        var detail: String?
        var modified: String?
        var version: String?
        /// "Applications › Calendar.app"
        var location: String?
        /// "2 years ago"
        var modifiedAgo: String?
    }

    /// Results that get the Fluent-style card: something to open, with actions.
    private var usesCard: Bool {
        !actions.isEmpty && [.app, .folder, .url, .tab, .setting, .window].contains(item.kind)
    }

    var body: some View {
        if usesCard {
            card
        } else {
            classic
        }
    }

    /// Fluent Search's detail card: big icon, name, facts, tag chips, then every action.
    private var card: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 11) {
                    SpotlightTile(item: item, size: 68)
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                        .padding(.top, 6)
                    Text(item.name)
                        .font(.system(size: 15.5, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    cardFacts
                    if !chips.isEmpty {
                        ChipFlow(spacing: 6) {
                            ForEach(chips) { chip in PreviewChipButton(chip: chip) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actionList
                }
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .scrollIndicators(.never)
            .onChange(of: selectedActionID, initial: true) { _, selected in
                if let selected {
                    proxy.scrollTo("action|\(selected)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .task(id: item.id) {
            // Off the main thread like `classic`: the top result's card is rebuilt on each
            // keystroke, and a disk read here stalled typing.
            let current = item
            info = Info(detail: Self.immediateDetail(for: current))
            let loaded = await Task.detached(priority: .userInitiated) { Self.loadInfo(for: current) }.value
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.14)) { info = loaded }
        }
    }

    /// App and folder metadata, or the address and owner of another result.
    @ViewBuilder
    private var cardFacts: some View {
        let link = item.tab?.url ?? item.target.flatMap { $0.hasPrefix("http") ? $0 : nil }
        if info.location != nil || info.modifiedAgo != nil || info.version != nil || link != nil
            || item.kind == .window
        {
            VStack(alignment: .leading, spacing: 5) {
                if let link { factRow("URL", link) }
                if item.kind == .window, let app = item.meta { factRow("Window", app) }
                if let location = info.location { factRow("Location", location) }
                if let version = info.version { factRow("Version", version) }
                if let modified = info.modifiedAgo { factRow("Modified", modified) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func factRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
    }

    private var classic: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            details
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .task(id: item.id) {
            // Disk reads (attributes, Info.plist) stay off the main thread: arrowing through
            // results must never wait on a slow volume.
            let current = item
            info = Info(detail: Self.immediateDetail(for: current))
            let loaded = await Task.detached(priority: .userInitiated) { Self.loadInfo(for: current) }.value
            guard !Task.isCancelled else { return }
            info = loaded
        }
    }

    // MARK: - Quick actions

    /// Highlights the keyboard selection or, outside the detail page, the default action.
    private var actionList: some View {
        VStack(spacing: 2) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, action in
                let selected = action.id == selectedActionID
                PreviewActionRow(
                    action: action,
                    highlighted: selected || (selectedActionID == nil && index == 0),
                    selected: selected
                )
                .id("action|\(action.id)")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            SpotlightTile(item: item, size: 48)
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                HStack(spacing: 7) {
                    Text(item.kind.label)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color(nsColor: .systemBlue), in: Capsule())
                    if let detail = info.detail {
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 58)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .tab:
            note(item.tab?.url ?? item.target ?? "", key: "⏎", action: "switch to this tab")
        case .tagHint:
            note(item.meta ?? "", key: "⇥", action: "search \(item.name)")
        case .window:
            note(item.meta ?? "", key: "⏎", action: "switch to this window")
        case .url:
            note(item.target ?? item.name, key: "⏎", action: "open link")
        case .setting:
            note("This item is in System Settings.", key: "⏎", action: "open")
        case .prefix:
            note(item.meta ?? "", key: "⏎", action: "use prefix \(item.payload ?? "")")
        case .command:
            if item.id == "command|emptytrash" {
                note(item.meta ?? "", key: "⏎ ⏎", action: "empty the Trash")
            } else if item.id.hasPrefix(SystemCommands.idPrefix) || item.id.hasPrefix(SystemCommands.runPrefix) {
                note(item.meta ?? "", key: "⏎", action: "run")
            } else {
                note(item.meta ?? "", key: "⏎", action: "enter command")
            }
        case .help:
            Text(item.meta ?? "")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .process:
            processContent
        case .app, .folder, .cmd:
            EmptyView()
        }
    }

    /// The process's command line.
    private func textBox(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .scrollIndicators(.never)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var processContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let pid = item.pid { infoRow("PID", "\(pid)") }
            if measuringCPU {
                infoRow("CPU", "measuring…")
            } else if let processCPU {
                infoRow("CPU", String(format: "%.1f%%", processCPU))
            } else {
                infoRow("CPU", "not measured")
            }
            if let detail = processDetail {
                infoRow("Memory", ByteCountFormatter.string(fromByteCount: Int64(detail.memoryKB) * 1024, countStyle: .memory))
                infoRow("User", detail.user)
                infoRow("PPID", "\(detail.ppid)")
                if !detail.cmdline.isEmpty {
                    textBox(detail.cmdline)
                        .padding(.top, 6)
                }
            }
        }
    }

    private func note(_ text: String, key: String, action: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .truncationMode(.middle)
            hint(key, action)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(action)
                .font(.system(size: 12.5))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Bottom details

    @ViewBuilder
    private var details: some View {
        let path = item.target.flatMap { $0.hasPrefix("/") ? $0 : nil }
        if path != nil || info.modified != nil || info.version != nil {
            VStack(spacing: 7) {
                if let version = info.version { infoRow("Version", version) }
                if let path { infoRow("Path", PathDisplay.abbreviated(path)) }
                if let modified = info.modified { infoRow("Modified", modified) }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.system(size: 12.5))
    }

    // MARK: - Disk reads

    /// What the header can show before any disk read lands.
    private static func immediateDetail(for item: SpotlightItem) -> String? {
        switch item.kind {
        case .setting: "System Settings"
        case .process: item.meta
        default: nil
        }
    }

    nonisolated private static func loadInfo(for item: SpotlightItem) -> Info {
        var info = Info()
        switch item.kind {
        case .setting:
            info.detail = "System Settings"
            return info
        case .process:
            info.detail = item.meta
            return info
        case .app, .folder:
            break
        default:
            return info
        }
        guard let path = item.target, path.hasPrefix("/") else { return info }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        if let date = attrs?[.modificationDate] as? Date {
            info.modified = date.formatted(date: .abbreviated, time: .shortened)
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            info.modifiedAgo = relative.localizedString(for: date, relativeTo: Date())
        }
        info.location = Self.breadcrumb(path)
        guard item.kind == .app else { return info }
        // Read the plist directly to avoid retaining a cached Bundle for every app.
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        let plist = NSDictionary(contentsOf: plistURL)
        info.version = plist?["CFBundleShortVersionString"] as? String
            ?? plist?["CFBundleVersion"] as? String
        info.detail = info.version.map { "Version \($0)" }
        return info
    }

    /// A readable path of up to four components, relative to the home directory when possible.
    nonisolated private static func breadcrumb(_ path: String) -> String {
        let home = NSHomeDirectory()
        let shown = path.hasPrefix(home + "/") ? String(path.dropFirst(home.count + 1)) : path
        var parts = shown.split(separator: "/").map(String.init)
        if parts.count > 4 { parts = ["…"] + parts.suffix(4) }
        return parts.joined(separator: " › ")
    }
}

/// A row of the actions list with the shortcut for its current state.
private struct PreviewActionRow: View {
    let action: PreviewAction
    let highlighted: Bool
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        let shortcut = selected ? "⏎" : action.shortcut
        Button(action: action.run) {
            HStack(spacing: 10) {
                Image(systemName: action.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(action.label)
                    .font(.system(size: 13.5, weight: highlighted ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(highlighted ? Color.white : Color.primary)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                highlighted ? Color(nsColor: .systemBlue).opacity(hovering ? 1 : 0.9)
                    : Color.primary.opacity(hovering ? 0.1 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(shortcut.map { "\(action.label)  \($0)" } ?? action.label)
    }
}

/// A tag chip on the detail card.
private struct PreviewChipButton: View {
    let chip: PreviewChip
    @State private var hovering = false

    var body: some View {
        Button(action: chip.run) {
            HStack(spacing: 5) {
                if let symbol = chip.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .medium))
                }
                Text(chip.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(hovering ? 0.18 : 0.09), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Search in \(chip.label)")
    }
}

struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
