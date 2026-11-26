import Darwin
import Foundation

/// Drops the launcher's preview, highlighted text, and row icon caches and returns the
/// freed memory to macOS. The caches rebuild on demand.
enum MemoryTrim {
    /// How long the launcher must stay hidden before its caches are dropped. Trimming on every
    /// hide made the next open rebuild every row icon on the main thread; a launcher that is
    /// reopened within minutes keeps its warm caches, and one left alone still shrinks.
    static let hiddenTrimDelay: Duration = .seconds(180)

    /// Called after the launcher has stayed hidden for `hiddenTrimDelay`, and when macOS
    /// reports memory pressure.
    static func releaseCaches() async {
        HighlightedTextCache.purge()
        RowIconCache.purge()
        PreviewFacts.purge()
        await QuickLookPreviewService.shared.purge()
        malloc_zone_pressure_relief(nil, 0)
    }

    nonisolated(unsafe) private static var pressureSource: DispatchSourceMemoryPressure?

    /// Trims as soon as macOS says memory is short, without waiting out `hiddenTrimDelay`.
    static func watchMemoryPressure() {
        guard pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            Task { @MainActor in await releaseCaches() }
        }
        source.resume()
        pressureSource = source
    }
}
