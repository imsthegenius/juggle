#!/bin/bash
# release.sh — build a signed, notarized, drag-to-Applications DMG of Juggle.
#
# Pipeline: swift build (release) → assemble Juggle.app → sign with Developer ID +
# hardened runtime → notarize (notarytool) → staple → build a DMG → staple the DMG.
# Output lands in dist/. Uses only built-in tools (codesign/notarytool/stapler/hdiutil).
#
# One-time prerequisite (yours — needs your Apple ID):
#   xcrun notarytool store-credentials "$JUGGLE_NOTARY_PROFILE" \
#     --apple-id <your-apple-id> --team-id <team-id> --password <app-specific-password>
#
# Usage:
#   scripts/release.sh                 # full: sign + notarize + DMG
#   scripts/release.sh --skip-notarize # sign + DMG only (fast local check; not distributable)
#
# Overrides (env): JUGGLE_SIGN_IDENTITY, JUGGLE_TEAM_ID, JUGGLE_NOTARY_PROFILE

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$REPO_ROOT/dist"
APP="$DIST/Juggle.app"
ENTITLEMENTS="$REPO_ROOT/Packaging/Juggle.entitlements"
INFO_PLIST="$REPO_ROOT/Packaging/Info.plist"
NOTARY_PROFILE="${JUGGLE_NOTARY_PROFILE:-juggle-notary}"

SKIP_NOTARIZE=0
[ "${1:-}" = "--skip-notarize" ] && SKIP_NOTARIZE=1

# ── Resolve signing identity + team ───────────────────────────────────────────
IDENTITY="${JUGGLE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F\" '/Developer ID Application/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "ERROR: no 'Developer ID Application' identity found."; exit 1; }
TEAM_ID="${JUGGLE_TEAM_ID:-$(printf '%s' "$IDENTITY" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"

echo "==> identity : $IDENTITY"
echo "==> team     : $TEAM_ID"
echo "==> version  : $VERSION"

# ── Build (release) ───────────────────────────────────────────────────────────
echo "==> swift build -c release"
( cd "$REPO_ROOT" && swift build -c release ) 2>&1 | tail -3
BINARY="$(cd "$REPO_ROOT" && swift build -c release --show-bin-path)/Juggle"

# ── Assemble a clean bundle in dist/ ──────────────────────────────────────────
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$REPO_ROOT/Packaging/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BINARY" "$APP/Contents/MacOS/Juggle"
chmod +x "$APP/Contents/MacOS/Juggle"

# ── Sign (hardened runtime + secure timestamp) ────────────────────────────────
# libghostty is static — no nested code — so a single signature on the bundle is
# sufficient (no --deep needed).
echo "==> signing with Developer ID + hardened runtime"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

echo "==> verifying signature"
codesign --verify --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E "^(Authority|TeamIdentifier|Timestamp|Runtime|Signature)" || true

# ── Build the drag-to-Applications DMG (the app is already signed above) ──────
echo "==> building DMG"
DMG="$DIST/Juggle-$VERSION.dmg"
# Stable, version-independent alias so a public download link
# (/releases/latest/download/Juggle.dmg) never breaks when VERSION changes.
DMG_STABLE="$DIST/Juggle.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/Juggle.app"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "Juggle" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> verifying DMG container"
hdiutil verify "$DMG" >/dev/null

echo "==> signing DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"

if [ "$SKIP_NOTARIZE" -eq 1 ]; then
  cp -f "$DMG" "$DMG_STABLE"
  ( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
  ( cd "$DIST" && shasum -a 256 "$(basename "$DMG_STABLE")" > "$(basename "$DMG_STABLE").sha256" )
  echo ""
  echo "✅ Signed DMG built → $DMG  (NOT notarized — local check only)"
  echo "   SHA-256 → $DMG.sha256"
  echo "   Stable alias → $DMG_STABLE (+ .sha256)"
  exit 0
fi

# ── Notarize the DMG (ONE round trip; notarization covers the app inside) ─────
# We notarize + staple the DMG itself so it opens with no Gatekeeper warning, and
# the app inside is covered by the same notarization.
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "ERROR: notary profile '$NOTARY_PROFILE' not found. Store it once with:"
  echo "  xcrun notarytool store-credentials \"$NOTARY_PROFILE\" --apple-id <id> --team-id $TEAM_ID --password <app-specific-pw>"
  exit 1
fi

echo "==> notarizing the DMG (uploads to Apple and waits — can be slow on their side)…"
SUBMIT_OUT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
printf '%s\n' "$SUBMIT_OUT" | sed 's/^/    /'
SUB_ID="$(printf '%s\n' "$SUBMIT_OUT" | awk '/  id: /{print $2; exit}')"
STATUS="$(printf '%s\n' "$SUBMIT_OUT" | awk -F'status: ' '/status: /{v=$2} END{print v}')"
[ -n "$SUB_ID" ] && printf '%s\n' "$SUB_ID" > "$DIST/.last-notarization-id"

if [ "$STATUS" != "Accepted" ]; then
  echo "ERROR: notarization status='$STATUS' (submission $SUB_ID). Notary log follows:"
  [ -n "$SUB_ID" ] && xcrun notarytool log "$SUB_ID" --keychain-profile "$NOTARY_PROFILE" || true
  exit 1
fi

echo "==> stapling the DMG"
xcrun stapler staple "$DMG"

echo "==> verification"
hdiutil verify "$DMG" >/dev/null && echo "  ✓ hdiutil verify passed"
xcrun stapler validate "$DMG" && echo "  ✓ stapler validate passed"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
# Publish a stable, version-independent copy too (already notarized+stapled).
cp -f "$DMG" "$DMG_STABLE"
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256" )
( cd "$DIST" && shasum -a 256 "$(basename "$DMG_STABLE")" > "$(basename "$DMG_STABLE").sha256" )

echo ""
echo "✅ Notarized + stapled → $DMG"
echo "   SHA-256 → $DMG.sha256"
echo "   Stable alias → $DMG_STABLE (+ .sha256)"
