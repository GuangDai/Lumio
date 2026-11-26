//
//  SpotlightQuickLook.swift
//  lumio-app
//
//  The side preview's expand button opens the system Quick Look panel, the same one
//  Finder shows on Space for documents, images, and PDFs.
//  The launcher window is the panel's controller (see LauncherPanelWindow).
//

import AppKit
import Quartz
import SwiftUI

final class SpotlightQuickLook: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = SpotlightQuickLook()

    /// Only touched on the main thread (Quick Look calls its data source there).
    nonisolated(unsafe) private var url: URL?
    /// The side preview that the panel zooms out of and back into.
    @MainActor fileprivate weak var sourceView: NSView?
    /// The picture used during the zoom. Main thread only, like `url`.
    nonisolated(unsafe) private var transitionImage: NSImage?

    /// Opens Quick Look on `item`, or swaps what it shows if it is already open.
    static func show(item: SpotlightItem) {
        guard updateItem(item) else {
            NSSound.beep()
            return
        }
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        // The launcher sits at .floating: keep Quick Look above it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
    }

    /// Settings ▸ Shortcuts ▸ Quick Look (⌘Y by default); nil = turned off.
    static var shortcut: KeyCombo? { ThemeStore.shared.settings.hotKey(for: .quickLook) }

    static func matchesShortcut(_ event: NSEvent) -> Bool {
        shortcut?.matches(keyCode: event.keyCode, flags: event.modifierFlags) == true
    }

    static var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
    }

    static func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    /// ⌘Y: open on `item`, or close if already open.
    static func toggle(item: SpotlightItem) {
        if isVisible { close() } else { show(item: item) }
    }

    /// While open, follows the launcher's selection (↑ / ↓ inside the panel).
    static func follow(item: SpotlightItem) {
        guard isVisible, updateItem(item) else { return }
        QLPreviewPanel.shared()?.reloadData()
    }

    private static func updateItem(_ item: SpotlightItem) -> Bool {
        guard item.kind.isDocument, let path = item.target, path.hasPrefix("/"),
              FileManager.default.fileExists(atPath: path) else { return false }
        shared.url = URL(fileURLWithPath: path)
        shared.transitionImage = NSWorkspace.shared.icon(forFile: path)
        return true
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        url == nil ? 0 : 1
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        url.map { $0 as NSURL }
    }

    // MARK: - QLPreviewPanelDelegate (zoom animation)

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard Thread.isMainThread else { return .zero }
        return MainActor.assumeIsolated {
            guard let view = sourceView, let window = view.window, window.isVisible else { return .zero }
            return window.convertToScreen(view.convert(view.bounds, to: nil))
        }
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
        contentRect: UnsafeMutablePointer<NSRect>!
    ) -> Any! {
        transitionImage
    }
}

/// Marks the side preview as the place Quick Look zooms from and back into.
struct QuickLookSourceAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        SpotlightQuickLook.shared.sourceView = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        SpotlightQuickLook.shared.sourceView = view
    }
}

/// The small expand button on the side preview's top-right corner.
struct PreviewExpandButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(SpotlightQuickLook.shortcut.map { "Quick Look (\($0.display))" } ?? "Quick Look")
    }
}
