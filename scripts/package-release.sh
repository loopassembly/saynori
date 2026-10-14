#!/usr/bin/env bash
# Packages Saynori for download: build/release/Saynori-<version>.dmg (drag to Applications), a .zip of the app,
# and SHA-256 checksums. Nothing from your own setup (keys, settings, history) goes into the package.
#   ./scripts/package-release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh --bundle-only
APP=build/Saynori.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT=build/release
rm -rf "$OUT" && mkdir -p "$OUT"

# Disk image: the app next to an Applications shortcut.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Saynori" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT/Saynori-$VERSION.dmg"
rm -rf "$STAGE"

# Plain zip of the app (keeps the code signature intact).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Saynori-$VERSION.zip"

(cd "$OUT" && shasum -a 256 Saynori-"$VERSION".dmg Saynori-"$VERSION".zip > SHA256SUMS.txt)
echo "▸ Packaged Saynori $VERSION:"
ls -lh "$OUT" | tail -n +2 | awk '{print "   " $5 "  " $9}'
