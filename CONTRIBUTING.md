# Contributing to Lumio

Thanks for contributing! Bug reports, ideas and pull requests are all welcome.

## Issues

Search existing issues first. A good bug report has:

- what you expected and what happened
- numbered steps to reproduce, and how often it happens (`always`, `sometimes`, `once`)
- macOS version, Lumio version (or commit), Apple Silicon or Intel
- logs, screenshots or the crash text if you have them

For a feature request, describe the problem first, then the behavior you'd like.

## Development setup

**Requirements:** macOS 15+, Xcode 26 (its SDK is needed for Liquid Glass), Rust stable and nightly (the Xcode build phase builds the Rust bridge with `cargo +nightly`), GNU Make.

```text
apps/macos/LauncherApp/   Swift app (Xcode project: lumio-app.xcodeproj)
core/                     Rust: query engine, indexing, matching, ranking, storage, tools
bridge/ffi/               Rust FFI bridge linked into the app
scripts/                  build.sh (local DMG), release.sh, notify-update.sh, lumiodev, Makefile.mac
assets/                   app icon (icon-source.png is the original)
tools/perf/               benchmarks (separate crate, never bundled)
```

Build and run (from the repo root):

```bash
make app-run       # Debug build, launched with ~/.lumio/config.dev
make app-run-dev   # installs a side-by-side "/Applications/Lumio Dev.app" and runs it
make help          # every target
```

Run the checks before opening a PR:

```bash
cargo test --workspace --manifest-path core/Cargo.toml
cargo test --manifest-path bridge/ffi/Cargo.toml
```

## App icon

Replace `assets/icon-source.png` with the new artwork (1024 px or larger), then run:

```bash
make icons
```

`assets/generate-icons.py` removes a solid background (the edge turns transparent, with no leftover fringe), trims the empty margin, centers the shape on Apple's macOS icon grid and writes `assets/icon.png` plus every size in `AppIcon.appiconset`. Run `pipx run assets/generate-icons.py --help` for the options (`--padding 0` fills the whole canvas).

## Pull requests

- branch from `main` and target `main`; it is the only long-lived branch and must stay releasable
- keep the change focused; no unrelated formatting
- rebase onto the latest `main` (or merge `origin/main` whole) before asking for review
- update the README when user-visible behavior changes
- explain *why* in the PR description, and add before/after screenshots for UI changes

Commit prefixes: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.

## Building a DMG locally

```bash
./scripts/build.sh            # release/Lumio.dmg (Release, Apple Silicon, ad-hoc signed)
./scripts/build.sh v1.2.3     # same, with the version shown in About
```

CI builds the release with this same script.

## GitHub Actions

The [CI workflow](.github/workflows/ci.yml) builds and uploads an Apple Silicon DMG when changes are pushed to `main` or a pull request targets it. It also supports manual runs.

## Releasing (maintainers)

```bash
./scripts/release.sh v1.2.3
```

`release.sh` runs the Rust tests and the local DMG build, then pushes the tag to `origin`. The [Release workflow](.github/workflows/release.yml) builds and attaches the DMG to the GitHub release. Use `--skip-checks` to skip the local checks.
