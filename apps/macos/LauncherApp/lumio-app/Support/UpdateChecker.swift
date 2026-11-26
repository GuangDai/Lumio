import AppKit
import Combine
import Sparkle

/// Sparkle installs updates only for release builds configured with their own
/// feed URL and public signing key.
final class UpdateChecker: NSObject, ObservableObject {
    static let shared = UpdateChecker()

    /// Requires both update settings in the release bundle.
    let isEnabled: Bool

    /// False while a check or an update is already in progress.
    @Published private(set) var canCheckForUpdates = false

    private var controller: SPUStandardUpdaterController?

    override init() {
        #if DEBUG
        isEnabled = false
        #else
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isEnabled = !AppVersion.isDevBuild && feed?.isEmpty == false && key?.isEmpty == false
        #endif
        super.init()
    }

    /// Starts Sparkle's scheduled checks (once a day). Call once at launch.
    func start() {
        guard isEnabled, controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set {
            objectWillChange.send()
            controller?.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// "Check for Updates": Sparkle shows the result (up to date, or the update).
    func checkForUpdates() {
        guard let controller else { return }
        // Lumio is a background (LSUIElement) app: Sparkle's windows only take
        // input while it is active.
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }
}

extension UpdateChecker: SPUUpdaterDelegate {
    /// Never show Sparkle's "check for updates automatically?" prompt: in a
    /// background app it freezes and comes back on every launch
    /// (jordanbaird/Ice#681). Settings > About has the same toggle.
    @objc(updaterShouldPromptForPermissionToCheckForUpdates:)
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }
}

extension UpdateChecker: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled check found an update: activate first so the alert Sparkle
    /// shows can take input while Lumio sits in the background.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return true
    }
}
