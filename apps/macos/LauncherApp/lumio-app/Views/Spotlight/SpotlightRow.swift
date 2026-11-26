import AppKit
import SwiftUI

// One result row of the launcher list, and the pieces only rows use.
//
// The row is a separate `Equatable` view so SwiftUI can skip rendering rows whose inputs
// stayed the same when the selection moves.

struct SpotlightRow: View, Equatable {
    private typealias Metric = SpotlightSpec.Metric

    let item: SpotlightItem
    let selected: Bool
    /// :kill — this process is armed, the next Enter kills it.
    let armed: Bool
    /// App rows: the app is running (green dot; ⏎ switches to it).
    var running = false
    /// Typed words shown in bold in the title (Fluent Search-style); empty = plain title.
    var highlight: [String] = []
    let palette: SpotlightPalette
    let reduceMotion: Bool
    let namespace: Namespace.ID

    static func == (lhs: SpotlightRow, rhs: SpotlightRow) -> Bool {
        lhs.item.sameRowContent(as: rhs.item)
            && lhs.selected == rhs.selected && lhs.armed == rhs.armed
            && lhs.running == rhs.running && lhs.highlight == rhs.highlight
            && lhs.palette.isDark == rhs.palette.isDark
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.namespace == rhs.namespace
    }

    private var selection: SpotlightSelection {
        SpotlightSelection(
            isSelected: selected,
            fill: palette.rowSel,
            namespace: namespace,
            reduceMotion: reduceMotion
        )
    }

    var body: some View {
        HStack(spacing: 11) {
            SpotlightRowIcon(item: item, size: 30, isSelected: selected)
            // Narrow left column (right half is the preview): name on top, path / description below.
            VStack(alignment: .leading, spacing: 2) {
                titleText
                    .font(.system(size: 14.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let meta = rowMeta, !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if running {
                // Running: ⏎ switches to it instead of launching.
                Circle()
                    .fill(Color(nsColor: .systemGreen))
                    .frame(width: 6, height: 6)
                    .help("Running")
            }
            // Change IMMEDIATELY on selection: cross-fading them in step with the slide would make the
            // text of both states overlap.
            Group {
                if selected || armed {
                    keyCap("⏎")
                }
            }
            .animation(nil, value: selected)
        }
        .padding(.horizontal, 10)
        .frame(height: Metric.rowHeight)
        .modifier(selection)
        .contentShape(Rectangle())
    }

    /// The title, with the typed words in bold where they appear (like Fluent Search).
    private var titleText: Text {
        if item.kind == .web, item.target == nil, !item.id.hasPrefix("suggest|") {
            return Text("Search the web — \(item.name)")
        }
        guard !highlight.isEmpty else { return Text(item.name) }
        var title = AttributedString(item.name)
        for word in highlight {
            var remaining = title.startIndex..<title.endIndex
            while let match = title[remaining].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                title[match].font = .system(size: 14.5, weight: .heavy)
                remaining = match.upperBound..<title.endIndex
            }
        }
        return Text(title)
    }

    /// Secondary line under the name. Apps don't need one (the name is enough); action rows show the item name.
    private var rowMeta: String? {
        switch item.kind {
        case .app: return nil
        case .cmd: return nil
        default: return item.meta ?? item.kind.label
        }
    }

    private func keyCap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12))
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(palette.kbd, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// Background of the selected row. ONE single bar is moved between rows via
/// `matchedGeometryEffect`, so it SLIDES when the selection change happens inside
/// `withAnimation` (arrow keys, hover) and jumps straight when it doesn't (new results).
/// The newly selected row also zooms up one beat and back — same approach as the legacy launcher's
/// SelectionPill, just a different color (follows the glass, not the theme).
struct SpotlightSelection: ViewModifier {
    let isSelected: Bool
    let fill: Color
    let namespace: Namespace.ID
    let reduceMotion: Bool

    @State private var zoomed = false
    /// Incremented on each zoom: the return leg of an old beat doesn't cut off a new one
    /// (moving away then back very quickly).
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            // Pushed down so the row's icon zooms in step.
            .environment(\.isSelectionZoomed, zoomed)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: SpotlightSpec.Metric.rowRadius, style: .continuous)
                        .fill(fill)
                        .matchedGeometryEffect(id: "spotlight.selection", in: namespace)
                        .scaleEffect(zoomed ? SpotlightMotion.pillZoomScale : 1)
                }
            }
            // No .animation(value:) here: attached per row, every row the
            // selection bar passes over would flash.
            .onChange(of: isSelected) { _, selected in
                generation &+= 1
                guard selected else {
                    zoomed = false
                    return
                }
                guard !reduceMotion else { return }
                let mine = generation
                withAnimation(SpotlightMotion.zoomIn) { zoomed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + SpotlightMotion.zoomInSeconds) {
                    guard mine == generation else { return }
                    withAnimation(SpotlightMotion.zoomOut) { zoomed = false }
                }
            }
    }
}

/// The row's icon, zooming with the selection beat. A separate view because a view can't read
/// environment values set by its own body.
struct SpotlightRowIcon: View {
    @Environment(\.isSelectionZoomed) private var zoomed
    let item: SpotlightItem
    let size: CGFloat
    let isSelected: Bool

    var body: some View {
        SpotlightTile(item: item, size: size)
            .scaleEffect(isSelected && zoomed ? SpotlightMotion.iconZoomScale : 1)
    }
}

private struct SelectionZoomedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True during the one-shot zoom of the newly selected row.
    var isSelectionZoomed: Bool {
        get { self[SelectionZoomedKey.self] }
        set { self[SelectionZoomedKey.self] = newValue }
    }
}
