//
//  SpotlightOpener.swift
//  lumio-app
//
//  Opens a Spotlight launcher row and runs Tab actions. Same approach as the legacy
//  launcher (LauncherView+Results): check the target still exists, record usage in the
//  core so ranking improves next time, open apps without stealing focus if the user
//  has moved elsewhere while a heavy app is launching.
//

import AppKit
import OSLog

nonisolated private let spotlightOpenLog = Logger(subsystem: "com.cavaldos.Lumio", category: "spotlight-open")

enum SpotlightOpener {
    enum Outcome {
        /// Handed off to another app: the launcher closes and does not return focus to the previous app.
        case launched
        /// Stay in the launcher and report via a toast.
        case message(String)
    }

    // MARK: - Open

    static func open(_ item: SpotlightItem, inFinder: Bool = false) -> Outcome {
        switch item.kind {
        case .tab:
            guard let tab = item.tab else { return .message("Tab not found") }
            // AppleScript: off the main thread so the launcher closes without a hitch.
            Task.detached(priority: .userInitiated) { await BrowserTabs.shared.activate(tab) }
            return .launched
        case .url:
            guard let target = item.target, let url = URL(string: target),
                  BrowserOpening.open(url, preferredAppPath: item.iconPath)
            else { return .message("Couldn't open link in a supported browser") }
            return .launched
        case .app:
            return openApplication(item)
        case .folder:
            guard let target = item.target, target.hasPrefix("/"),
                  SpotlightBackend.isBrowsableFolder(at: URL(fileURLWithPath: target).standardizedFileURL)
            else { return .message("Folder isn't available") }
            FileManagerApp.openFolder(target, inFinder: inFinder)
            recordUsage(item, action: "open_folder")
            return .launched
        case .setting:
            // LaunchServices forwards this scheme to System Settings.
            guard let target = item.target, let url = URL(string: target),
                  url.scheme == "x-apple.systempreferences", NSWorkspace.shared.open(url)
            else { return .message("Couldn't open \(item.name)") }
            recordUsage(item, action: "open_app")
            return .launched
        case .cmd, .prefix, .command, .process, .help, .tagHint, .window:
            // The view handles rows that depend on its state.
            return .message("Nothing to open")
        }
    }

    private static func openApplication(_ item: SpotlightItem) -> Outcome {
        guard let target = item.target, target.hasPrefix("/") else { return .message("No application to open") }
        let app = URL(fileURLWithPath: target)
        guard !BrowserOpening.isBlockedApplication(app) else { return .message("Safari is unavailable in Lumio") }
        guard FileManager.default.fileExists(atPath: target) else {
            // Still in the index but deleted/moved: refresh so the core drops it.
            Task.detached(priority: .utility) { _ = EngineBridge.shared.requestIndexRefresh() }
            return .message("This item no longer exists — refreshing the index")
        }

        launchApp(at: target)
        recordUsage(item, action: "open_app")
        return .launched
    }

    // MARK: - Actions (⌘K)

    static func perform(_ action: SpotlightAction, on item: SpotlightItem) -> Outcome {
        guard let target = item.target else { return .message("No target") }
        switch action {
        case .open:
            return open(item)
        case .reveal:
            guard !isURLScheme(target), FileManager.default.fileExists(atPath: target) else {
                return .message("Couldn't show in \(FileManagerApp.name)")
            }
            if item.kind == .folder, !SpotlightBackend.isBrowsableFolder(at: URL(fileURLWithPath: target)) {
                return .message("Folder isn't available")
            }
            FileManagerApp.reveal(target)
            return .launched
        case .hideApp:
            guard let app = runningApp(at: target) else { return .message("\(item.name) isn't running") }
            app.hide()
            return .launched
        case .quitApp:
            guard let app = runningApp(at: target) else { return .message("\(item.name) isn't running") }
            app.terminate()
            return .launched
        case .measureCPU, .killProcess, .moveToTrash, .emptyTrash, .excludeApp:
            // These actions need the launcher's process model or confirmation state.
            return .message("Not applicable")
        }
    }

    static func runningApp(at path: String) -> NSRunningApplication? {
        let wanted = URL(fileURLWithPath: path).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == wanted
        }
    }

    // MARK: - System

    private static func launchApp(at path: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let ownPID = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config) { app, error in
            DispatchQueue.main.async {
                if let error {
                    spotlightOpenLog.error("openApplication failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return
                }
                guard let app else { return }
                // Heavy apps take a few seconds to launch: if the user has already switched to
                // another app, don't pull focus back.
                if let front = NSWorkspace.shared.frontmostApplication,
                   front.processIdentifier != ownPID,
                   front.processIdentifier != app.processIdentifier
                {
                    return
                }
                app.activate()
            }
        }
    }

    private static func isURLScheme(_ target: String) -> Bool {
        target.contains(":") && !target.hasPrefix("/")
    }

    /// Record the open in the core (opens the DB, so it runs in the background without blocking launcher close).
    private static func recordUsage(_ item: SpotlightItem, action: String) {
        guard let candidateID = item.candidateID else { return }
        Task.detached(priority: .utility) {
            if let error = EngineBridge.shared.recordUsage(candidateID: candidateID, action: action) {
                spotlightOpenLog.error("record usage failed: \(error.code, privacy: .public)")
            }
        }
    }
}
