# macOS app

SwiftUI app in `apps/macos/LauncherApp/lumio-app`. Runs on Apple Silicon with macOS 15+. The build uses Xcode 26.

```text
lumio-app/
├── lumio_appApp.swift, ContentView.swift   entry point
├── Window/                                 floating panel, settings window, window setup
├── Views/
│   ├── Spotlight/                          launcher UI: search field, results, previews
│   ├── Settings/                           settings and update status
│   └── Commands/                           `:kill` and other commands
├── Models/                                 LauncherResult and theme models
└── Support/
    ├── Launcher/                           engine bridge, hotkey, processes, trash, tools
    ├── UI/                                 motion
    └── …                                   config path, theme store, update checker, single-instance lock
```

## Responsibilities

- **Panel and hotkey.** `LauncherPanelWindow` is a non-activating floating panel; `GlobalHotKeyManager` registers `Option+Space`. `SingleInstanceLock` keeps one copy running.
- **Search.** `EngineBridge` talks to the Rust core. `LauncherSearchLogic` and `SpotlightBackend` turn results into rows and handle filters.
- **Actions.** `SpotlightOpener`, `ToolLauncher` and `TrashService` open, reveal, run or delete the selected item.
- **Processes.** `ProcessFinderModel`, `ProcessScoring` and `ProcessService` list, rank and force quit running processes.
- **Updates.** Release builds can use Sparkle if a feed URL and signing key are configured. The fork ships without a feed.

## Rust build phase

The Xcode project builds the bridge with `cargo +nightly` and links `RustBuild/liblumio_ffi.a`.

## Tests

`LauncherLogicTests/` holds the pure-logic tests (search logic, delete target, config lines, process scoring, bridge error mapping, …).
