#!/bin/zsh
# One-command install: BlackHole virtual audio + build the app + move to /Applications.
# 一键安装：BlackHole 虚拟声卡 + 编译 App + 装入“应用程序”。
set -e
cd "$(dirname "$0")"

echo "== 1/4 检查 Homebrew =="
if ! command -v brew >/dev/null 2>&1; then
  echo "未安装 Homebrew。请先安装： https://brew.sh 然后重跑本脚本。"
  exit 1
fi

echo "== 2/4 安装 BlackHole 虚拟声卡（语音当麦克风所需，可能要求输入开机密码）=="
if [ -d "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver" ]; then
  echo "BlackHole 已安装，跳过。"
else
  brew install blackhole-2ch
  echo "⚠️  BlackHole 安装后需要【重启电脑】才生效。"
fi

echo "== 3/4 检查编译工具 =="
if ! command -v swiftc >/dev/null 2>&1; then
  echo "缺少 Xcode 命令行工具，正在触发安装（弹窗里点“安装”后重跑本脚本）…"
  xcode-select --install || true
  exit 1
fi

echo "== 4/4 编译并安装 App =="
./build.sh
DEST="/Applications/MiRemote Mapper.app"
rm -rf "$DEST"
cp -R "build/MiRemote Mapper.app" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true

cat <<'EOF'

✅ 完成！

接下来：
  1. 若刚装了 BlackHole，请【重启电脑】。
  2. 在系统蓝牙里，把 Android TV 语音遥控器和这台 Mac 配对连接。
  3. 打开“应用程序 → MiRemote Mapper”（首次右键→打开）。
  4. 点菜单栏图标 → 设置，按提示授权：蓝牙 / 辅助功能 / 输入监控。
  5. 要让某个 App 用遥控器麦克风：把它的输入设备选成 “BlackHole 2ch”。
EOF
