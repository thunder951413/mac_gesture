import Foundation
import CoreGraphics

enum GestureDirection: String, Codable {
    case up, down, left, right, pinch, spread
}

struct GestureMapping: Codable {
    let name: String
    let fingers: Int
    let direction: GestureDirection
    let minDistance: Double
    let keys: [String]
}

struct HotkeyMapping: Codable {
    let name: String
    let `when`: [String]
    let send: [String]
}

struct AppConfig: Codable {
    let gestures: [GestureMapping]
    let hotkeys: [HotkeyMapping]?
    let settings: SettingsConfig

    struct SettingsConfig: Codable {
        let debounceMs: Int
        let logLevel: String
    }
}

final class Config {
    let gestures: [GestureMapping]
    let hotkeys: [HotkeyMapping]
    let settings: AppConfig.SettingsConfig

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let config = try decoder.decode(AppConfig.self, from: data)
        self.gestures = config.gestures
        self.hotkeys = config.hotkeys ?? []
        self.settings = config.settings
    }

    init(defaultConfig: Bool = true) {
        self.gestures = [
            GestureMapping(name: "三指下滑关闭窗口", fingers: 3, direction: .down, minDistance: 0.15, keys: ["cmd", "w"]),
            GestureMapping(name: "三指左滑后退", fingers: 3, direction: .left, minDistance: 0.15, keys: ["cmd", "["]),
            GestureMapping(name: "三指右滑前进", fingers: 3, direction: .right, minDistance: 0.15, keys: ["cmd", "]"]),
            GestureMapping(name: "三指上滑刷新", fingers: 3, direction: .up, minDistance: 0.15, keys: ["cmd", "r"]),
            GestureMapping(name: "四指下滑隐藏", fingers: 4, direction: .down, minDistance: 0.12, keys: ["cmd", "h"]),
            GestureMapping(name: "四指上滑切换应用", fingers: 4, direction: .up, minDistance: 0.12, keys: ["cmd", "tab"])
        ]
        self.hotkeys = [
            HotkeyMapping(name: "Ctrl+Shift+A → Hello输入", when: ["ctrl", "shift", "a"], send: ["hello"]),
        ]
        self.settings = AppConfig.SettingsConfig(debounceMs: 300, logLevel: "info")
    }
}
