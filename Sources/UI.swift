import SwiftUI

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle().fill(ok ? Color.green : Color.orange).frame(width: 10, height: 10)
    }
}

// Compact popover shown from the menu-bar icon: connection status + 设置 / 退出
struct StatusView: View {
    @ObservedObject var e: Engine
    var onSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("小米遥控器映射").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                row("蓝牙", e.btOn)
                row("遥控器连接", e.remoteConnected)
                row("语音通道就绪", e.handshakeReady)
                row("BlackHole 声卡", e.blackholeFound)
                if e.micStreaming {
                    HStack(spacing: 8) { StatusDot(ok: true); Text("🎤 正在采集语音").foregroundColor(.green) }
                }
            }
            Divider()
            HStack {
                Button(action: onSettings) {
                    Label("设置…", systemImage: "slider.horizontal.3")
                }.keyboardShortcut(",", modifiers: .command)
                Spacer()
                Button("退出", action: onQuit)
            }
        }
        .padding(16)
        .frame(width: 260)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in e.checkPermissions() }
    }
    func row(_ name: String, _ ok: Bool) -> some View {
        HStack(spacing: 8) { StatusDot(ok: ok); Text(name); Spacer()
            Text(ok ? "正常" : "未就绪").font(.caption).foregroundColor(ok ? .green : .orange) }
    }
}

struct ContentView: View {
    @ObservedObject var e: Engine
    @State private var learning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("小米遥控器 · 按键映射与语音麦克风")
                    .font(.title2).bold()

                permissions
                Divider()
                connection
                Divider()
                voiceRow
                Divider()
                buttonsSection
                Divider()
                logSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 560, minHeight: 640)
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            e.checkPermissions()
        }
    }

    var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("权限与依赖").font(.headline)
            permRow("蓝牙", e.btOn, action: nil, hint: "系统设置里打开蓝牙")
            permRow("辅助功能（合成/拦截按键必需）", e.axTrusted, action: { e.requestAX(); e.openAXSettings() }, hint: "点右侧授权")
            permRow("输入监控（读取遥控器按键必需）", e.inputMonitoringOK, action: { e.requestInputMonitoring(); e.openInputMonitoringSettings() }, hint: "点右侧授权")
            permRow("BlackHole 虚拟声卡（当麦克风用）", e.blackholeFound, action: nil, hint: "需安装 BlackHole")
        }
    }
    func permRow(_ name: String, _ ok: Bool, action: (() -> Void)?, hint: String) -> some View {
        HStack {
            StatusDot(ok: ok)
            Text(name)
            Spacer()
            if !ok, let a = action {
                Button("去授权", action: a)
            } else if !ok {
                Text(hint).foregroundColor(.secondary).font(.caption)
            } else {
                Text("正常").foregroundColor(.green).font(.caption)
            }
        }
    }

    var connection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("遥控器连接").font(.headline)
            HStack { StatusDot(ok: e.remoteConnected); Text(e.remoteConnected ? "已连接：小米蓝牙语音遥控器" : "未连接（请在系统蓝牙里配对连接遥控器）") }
            HStack { StatusDot(ok: e.handshakeReady); Text(e.handshakeReady ? "语音通道就绪" : "语音通道未就绪") }
            if e.micStreaming { HStack { StatusDot(ok: true); Text("🎤 正在采集语音 → BlackHole").foregroundColor(.green) } }
        }
    }

    // one row: physical button -> recorded target key, with 录制 / 清除 buttons
    func mappingRow(usage: Int, name: String, display: String) -> some View {
        let capturing = (e.capturingUsage == usage)
        return HStack(spacing: 10) {
            Text(name).frame(width: 110, alignment: .leading)
            if usage >= 0 {
                Text(String(format:"0x%02x", usage)).font(.caption).foregroundColor(.secondary).frame(width: 44)
            } else {
                Text("语音").font(.caption).foregroundColor(.secondary).frame(width: 44)
            }
            Image(systemName: "arrow.right").foregroundColor(.secondary)
            // current mapping / capture state
            Text(capturing ? "⌨️ 请按键盘上的键…" : display)
                .foregroundColor(capturing ? .blue : .primary)
                .frame(width: 170, alignment: .leading)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.gray.opacity(capturing ? 0.18 : 0.08)))
            if capturing {
                Button("取消") { e.cancelCapture() }
            } else {
                Button("录制") { e.beginCapture(usage: usage) }
                Menu("鼠标/滚轮") {
                    ForEach(KeyNames.specials, id: \.code) { sp in
                        Button(sp.name) { e.setSpecial(usage: usage, keycode: sp.code) }
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: 92)
                Button("清除") { e.clearMapping(usage: usage) }.foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    var voiceRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("语音键").font(.headline)
            mappingRow(usage: -1, name: "语音键", display: e.config.voice.display)
            Toggle("同时开启麦克风（灌入 BlackHole）", isOn: Binding(
                get: { e.config.voiceStartsMic },
                set: { e.config.voiceStartsMic = $0; e.saveConfig() }))
            Text("按住语音键 = 按住所录制的键 + （可选）麦克风。").font(.caption).foregroundColor(.secondary)
        }
    }

    var buttonsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("按键映射").font(.headline)
            Text("点「录制」后在 Mac 键盘上按目标键（支持组合键/修饰键）。").font(.caption).foregroundColor(.secondary)
            ForEach(e.config.buttons) { b in
                mappingRow(usage: b.usage, name: b.name, display: b.display)
            }
        }
    }

    var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("日志").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(e.log.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 140).background(Color.gray.opacity(0.08)).cornerRadius(6)
        }
    }
}
