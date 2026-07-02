#!/bin/bash
# juggle-ship.sh — reproducible packaging for ~/Applications/Juggle.app.
#
# Builds (release), assembles the bundle, copies the canonical Info.plist
# (Packaging/Info.plist — the one with the folder usage-description strings), then
# signs with a STABLE identity so the Designated Requirement is pinned to a
# certificate/team — not to the per-build cdhash — and macOS folder-access grants
# survive rebuilds. Prefers JUGGLE_LOCAL_SIGN_IDENTITY when set, then any
# Apple Development identity, then Developer ID Application. It NEVER signs
# ad-hoc: a plain rebuild through this path must never reinstall an ad-hoc binary
# (ad-hoc pins TCC to the cdhash, which changes every build and revokes
# Desktop/Documents — breaking every shell Juggle spawns there). If no stable
# identity is present it errors loudly instead. No hardened runtime
# (--options runtime) — that's for notarized release builds only; no timestamp —
# the DR doesn't depend on it and local builds stay fast/offline.
#
# Usage: scripts/juggle-ship.sh [path-to-prebuilt-binary]

set -euo pipefail

APP_DEST="$HOME/Applications/Juggle.app"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── Build (unless a binary was supplied) ──────────────────────────────────────
if [ $# -ge 1 ]; then
  NEW_BINARY="$1"
  echo "==> using supplied binary: $NEW_BINARY"
else
  echo "==> swift build -c release"
  ( cd "$REPO_ROOT" && swift build -c release ) 2>&1 | tail -3
  NEW_BINARY="$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)/Juggle"
fi
[ -f "$NEW_BINARY" ] || { echo "ERROR: binary not found: $NEW_BINARY"; exit 1; }

# ── Assemble bundle ───────────────────────────────────────────────────────────
echo "==> assembling $APP_DEST"
mkdir -p "$APP_DEST/Contents/MacOS" "$APP_DEST/Contents/Resources"
cp "$REPO_ROOT/Packaging/Info.plist" "$APP_DEST/Contents/Info.plist"
cp "$REPO_ROOT/Packaging/AppIcon.icns" "$APP_DEST/Contents/Resources/AppIcon.icns"
cp "$NEW_BINARY" "$APP_DEST/Contents/MacOS/Juggle"
chmod +x "$APP_DEST/Contents/MacOS/Juggle"

# ── Sign ──────────────────────────────────────────────────────────────────────
# Use a STABLE, team-based identity so the Designated Requirement is pinned to the
# team (certificate leaf[subject.OU]), NOT to the per-build cdhash. That is exactly
# what makes macOS TCC folder-access grants survive rebuilds: an ad-hoc signature
# pins TCC to the cdhash, which changes every build, so every rebuild revokes
# Desktop/Documents and breaks every shell Juggle spawns under those folders.
#
# Resolution order — every option below is stable/team-pinned, never ad-hoc:
#   1. JUGGLE_LOCAL_SIGN_IDENTITY, if set
#   2. any "Apple Development: …" identity
#   3. "Developer ID Application: …" (distribution cert; release.sh uses the same family)
# If none are present we ERROR OUT instead of signing ad-hoc — a plain rebuild
# through this path must never reinstall an ad-hoc binary.
#
# No --options runtime: hardened runtime is notarization-only and, without the pty/
# terminal-host entitlements, can break the embedded terminal; it is not required for
# TCC persistence. No --timestamp: the DR does not depend on it and local builds stay
# fast/offline. Revisit both only when notarizing for distribution (scripts/release.sh).
IDENTITY="${JUGGLE_LOCAL_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ] && ! security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" >/dev/null; then
  echo "ERROR: JUGGLE_LOCAL_SIGN_IDENTITY was set but not found: $IDENTITY" >&2
  echo "       Run: security find-identity -v -p codesigning" >&2
  exit 1
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F\" '/Apple Development/{print $2; exit}')"
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning \
    | awk -F\" '/Developer ID Application/{print $2; exit}')"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> signing with '$IDENTITY' (stable, team-pinned DR — folder grants persist across rebuilds)"
  codesign --force --sign "$IDENTITY" "$APP_DEST"
else
  echo "ERROR: no stable signing identity found — refusing to sign ad-hoc." >&2
  echo "       Run:  security find-identity -v -p codesigning" >&2
  echo "       Expected an 'Apple Development' or 'Developer ID Application' identity." >&2
  echo "       Or set JUGGLE_LOCAL_SIGN_IDENTITY to a specific installed identity." >&2
  echo "       Juggle must be stably signed — never ad-hoc — or macOS revokes its" >&2
  echo "       folder (TCC) permissions on every rebuild." >&2
  exit 1
fi

# ── Report ────────────────────────────────────────────────────────────────────
echo "==> done."
codesign -dvvv "$APP_DEST" 2>&1 | grep -E "Authority|TeamIdentifier|CodeDirectory" || true
codesign -d -r- "$APP_DEST" 2>&1 | grep -i "designated" || true
