#!/bin/bash
# Build "Claude Usage Bar" (Apple Silicon + Intel) and put it in /Applications, then start it.
# Needs Xcode's command line tools: xcode-select --install
# ./build.sh --no-install builds dist/Claude Usage Bar.app only.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$here/dist/Claude Usage Bar.app"
tmp="$(mktemp -d)"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos14" \
    "$here/ClaudeUsageBar.swift" -o "$tmp/ClaudeUsageBar-$arch"
done
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "$tmp/ClaudeUsageBar-arm64" "$tmp/ClaudeUsageBar-x86_64" -output "$app/Contents/MacOS/ClaudeUsageBar"
cp "$here/Info.plist" "$app/Contents/Info.plist"
cp "$here/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
echo "Built $app"
[ "${1:-}" = "--no-install" ] && exit 0
pkill -x ClaudeUsageBar 2>/dev/null && sleep 0.5 || true
rm -rf "/Applications/Claude Usage Bar.app"
cp -R "$app" "/Applications/"
open "/Applications/Claude Usage Bar.app"
echo "Installed and started. Look for it in the menu bar."
