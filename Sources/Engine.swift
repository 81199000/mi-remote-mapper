import Foundation
import CoreBluetooth
import AVFoundation
import CoreAudio
import CoreGraphics
import ApplicationServices
import IOKit.hid
import Combine
import AppKit
import ServiceManagement
import UserNotifications

// ============ ADPCM (IMA, high-nibble-first, 16 kHz mono) ============
// 注意 nibble 顺序：ATVV 实测（对照米遥实现）为「高 nibble 在前」。
// 支持 v1.0 的 audioSync 重置（predictor/stepIndex）与 v0.4 帧头重置。
struct ADPCM {
    static let step: [Int32] = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    static let idxT: [Int32] = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]
    var pred: Int32 = 0, idx: Int32 = 0
    mutating func reset() { pred = 0; idx = 0 }
    mutating func reset(predictor: Int32, stepIndex: Int32) {
        pred = max(-32768, min(32767, predictor))
        idx = max(0, min(88, stepIndex))
    }
    mutating func nib(_ n: UInt8) -> Float {
        let s = ADPCM.step[Int(idx)]; var d = s >> 3
        if n & 4 != 0 { d += s }; if n & 2 != 0 { d += s >> 1 }; if n & 1 != 0 { d += s >> 2 }
        pred += (n & 8 != 0) ? -d : d; pred = max(-32768, min(32767, pred))
        idx += ADPCM.idxT[Int(n & 15)]; idx = max(0, min(88, idx))
        return Float(pred) / 32768.0
    }
    mutating func decode(_ data: Data) -> [Float] {
        var o = [Float](); o.reserveCapacity(data.count * 2)
        for b in data { o.append(nib((b >> 4) & 15)); o.append(nib(b & 15)) }
        return o
    }
}

// ============ 语音增强 DSP（16 kHz）：高通 → 人声EQ → 噪声门 → AGC → 软限幅 ============
struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0
    mutating func reset() { z1 = 0; z2 = 0 }
    mutating func run(_ x: Float) -> Float {
        let y = b0*x + z1
        z1 = b1*x - a1*y + z2
        z2 = b2*x - a2*y
        return y
    }
    static func highpass(f0: Float, fs: Float, q: Float) -> Biquad {
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q), a0 = 1+al
        var b = Biquad()
        b.b0 = (1+cw)/2/a0; b.b1 = -(1+cw)/a0; b.b2 = (1+cw)/2/a0
        b.a1 = -2*cw/a0; b.a2 = (1-al)/a0
        return b
    }
    static func peaking(f0: Float, fs: Float, q: Float, dbGain: Float) -> Biquad {
        let A = pow(10, dbGain/40)
        let w = 2*Float.pi*f0/fs, cw = cos(w), al = sin(w)/(2*q), a0 = 1 + al/A
        var b = Biquad()
        b.b0 = (1 + al*A)/a0; b.b1 = -2*cw/a0; b.b2 = (1 - al*A)/a0
        b.a1 = -2*cw/a0; b.a2 = (1 - al/A)/a0
        return b
    }
}

struct VoiceDSP {
    var hp = Biquad.highpass(f0: 100, fs: 16000, q: 0.707)   // 滤掉 100Hz 以下轰声
    var eq = Biquad.peaking(f0: 2500, fs: 16000, q: 1.0, dbGain: 3)  // 提亮人声清晰度
    var env: Float = 0      // 电平包络（噪声门/AGC 共用）
    var gate: Float = 0     // 门开度 0…1
    var gain: Float = 4     // AGC 当前增益，跨次保留学到的值
    mutating func reset() { hp.reset(); eq.reset(); env = 0; gate = 0 }
    mutating func process(_ xs: [Float]) -> [Float] {
        var out = [Float](); out.reserveCapacity(xs.count)
        let floorLevel: Float = 0.0025   // ≈ -52 dBFS，低于此视为底噪
        for x0 in xs {
            var x = eq.run(hp.run(x0))
            env = max(abs(x), env * 0.999)
            // 噪声门：说话快开（~1ms），停顿慢关（~100ms），关到 5% 而非全静音以免生硬
            let want: Float = env > floorLevel ? 1 : 0.05
            gate += (want - gate) * (want > gate ? 0.05 : 0.0005)
            x *= gate
            // AGC：把电平缓慢拉向目标响度，增益限 1…24 倍
            if env > floorLevel {
                let desired = min(24, max(1, 0.25 / max(env, 1e-4)))
                gain += (desired - gain) * 0.0008
            }
            out.append(tanh(x * gain))   // 软限幅防爆音
        }
        return out
    }
}

// ============ ring buffer feeding BlackHole ============
final class Ring {
    private var buf: [Float]; private var r = 0, w = 0, cnt = 0
    private let lock = NSLock(); let cap: Int
    init(_ c: Int) { cap = c; buf = [Float](repeating: 0, count: c) }
    func push(_ s: [Float]) { lock.lock(); defer { lock.unlock() }
        for v in s { buf[w] = v; w = (w+1)%cap; if cnt < cap { cnt += 1 } else { r = (r+1)%cap } } }
    func pop(_ p: UnsafeMutablePointer<Float>, _ n: Int) { lock.lock(); defer { lock.unlock() }
        var i = 0; while i < n && cnt > 0 { p[i] = buf[r]; r = (r+1)%cap; cnt -= 1; i += 1 }
        if i < n { underruns += 1 }   // 拉不到数据=音频空洞（丢包/主线程卡顿的下游证据）
        while i < n { p[i] = 0; i += 1 } }
    // 空洞计数（诊断）
    private(set) var underruns = 0
    func underrunCount() -> Int { lock.lock(); defer { lock.unlock() }; return underruns }
    func resetUnderruns() { lock.lock(); underruns = 0; lock.unlock() }
}

// ============ 音频处理通道：解码+DSP+质量统计（串行队列，移出主线程防音频空洞） ============
final class AudioPath {
    private let ring: Ring
    private let onLog: (String) -> Void
    private let q = DispatchQueue(label: "miremote.audio")
    private var codec = ADPCM()
    private var dsp = VoiceDSP()
    private var streaming = false
    private var version = 0
    private var frameSize = 0
    private var codec8k = false
    private var dspOn = true
    private var bytes = 0, packets = 0
    private var start: TimeInterval = 0
    private var peak: Float = 0, rmsSum: Double = 0, rmsN = 0, clipped = 0
    private var firstLogged = false
    // 预缓冲：会话开始先攒 ~300ms 再放行，吸收 BLE 突发抖动
    // （500ms 治长会话空洞有效但尾延迟明显——松开键后缓冲里半秒语音来不及播完被切；
    //  300ms 折中：抖动吸收够用，尾部损失可接受）
    private var pending: [Float] = []
    private var cushionBuilt = false
    private let cushionSamples = 4800   // 300ms @16kHz

    init(ring: Ring, onLog: @escaping (String) -> Void) {
        self.ring = ring
        self.onLog = onLog
    }

    func startSession(version: Int, frameSize: Int, codec8k: Bool, dspOn: Bool) {
        q.async {
            self.version = version; self.frameSize = frameSize
            self.codec8k = codec8k; self.dspOn = dspOn
            self.codec.reset(); self.dsp.reset()
            self.bytes = 0; self.packets = 0; self.peak = 0
            self.rmsSum = 0; self.rmsN = 0; self.clipped = 0
            self.firstLogged = false
            self.pending.removeAll(keepingCapacity: true)
            self.cushionBuilt = false
            self.start = ProcessInfo.processInfo.systemUptime
            self.ring.resetUnderruns()
            self.streaming = true
        }
    }

    func stopSession() {
        q.async {
            guard self.streaming else { return }
            self.streaming = false
            let dur = ProcessInfo.processInfo.systemUptime - self.start
            guard dur > 0.2 else { return }
            let expect = max(1, Int(dur * 8000))
            let comp = Double(self.bytes) / Double(expect)
            let rms = self.rmsN > 0 ? sqrt(self.rmsSum / Double(self.rmsN)) : 0
            let rmsDb = rms > 0 ? 20 * log10(Double(rms)) : -120
            let peakDb = self.peak > 0 ? 20 * log10(Double(self.peak)) : -120
            let und = self.ring.underrunCount()
            let diag: String
            if !self.cushionBuilt { diag = "缓冲垫未建立（丢包严重或会话过短）" }
            else if comp < 0.6 { diag = "疑似丢包/传输中断" }
            else if und > 20 { diag = "疑似系统卡顿致音频空洞" }
            else if rmsDb < -38 { diag = "疑似音量过低（离麦克风远或增益不足）" }
            else if self.clipped > Int(dur * 200) { diag = "疑似削顶失真（输入过大）" }
            else { diag = "传输与电平正常（若识别仍差，问题在识别端）" }
            self.onLog(String(format: "📊 语音统计: %.1fs, %d 字节(完整度 %.0f%%), 空洞 %d, 平均 %.1f dBFS, 峰值 %.1f dBFS, 削顶 %d → %@",
                              dur, self.bytes, comp * 100, und, rmsDb, peakDb, self.clipped, diag))
        }
    }

    func onRx(_ data: Data) {
        q.async {
            guard self.streaming else { return }
            self.packets += 1
            self.bytes += data.count
            if !self.firstLogged {
                self.firstLogged = true
                self.onLog("RX 音频数据开始流入：首包 \(data.count) 字节")
            }
            var samples: [Float]
            if self.version == 4 && self.frameSize > 0 && data.count == self.frameSize && data.count >= 6 {
                let b = [UInt8](data)
                let pred = Int16(bitPattern: UInt16(b[3]) << 8 | UInt16(b[4]))
                self.codec.reset(predictor: Int32(pred), stepIndex: Int32(b[5]))
                samples = self.codec.decode(Data(b.dropFirst(6)))
            } else {
                samples = self.codec.decode(data)
            }
            if self.codec8k && !samples.isEmpty {
                var up = [Float](); up.reserveCapacity(samples.count * 2)
                for s in samples { up.append(s); up.append(s) }
                samples = up
            }
            for s in samples {
                let a = abs(s)
                if a > self.peak { self.peak = a }
                if a >= 0.985 { self.clipped += 1 }
                self.rmsSum += Double(s) * Double(s)
                self.rmsN += 1
            }
            // 预缓冲垫：攒够 200ms 再开始向 ring 放行，之后直接透传
            if !self.cushionBuilt {
                self.pending.append(contentsOf: samples)
                if self.pending.count >= self.cushionSamples {
                    let chunk = self.pending
                    self.pending.removeAll(keepingCapacity: true)
                    self.cushionBuilt = true
                    self.ring.resetUnderruns()   // 缓冲建立后才计空洞，指标才真实
                    self.ring.push(self.dspOn ? self.dsp.process(chunk) : chunk)
                }
            } else {
                self.ring.push(self.dspOn ? self.dsp.process(samples) : samples)
            }
        }
    }

    func onSync(predictor: Int16, stepIndex: UInt8) {
        q.async { self.codec.reset(predictor: Int32(predictor), stepIndex: Int32(stepIndex)) }
    }
}

// magic marker so our own synthetic CGEvents are ignored by our tap
let kSyntheticMarker: Int64 = 0x4D49_5245  // "MIRE"

@MainActor
final class Engine: ObservableObject {
    // status published to UI
    @Published var btOn = false
    @Published var remoteConnected = false
    @Published var handshakeReady = false
    @Published var blackholeFound = false
    @Published var axTrusted = false
    @Published var inputMonitoringOK = false
    @Published var micStreaming = false
    @Published var lastButton = ""            // last raw button seen (for Learn)
    @Published var lastButtonUsage: Int = 0
    @Published var capturingUsage: Int? = nil // which button is currently recording a key (-1 = voice)
    @Published var launchAtLogin = (SMAppService.mainApp.status == .enabled)
    @Published var log: [String] = []

    // MCP 集成：配置热重载用（App 自身保存时记录 mtime，跳过误报）
    @Published var config = ConfigStore.load()

    private let ring = Ring(16000 * 4)
    // 音频处理通道（解码/DSP/质量统计，串行队列）
    private lazy var audio = AudioPath(ring: ring) { [weak self] s in
        Task { @MainActor in self?.L(s) }
    }
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!

    // BLE
    private var cm: CBCentralManager!
    private var dev: CBPeripheral?
    private var tx: CBCharacteristic?
    private var capsSent = false
    private var streaming = false

    // ATVV 协议状态（对照米遥实现补全：能力协商 → 0x0C 开麦 → 0x0D 关麦 → 0x0E 保活）
    private var atvvVersion = 0        // 0=未知, 4=v0.4, 10=v1.0
    private var atvvCodec: UInt8 = 0x02  // 0x01=8kHz, 0x02=16kHz
    private var atvvFrameSize = 0      // v0.4 帧长
    private var streamID: UInt8 = 0    // v1.0 流 ID
    private var micOpened = false
    private var capsRetryTimer: Timer?
    private var keepAliveTimer: Timer?
    private var voiceKeyDown = false   // 当前语音键按住中（用于保活窗口判断）

    // HID
    private var hidMgr: IOHIDManager?
    private var hidBufs: [UnsafeMutablePointer<UInt8>] = []
    private var lastHidKeycodeAt: [CGKeyCode: TimeInterval] = [:]
    private var voiceHidDown = false   // 语音键的 HID F5 正被按住（需持续吞掉）
    private var downButtonUsage: Int = 0
    private var downTarget: ButtonMapping?
    private var keyMonitor: Any?

    // event tap
    private var tap: CFMachPort?
    private var proxy: BTProxy!

    private let ATVV = CBUUID(string: "AB5E0001-5A21-4F05-BC7D-AF01F617B664")
    private let TX = CBUUID(string: "AB5E0002-5A21-4F05-BC7D-AF01F617B664")
    private let RX = CBUUID(string: "AB5E0003-5A21-4F05-BC7D-AF01F617B664")
    private let CTL = CBUUID(string: "AB5E0004-5A21-4F05-BC7D-AF01F617B664")
    private let seed = [CBUUID(string:"1812"), CBUUID(string:"180F"),
                        CBUUID(string:"AB5E0001-5A21-4F05-BC7D-AF01F617B664")]
    // 电池服务（0x180F / 0x2A19）
    private let BATTERY = CBUUID(string: "180F")
    private let BATTERY_LEVEL = CBUUID(string: "2A19")
    @Published var batteryLevel: Int? = nil   // 遥控器电量 %（nil=未知）
    // 当前设备（多遥控器按设备存配置）
    @Published var activeDeviceID: String? = nil
    @Published var activeDeviceName: String? = nil
    private var batteryLowNotified = false   // 低电量提醒已发（电量回升后复位，防刷屏）
    // 当前前台应用（按应用自动切换配置）
    @Published var activeAppBundleID: String? = nil
    @Published var activeAppName: String? = nil

    // 可用遥控器列表（手动切换用）
    struct RemoteDeviceInfo: Identifiable {
        let id: String
        let name: String
        var connected: Bool
    }
    @Published var knownDevices: [RemoteDeviceInfo] = []

    // 应用专用配置列表（UI 展示/切换用）
    struct AppProfileInfo: Identifiable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }
    @Published var appProfileList: [AppProfileInfo] = []

    // 配置目标应用（编辑模式：选定后录制的映射写入该应用配置，不随前台切换）
    @Published var editTargetBundleID: String? = nil
    @Published var editTargetName: String? = nil
    @Published var candidateApps: [AppProfileInfo] = []   // 可配置的应用候选（运行中 + 已有配置）

    var currentAppHasProfile: Bool {
        guard let devID = activeDeviceID, let bid = activeAppBundleID else { return false }
        return config.devices?[devID]?.appProfiles?[bid] != nil
    }
    var editTargetHasProfile: Bool {
        guard let devID = activeDeviceID, let bid = editTargetBundleID else { return false }
        return config.devices?[devID]?.appProfiles?[bid] != nil
    }

    /// 选择配置目标应用（nil = 退出编辑，恢复自动跟随前台应用）
    func selectEditTarget(bundleID: String?, name: String?) {
        editTargetBundleID = bundleID
        editTargetName = name
        guard let devID = activeDeviceID else { return }
        if let bid = bundleID {
            if config.devices?[devID]?.appProfiles?[bid] == nil {
                // 目标应用还没有配置 → 以当前生效配置为模板创建
                if config.devices == nil { config.devices = [:] }
                if config.devices?[devID] == nil {
                    config.devices?[devID] = DeviceProfile(name: activeDeviceName ?? devID, config: config)
                }
                if config.devices?[devID]?.appProfiles == nil { config.devices?[devID]?.appProfiles = [:] }
                config.devices?[devID]?.appProfiles?[bid] = AppProfile(name: name ?? bid, config: config)
                L("已为目标应用创建配置（当前配置为模板）：\(name ?? bid)")
            }
            // 载入目标应用配置到当前生效配置（供 UI 编辑）
            if let ap = config.devices?[devID]?.appProfiles?[bid] {
                config.buttons = ap.buttons
                config.voice = ap.voice
                config.voiceStartsMic = ap.voiceStartsMic
                config.voiceDSP = ap.voiceDSP
                config.voiceHotkey = ap.voiceHotkey
            }
            L("正在配置应用专用配置：\(name ?? bid)（编辑期间不随前台切换）")
        } else {
            applyAppProfile()   // 退出编辑 → 恢复前台应用自动切换
            saveConfig()
            L("已退出应用配置编辑模式，恢复自动跟随前台应用")
        }
    }

    static let logFile: FileHandle? = {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/miremote_engine.log")
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    func L(_ s: String) {
        NSLog("[MiRemote] %@", s)
        // 日志文件带时间戳（MCP 事件流解析依赖）
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = df.string(from: Date())
        Engine.logFile?.write(("[\(ts)] " + s + "\n").data(using: .utf8)!)
        log.append(s); if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // ---------- lifecycle ----------
    func start() {
        proxy = BTProxy(self)
        ConfigStore.save(config)   // persist merged button list (power/menu/TV/volume)
        refreshConfigMtime()
        setupAudio()
        checkPermissions()
        cm = CBCentralManager(delegate: proxy, queue: nil)
        installTap()
        setupHID()
        installKeyCapture()
        // 守护定时器：① 授权后自动补装事件拦截；② 输出设备脱离 BlackHole 时自动重挂；
        // ③ BLE 自愈（掉线未恢复 / 连接尝试卡死）
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.audioWatchdog()
                if self.tap == nil, AXIsProcessTrusted() {
                    self.installTap()
                    if self.tap != nil { self.L("辅助功能已授权，事件拦截已启用") }
                }
                // BLE 自愈：已连接但握手丢失 → 重新协商；连接尝试超过 15s 无结果 → 重置重试
                if self.remoteConnected, !self.handshakeReady, !self.capsSent {
                    self.L("BLE 自愈：已连接但语音通道未就绪，重新协商…")
                    if let p = self.dev { self.didServices(p) }
                }
                if self.reconnecting, let t = self.connectStartedAt,
                   ProcessInfo.processInfo.systemUptime - t > 15 {
                    self.L("BLE 自愈：连接尝试超时，重置重试…")
                    self.reconnecting = false
                    if let p = self.dev { self.cm?.cancelPeripheralConnection(p) }
                    self.connectRemote()
                }
                // HID 自愈：设备实例可能在重连后更换而 BLE 回调未触发，周期补注册
                self.refreshHID()
            }
        }
        // MCP 集成守护（1s）：配置热重载 + status.json 状态快照 + commands.json 命令通道
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.integrationTick()
            }
        }
        // 低电量提醒通知授权
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { self.L("低电量提醒通知已授权") }
        }
        // 前台应用监听：同一台遥控器在不同软件里自动切换配置
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in self?.appActivated(app) }
        }
        appActivated(NSWorkspace.shared.frontmostApplication)
    }

    // ---------- 按前台应用切换配置 ----------
    private func appActivated(_ app: NSRunningApplication?) {
        guard editTargetBundleID == nil else { return }   // 编辑模式锁定，不随前台切换
        guard let app = app else { return }
        let bid = app.bundleIdentifier ?? ""
        guard !bid.isEmpty, bid != activeAppBundleID else { return }
        saveConfig()   // 先把当前配置写回原槽位（应用专用或设备）
        activeAppBundleID = bid
        activeAppName = app.localizedName ?? bid
        applyAppProfile()
        saveConfig()   // 新生效配置落盘，保证顶层=生效值（MCP/文件读取一致）
        L("前台应用切换：\(activeAppName ?? bid) (\(bid))")
    }

    // 应用当前前台应用的专用配置（无则还原为设备默认配置）
    private func applyAppProfile() {
        guard let devID = activeDeviceID, let bid = activeAppBundleID else { return }
        if let appProf = config.devices?[devID]?.appProfiles?[bid] {
            config.buttons = appProf.buttons
            config.voice = appProf.voice
            config.voiceStartsMic = appProf.voiceStartsMic
            config.voiceDSP = appProf.voiceDSP
            config.voiceHotkey = appProf.voiceHotkey
            L("已应用应用专用配置：\(appProf.name)")
        } else if let devProf = config.devices?[devID] {
            // 无该应用专用配置 → 还原为设备默认配置
            config.buttons = devProf.buttons
            config.voice = devProf.voice
            config.voiceStartsMic = devProf.voiceStartsMic
            config.voiceDSP = devProf.voiceDSP
            config.voiceHotkey = devProf.voiceHotkey
            L("应用 \(activeAppName ?? bid) 无专用配置，已还原设备默认")
        }
    }

    // ---------- keyboard capture (record a target key) ----------
    func beginCapture(usage: Int) { capturingUsage = usage; L("请在键盘上按下要映射的键…") }
    func cancelCapture() { capturingUsage = nil }
    func clearMapping(usage: Int) {
        if usage == -1 { config.voice.keycode = KeyNames.kNone; config.voice.cmd = false; config.voice.shift = false; config.voice.opt = false; config.voice.ctrl = false }
        else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].keycode = KeyNames.kNone; config.buttons[i].cmd = false
            config.buttons[i].shift = false; config.buttons[i].opt = false; config.buttons[i].ctrl = false
        }
        saveConfig()
    }
    private var pendingCaptureMod: UInt16? = nil   // 录制中按住的修饰键（等松开或组合普通键）
    private func installKeyCapture() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self = self, self.capturingUsage != nil else { return ev }
            let loneMods: Set<UInt16> = [0x36,0x37,0x38,0x3C,0x3A,0x3D,0x3B,0x3E,0x39,0x3F]
            let f = ev.modifierFlags
            if ev.type == .keyDown {
                // 普通键落下：连同当前按住的修饰键一起录成组合
                self.pendingCaptureMod = nil
                self.applyCapture(keycode: Int(ev.keyCode),
                                  cmd: f.contains(.command), shift: f.contains(.shift),
                                  opt: f.contains(.option), ctrl: f.contains(.control))
                return nil // swallow this key so it doesn't act while recording
            }
            // flagsChanged：修饰键按下先挂起，等松开时才录成"单独修饰键"，给组合留机会
            guard loneMods.contains(ev.keyCode) else { return nil }
            let active: Bool
            switch ev.keyCode {
            case 0x36,0x37: active = f.contains(.command)
            case 0x38,0x3C: active = f.contains(.shift)
            case 0x3A,0x3D: active = f.contains(.option)
            case 0x3B,0x3E: active = f.contains(.control)
            case 0x39:      active = f.contains(.capsLock)
            case 0x3F:      active = f.contains(.function)
            default:        active = false
            }
            if active { self.pendingCaptureMod = ev.keyCode; return nil }
            // 松开：只有它是最后按下的挂起修饰键才录制（含其余仍按住的修饰键 → 支持纯修饰键组合）
            guard self.pendingCaptureMod == ev.keyCode else { self.pendingCaptureMod = nil; return nil }
            self.pendingCaptureMod = nil
            var cmd = f.contains(.command), shift = f.contains(.shift), opt = f.contains(.option), ctrl = f.contains(.control)
            switch ev.keyCode {   // 自身类别也算按下（目标 App 靠 flag 识别修饰键）
            case 0x36,0x37: cmd = true
            case 0x38,0x3C: shift = true
            case 0x3A,0x3D: opt = true
            case 0x3B,0x3E: ctrl = true
            default: break
            }
            self.applyCapture(keycode: Int(ev.keyCode), cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
            return nil
        }
    }
    private func applyCapture(keycode: Int, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) {
        guard let usage = capturingUsage else { return }
        if usage == -1 {
            config.voice.keycode = keycode; config.voice.cmd = cmd; config.voice.shift = shift; config.voice.opt = opt; config.voice.ctrl = ctrl
        } else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].keycode = keycode; config.buttons[i].cmd = cmd
            config.buttons[i].shift = shift; config.buttons[i].opt = opt; config.buttons[i].ctrl = ctrl
        }
        let label = KeyNames.label(keycode: keycode, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
        L("已录制映射 → \(label)")
        capturingUsage = nil
        saveConfig()
    }

    func saveConfig() {
        // 当前配置写回正确槽位：编辑模式→目标应用槽；否则有当前应用专用配置→应用槽；否则设备槽
        if let id = activeDeviceID {
            if config.devices == nil { config.devices = [:] }
            if let tid = editTargetBundleID {
                if config.devices?[id] == nil {
                    config.devices?[id] = DeviceProfile(name: activeDeviceName ?? id, config: config)
                }
                if config.devices?[id]?.appProfiles == nil { config.devices?[id]?.appProfiles = [:] }
                config.devices?[id]?.appProfiles?[tid] = AppProfile(name: editTargetName ?? tid, config: config)
            } else if let bid = activeAppBundleID, config.devices?[id]?.appProfiles?[bid] != nil {
                config.devices?[id]?.appProfiles?[bid] = AppProfile(name: activeAppName ?? bid, config: config)
            } else {
                var prof = DeviceProfile(name: activeDeviceName ?? id, config: config)
                prof.appProfiles = config.devices?[id]?.appProfiles
                config.devices?[id] = prof
            }
        }
        ConfigStore.save(config); refreshConfigMtime(); L("配置已保存")
    }

    // ---------- MCP 集成（配置热重载 / 状态快照 / 命令通道） ----------
    // 命令通道回调（AppDelegate 注入：打开设置窗口）
    var onOpenSettings: (() -> Void)? = nil
    private var lastConfigMtime: Date?

    private func refreshConfigMtime() {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: ConfigStore.path) {
            lastConfigMtime = attrs[.modificationDate] as? Date
        }
    }

    private func integrationTick() {
        // ① config.json 外部修改（MCP set_mapping 等）→ 热重载，立即生效
        if let attrs = try? FileManager.default.attributesOfItem(atPath: ConfigStore.path),
           let m = attrs[.modificationDate] as? Date, m != lastConfigMtime {
            lastConfigMtime = m
            config = ConfigStore.load()
            L("配置已热重载（config.json 被外部修改）")
            applyAppProfile()   // 热重载后重新套当前应用专用配置
        }
        // ② 状态快照：MCP get_status 读取
        writeStatus()
        // ③ 命令通道：MCP 投递的模拟按键/语音
        readCommands()
        // ④ 低电量检测提醒
        checkBatteryAlert()
        // ⑤ 刷新可用设备列表（手动切换 UI）
        refreshDeviceList()
        // ⑥ 刷新应用配置列表（UI）
        if let devID = activeDeviceID {
            appProfileList = (config.devices?[devID]?.appProfiles ?? [:])
                .map { AppProfileInfo(bundleID: $0.key, name: $0.value.name) }
                .sorted { $0.name < $1.name }
        } else {
            appProfileList = []
        }
        // ⑦ 刷新候选应用（运行中 + 已有配置 + 当前前台）
        var cand: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, !bid.isEmpty {
                cand[bid] = app.localizedName ?? bid
            }
        }
        if let devID = activeDeviceID {
            for (bid, ap) in (config.devices?[devID]?.appProfiles ?? [:]) {
                cand[bid] = ap.name
            }
        }
        if let bid = activeAppBundleID, let name = activeAppName { cand[bid] = name }
        candidateApps = cand.map { AppProfileInfo(bundleID: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }

    // ---------- 应用专用配置（UI 操作） ----------
    func saveCurrentAppProfile() {
        let bid = editTargetBundleID ?? activeAppBundleID
        let name = editTargetName ?? activeAppName ?? bid
        guard let bid = bid, let devID = activeDeviceID else { L("无应用上下文"); return }
        if config.devices == nil { config.devices = [:] }
        if config.devices?[devID] == nil {
            config.devices?[devID] = DeviceProfile(name: activeDeviceName ?? devID, config: config)
        }
        if config.devices?[devID]?.appProfiles == nil { config.devices?[devID]?.appProfiles = [:] }
        config.devices?[devID]?.appProfiles?[bid] = AppProfile(name: name ?? bid, config: config)
        saveConfig()
        L("已保存应用专用配置：\(name ?? bid)（当前生效配置）")
    }

    func removeEditTargetProfile() {
        guard let bid = editTargetBundleID, let devID = activeDeviceID else { return }
        config.devices?[devID]?.appProfiles?[bid] = nil
        editTargetBundleID = nil; editTargetName = nil
        applyAppProfile()   // 删除后还原前台应用/设备默认
        saveConfig()
        L("已删除应用配置：\(bid)，退出编辑模式")
    }

    func removeCurrentAppProfile() {
        guard let bid = activeAppBundleID, let devID = activeDeviceID else { return }
        config.devices?[devID]?.appProfiles?[bid] = nil
        applyAppProfile()   // 删除后还原设备默认
        saveConfig()
        L("已删除应用专用配置：\(bid)，还原为设备默认")
    }

    func activateApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            L("找不到应用：\(bundleID)"); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        L("正在切换到应用：\(bundleID)（其专用配置将自动套用）")
    }

    // ---------- 通用通知（去重 + 冷却，避免刷屏） ----------
    private var lastNotifyAt: [String: TimeInterval] = [:]
    private var hasConnectedOnce = false   // 是否已连接过（首连静默，重连才通知）

    func notify(_ key: String, title: String, body: String, cooldown: TimeInterval = 300) {
        guard config.notifyEnabled ?? true else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastNotifyAt[key], now - last < cooldown { return }
        lastNotifyAt[key] = now
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(identifier: "miremote-\(key)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
        L("🔔 [\(key)] \(title)：\(body)")
    }

    // ---------- 低电量提醒 ----------
    private func checkBatteryAlert() {
        guard let b = batteryLevel else { return }
        let threshold = config.batteryAlertThreshold ?? 20
        let enabled = config.batteryAlertEnabled ?? true
        if b <= threshold {
            if enabled && !batteryLowNotified {
                batteryLowNotified = true
                notify("battery-low", title: "小米遥控器电量低",
                       body: "当前电量 \(b)%，请及时充电。", cooldown: 0)
            }
        } else {
            batteryLowNotified = false   // 电量回升后允许再次提醒
        }
    }

    private func writeStatus() {
        var d: [String: Any] = [:]
        d["btOn"] = btOn
        d["remoteConnected"] = remoteConnected
        d["handshakeReady"] = handshakeReady
        d["blackholeFound"] = blackholeFound
        d["axTrusted"] = axTrusted
        d["inputMonitoringOK"] = inputMonitoringOK
        d["micStreaming"] = micStreaming
        d["launchAtLogin"] = launchAtLogin
        d["voiceStartsMic"] = config.voiceStartsMic
        d["lastButton"] = lastButton
        d["lastButtonUsage"] = lastButtonUsage
        d["batteryLevel"] = batteryLevel ?? -1   // -1 = 未知
        d["batteryLow"] = (batteryLevel ?? 0) <= (config.batteryAlertThreshold ?? 20)
        d["audioUnderruns"] = ring.underrunCount()   // 音频空洞计数（诊断）
        d["deviceId"] = activeDeviceID ?? ""
        d["deviceName"] = activeDeviceName ?? ""
        d["activeAppBundleID"] = activeAppBundleID ?? ""
        d["activeAppName"] = activeAppName ?? ""
        d["preferredDeviceID"] = config.preferredDeviceID ?? ""
        d["availableDevices"] = knownDevices.map { ["id": $0.id, "name": $0.name, "connected": $0.connected] }
        d["appVersion"] = ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.11") + ".0"
        d["patched"] = true
        d["ts"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: d),
           let str = String(data: data, encoding: .utf8) {
            try? str.write(toFile: (ConfigStore.dir as NSString).appendingPathComponent("status.json"),
                           atomically: true, encoding: .utf8)
        }
    }

    private func readCommands() {
        let p = (ConfigStore.dir as NSString).appendingPathComponent("commands.json")
        guard FileManager.default.fileExists(atPath: p),
              let data = FileManager.default.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else { return }
        try? FileManager.default.removeItem(atPath: p)   // 先删除防重复执行
        switch action {
        case "press":
            if let u = obj["usage"] as? Int { mcpPress(u) }
        case "voice":
            if let down = obj["down"] as? Bool { mcpVoice(down) }
        case "select_device":
            if let id = obj["id"] as? String { selectDevice(id: id) }
        case "open_settings":
            L("[MCP] 打开设置窗口")
            onOpenSettings?()
        default:
            L("未知 MCP 命令: \(action)")
        }
    }

    /// MCP 命令通道：模拟按一下物理按键（与真实按键同一套映射逻辑）
    func mcpPress(_ usage: Int) {
        if usage == -1 {   // 语音键：按 0.2s
            L("[MCP] 模拟语音键按下 → \(config.voice.display)")
            voiceButton(down: true)
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.mcpVoice(false) }
            }
            return
        }
        guard let m = config.buttons.first(where: { $0.usage == usage }) else {
            L("[MCP] 未知按键 usage=\(usage)"); return
        }
        L(String(format: "[MCP] 模拟按键 0x%02x [%@] → %@", usage, m.name, m.display))
        if m.keycode == KeyNames.kNone { return }
        if m.keycode >= KeyNames.kSpecialBase {
            startSpecial(m.keycode)
            let code = m.keycode
            Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.stopSpecial(code) }
            }
        } else {
            postKey(CGKeyCode(m.keycode), down: true, cmd: m.cmd, shift: m.shift, opt: m.opt, ctrl: m.ctrl)
            let code = m.keycode, c = m.cmd, s = m.shift, o = m.opt, t = m.ctrl
            Timer.scheduledTimer(withTimeInterval: 0.08, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.postKey(CGKeyCode(code), down: false, cmd: c, shift: s, opt: o, ctrl: t) }
            }
        }
    }

    /// MCP 命令通道：模拟按住/松开语音键
    func mcpVoice(_ down: Bool) {
        L(down ? "[MCP] 模拟语音键按下" : "[MCP] 模拟语音键松开")
        voiceButton(down: down)
        if down { sendMicOpen() } else { sendMicClose() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            L(on ? "已开启开机自启" : "已关闭开机自启")
        } catch {
            L("开机自启设置失败: \(error.localizedDescription)（App 需位于 /Applications）")
        }
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    // ---------- 提醒设置（UI 用） ----------
    func setBatteryAlertEnabled(_ on: Bool) { config.batteryAlertEnabled = on; saveConfig() }
    func setBatteryThreshold(_ v: Int) {
        config.batteryAlertThreshold = max(1, min(100, v))
        batteryLowNotified = false   // 改阈值后重新评估
        saveConfig()
    }
    func setNotifyEnabled(_ on: Bool) { config.notifyEnabled = on; saveConfig() }

    // ---------- 界面主题（深色/浅色/自动） ----------
    func setTheme(_ t: String) {
        config.theme = (t == "auto") ? nil : t
        saveConfig()
        L("界面主题切换：\(config.theme ?? "auto")")
    }

    func checkPermissions() {
        axTrusted = AXIsProcessTrusted()
        blackholeFound = (Self.deviceID(named: "BlackHole") != nil)
        inputMonitoringOK = (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted)
    }
    func requestAX() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func requestInputMonitoring() { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
    func openAXSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    // ---------- audio ----------
    private func setupAudio() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        srcNode = AVAudioSourceNode(format: fmt) { [ring] _, _, frames, abl in
            let l = UnsafeMutableAudioBufferListPointer(abl)
            if let m = l[0].mData { ring.pop(m.assumingMemoryBound(to: Float.self), Int(frames)) }
            return noErr
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
        // 输出设备必须在节点接线完成之后再切到 BlackHole：
        // 访问 mainMixerNode 会重建输出单元并把设备重置回系统默认，之前设置的会被覆盖
        setOutputDevice()
        engine.prepare()
        do { try engine.start() } catch { L("音频引擎启动失败: \(error)") }
        verifyOutputDevice()
        // 设备配置变化（显示器休眠/重连、采样率切换等）会让引擎重建并重置回默认输出，必须重新挂载
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.audioWatchdog(reason: "配置变化通知") }
        }
    }
    func audioWatchdog(reason: String = "定时检查") {
        guard let bh = Self.deviceID(named: "BlackHole"), let u = engine.outputNode.audioUnit else { return }
        var cur: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        guard cur != bh || !engine.isRunning else { return }
        L("⚠️ 音频输出脱离 BlackHole（\(reason)，当前设备 \(cur)），自动重新挂载…")
        engine.stop()
        setOutputDevice()
        engine.prepare()
        do { try engine.start() } catch { L("音频引擎重启失败: \(error)") }
        verifyOutputDevice()
    }
    private func setOutputDevice() {
        guard let bh = Self.deviceID(named: "BlackHole") else {
            L("⚠️ 未找到 BlackHole 声卡，语音无法当麦克风")
            notify("blackhole", title: "缺少 BlackHole 声卡",
                   body: "未找到 BlackHole 虚拟声卡，语音无法作为麦克风。请运行 install.sh 安装。")
            return
        }
        guard let u = engine.outputNode.audioUnit else { L("⚠️ 输出单元不可用"); return }
        var d = bh
        let st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        if st != noErr { L("⚠️ 切换输出到 BlackHole 失败 (OSStatus \(st))") }
    }
    private func verifyOutputDevice() {
        guard let bh = Self.deviceID(named: "BlackHole"), let u = engine.outputNode.audioUnit else { return }
        var cur: AudioDeviceID = 0
        var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
        if cur == bh {
            L("音频输出已挂到 BlackHole (设备 \(bh))")
        } else {
            // 启动过程又被重置了：停机重设再启动
            L("⚠️ 输出设备被重置 (当前 \(cur))，重试切换 BlackHole…")
            engine.stop()
            setOutputDevice()
            engine.prepare()
            do { try engine.start() } catch { L("音频引擎重启失败: \(error)") }
            AudioUnitGetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &cur, &sz)
            L(cur == bh ? "音频输出已挂到 BlackHole (设备 \(bh))" : "❌ 仍未能切到 BlackHole，语音无法当麦克风")
        }
    }
    static func deviceID(named target: String) -> AudioDeviceID? {
        var size = UInt32(0)
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        let n = Int(size)/MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: n)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        // 优先匹配 2ch（与 README/听写默认输入一致），否则回退到任意匹配设备
        var fallback: AudioDeviceID?
        for id in ids {
            var ns = UInt32(MemoryLayout<CFString?>.size); var name: CFString? = nil
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            withUnsafeMutablePointer(to: &name) { _ = AudioObjectGetPropertyData(id, &na, 0, nil, &ns, $0) }
            if let nm = name as String?, nm.contains(target) {
                if nm.contains("2ch") || nm.contains("2 ch") { return id }   // 首选 BlackHole 2ch
                if fallback == nil { fallback = id }                          // 16ch 等兜底
            }
        }
        return fallback
    }

    // ---------- BLE (ATVV voice + mic) ----------
    fileprivate func btStateChanged(_ c: CBCentralManager) {
        btOn = (c.state == .poweredOn)
        L("蓝牙状态: \(c.state.rawValue) (\(c.state == .poweredOn ? "开" : "非开"))")
        if btOn { connectRemote() }
    }
    // ---------- BLE 重连状态机（防卡死：失败退避重试 + 自愈） ----------
    private var reconnecting = false        // 已有连接尝试/重试排队，防止并发重试堆积
    private var reconnectDelay = 2.0        // 指数退避：2→4→8→10s 封顶
    private var connectAttempts = 0
    private var connectStartedAt: TimeInterval? = nil   // 连接尝试发起时刻（超时兜底用）

    func connectRemote() {
        guard let c = cm, c.state == .poweredOn else { return }
        guard !reconnecting else { return }   // 关键：防止多条重试链叠加并发 connect
        let atvvDevices = c.retrieveConnectedPeripherals(withServices: [ATVV])
        var d: CBPeripheral?
        // 首选设备（手动切换记住的）
        if let pid = config.preferredDeviceID {
            d = atvvDevices.first { $0.identifier.uuidString == pid }
        }
        if d == nil { d = atvvDevices.first }
        if d == nil {
            // 兜底：seed 匹配 + 名称过滤（某些遥控器广播里不含 ATVV 服务）
            d = c.retrieveConnectedPeripherals(withServices: seed).first {
                $0.name?.contains("小米") == true || $0.name?.contains("遥控") == true
                    || $0.name?.localizedCaseInsensitiveContains("remote") == true
            }
        }
        if let d = d {
            reconnecting = true
            connectAttempts += 1
            connectStartedAt = ProcessInfo.processInfo.systemUptime
            dev = d; d.delegate = proxy; capsSent = false
            c.connect(d, options: nil)
            L("找到已连接遥控器 \(d.name ?? "?")，正在连接…（第 \(connectAttempts) 次）")
        } else {
            L("未找到已连接遥控器，\(Int(reconnectDelay))s 后重试…")
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.reconnectDelay = min(self.reconnectDelay * 2, 10)   // 指数退避封顶 10s
                self.connectRemote()
            }
        }
    }

    /// 连接失败（含超时）：以前完全没处理 → 卡死只能重启；现在退避重试 + 通知
    fileprivate func didFailToConnect(_ p: CBPeripheral, error: Error?) {
        reconnecting = false
        L("⚠️ 连接失败：\(error?.localizedDescription ?? "未知")，\(Int(reconnectDelay * 2))s 后重试…")
        notify("connect-fail", title: "遥控器连接失败",
               body: "\(p.name ?? "遥控器") 连接失败，正在自动重试（无需重启 App）。")
        scheduleReconnect()
    }

    // ---------- 手动切换遥控器 ----------
    func refreshDeviceList() {
        guard let c = cm else { return }
        let connected = c.retrieveConnectedPeripherals(withServices: [ATVV])
        var list = connected.map { RemoteDeviceInfo(id: $0.identifier.uuidString, name: $0.name ?? "?", connected: true) }
        for (did, prof) in (config.devices ?? [:]) where !list.contains(where: { $0.id == did }) {
            list.append(RemoteDeviceInfo(id: did, name: prof.name, connected: false))
        }
        knownDevices = list
    }

    func selectDevice(id: String) {
        guard let c = cm, c.state == .poweredOn else { return }
        guard let periph = c.retrieveConnectedPeripherals(withServices: [ATVV]).first(where: { $0.identifier.uuidString == id }) else {
            L("目标设备不在已连接列表，无法切换：\(id)")
            return
        }
        if let cur = dev, cur.identifier.uuidString != id {
            c.cancelPeripheralConnection(cur)
        }
        config.preferredDeviceID = id
        saveConfig()
        dev = periph
        periph.delegate = proxy
        capsSent = false
        c.connect(periph, options: nil)
        L("手动切换设备：\(periph.name ?? id)")
    }
    fileprivate func didConnect(_ p: CBPeripheral) {
        remoteConnected = true
        reconnecting = false; connectAttempts = 0; reconnectDelay = 2.0   // 重连成功，复位退避
        activeDeviceID = p.identifier.uuidString
        activeDeviceName = p.name
        if config.preferredDeviceID == nil { config.preferredDeviceID = p.identifier.uuidString }  // 记住当前设备
        L("BLE 已连接 \(p.name ?? "?")，发现服务…")
        if hasConnectedOnce {
            notify("reconnect", title: "遥控器已重连", body: "\(p.name ?? "遥控器") 已重新连接。")
        }
        hasConnectedOnce = true
        refreshHID()   // 重连后 HID 设备实例可能已更换，重新注册回调（否则按键映射失效）
        loadDeviceProfile(p)
        p.discoverServices([ATVV, BATTERY])
    }

    // 多设备配置：连接时加载/创建该设备的独立配置，并让 config.json 顶层=当前设备配置
    private func loadDeviceProfile(_ p: CBPeripheral) {
        guard let id = activeDeviceID else { return }
        if var devices = config.devices, let prof = devices[id] {
            config.buttons = prof.buttons
            config.voice = prof.voice
            config.voiceStartsMic = prof.voiceStartsMic
            config.voiceDSP = prof.voiceDSP
            config.voiceHotkey = prof.voiceHotkey
            L("已加载设备独立配置：\(prof.name)")
        } else {
            if config.devices == nil { config.devices = [:] }
            config.devices?[id] = DeviceProfile(name: p.name ?? id, config: config)
            L("首次连接该设备，已创建独立配置（模板=当前配置）")
        }
        applyAppProfile()   // 设备配置之上再套当前前台应用的专用配置（先别保存，避免把设备值写进应用槽）
        saveConfig()        // 生效配置落盘（顶层=生效值，写入正确槽位）
    }
    fileprivate func didDisconnect() {
        remoteConnected = false; handshakeReady = false; streaming = false
        micOpened = false; voiceKeyDown = false; atvvVersion = 0; atvvFrameSize = 0
        capsAttempts = 0
        // 复位按键状态：断开时若正按住某键，keyUp 永远不会来，不清会卡住后续映射
        voiceHidDown = false; downTarget = nil; downButtonUsage = 0
        capsRetryTimer?.invalidate(); capsRetryTimer = nil
        stopKeepAlive()
        reconnecting = false
        L("⚠️ 遥控器断开，\(Int(reconnectDelay))s 后重连…")
        notify("disconnect", title: "遥控器已断开",
               body: "\(activeDeviceName ?? "遥控器") 连接已断开，正在自动重连…")
        // 不立即 connect：给 macOS 自身重连留出稳定期，避免与系统抢连接造成抖动
        scheduleReconnect()
    }
    fileprivate func didServices(_ p: CBPeripheral) {
        L("发现服务: \(p.services?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "无")")
        if let s = p.services?.first(where: { $0.uuid == ATVV }) { p.discoverCharacteristics([TX,RX,CTL], for: s) }
        else {
            L("⚠️ 未发现 ATVV 语音服务（AB5E0001）！")
            notify("no-atvv", title: "遥控器无语音通道",
                   body: "\(p.name ?? "该设备") 未发现 ATVV 服务，可能不是语音遥控器。")
        }
        if let bs = p.services?.first(where: { $0.uuid == BATTERY }) {
            p.discoverCharacteristics([BATTERY_LEVEL], for: bs)
        } else {
            L("⚠️ 遥控器无电池服务（0x180F），无法读取电量")
        }
    }
    fileprivate func didChars(_ p: CBPeripheral, _ s: CBService) {
        if s.uuid == ATVV {
            L("ATVV 特征: \(s.characteristics?.map { "\($0.uuid.uuidString)\($0.properties.contains(.notify) ? "(notify)" : "")" }.joined(separator: ", ") ?? "无")")
            for ch in s.characteristics ?? [] {
                if ch.uuid == TX { tx = ch }
                else if ch.uuid == RX || ch.uuid == CTL { p.setNotifyValue(true, for: ch) }
            }
        } else if s.uuid == BATTERY {
            L("电池特征: \(s.characteristics?.map { $0.uuid.uuidString }.joined(separator: ", ") ?? "无")")
            for ch in s.characteristics ?? [] where ch.uuid == BATTERY_LEVEL {
                p.readValue(for: ch)
                p.setNotifyValue(true, for: ch)   // 电量变化时主动通知
            }
        }
    }
    fileprivate func didNotify(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        L("订阅确认 \(ch.uuid.uuidString) isNotifying=\(ch.isNotifying)")
        if ch.uuid == CTL && ch.isNotifying && !capsSent {
            capsSent = true
            // ATVV 能力协商：请求遥控器回报能力（0x0B）。米遥实测命令为 0A 01 00 00 03 03
            let capsCmd = Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03])
            writeTX(p, capsCmd)
            L("已发送 ATVV 能力协商请求，等待遥控器回应…")
            scheduleCapsRetry()
        }
    }
    // 能力协商超时重试（最多 3 次，间隔 2s）
    private func scheduleCapsRetry() {
        capsRetryTimer?.invalidate()
        capsRetryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.atvvVersion == 0, let p = self.dev else { return }
                if self.capsAttempts < 3 {
                    self.capsAttempts += 1
                    self.L("遥控器未回应能力协商（第 \(self.capsAttempts) 次），重试…")
                    self.writeTX(p, Data([0x0A, 0x01, 0x00, 0x00, 0x03, 0x03]))
                    self.scheduleCapsRetry()
                } else {
                    self.L("⚠️ 能力协商超时（3 次），主动断开重连…")
                    self.notify("voice-handshake", title: "语音通道异常",
                                body: "能力协商失败，正在自动重连（无需重启 App）。")
                    if let p = self.dev { self.cm?.cancelPeripheralConnection(p) }  // didDisconnect 会触发重连
                    self.reconnecting = false
                    self.scheduleReconnect()
                }
            }
        }
    }
    private var capsAttempts = 0

    fileprivate func didValue(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        guard let d = ch.value else { return }
        if ch.uuid == RX {
            // 解码+DSP+质量统计全部在 AudioPath 串行队列执行（不占主线程，避免音频空洞）
            audio.onRx(d)
        } else if ch.uuid == BATTERY_LEVEL, let d = ch.value, !d.isEmpty {
            batteryLevel = Int(d[0])
            L("遥控器电量: \(batteryLevel ?? -1)%")
        } else if ch.uuid == CTL, let f = d.first {
            L("CTL 数据: \(String(format: "0x%02x", f))")
            switch f {
            case 0x0B:   // 能力包（ATVVCapabilities）
                parseCaps(d)
            case 0x08:   // startSearch：遥控器要求开麦
                voiceButton(down: true)
                sendMicOpen()
            case 0x04:   // audioStart：开麦/开始流（v1.0: bytes[2]=codec, bytes[3]=streamID）
                if atvvVersion == 10 {
                    if d.count >= 3 { streamCodec8k = (d[2] == 0x01) }
                    if d.count >= 4 { streamID = d[3] }
                    L("audioStart codec=0x\(String(format: "%02x", d.count > 2 ? d[2] : 0)) streamID=0x\(String(format: "%02x", streamID))\(streamCodec8k ? "（8kHz）" : "")")
                }
                voiceButton(down: true)
                sendMicOpen()
            case 0x00:   // audioStop：松开语音键
                voiceButton(down: false)
                sendMicClose()
            case 0x0A:   // audioSync (v1.0)：codec 字节 + 用 predictor/stepIndex 重置解码器
                if d.count >= 7 {
                    if atvvVersion == 10 {
                        let c8k = (d[1] == 0x01)
                        if c8k != streamCodec8k {
                            streamCodec8k = c8k
                            L("audioSync 切换码率 → \(c8k ? "8kHz" : "16kHz")")
                        }
                    }
                    let pred = Int16(bitPattern: UInt16(d[4]) << 8 | UInt16(d[5]))
                    audio.onSync(predictor: pred, stepIndex: d[6])
                    L("audioSync 重置解码器 pred=\(pred) step=\(d[6])")
                }
            case 0x0C:   // micOpenError
                L("⚠️ 遥控器拒绝开麦 (MIC_OPEN_ERROR 0x\(String(format: "%02x%02x", d.count > 1 ? d[1] : 0, d.count > 2 ? d[2] : 0)))")
                micOpened = false
            default:
                L("未识别的 CTL 指令: 0x\(String(format: "%02x", f))")
            }
        }
    }

    // ---------- ATVV 能力解析（0x0B） ----------
    private func parseCaps(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 3, b[0] == 0x0B else { return }
        let ver = Int(b[1]) << 8 | Int(b[2])
        switch ver {
        case 0x0004:
            guard b.count >= 9 else { return }
            atvvVersion = 4; atvvCodec = b[4]; atvvFrameSize = Int(b[5]) << 8 | Int(b[6])
        case 0x0100:
            guard b.count >= 7 else { return }
            atvvVersion = 10
            // 小米固件 2671 偶发把 codecs 与 interactionModel 写反，按米遥同款规则纠正
            var codecs = b[3]; let model = b[4]
            let hasStd = (codecs & 0x03) != 0
            let hasSwapped = (model & 0x03) != 0
            if !hasStd && hasSwapped { codecs = model }
            atvvCodec = codecs; atvvFrameSize = Int(b[5]) << 8 | Int(b[6])
        default:
            return
        }
        capsRetryTimer?.invalidate(); capsRetryTimer = nil
        capsAttempts = 0
        handshakeReady = true
        let codecName = (atvvCodec & 0x02) != 0 ? "ADPCM 16kHz" : ((atvvCodec & 0x01) != 0 ? "ADPCM 8kHz" : "未知")
        L("语音握手完成：ATVV v\(atvvVersion == 4 ? "0.4" : "1.0")，\(codecName)，frame=\(atvvFrameSize)B")
        if (atvvCodec & 0x02) == 0 && (atvvCodec & 0x01) != 0 {
            L("⚠️ 遥控器仅支持 8kHz，App 按 16kHz 渲染，音调可能偏快（后续版本适配）")
        }
    }

    fileprivate func didWrite(ch: CBCharacteristic, error: Error?) {
        if let error {
            L("⚠️ TX 写入失败 \(ch.uuid.uuidString): \(error.localizedDescription)")
        } else {
            L("TX 写入成功 \(ch.uuid.uuidString)")
        }
    }

    /// 链路信号强度诊断：丢包时看这条就能区分 距离/干扰/链路参数
    fileprivate func didReadRSSI(_ rssi: NSNumber, error: Error?) {
        guard error == nil else { return }
        let v = rssi.intValue
        let hint: String
        switch v {
        case let x where x > -55: hint = "优秀"
        case let x where x > -70: hint = "良好"
        case let x where x > -85: hint = "偏弱（可能偶发丢包）"
        default: hint = "差（持续丢包主因，请靠近或换电池）"
        }
        L("📶 链路信号: \(v) dBm（\(hint)）")
    }

    // ---------- ATVV 开麦 / 关麦 / 保活 ----------
    // TX 写入：按特征属性选 withoutResponse（与米遥一致；withResponse 在不支持时会被拒收）
    private func writeTX(_ p: CBPeripheral, _ data: Data) {
        guard let tx = tx else { return }
        let type: CBCharacteristicWriteType =
            tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: tx, type: type)
    }
    private func sendMicOpen() {
        guard atvvVersion != 0, let p = dev, !micOpened else { return }
        var cmd: Data
        if atvvVersion == 4 { cmd = Data([0x0C, 0x00, atvvCodec]) }
        else { cmd = Data([0x0C, 0x00]) }
        micOpened = true
        writeTX(p, cmd)
        L("TX MIC_OPEN \(cmd.map { String(format: "%02x", $0) }.joined(separator: " "))")
        startKeepAlive()
    }
    private func sendMicClose() {
        guard atvvVersion != 0, let p = dev, micOpened else { return }
        var cmd: Data
        if atvvVersion == 4 { cmd = Data([0x0D]) }
        else { cmd = Data([0x0D, streamID]) }
        micOpened = false
        writeTX(p, cmd)
        L("TX MIC_CLOSE \(cmd.map { String(format: "%02x", $0) }.joined(separator: " "))")
        stopKeepAlive()
    }
    private func startKeepAlive() {
        stopKeepAlive()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, self.micOpened, self.voiceKeyDown,
                      let p = self.dev else { return }
                let cmd: Data = self.atvvVersion == 4 ? Data([0x0C, 0x00, self.atvvCodec]) : Data([0x0E, self.streamID])
                self.writeTX(p, cmd)
            }
        }
    }
    private func stopKeepAlive() {
        keepAliveTimer?.invalidate(); keepAliveTimer = nil
    }

    private var streamCodec8k = false   // 当前流是否为 8kHz（由 audioStart/audioSync 的 codec 字节决定）

    private func voiceButton(down: Bool) {
        let v = config.voice
        // BLE 通道也标记语音键状态：与 HID 报告双保险，谁先到谁立标记，确保原生 F5 被吞
        voiceHidDown = down
        lastHidKeycodeAt[HIDMap.voiceKeycode] = ProcessInfo.processInfo.systemUptime
        if down {
            streaming = true; micStreaming = config.voiceStartsMic
            voiceKeyDown = true
            audio.startSession(version: atvvVersion, frameSize: atvvFrameSize,
                               codec8k: streamCodec8k, dspOn: config.voiceDSP ?? true)
            // 接管系统默认输入：识别端（听写/输入法）永远从默认输入取音，
            // 若 macOS 把默认输入改回物理麦克风，就会完全听不到遥控器。
            if config.voiceSwitchesInput ?? true {
                if let msg = AudioRoute.capture(uid: config.voiceInputDeviceUID) {
                    L("🔀 \(msg)")
                } else {
                    L("⚠️ 未找到虚拟声卡（BlackHole），默认输入未接管")
                }
            }
            if v.keycode >= KeyNames.kSpecialBase { startSpecial(v.keycode) }
            else if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: true, cmd: v.cmd, shift: v.shift, opt: v.opt, ctrl: v.ctrl) }
            L("🎤 语音键按下 → \(v.display)\(config.voiceStartsMic ? " + 麦克风开" : "")")
        } else {
            streaming = false; micStreaming = false; voiceKeyDown = false
            audio.stopSession()
            if (config.voiceSwitchesInput ?? true), let msg = AudioRoute.restore() {
                L("🔀 \(msg)")
            }
            dev?.readRSSI()   // 会话结束测一次链路信号强度（结果走 didReadRSSI 日志）
            if v.keycode >= KeyNames.kSpecialBase { stopSpecial(v.keycode) }
            else if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: false, cmd: false) }
            L("语音键松开")
        }
    }

    // ---------- HID reading ----------
    private func setupHID() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        // 通用匹配：枚举所有 HID 设备，按名称/vendor 过滤出 ATVV 遥控器（支持非小米品牌）
        IOHIDManagerSetDeviceMatching(mgr, nil)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(mgr, 0)
        hidMgr = mgr
        refreshHID()
    }

    // 已注册 HID 设备（遥控器断连重连后设备实例会变，旧回调失效 → 按键映射"自己失效"）
    private var hidRegistered: Set<ObjectIdentifier> = []

    /// 重新枚举并注册尚未跟踪的遥控器设备；由 didConnect 与看门狗周期调用
    func refreshHID() {
        guard let mgr = hidMgr,
              let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> else { return }
        inputMonitoringOK = !set.isEmpty
        let vendors = (config.hidVendors ?? []) + [0x2717]   // 默认含小米
        for dvc in set {
            let oid = ObjectIdentifier(dvc)
            if hidRegistered.contains(oid) { continue }
            let name = (IOHIDDeviceGetProperty(dvc, kIOHIDProductKey as CFString) as? String) ?? ""
            let vendor = (IOHIDDeviceGetProperty(dvc, kIOHIDVendorIDKey as CFString) as? Int) ?? 0
            let isRemote = name.contains("遥控") || name.localizedCaseInsensitiveContains("remote")
                || vendors.contains(vendor)
            guard isRemote else { continue }
            L("HID 遥控器: \(name) vendor=0x\(String(format: "%04x", vendor))")
            let rsize = (IOHIDDeviceGetProperty(dvc, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? 64
            _ = IOHIDDeviceOpen(dvc, IOHIDOptionsType(kIOHIDOptionsTypeNone))
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: max(rsize,8)); hidBufs.append(buf)
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(dvc, buf, max(rsize,8), { context, _, _, _, _, report, len in
                guard let context = context, len >= 4 else { return }
                let me = Unmanaged<Engine>.fromOpaque(context).takeUnretainedValue()
                let usage = report[3]
                // 回调本就在主运行循环上，必须同步处理：
                // 若 async 延后一拍，系统生成的原生键事件会抢先到达拦截器，抑制标记来不及生效
                MainActor.assumeIsolated { me.hidReport(usage: usage) }
            }, ctx)
            IOHIDDeviceScheduleWithRunLoop(dvc, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            hidRegistered.insert(oid)
        }
    }

    private func hidReport(usage: UInt8) {
        let now = ProcessInfo.processInfo.systemUptime
        if usage == 0x00 {
            // release: send keyUp for the held mapped target, if any
            if voiceHidDown { voiceHidDown = false; lastHidKeycodeAt[HIDMap.voiceKeycode] = now }
            if let t = downTarget {
                if t.keycode >= KeyNames.kSpecialBase { stopSpecial(t.keycode) }
                else if t.keycode != KeyNames.kNone { postKey(CGKeyCode(t.keycode), down: false, cmd: false) }
            }
            downButtonUsage = 0; downTarget = nil
            return
        }
        if usage == HIDMap.voiceUsage {
            // 语音键的原生 F5：吞掉（BLE 通道已负责发所录制的键），避免触发系统听写
            L("HID 诊断: 收到语音键 usage 0x3E")
            voiceHidDown = true
            lastHidKeycodeAt[HIDMap.voiceKeycode] = now
            return
        }
        // a button is pressed
        lastButtonUsage = Int(usage)
        lastButton = String(format: "0x%02x", usage)
        // mark for suppression if macOS will also generate a keycode
        if let kc = HIDMap.usageToKeycode[usage] { lastHidKeycodeAt[kc] = now }
        // find mapping
        guard let m = config.buttons.first(where: { $0.usage == Int(usage) }) else {
            L(String(format: "按键 0x%02x 未在映射表中（保持原样）", usage))
            return
        }
        L(String(format: "按键 0x%02x [%@] → %@", usage, m.name, m.display))
        if m.keycode == KeyNames.kNone { downButtonUsage = Int(usage); downTarget = nil; return } // keep original
        if m.keycode >= KeyNames.kSpecialBase {   // 鼠标/滚轮：按住持续，松开停止
            startSpecial(m.keycode); downButtonUsage = Int(usage); downTarget = m; return
        }
        // emit mapped key (down); keyUp on release
        postKey(CGKeyCode(m.keycode), down: true, cmd: m.cmd, shift: m.shift, opt: m.opt, ctrl: m.ctrl)
        downButtonUsage = Int(usage); downTarget = m
    }

    // ---------- CGEvent tap: suppress originals of mapped buttons ----------
    private func installTap() {
        guard tap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: mask,
                callback: { _, type, event, ud in
                    guard let ud = ud else { return Unmanaged.passUnretained(event) }
                    let me = Unmanaged<Engine>.fromOpaque(ud).takeUnretainedValue()
                    // 事件拦截被系统禁用（回调超时/用户 Ctrl-Ctrl）：必须重新启用，
                    // 否则抑制逻辑静默死亡 → 按键映射"自己失效"，只能重启
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        if let t = me.tap {
                            CGEvent.tapEnable(tap: t, enable: true)
                            me.L("⚠️ 事件拦截被系统禁用（\(type == .tapDisabledByTimeout ? "超时" : "用户输入")），已重新启用")
                        }
                        return Unmanaged.passUnretained(event)
                    }
                    // ignore our own synthetic events
                    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMarker {
                        return Unmanaged.passUnretained(event)
                    }
                    let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                    // 诊断：遥控器语音键是否产生真实 F5 硬件事件
                    if kc == HIDMap.voiceKeycode {
                        me.L("TAP 诊断: 看到 F5 事件 (\(type == .keyDown ? "down" : "up"))")
                    }
                    // 语音键方案二：把遥控器真实的 F5 硬件事件改写为目标热键放行，
                    // 输入法（微信输入法"按住说话"）能识别真实事件但认不出合成键
                    if kc == HIDMap.voiceKeycode, me.shouldSuppress(kc) {
                        var hotkey: Int?
                        MainActor.assumeIsolated { hotkey = me.config.voiceHotkey }
                        if let hk = hotkey {
                            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(hk))
                            me.L("TAP: F5 改写为 \(String(format: "0x%02x", hk)) 放行 (\(type == .keyDown ? "down" : "up"))")
                            return Unmanaged.passUnretained(event)
                        }
                        return nil // 未配置热键：吞掉 F5（原行为）
                    }
                    if me.shouldSuppress(kc) {
                        return nil // swallow the remote's original key
                    }
                    return Unmanaged.passUnretained(event)
                }, userInfo: ctx) else { L("⚠️ 无法创建事件拦截（需辅助功能授权）"); return }
        tap = t
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }
    // called from tap thread — keep it cheap & thread-safe-ish (dictionary read)
    nonisolated func shouldSuppress(_ kc: CGKeyCode) -> Bool {
        // suppress if the remote produced this keycode within the last 120ms AND that button is mapped to something other than "keep original"
        var suppress = false
        MainActor.assumeIsolated {
            let now = ProcessInfo.processInfo.systemUptime
            // 语音键的 F5：按住期间全部吞掉（含自动重复），松开后 120ms 内吞掉 keyUp
            if kc == HIDMap.voiceKeycode {
                suppress = voiceHidDown || (lastHidKeycodeAt[kc].map { now - $0 < 0.12 } ?? false)
                if !suppress { L("⚠️ F5 事件到达时语音键标记未立，漏过一次（请反馈）") }
                return
            }
            if let ts = lastHidKeycodeAt[kc], now - ts < 0.12 {
                // find which usage produced this keycode
                if let usage = HIDMap.usageToKeycode.first(where: { $0.value == kc })?.key,
                   let m = config.buttons.first(where: { $0.usage == Int(usage) }),
                   m.keycode != KeyNames.kNone {
                    suppress = true
                }
            }
        }
        return suppress
    }

    // ---------- 特殊动作：鼠标移动/点击/滚轮 ----------
    private var specialTimer: Timer?
    private var specialCode = 0
    private var mouseSpeed: CGFloat = 0

    func setSpecial(usage: Int, keycode: Int) {
        if usage == -1 {
            config.voice.keycode = keycode; config.voice.cmd = false; config.voice.shift = false; config.voice.opt = false; config.voice.ctrl = false
        } else if let i = config.buttons.firstIndex(where: { $0.usage == usage }) {
            config.buttons[i].keycode = keycode; config.buttons[i].cmd = false
            config.buttons[i].shift = false; config.buttons[i].opt = false; config.buttons[i].ctrl = false
        }
        L("已设置映射 → \(KeyNames.label(keycode: keycode, cmd: false, shift: false, opt: false, ctrl: false))")
        saveConfig()
    }

    private func startSpecial(_ code: Int) {
        switch code {
        case KeyNames.kMouseClick:  postMouse(.leftMouseDown, .left)
        case KeyNames.kMouseRClick: postMouse(.rightMouseDown, .right)
        default:
            specialCode = code; mouseSpeed = 4
            specialTimer?.invalidate()
            specialTimer = Timer.scheduledTimer(withTimeInterval: 1.0/60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.specialTick() }
            }
        }
    }
    private func stopSpecial(_ code: Int) {
        switch code {
        case KeyNames.kMouseClick:  postMouse(.leftMouseUp, .left)
        case KeyNames.kMouseRClick: postMouse(.rightMouseUp, .right)
        default: specialTimer?.invalidate(); specialTimer = nil
        }
    }
    private func specialTick() {
        switch specialCode {
        case KeyNames.kMouseUp:    moveMouse(0, -1)
        case KeyNames.kMouseDown:  moveMouse(0, 1)
        case KeyNames.kMouseLeft:  moveMouse(-1, 0)
        case KeyNames.kMouseRight: moveMouse(1, 0)
        case KeyNames.kScrollUp:   postScroll(2)
        case KeyNames.kScrollDown: postScroll(-2)
        default: break
        }
    }
    private func moveMouse(_ dx: CGFloat, _ dy: CGFloat) {
        let p = CGEvent(source: nil)?.location ?? .zero
        var np = CGPoint(x: p.x + dx * mouseSpeed, y: p.y + dy * mouseSpeed)
        mouseSpeed = min(28, mouseSpeed * 1.05)   // 按住越久移动越快
        // 不越出屏幕：目标点不在任何屏幕上时，钳制回当前屏幕
        var cnt: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &cnt)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(cnt))
        CGGetActiveDisplayList(cnt, &ids, &cnt)
        let ds = ids.map { CGDisplayBounds($0) }
        if !ds.contains(where: { $0.contains(np) }), let d = ds.first(where: { $0.contains(p) }) {
            np.x = min(max(np.x, d.minX), d.maxX - 1)
            np.y = min(max(np.y, d.minY), d.maxY - 1)
        }
        if let e = CGEvent(mouseEventSource: evSrc, mouseType: .mouseMoved, mouseCursorPosition: np, mouseButton: .left) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
    private func postMouse(_ type: CGEventType, _ btn: CGMouseButton) {
        let p = CGEvent(source: nil)?.location ?? .zero
        if let e = CGEvent(mouseEventSource: evSrc, mouseType: type, mouseCursorPosition: p, mouseButton: btn) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }
    private func postScroll(_ lines: Int32) {
        if let e = CGEvent(scrollWheelEvent2Source: evSrc, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) {
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    // ---------- synthesize keys ----------
    private let evSrc = CGEventSource(stateID: .hidSystemState)
    func postKey(_ code: CGKeyCode, down: Bool, cmd: Bool, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) {
        guard let e = CGEvent(keyboardEventSource: evSrc, virtualKey: code, keyDown: down) else { return }
        var flags: CGEventFlags = []
        if down {
            if cmd { flags.insert(.maskCommand) }
            if shift { flags.insert(.maskShift) }
            if opt { flags.insert(.maskAlternate) }
            if ctrl { flags.insert(.maskControl) }
        }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
        e.post(tap: .cghidEventTap)
    }
}

// CBCentralManager/CBPeripheral delegate proxy (Engine is @MainActor)
final class BTProxy: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var e: Engine?
    init(_ e: Engine) { self.e = e }
    func centralManagerDidUpdateState(_ c: CBCentralManager) { Task { @MainActor in e?.btStateChanged(c) } }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { Task { @MainActor in e?.didConnect(p) } }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) { Task { @MainActor in e?.didDisconnect() } }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { Task { @MainActor in e?.didFailToConnect(p, error: error) } }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { Task { @MainActor in e?.didServices(p) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) { Task { @MainActor in e?.didChars(p, s) } }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didNotify(p, ch) } }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didValue(p, ch) } }
    func peripheral(_ p: CBPeripheral, didWriteValueFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didWrite(ch: ch, error: error) } }
    func peripheral(_ p: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) { Task { @MainActor in e?.didReadRSSI(RSSI, error: error) } }
}
