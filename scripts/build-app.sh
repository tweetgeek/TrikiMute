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

codesign --force \
    --sign "$IDENTITY" \
    --identifier pl.tweetgeek.trikimute \
    --entitlements "$ROOT/Sources/TrikiMute/TrikiMute.entitlements" \
    --options runtime \
    "$APP"

codesign --verify --verbose=2 "$APP"
echo "Zbudowano: $APP"
