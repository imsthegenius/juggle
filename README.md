# Juggle

A native macOS terminal cockpit for developers running multiple agents, repositories, and Git worktrees at once.

Juggle opens real Ghostty-powered terminal windows, keeps them visible as separate macOS windows, groups them by project/worktree, and surfaces the things that need you: blocked agents, finished runs, failed commands, and pull requests that are ready to review or merge.

![Juggle icon](docs/assets/juggle-logo.png)

## Download

The public download page is:

```text
https://getjuggle.xyz
```

The recommended install is the signed, notarized DMG linked from that page:

1. Download the latest `Juggle.dmg`.
2. Open the DMG.
3. Drag `Juggle.app` to `Applications`.
4. Launch Juggle from Applications.

On first use, macOS may ask for folder access when you open projects from Desktop, Documents, Downloads, network volumes, or removable drives. Juggle needs that access only to open terminal windows in your project folders and run local `git`/`gh` commands there.

## What it does

- **One native window per terminal** — no tab pile-up.
- **Project and worktree awareness** — see which repo/worktree every terminal belongs to.
- **Menu-bar cockpit** — open projects, jump to terminals, create worktrees, and review PR state from one compact surface.
- **Needs-you surface** — ambient indicators for blocked agents, completed runs, errors, and PRs ready to merge.
- **PR safety** — merge actions re-check GitHub live before acting and use `--match-head-commit` so a stale green badge cannot merge a moved branch.
- **Terminal.app-like profiles** — Basic, Clear Dark, and Clear Light profiles are matched to macOS Terminal defaults.

## Requirements

- macOS 14 or later
- Apple Silicon Mac
- GitHub CLI (`gh`) for PR features

## Build from source

Requires Xcode / Swift toolchain compatible with Swift 6.

```bash
swift build
swift test
```

For local installs during development, use the signed bundle path:

```bash
scripts/juggle-ship.sh
```

Avoid launching workspace builds directly with `swift run Juggle` when testing real projects. macOS folder permissions are tied to the app's code identity; unbundled ad-hoc builds can create confusing temporary folder-access grants. Use `scripts/juggle-ship.sh` for local use and `scripts/juggle-diagnostic.sh` for visual diagnostics.

## Release builds

Distribution builds are produced as drag-to-Applications DMGs:

```bash
scripts/release.sh                 # signed + notarized DMG
scripts/release.sh --skip-notarize # local packaging check only
```

A public release should ship only the notarized DMG from `dist/`, attached to a GitHub Release.

Release notes for the current version live in [RELEASE_NOTES.md](RELEASE_NOTES.md).

## License

MIT. Juggle embeds Ghostty through `libghostty-spm`; see [NOTICES.md](NOTICES.md) for third-party notices.
