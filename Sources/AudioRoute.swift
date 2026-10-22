import Foundation
import CoreAudio

/// 语音键按下时把"系统默认输入设备"临时切到虚拟声卡（BlackHole），松开后还原。
///
/// 背景故障：MiRemote 把遥控器的 ATVV 音频写进 BlackHole，而 macOS 的听写 /
/// 微信输入法等识别端总是从**系统默认输入设备**取音。一旦 macOS 在 USB 设备插拔、
/// 重启或显示器 hub 重新枚举后把默认输入改回物理麦克风，识别端就永远听不到遥控器
/// 的声音 —— 表现为"语音输入突然失效"，但蓝牙链路、ATVV 握手、音频字节数全部正常。
///
/// 这里按下即接管、松开即还原，因此平时麦克风照常可用，只在说话的那几秒借用。
enum AudioRoute {

    struct Device {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let channels: Int
    }

    // MARK: - CoreAudio 底层读写

    private static func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var a = addr(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = value else { return "" }
        return cf as String
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                           mScope: kAudioObjectPropertyScopeInput,
                                           mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 4)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = raw.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - 对外能力

    /// 所有具备输入通道的设备
    static func inputDevices() -> [Device] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            let channels = inputChannels(id)
            guard channels > 0 else { return nil }
            return Device(id: id,
                          name: stringProperty(id, kAudioDevicePropertyDeviceNameCFString),
                          uid: stringProperty(id, kAudioDevicePropertyDeviceUID),
                          channels: channels)
        }
    }

    static func defaultInput() -> AudioDeviceID {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var a = addr(kAudioHardwarePropertyDefaultInputDevice)
        var target = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, size, &target) == noErr
    }

    /// 选定接管目标：优先用户指定 UID，否则自动挑名字含 BlackHole 且通道数最少的设备
    static func resolveTarget(uid: String?) -> Device? {
        let all = inputDevices()
        if let uid, !uid.isEmpty, let hit = all.first(where: { $0.uid == uid || $0.uid.contains(uid) }) {
            return hit
        }
        let virtual = all.filter { $0.name.localizedCaseInsensitiveContains("blackhole") }
        return virtual.sorted { $0.channels < $1.channels }.first
    }

    // MARK: - 接管 / 还原

    /// 语音会话期间保存的原设备（nil = 当前未接管）
    private static var savedDevice: AudioDeviceID? = nil

    static var isCaptured: Bool { savedDevice != nil }

    /// 按下语音键：把默认输入切到虚拟声卡，并记住原设备
    /// - Returns: 供日志展示的一行结果
    @discardableResult
    static func capture(uid: String?) -> String? {
        // 遥控器 audioStart 回执会让 voiceButton(down:true) 被二次触发，
        // 此处若再走一遍会把 savedDevice 清空 → 松开时不再还原。已在接管中则直接跳过。
        if savedDevice != nil { return nil }
        guard let target = resolveTarget(uid: uid) else {
            return nil
        }
        let current = defaultInput()
        if current == target.id {
            // 已经是目标设备：无需接管，也不记录（避免松开时误还原）
            savedDevice = nil
            return "默认输入已是 \(target.name)"
        }
        guard setDefaultInput(target.id) else { return nil }
        savedDevice = current
        let previous = inputDevices().first { $0.id == current }?.name ?? "未知设备"
        return "默认输入 \(previous) → \(target.name)（松开还原）"
    }

    /// 松开语音键：还原到接管前的设备
    @discardableResult
    static func restore() -> String? {
        guard let previous = savedDevice else { return nil }
        savedDevice = nil
        guard setDefaultInput(previous) else { return nil }
        let name = inputDevices().first { $0.id == previous }?.name ?? "原设备"
        return "默认输入已还原 → \(name)"
    }
}
