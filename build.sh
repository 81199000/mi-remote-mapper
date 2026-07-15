#!/bin/zsh
# Build MiRemote Mapper.app from source. Requires Xcode Command Line Tools.
#   xcode-select --install
set -e
cd "$(dirname "$0")"

APP="build/MiRemote Mapper.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Apple Silicon build, min macOS 13. Intel Macs: change target to x86_64-apple-macos13.0
swiftc -O \
  -target arm64-apple-macos13.0 \
  Sources/Model.swift Sources/Engine.swift Sources/UI.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/MiRemote"

# Ad-hoc sign so it runs locally (first launch: right-click > Open).
xattr -cr "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"

echo "✅ Built: $APP"
echo "   打开：open \"$APP\"   （首次右键→打开）"
