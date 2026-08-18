#!/usr/bin/env bash
# Składa podpisany pakiet .app z produktu SPM.
# Podpis stałą tożsamością jest wymagany: macOS wiąże z nim zgody na Bluetooth
# i Automation, a podpis ad-hoc unieważnia je przy każdej przebudowie.
set -euo pipefail

CONFIG="${1:-debug}"
IDENTITY="Apple Development: Sebastian Dawidziak"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/TrikiMute.app"

cd "$ROOT"
swift build -c "$CONFIG" --product TrikiMute

BIN="$(swift build -c "$CONFIG" --product TrikiMute --show-bin-path)/TrikiMute"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TrikiMute"
cp "$ROOT/Sources/TrikiMute/Info.plist" "$APP/Contents/Info.plist"

# The app icon is built from icon.png at the repo root rather than shipped
# as a pre-made binary, so the bundle stays reproducible from the artwork.
#
# icon.png is 1061x992 (not square, as .icns requires) and carries a
# caption strip along the bottom ("Universal Meeting Mute Button") that
# becomes an illegible smear at 16px while stealing room from the bottle
# cap the icon is actually about. The crop below — an 890x890 square
# starting 85px down from the top-left — was chosen by eye: it keeps the
# complete cap, excludes the caption entirely, and leaves no visible seam.
# If the artwork changes, re-validate these four numbers against the new
# image rather than assuming they still apply.
ICONSET="$ROOT/build/AppIcon.iconset"
CROPPED="$ROOT/build/icon-cropped.png"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -c 890 890 --cropOffset 0 85 "$ROOT/icon.png" --out "$CROPPED" >/dev/null

# Full size set an .iconset expects: each size plus its @2x Retina variant.
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$CROPPED" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$CROPPED" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$CROPPED"

codesign --force \
    --sign "$IDENTITY" \
    --identifier pl.tweetgeek.trikimute \
    --entitlements "$ROOT/Sources/TrikiMute/TrikiMute.entitlements" \
    --options runtime \
    "$APP"

codesign --verify --verbose=2 "$APP"
echo "Zbudowano: $APP"
