#!/bin/zsh
# Builds Martin.app next to this script. Run: ./build.sh, then open Martin.app
set -e
cd "$(dirname "$0")"
swift build -c release
APP=Martin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Martin "$APP/Contents/MacOS/Martin"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/martin.html Resources/ding.wav "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $(pwd)/$APP"
