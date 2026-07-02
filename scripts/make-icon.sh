#!/bin/bash
# make-icon.sh — generate Packaging/AppIcon.icns from Packaging/icon-source.png.
#
# Produces the macOS icon grid: the artwork as an 824px rounded-rect tile, centered
# on a 1024 canvas with a soft drop shadow (so it sits correctly among native Mac
# icons), then every .icns size via iconutil. Re-run after changing the source art.
#
# Requires: ImageMagick (`magick`), sips, iconutil.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${1:-$REPO_ROOT/Packaging/icon-source.png}"
OUT="$REPO_ROOT/Packaging/AppIcon.icns"
PREVIEW="${JUGGLE_ICON_PREVIEW:-/tmp/juggle-icon-preview.png}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

TILE=824
RADIUS=185   # ≈ macOS continuous corner for an 824 tile

# 1) art → square tile
magick "$SRC" -resize "${TILE}x${TILE}^" -gravity center -extent "${TILE}x${TILE}" "$WORK/art.png"
# 2) rounded-rect mask (white rect on black) → copy into the art's alpha
magick -size "${TILE}x${TILE}" xc:black -fill white \
  -draw "roundrectangle 0,0,$((TILE-1)),$((TILE-1)),$RADIUS,$RADIUS" "$WORK/mask.png"
magick "$WORK/art.png" "$WORK/mask.png" -alpha off -compose CopyOpacity -composite "$WORK/tile.png"
# 3) soft shadow, centered on a 1024 canvas
magick "$WORK/tile.png" \( +clone -background black -shadow 35x10+0+10 \) +swap \
  -background none -layers merge +repage \
  -gravity center -background none -extent 1024x1024 "$WORK/icon_1024.png"

# 4) iconset → icns
ICONSET="$WORK/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z "$s" "$s"           "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
  sips -z "$((s*2))" "$((s*2))" "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
cp "$WORK/icon_1024.png" "$PREVIEW"
echo "wrote $OUT (preview: $PREVIEW)"
