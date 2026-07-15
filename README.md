# MiRemote Mapper · 小米/安卓电视遥控器 → Mac

Use an **Android TV voice remote** (Xiaomi Mi Bluetooth Voice Remote and most
Google **ATVV** remotes) on your Mac: turn its **microphone into a real Mac
input device**, and freely **remap every button** to any keyboard key.

把**安卓电视语音遥控器**(小米蓝牙语音遥控器2Pro 等)接到 Mac:
**语音键当麦克风用**,并把**所有按键自由映射**到任意键盘按键。

> ⚠️ Works only with Android‑TV voice remotes that implement Google's ATVV
> service. **Apple TV Siri Remote is NOT supported** (Apple‑proprietary, its
> mic is not exposed to third parties).
> 仅支持走 Google ATVV 协议的安卓电视遥控器;**不支持 Apple TV 的 Siri Remote**。

---

## Features · 功能

- 🎙️ **Voice key → microphone.** Hold the mic button and your speech is decoded
  and streamed into a virtual audio device, so any app (dictation, Zoom, voice
  input, recorders…) can use the remote as a microphone.
- ⌨️ **Voice key → keystroke.** The mic button can also send a key you choose
  (default: Right ⌘), e.g. to trigger macOS Dictation while you speak.
- 🎛️ **Full button remapping.** D‑pad / OK / Back / Home / Menu / TV / Power /
  Volume — record any target key (including modifiers & combos) per button.
- 🖱️ **Mouse & scroll control.** Any button can instead drive the pointer
  (hold to move, with acceleration), left/right click (hold = drag), or scroll —
  turning the remote into an air mouse.
  按键也可映射为鼠标移动/左右键(按住可拖拽)/滚轮,遥控器秒变空中鼠标。
- 🔊 **Voice enhancement.** Decoded speech runs through a DSP chain
  (high‑pass → presence EQ → noise gate → AGC → soft limiter) for louder,
  cleaner mic audio. 语音经高通/人声EQ/噪声门/自动增益/软限幅增强,更响更干净。
- 📊 **Menu‑bar app.** Lives in the menu bar; click for status, open Settings to
  configure.
- 🚀 **Launch at login.** One toggle in Settings (requires the app to be in
  `/Applications`). 设置里一键开机自启（需将 App 放入"应用程序"文件夹）。

## How it works · 原理

- **Voice** rides Google's **ATVV** GATT service
  (`AB5E0001‑5A21‑4F05‑BC7D‑AF01F617B664`). Audio is **IMA ADPCM, 16 kHz mono**,
  decoded in real time, enhanced (high‑pass → presence EQ → noise gate → AGC →
  soft limiter), and pushed into **[BlackHole]** (a virtual audio device) so
  other apps see it as a mic.
- **Buttons** are read straight from the remote over HID
  (`IOHIDManager`), and remapped by synthesizing key events (`CGEvent`); a
  `CGEventTap` suppresses the original key so there's no double input.

## Requirements · 依赖

- macOS 13+ (Apple Silicon or Intel)
- [Homebrew](https://brew.sh) (for installing the virtual audio device)
- Xcode Command Line Tools — `xcode-select --install`
- **[BlackHole 2ch]** virtual audio device (installed by `install.sh`)

> We **don't bundle** BlackHole — it is GPL‑3.0 and ships as a system audio
> driver. We depend on it and install it via Homebrew. 项目**不打包**虚拟声卡,
> 而是依赖并用 Homebrew 安装,避免许可与驱动签名问题。

## Install · 安装(一键)

```sh
git clone https://github.com/<you>/mi-remote-mapper.git
cd mi-remote-mapper
./install.sh
```

`install.sh` will: install BlackHole via Homebrew → build the app → copy it to
`/Applications`. If BlackHole was just installed, **reboot** once.

Then:
1. Pair the remote with your Mac in **System Settings → Bluetooth**.
2. Open **MiRemote Mapper** (first launch: right‑click → Open).
3. Click the menu‑bar icon → **设置 / Settings**, grant **Bluetooth**,
   **Accessibility**, **Input Monitoring** when prompted.
4. To feed the remote mic into an app, set that app's input device to
   **“BlackHole 2ch”**.

### Build only · 仅编译

```sh
./build.sh          # produces build/MiRemote Mapper.app
```

## Permissions · 权限说明(为什么需要)

| Permission | Why |
|---|---|
| Bluetooth | connect to the remote & receive the voice stream |
| Accessibility | synthesize the remapped keystrokes / suppress originals |
| Input Monitoring | read the remote's raw HID button reports |

This app reads the remote's key presses and synthesizes keystrokes (like any
remapper) and captures the remote's audio. **Everything is local** — nothing is
uploaded. The source is here so you can audit it.
本工具会读取遥控器按键并合成键盘事件、采集遥控器音频,**全部本地处理,不上传**。

## Supporting other remotes · 适配其它遥控器

Button reading is currently matched to Xiaomi's USB vendor id `0x2717`
(`Sources/Engine.swift`, `setupHID`). Other brands' **voice** should work as‑is
(ATVV is standard); for **button** remapping on another brand, change the vendor
id. PRs to auto‑discover ATVV remotes are welcome.

## Project layout · 结构

```
Sources/        Model.swift · Engine.swift · UI.swift · main.swift
Resources/      Info.plist · AppIcon.icns
build.sh        build the .app
install.sh      BlackHole + build + install to /Applications
```

## Credits · 致谢

- Google **ATVV** (Android TV Voice) protocol — community reverse engineering.
- **[BlackHole]** by Existential Audio (GPL‑3.0) — the virtual audio device.

## License

[MIT](LICENSE) © 2026 零度汉化

[BlackHole]: https://github.com/ExistentialAudio/BlackHole
[BlackHole 2ch]: https://github.com/ExistentialAudio/BlackHole
