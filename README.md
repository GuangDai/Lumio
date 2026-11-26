<div align="center">
    <img src="apps/macos/LauncherApp/lumio-app/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width=160 height=160>
    <h1>Lumio</h1>
    <p><strong>A fast, free and open-source keyboard launcher for macOS.</strong></p>
    <p>Press <code>Option+Space</code> to find apps, folders, settings, windows and browser tabs. Lumio combines a Rust search index with a native SwiftUI launcher and Fluent Search–inspired tags and actions.</p>
    <p>A fork of <a href="https://github.com/kunkka19xx/look"><strong>kunkka19xx/look</strong></a>. Huge thanks to <a href="https://github.com/kunkka19xx">kunkka19xx</a> for the original work this project builds on.</p>
</div>

<div align="center">

[![Build](https://github.com/GuangDai/Lumio/actions/workflows/ci.yml/badge.svg)](https://github.com/GuangDai/Lumio/actions/workflows/ci.yml)
![Platform](https://img.shields.io/badge/platform-macOS-blue?style=flat-square)
![Requirements](https://img.shields.io/badge/requirements-macOS%2015%2B-fa4e49?style=flat-square)
[![GitHub stars](https://img.shields.io/github/stars/cavaldos/Lumio?style=flat-square)](https://github.com/cavaldos/Lumio/stargazers)
[![GitHub forks](https://img.shields.io/github/forks/cavaldos/Lumio?style=flat-square)](https://github.com/cavaldos/Lumio/network/members)
[![License](https://img.shields.io/github/license/cavaldos/Lumio?style=flat-square)](LICENSE)
[![Sponsor](https://img.shields.io/badge/Sponsor%20%E2%9D%A4%EF%B8%8F-8A2BE2?style=flat-square)](https://ko-fi.com/calvados)

</div>

## How Lumio compares

Lumio is a free, open-source keyboard launcher for apps, folders, browser tabs and system commands.

| | Lumio | Spotlight | [Alfred](https://www.alfredapp.com) | [Raycast](https://www.raycast.com) |
| --- | --- | --- | --- | --- |
| Price | Free | Free, built into macOS | Free core; paid Powerpack for additional features | Free core; paid Pro plan for cloud sync and AI |
| Open source | Yes (GPL-3.0) | No | No | No |
| Platform | macOS 15+, Apple Silicon | macOS | macOS | macOS |
| App search | Yes | Yes | Yes | Yes |
| Extensions and workflows | No, built-in modes only | Limited (Shortcuts) | Yes, large workflow community | Yes, extension store (TypeScript) |
| Window management | No | No | Via workflows | Yes, built in |
| AI chat | No | — | Via workflows | Yes (Pro) |

**Choose Lumio if** you want a free, open-source launcher that works without an account or a subscription.

**Choose Raycast or Alfred if** you need an extension ecosystem, window management, AI chat or a large library of ready-made workflows. Both are more mature and more extensible than Lumio.

**Choose Spotlight if** you want zero setup and only need basic app, file and web search. It is already on your Mac.

**Lumio's limits.** No plugin or workflow system, no window management, no AI features, no cloud sync, and it runs only on Apple Silicon Macs with macOS 15 or later.

_Competitor features and pricing change often. Check their websites for the latest details._

## Install

Requires macOS 15 or later on Apple Silicon.

1. Open the latest successful [CI](https://github.com/GuangDai/Lumio/actions/workflows/ci.yml) run on `main` and download the `Lumio-macOS-arm64` artifact. GitHub requires sign-in for artifact downloads.
2. Extract the archive, open `Lumio.dmg` and drag `Lumio.app` into Applications.
3. If Gatekeeper blocks the ad-hoc signed build, clear its quarantine flag:

```bash
xattr -dr com.apple.quarantine /Applications/Lumio.app
```

Open Lumio and press **`Option+Space`**. To update, download the latest build.

For local development, see [CONTRIBUTING.md](CONTRIBUTING.md#development-setup).

## Uninstall

Quit Lumio and move `/Applications/Lumio.app` to the Trash. To remove its settings and data too, remove `~/.lumio` and `~/Library/Application Support/lumio`.

## Usage

| Action | Shortcut |
| --- | --- |
| Show / hide Lumio | `Option+Space` |
| Settings | `Cmd+Shift+Space` |
| Open / run | `Enter` |
| Show in Finder | `Cmd+F` |
| Open the selected result's action page | `Tab` or `Cmd+K` |
| Hide the selected app from results | `Cmd+Shift+H` |
| Use a launcher quick button | `Cmd+1` … `Cmd+3` (depends on button order) |
| Search tag (`apps`, `folders`, `windows`…) | type keyword, then `Tab` |
| Browse search tags | `Option+T` |
| Cycle result filters | `Shift+Tab` |
| Pin / unpin a result | `Cmd+Shift+P` |
| Command mode | `Cmd+/` |
| Help | `Cmd+H` |
| Close | `Esc` |

### Fluent Search–inspired search

Lumio fuzzy-searches apps, folders and settings. Results can also include bookmarks, Chromium history, open browser tabs and windows. Results learn from what you open, and the detail pane shows actions for the selected result.

Matching applications appear first in general searches. Built-in macOS apps display their Simplified Chinese names when available and can also be found by their English names.

Type a tag and press `Tab` to narrow a search. Tags can be stacked, and `Option+T` opens the tag browser:

```text
apps Tab mail              Find apps matching mail
folders Tab D/T            Find folder paths such as Downloads/Telegram
bookmark Tab lumio         Find saved bookmarks matching lumio
windows Tab                List open windows
```

Press `Enter` on an open browser tab to switch to it. Pin results to Home with `Cmd+Shift+P`, or enable recently used apps in Settings → General → **Suggestions when empty**.

Search for `settings` to find System Settings, or press `Tab` on the `settings` keyword to search its individual panes. Search for `Lumio Settings` to open this app's settings.

### Open a folder in Finder

Search for Finder, select its application result, and press `Tab` to open its details and actions. Type a folder name, abbreviated path such as `D/T`, or full local address to switch the page to folder results. A file address resolves to its parent directory. Press `Enter` to open the selected folder in Finder, or choose **Open in Terminal**.

From the main search field, use `cd ~/Library` or `cd D/T` to go straight to folder results. The default folder index includes `~/Library` and hidden folders such as `~/.config`.

See [Search tags and browser tabs](assets/docs/search-tags.md) for supported browsers, tags, shortcuts and configuration.

**Commands.** Type `:` or press `Cmd+/` for `:kill <name, PID or port>`, `:emptytrash` and `:help`. Type `> npm run dev` to run a terminal command.

## Configuration

Settings live in `~/.lumio/config`, created on first launch. Use Settings (`Cmd+Shift+Space`) to configure folder indexing, shortcuts and appearance. You can also edit the config file and press `Cmd+Shift+;` to reload.

Options include search aliases, Processes tab visibility and the order of the launcher quick buttons.

## Permissions

Most features work without special permissions. macOS may request access when you use these features:

- **Accessibility**: list or switch to open windows.
- **Automation**: access open tabs in each supported browser, or empty the Trash via Finder.

## Privacy and network access

App, folder and settings indexing, browser data lookup and query matching run locally. Opening a URL passes it to a supported non-Safari browser.

## Documentation

- [Architecture](assets/docs/architecture.md)
- [Rust core](assets/docs/core.md)
- [FFI bridge](assets/docs/ffi-bridge.md)
- [macOS app](assets/docs/macos-app.md)
- [Search tags and browser tabs](assets/docs/search-tags.md)
- [Build and release](assets/docs/build-and-release.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Acknowledgments

Based on [cavaldos/Lumio](https://github.com/cavaldos/Lumio), which was forked from [look](https://github.com/kunkka19xx/look) by [kunkka19xx](https://github.com/kunkka19xx).

## License

[GPL-3.0](LICENSE). Lumio is and will always remain open-source and free.

## Star History

<a href="https://star-history.com/#cavaldos/Lumio&Date">
    <img src="https://api.star-history.com/svg?repos=cavaldos/Lumio&type=Date" alt="Star History Chart" width="500">
</a>
