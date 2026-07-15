import Foundation
import CoreBluetooth
import AVFoundation
import CoreAudio
import CoreGraphics
import ApplicationServices
import IOKit.hid
import Combine
import AppKit

// ============ ADPCM (IMA, low-nibble-first, 16 kHz mono) ============
struct ADPCM {
    static let step: [Int32] = [7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    static let idxT: [Int32] = [-1,-1,-1,-1,2,4,6,8,-1,-1,-1,-1,2,4,6,8]
    var pred: Int32 = 0, idx: Int32 = 0
    mutating func reset() { pred = 0; idx = 0 }
    mutating func nib(_ n: UInt8) -> Float {
        let s = ADPCM.step[Int(idx)]; var d = s >> 3
        if n & 4 != 0 { d += s }; if n & 2 != 0 { d += s >> 1 }; if n & 1 != 0 { d += s >> 2 }
        pred += (n & 8 != 0) ? -d : d; pred = max(-32768, min(32767, pred))
        idx += ADPCM.idxT[Int(n & 15)]; idx = max(0, min(88, idx))
        return Float(pred) / 32768.0
    }
    mutating func decode(_ data: Data) -> [Float] {
        var o = [Float](); o.reserveCapacity(data.count * 2)
        for b in data { o.append(nib(b & 15)); o.append(nib((b >> 4) & 15)) }
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
        while i < n { p[i] = 0; i += 1 } }
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
    @Published var log: [String] = []

    var config = ConfigStore.load()

    private let ring = Ring(16000 * 4)
    private var codec = ADPCM()
    private var dsp = VoiceDSP()
    private let engine = AVAudioEngine()
    private var srcNode: AVAudioSourceNode!

    // BLE
    private var cm: CBCentralManager!
    private var dev: CBPeripheral?
    private var tx: CBCharacteristic?
    private var capsSent = false
    private var streaming = false

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

    static let logFile: FileHandle? = {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/miremote_engine.log")
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    func L(_ s: String) {
        NSLog("[MiRemote] %@", s)
        Engine.logFile?.write((s + "\n").data(using: .utf8)!)
        log.append(s); if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // ---------- lifecycle ----------
    func start() {
        proxy = BTProxy(self)
        ConfigStore.save(config)   // persist merged button list (power/menu/TV/volume)
        setupAudio()
        checkPermissions()
        cm = CBCentralManager(delegate: proxy, queue: nil)
        installTap()
        setupHID()
        installKeyCapture()
        // 守护定时器：① 授权后自动补装事件拦截；② 输出设备脱离 BlackHole 时自动重挂
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.audioWatchdog()
                if self.tap == nil, AXIsProcessTrusted() {
                    self.installTap()
                    if self.tap != nil { self.L("辅助功能已授权，事件拦截已启用") }
                }
            }
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

    func saveConfig() { ConfigStore.save(config); L("配置已保存") }

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
        guard let bh = Self.deviceID(named: "BlackHole") else { L("⚠️ 未找到 BlackHole 声卡，语音无法当麦克风"); return }
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
        for id in ids {
            var ns = UInt32(MemoryLayout<CFString?>.size); var name: CFString? = nil
            var na = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            withUnsafeMutablePointer(to: &name) { _ = AudioObjectGetPropertyData(id, &na, 0, nil, &ns, $0) }
            if let nm = name as String?, nm.contains(target) { return id }
        }
        return nil
    }

    // ---------- BLE (ATVV voice + mic) ----------
    fileprivate func btStateChanged(_ c: CBCentralManager) {
        btOn = (c.state == .poweredOn)
        if btOn { connectRemote() }
    }
    func connectRemote() {
        guard let c = cm, c.state == .poweredOn else { return }
        if let d = c.retrieveConnectedPeripherals(withServices: seed).first {
            dev = d; d.delegate = proxy; capsSent = false; c.connect(d, options: nil)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connectRemote() }
        }
    }
    fileprivate func didConnect(_ p: CBPeripheral) { remoteConnected = true; p.discoverServices([ATVV]) }
    fileprivate func didDisconnect() { remoteConnected = false; handshakeReady = false; streaming = false; connectRemote() }
    fileprivate func didServices(_ p: CBPeripheral) {
        if let s = p.services?.first(where: { $0.uuid == ATVV }) { p.discoverCharacteristics([TX,RX,CTL], for: s) }
    }
    fileprivate func didChars(_ p: CBPeripheral, _ s: CBService) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == TX { tx = ch }
            else if ch.uuid == RX || ch.uuid == CTL { p.setNotifyValue(true, for: ch) }
        }
    }
    fileprivate func didNotify(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        if ch.uuid == CTL && ch.isNotifying && !capsSent, let tx = tx {
            capsSent = true
            p.writeValue(Data([0x0A,0x00,0x06,0x00,0x01]), for: tx, type: .withResponse)
            handshakeReady = true; L("语音握手完成，随时可用")
        }
    }
    fileprivate func didValue(_ p: CBPeripheral, _ ch: CBCharacteristic) {
        guard let d = ch.value else { return }
        if ch.uuid == RX {
            if streaming { ring.push(dsp.process(codec.decode(d))) }
        } else if ch.uuid == CTL, let f = d.first {
            if f == 0x04 { voiceButton(down: true) }
            else if f == 0x00 { voiceButton(down: false) }
        }
    }
    private func voiceButton(down: Bool) {
        let v = config.voice
        // BLE 通道也标记语音键状态：与 HID 报告双保险，谁先到谁立标记，确保原生 F5 被吞
        voiceHidDown = down
        lastHidKeycodeAt[HIDMap.voiceKeycode] = ProcessInfo.processInfo.systemUptime
        if down {
            codec.reset(); dsp.reset(); streaming = true; micStreaming = config.voiceStartsMic
            if v.keycode >= KeyNames.kSpecialBase { startSpecial(v.keycode) }
            else if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: true, cmd: v.cmd, shift: v.shift, opt: v.opt, ctrl: v.ctrl) }
            L("🎤 语音键按下 → \(v.display)\(config.voiceStartsMic ? " + 麦克风开" : "")")
        } else {
            streaming = false; micStreaming = false
            if v.keycode >= KeyNames.kSpecialBase { stopSpecial(v.keycode) }
            else if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: false, cmd: false) }
            L("语音键松开")
        }
    }

    // ---------- HID reading ----------
    private func setupHID() {
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(mgr, [kIOHIDVendorIDKey: 0x2717] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        _ = IOHIDManagerOpen(mgr, 0)
        if let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> {
            inputMonitoringOK = !set.isEmpty
            for dvc in set {
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
            }
        }
        hidMgr = mgr
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
                    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                        return Unmanaged.passUnretained(event)
                    }
                    guard let ud = ud else { return Unmanaged.passUnretained(event) }
                    let me = Unmanaged<Engine>.fromOpaque(ud).takeUnretainedValue()
                    // ignore our own synthetic events
                    if event.getIntegerValueField(.eventSourceUserData) == kSyntheticMarker {
                        return Unmanaged.passUnretained(event)
                    }
                    let kc = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
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
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) { Task { @MainActor in e?.didServices(p) } }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) { Task { @MainActor in e?.didChars(p, s) } }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didNotify(p, ch) } }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) { Task { @MainActor in e?.didValue(p, ch) } }
}
