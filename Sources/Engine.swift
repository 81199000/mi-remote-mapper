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
    private func installKeyCapture() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] ev in
            guard let self = self, let usage = self.capturingUsage else { return ev }
            // lone-modifier keycodes
            let loneMods: Set<UInt16> = [0x36,0x37,0x38,0x3C,0x3A,0x3D,0x3B,0x3E,0x39,0x3F]
            let kc = Int(ev.keyCode)
            let f = ev.modifierFlags
            var cmd = f.contains(.command), shift = f.contains(.shift), opt = f.contains(.option), ctrl = f.contains(.control)
            if ev.type == .flagsChanged {
                guard loneMods.contains(ev.keyCode) else { return nil }
                // only capture on PRESS (the pressed modifier is currently active), ignore release
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
                guard active else { return nil }
                cmd = (kc == 0x36 || kc == 0x37); shift = false; opt = false; ctrl = false
            }
            self.applyCapture(keycode: kc, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl)
            return nil // swallow this key so it doesn't act while recording
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
        _ = engine.outputNode
        if let bh = Self.deviceID(named: "BlackHole"), let u = engine.outputNode.audioUnit {
            var d = bh
            AudioUnitSetProperty(u, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &d, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        engine.attach(srcNode)
        engine.connect(srcNode, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        do { try engine.start() } catch { L("音频引擎启动失败: \(error)") }
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
            if streaming { ring.push(codec.decode(d)) }
        } else if ch.uuid == CTL, let f = d.first {
            if f == 0x04 { voiceButton(down: true) }
            else if f == 0x00 { voiceButton(down: false) }
        }
    }
    private func voiceButton(down: Bool) {
        let v = config.voice
        if down {
            codec.reset(); streaming = true; micStreaming = config.voiceStartsMic
            if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: true, cmd: v.cmd, shift: v.shift, opt: v.opt, ctrl: v.ctrl) }
            L("🎤 语音键按下 → \(v.display)\(config.voiceStartsMic ? " + 麦克风开" : "")")
        } else {
            streaming = false; micStreaming = false
            if v.keycode != KeyNames.kNone { postKey(CGKeyCode(v.keycode), down: false, cmd: false) }
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
                    DispatchQueue.main.async { me.hidReport(usage: usage) }
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
            if let t = downTarget, t.keycode != KeyNames.kNone {
                postKey(CGKeyCode(t.keycode), down: false, cmd: false)
            }
            downButtonUsage = 0; downTarget = nil
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
        // emit mapped key (down); keyUp on release
        postKey(CGKeyCode(m.keycode), down: true, cmd: m.cmd, shift: m.shift, opt: m.opt, ctrl: m.ctrl)
        downButtonUsage = Int(usage); downTarget = m
    }

    // ---------- CGEvent tap: suppress originals of mapped buttons ----------
    private func installTap() {
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
