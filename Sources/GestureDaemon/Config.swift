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
        let diagonalRejectRatio: Double
        let downBiasRatio: Double

        init(debounceMs: Int, logLevel: String, diagonalRejectRatio: Double, downBiasRatio: Double) {
            self.debounceMs = debounceMs
            self.logLevel = logLevel
            self.diagonalRejectRatio = diagonalRejectRatio
            self.downBiasRatio = downBiasRatio
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.debounceMs = try container.decodeIfPresent(Int.self, forKey: .debounceMs) ?? 150
            self.logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
            self.diagonalRejectRatio = try container.decodeIfPresent(Double.self, forKey: .diagonalRejectRatio) ?? 0.95
            self.downBiasRatio = try container.decodeIfPresent(Double.self, forKey: .downBiasRatio) ?? 0.35
        }
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
        var debounce = config.settings.debounceMs
        if debounce < 0 { debounce = 0 }
        var ratio = config.settings.diagonalRejectRatio
        if ratio < 0.0 { ratio = 0.0 }
        if ratio > 1.0 { ratio = 1.0 }
        var bias = config.settings.downBiasRatio
        if bias < 0.0 { bias = 0.0 }
        if bias > 1.0 { bias = 1.0 }
        self.settings = AppConfig.SettingsConfig(debounceMs: debounce, logLevel: config.settings.logLevel, diagonalRejectRatio: ratio, downBiasRatio: bias)
    }

    init(defaultConfig: Bool = true) {
        self.gestures = [
            GestureMapping(name: "三指下滑关闭窗口", fingers: 3, direction: .down, minDistance: 0.05, keys: ["cmd", "w"]),
            GestureMapping(name: "三指左滑后退", fingers: 3, direction: .left, minDistance: 0.15, keys: ["cmd", "["]),
            GestureMapping(name: "三指右滑前进", fingers: 3, direction: .right, minDistance: 0.15, keys: ["cmd", "]"]),
            GestureMapping(name: "三指上滑刷新", fingers: 3, direction: .up, minDistance: 0.15, keys: ["cmd", "r"]),
            GestureMapping(name: "四指下滑隐藏", fingers: 4, direction: .down, minDistance: 0.12, keys: ["cmd", "h"]),
            GestureMapping(name: "四指上滑切换应用", fingers: 4, direction: .up, minDistance: 0.12, keys: ["cmd", "tab"])
        ]
        self.hotkeys = [
            HotkeyMapping(name: "Ctrl+Shift+A → Cmd+C", when: ["ctrl", "shift", "a"], send: ["cmd", "c"]),
        ]
        self.settings = AppConfig.SettingsConfig(debounceMs: 150, logLevel: "info", diagonalRejectRatio: 0.95, downBiasRatio: 0.35)
    }
}
