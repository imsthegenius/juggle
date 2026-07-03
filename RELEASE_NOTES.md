# Juggle 0.1.0

Juggle is a native macOS terminal cockpit for developers running multiple
agents, repositories, and Git worktrees at once. This is the first public
release.

## Install

1. Download Juggle from `https://getjuggle.xyz`.
2. Open the DMG and drag `Juggle.app` into `Applications`.
3. Launch Juggle from Applications and open your first project.

The DMG is Developer ID signed, notarized by Apple, and stapled, so it opens
without a Gatekeeper warning. Verify the download with the published SHA-256
(run it from the folder holding the downloaded file):

```bash
shasum -a 256 -c Juggle.dmg.sha256
```

## Requirements

- macOS 14 or later
- Apple Silicon Mac
- GitHub CLI (`gh`) for pull-request features

## Highlights

- One native window per terminal — no tab pile-up.
- Project and worktree awareness across every open terminal.
- Menu-bar cockpit for opening projects, jumping to terminals, creating
  worktrees, and reviewing PR state.
- Needs-you surface for blocked agents, finished runs, errors, and PRs ready to
  merge.
- PR safety: merge actions re-check GitHub live and use `--match-head-commit`
  so a stale green badge cannot merge a moved branch.
- Terminal.app-like Basic, Clear Dark, and Clear Light profiles.

## Notes

On first use, macOS may ask for folder access when you open projects from
Desktop, Documents, Downloads, network volumes, or removable drives. Juggle
needs that access only to open terminal windows in your project folders and run
local `git`/`gh` commands there.
