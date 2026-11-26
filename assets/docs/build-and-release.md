# Build and release

Run everything from the repo root. `Makefile` includes `scripts/Makefile.mac`; `make help` lists every target.

## Requirements

macOS 15+, Xcode 26, Rust stable and nightly, GNU Make.

## Common targets

| Command | Does |
| --- | --- |
| `make app-run` | Debug build, launched with `~/.lumio/config.dev` |
| `make app-run-dev` | Installs a side-by-side `/Applications/Lumio Dev.app` and runs it |
| `make app-logs` | Follow the app's logs |
| `make db-path`, `db-status`, `db-shell`, `db-reset` | Inspect or reset the SQLite index |
| `make icons` | Regenerate the app icon from `assets/icon-source.png` |

## Checks

```bash
cargo test --workspace --manifest-path core/Cargo.toml
cargo test --manifest-path bridge/ffi/Cargo.toml
```

## Local DMG

```bash
./scripts/build.sh            # release/Lumio.dmg (Release, Apple Silicon, ad-hoc signed)
./scripts/build.sh v1.2.3     # same, with the version shown in About
```

## GitHub Actions

The CI workflow runs on pushes to `main`, pull requests targeting `main`, and manual dispatch. Download the `Lumio-macOS-arm64` artifact from a successful run for the ad-hoc signed app packaged as a DMG.

## Releasing (maintainers)

```bash
./scripts/release.sh v1.2.3
```

`release.sh` requires a clean worktree and a commit on `origin/main`. It runs the Rust tests and the local DMG build, then pushes the version tag. The Release workflow builds and attaches the DMG to the fork's GitHub release.
