import Foundation
import CoreGraphics

enum KeyNames {
    // macOS virtual keycode -> label (for display of recorded keys)
    static let map: [Int: String] = [
        0x24:"Return", 0x30:"Tab", 0x31:"Space", 0x33:"Delete", 0x35:"Esc",
        0x7E:"↑", 0x7D:"↓", 0x7B:"←", 0x7C:"→",
        0x36:"右⌘", 0x37:"左⌘", 0x38:"⇧", 0x3C:"右⇧", 0x3A:"⌥", 0x3D:"右⌥",
        0x3B:"⌃", 0x3E:"右⌃", 0x39:"Caps", 0x3F:"Fn",
        0x7A:"F1",0x78:"F2",0x63:"F3",0x76:"F4",0x60:"F5",0x61:"F6",0x62:"F7",
        0x64:"F8",0x65:"F9",0x6D:"F10",0x67:"F11",0x6F:"F12",
        0x73:"Home",0x77:"End",0x74:"PgUp",0x79:"PgDn",0x75:"⌦",
        0x00:"A",0x0B:"B",0x08:"C",0x02:"D",0x0E:"E",0x03:"F",0x05:"G",0x04:"H",
        0x22:"I",0x26:"J",0x28:"K",0x25:"L",0x2E:"M",0x2D:"N",0x1F:"O",0x23:"P",
        0x0C:"Q",0x0F:"R",0x01:"S",0x11:"T",0x20:"U",0x09:"V",0x0D:"W",0x07:"X",
        0x10:"Y",0x06:"Z",
        0x12:"1",0x13:"2",0x14:"3",0x15:"4",0x17:"5",0x16:"6",0x1A:"7",0x1C:"8",
        0x19:"9",0x1D:"0",0x1B:"-",0x18:"=",0x21:"[",0x1E:"]",0x2A:"\\",
        0x29:";",0x27:"'",0x2B:",",0x2F:".",0x2C:"/",0x32:"`",
    ]
    // 特殊动作（鼠标/滚轮）：占用 0x10000 以上的伪键码
    static let kSpecialBase = 0x10000
    static let kMouseUp = 0x10001, kMouseDown = 0x10002, kMouseLeft = 0x10003, kMouseRight = 0x10004
    static let kMouseClick = 0x10005, kMouseRClick = 0x10006
    static let kScrollUp = 0x10007, kScrollDown = 0x10008
    static let specials: [(name: String, code: Int)] = [
        ("鼠标 ↑", kMouseUp), ("鼠标 ↓", kMouseDown), ("鼠标 ←", kMouseLeft), ("鼠标 →", kMouseRight),
        ("鼠标左键", kMouseClick), ("鼠标右键", kMouseRClick),
        ("滚轮 ↑", kScrollUp), ("滚轮 ↓", kScrollDown),
    ]
    static func label(keycode: Int, cmd: Bool, shift: Bool, opt: Bool, ctrl: Bool) -> String {
        if keycode == kNone { return "（不映射 / 保持原键）" }
        if keycode >= kSpecialBase {
            return specials.first(where: { $0.code == keycode })?.name ?? String(format:"特殊0x%x", keycode)
        }
        let base = map[keycode] ?? String(format:"键码0x%02x", keycode)
        var c = cmd, s = shift, o = opt, t = ctrl
        switch keycode {   // 修饰键自身的 flag 不重复显示
        case 0x36,0x37: c = false
        case 0x38,0x3C: s = false
        case 0x3A,0x3D: o = false
        case 0x3B,0x3E: t = false
        default: break
        }
        var p = ""
        if t { p += "⌃" }; if o { p += "⌥" }; if s { p += "⇧" }; if c { p += "⌘" }
        return p + base
    }
    static let kNone = 0xFFFF
}

enum HIDMap {
    // remote HID usage (report byte3) -> macOS keycode macOS also generates (for suppression)
    static let usageToKeycode: [UInt8: CGKeyCode] = [
        0x52:0x7E, 0x51:0x7D, 0x50:0x7B, 0x4F:0x7C, 0x28:0x24, 0x4A:0x73, 0x35:0x32,
    ]
    // 语音键除 BLE 语音流外还会发一个 HID F5（usage 0x3E）；macOS 把 F5 当系统听写🎤键，必须吞掉
    static let voiceUsage: UInt8 = 0x3E
    static let voiceKeycode: CGKeyCode = 0x60   // F5
}

struct ButtonMapping: Identifiable, Codable {
    var usage: Int          // HID usage byte; -1 = voice button
    var name: String        // physical button name
    var keycode: Int        // target macOS keycode; 0xFFFF = keep original
    var cmd: Bool
    var shift: Bool
    var opt: Bool
    var ctrl: Bool
    var id: Int { usage }

    init(usage: Int, name: String, keycode: Int = 0xFFFF, cmd: Bool = false, shift: Bool = false, opt: Bool = false, ctrl: Bool = false) {
        self.usage = usage; self.name = name; self.keycode = keycode
        self.cmd = cmd; self.shift = shift; self.opt = opt; self.ctrl = ctrl
    }
    var display: String { KeyNames.label(keycode: keycode, cmd: cmd, shift: shift, opt: opt, ctrl: ctrl) }
}

struct Config: Codable {
    var buttons: [ButtonMapping]
    var voice: ButtonMapping       // usage = -1
    var voiceStartsMic: Bool

    static let known: [(usage: Int, name: String)] = [
        (0x52, "方向 上"), (0x51, "方向 下"), (0x50, "方向 左"), (0x4F, "方向 右"),
        (0x28, "确认 OK"), (0xF1, "返回 Back"), (0x4A, "主页 Home"),
        (0x65, "菜单 Menu"), (0x35, "TV 键"), (0x66, "电源 Power"),
        (0x80, "音量 +"), (0x81, "音量 −"),
    ]
    // sensible defaults (keycodes)
    static let defaultTarget: [Int: (Int,Bool,Bool,Bool,Bool)] = [
        0x52:(0x7E,false,false,false,false), 0x51:(0x7D,false,false,false,false),
        0x50:(0x7B,false,false,false,false), 0x4F:(0x7C,false,false,false,false),
        0x28:(0x24,false,false,false,false), 0xF1:(0x35,false,false,false,false),
    ]
    static var defaultConfig: Config {
        let btns = known.map { k -> ButtonMapping in
            if let t = defaultTarget[k.usage] {
                return ButtonMapping(usage: k.usage, name: k.name, keycode: t.0, cmd: t.1, shift: t.2, opt: t.3, ctrl: t.4)
            }
            return ButtonMapping(usage: k.usage, name: k.name)
        }
        return Config(buttons: btns,
                      voice: ButtonMapping(usage: -1, name: "语音键", keycode: 0x36, cmd: true),
                      voiceStartsMic: true)
    }
    mutating func mergeKnown() {
        for k in Config.known {
            if let i = buttons.firstIndex(where: { $0.usage == k.usage }) {
                buttons[i].name = k.name
            } else {
                buttons.append(ButtonMapping(usage: k.usage, name: k.name))
            }
        }
        let order = Dictionary(uniqueKeysWithValues: Config.known.enumerated().map { ($1.usage, $0) })
        buttons.sort { (order[$0.usage] ?? 999) < (order[$1.usage] ?? 999) }
    }
}

final class ConfigStore {
    static let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/MiRemote")
    static let path = (dir as NSString).appendingPathComponent("config.json")
    static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: path),
              var cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config.defaultConfig
        }
        cfg.mergeKnown()
        return cfg
    }
    static func save(_ cfg: Config) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cfg) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}
