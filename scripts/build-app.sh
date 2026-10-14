#!/usr/bin/env bash
# Builds, signs and installs Saynori.app.
#   ./scripts/build-app.sh            → build + install to /Applications and launch
#   ./scripts/build-app.sh --no-run   → build + install only
set -euo pipefail
cd "$(dirname "$0")/.."

APP=Saynori
BUNDLE_ID=com.saynori.app
# The app's previous name, cleaned up on install (settings and history are migrated by the app itself).
OLD_APP=TypeLikeMe
VERSION=1.0.0
OUT=build/$APP.app

# Cactus Needle engine for Whistle speech recognition (static library, not committed).
if [ ! -f Vendor/needle/libneedle.a ]; then
  echo "▸ Fetching Needle engine…"
  mkdir -p Vendor/needle
  curl -fsSL -o Vendor/needle/libneedle.a https://huggingface.co/Cactus-Compute/needle3/resolve/main/macos-arm64/libneedle.a
fi

echo "▸ Compiling (release)…"
swift build -c release --arch arm64 2>&1 | grep -Ev "^\[|Compiling|Planning" || true
BIN=.build/arm64-apple-macosx/release/$APP
[ -x "$BIN" ] || BIN=.build/release/$APP

echo "▸ Testing the formatter…"
if ! "$BIN" --test-formatter Tests/formatter-cases.json; then
  echo "✗ Formatter tests failed: not installing." >&2
  exit 1
fi

echo "▸ Assembling bundle…"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/$APP"
strip -x "$OUT/Contents/MacOS/$APP" 2>/dev/null || true

# App icon from the brand tile, placed on the macOS icon grid; menu-bar icon from the transparent character.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$BIN" --render-icon build/icon-1024.png Resources/Brand/saynori-app-icon.png
"$BIN" --render-menubar Resources/Brand/saynori-character.png "$OUT/Contents/Resources"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT/Contents/Resources/AppIcon.icns"

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP</string>
  <key>CFBundleDisplayName</key><string>Saynori</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Saynori listens only while you hold the dictation key, and turns your voice into text.</string>
  <key>NSAppleEventsUsageDescription</key><string>Saynori types your dictation into the app you're using.</string>
</dict>
</plist>
PLIST

# Sign with a stable identity so macOS keeps Accessibility/Mic grants across rebuilds.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
if [ -n "${IDENTITY:-}" ]; then
  echo "▸ Signing with: $IDENTITY"
  codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$OUT"
else
  echo "▸ No developer identity found — ad-hoc signing (permissions reset on each rebuild)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$OUT"
fi
codesign --verify --strict "$OUT"

# Seed the API key config from .env on first install (never compiled into the binary).
CONF_DIR="$HOME/Library/Application Support/$APP"
# Stop the old app first, then carry its data folder over so nothing is written to the old place mid-move.
pkill -x "$OLD_APP" 2>/dev/null || true
OLD_DIR="$HOME/Library/Application Support/$OLD_APP"
if [ -d "$OLD_DIR" ] && [ ! -e "$CONF_DIR" ]; then
  mv "$OLD_DIR" "$CONF_DIR"
  echo "▸ Moved your settings and history to $CONF_DIR"
fi
mkdir -p "$CONF_DIR"
if [ ! -s "$CONF_DIR/config.json" ] && [ -f .env ]; then
  KEY=$(grep -E '^SARVAM_API_KEY=' .env | head -1 | cut -d= -f2- | tr -d '"'"'"' \r')
  if [ -n "$KEY" ]; then
    printf '{\n  "keys" : {\n    "sarvam" : "%s"\n  }\n}\n' "$KEY" > "$CONF_DIR/config.json"
    chmod 600 "$CONF_DIR/config.json"
    echo "▸ Sarvam key saved to $CONF_DIR/config.json"
  fi
fi

DEST=/Applications
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
pkill -x "$APP" 2>/dev/null || true
sleep 0.3
# If the old app opened at login, the new one takes over that login item on first launch.
if [ -d "$DEST/$OLD_APP.app" ] && sfltool dumpbtm 2>/dev/null | grep -A8 "Name: $OLD_APP\$" | grep -q "Disposition: \[enabled"; then
  defaults write "$BUNDLE_ID" restoreLaunchAtLogin -bool YES
fi
rm -rf "$DEST/$APP.app" "$DEST/$OLD_APP.app"
cp -R "$OUT" "$DEST/"
echo "▸ Installed $DEST/$APP.app ($(du -sh "$DEST/$APP.app" | cut -f1))"

if [ "${1:-}" != "--no-run" ]; then
  open "$DEST/$APP.app"
  echo "▸ Launched. Look for the floating line at the bottom of your screen."
fi
