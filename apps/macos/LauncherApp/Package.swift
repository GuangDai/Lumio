// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LauncherLogic",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "LauncherLogic", targets: ["LauncherLogic"]),
    ],
    targets: [
        .target(
            name: "LauncherLogic",
            path: "lumio-app",
            // Xcode compiles the entire app. SwiftPM builds only the shared logic.
            exclude: [
                "Assets.xcassets",
                "ContentView.swift",
                "Info.plist",
                "Lumio.entitlements",
                "Models/ThemeSettings.swift",
                "Support/AppDelegate.swift",
                "Support/AppUIState.swift",
                "Support/AppVersion.swift",
                "Support/Browser",
                "Support/ConfigPathResolver.swift",
                "Support/LaunchModes.swift",
                "Support/Launcher/AccessibilityAccess.swift",
                "Support/Launcher/AccessibilityDoctor.swift",
                "Support/Launcher/AppBundleLocator.swift",
                "Support/Launcher/AppExcludeWriter.swift",
                "Support/Launcher/EngineBridge.swift",
                "Support/Launcher/FileManagerApp.swift",
                "Support/Launcher/FileSearchPaths.swift",
                "Support/Launcher/GlobalHotKeyManager.swift",
                "Support/Launcher/HotKeyShortcut.swift",
                "Support/Launcher/IndexStats.swift",
                "Support/Launcher/LauncherProcessFeature.swift",
                "Support/Launcher/OpenWindows.swift",
                "Support/Launcher/PathDisplay.swift",
                "Support/Launcher/ProcessFinderModel.swift",
                "Support/Launcher/ProcessService.swift",
                "Support/Launcher/RecentItems.swift",
                "Support/Launcher/SpotlightFolders.swift",
                "Support/Launcher/SpotlightQueue.swift",
                "Support/Launcher/SystemCommands.swift",
                "Support/Launcher/TerminalApp.swift",
                "Support/Launcher/TrashService.swift",
                "Support/MemoryTrim.swift",
                "Support/ThemeStore+Appearance.swift",
                "Support/ThemeStore.swift",
                "Support/UI",
                "Support/UpdateChecker.swift",
                "Views",
                "Window",
                "lumio_appApp.swift",
            ],
            sources: [
                "Support/Launcher/HintText.swift",
                "Support/AppConstants.swift",
                "Support/ConfigFileLines.swift",
                "Support/Launcher/LauncherSearchLogic.swift",
                "Support/Launcher/FolderAddressQuery.swift",
                "Support/Launcher/ProcessScoring.swift",
                "Support/Launcher/DeleteTargetLogic.swift",
                "Support/Launcher/BridgeErrorMapping.swift",
                "Support/Launcher/QueryRetentionPolicy.swift",
                "Support/SingleInstanceLock.swift",
                "Models/LauncherResult.swift",
                "Support/Launcher/HiddenTabs.swift",
                "Support/Launcher/QuickBubbles.swift",
                "Support/DelayedAction.swift",
                "Support/RowIconCache.swift",
            ]
        ),
        .testTarget(
            name: "LauncherLogicTests",
            dependencies: ["LauncherLogic"],
            path: "LauncherLogicTests"
        ),
    ]
)
