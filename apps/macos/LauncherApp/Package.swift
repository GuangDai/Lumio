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
            sources: [
                "Support/Launcher/HintText.swift",
                "Support/AppConstants.swift",
                "Support/ConfigFileLines.swift",
                "Support/Launcher/LauncherSearchLogic.swift",
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
