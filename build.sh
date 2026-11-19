#!/bin/sh
set -eu
cd "$(dirname "$0")"
dest="${1:-../QuickShot.app}"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
cp Assets/QuickShot.icns "$dest/Contents/Resources/"
cp Info.plist "$dest/Contents/"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 -O -module-cache-path "${TMPDIR:-/tmp}/quickshot-module-cache" *.swift -o "$dest/Contents/MacOS/QuickShot"
codesign --force --sign - --identifier local.quickshot.camera "$dest"
