#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app='build/Codex Limits.app'
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" build/module-cache
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon.icns' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.1.0' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 3' "$app/Contents/Info.plist"
swiftc -O -target arm64-apple-macos13.0 Sources/main.swift -o "$app/Contents/MacOS/CodexLimits" -framework Cocoa -module-cache-path build/module-cache
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$app/Contents/MacOS/CodexLimits" --self-test
ditto -c -k --sequesterRsrc --keepParent "$app" build/Codex-Limits-macOS-arm64.zip
(cd build && shasum -a 256 Codex-Limits-macOS-arm64.zip > SHA256SUMS.txt)
echo 'Ready: build/Codex-Limits-macOS-arm64.zip'
