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
  Sources/Model.swift Sources/Engine.swift Sources/UI.swift Sources/AudioRoute.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/MiRemote"

# 稳定签名：优先用持久证书（Apple Development），身份跨构建不变，
# macOS 的辅助功能/输入监控授权就不会每次升级都被撤销。
# （ad-hoc 签名每次构建 cdhash 都变 → TCC 视为新 App → 需重新授权）
SIGN_IDENTITY="Apple Development: 1020118183@qq.com (L6CRLKZ45K)"
xattr -cr "$APP" 2>/dev/null || true
if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_IDENTITY"; then
  echo "🔑 稳定签名: $SIGN_IDENTITY"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  echo "⚠️ 未找到 $SIGN_IDENTITY，退回 ad-hoc 签名（每次构建需重新授权）"
  codesign --force --deep --sign - "$APP"
fi

echo "✅ Built: $APP"
echo "   打开：open \"$APP\"   （首次右键→打开）"
