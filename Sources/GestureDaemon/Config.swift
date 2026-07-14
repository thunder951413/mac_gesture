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
        // 高级调优参数（均有默认值，旧配置无需改动）
        let spreadThreshold: Double          // 捏合/张开最小 spread 变化量
        let minSwipeDistance: Double         // 滑动最小识别距离
        let downBiasMinAbsDy: Double         // 下偏修正触发的最小 |dy|
        let spreadToDistanceRatio: Double    // spread 判定优先于距离的倍数
        let liveTriggerDistance: Double      // 实时触发距离（手指未抬起时）

        init(debounceMs: Int, logLevel: String,
             diagonalRejectRatio: Double, downBiasRatio: Double,
             spreadThreshold: Double, minSwipeDistance: Double,
             downBiasMinAbsDy: Double, spreadToDistanceRatio: Double,
             liveTriggerDistance: Double) {
            self.debounceMs = debounceMs
            self.logLevel = logLevel
            self.diagonalRejectRatio = diagonalRejectRatio
            self.downBiasRatio = downBiasRatio
            self.spreadThreshold = spreadThreshold
            self.minSwipeDistance = minSwipeDistance
            self.downBiasMinAbsDy = downBiasMinAbsDy
            self.spreadToDistanceRatio = spreadToDistanceRatio
            self.liveTriggerDistance = liveTriggerDistance
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.debounceMs = try container.decodeIfPresent(Int.self, forKey: .debounceMs) ?? 150
            self.logLevel = try container.decodeIfPresent(String.self, forKey: .logLevel) ?? "info"
            self.diagonalRejectRatio = try container.decodeIfPresent(Double.self, forKey: .diagonalRejectRatio) ?? 0.95
            self.downBiasRatio = try container.decodeIfPresent(Double.self, forKey: .downBiasRatio) ?? 0.35
            self.spreadThreshold = try container.decodeIfPresent(Double.self, forKey: .spreadThreshold) ?? 0.03
            self.minSwipeDistance = try container.decodeIfPresent(Double.self, forKey: .minSwipeDistance) ?? 0.01
            self.downBiasMinAbsDy = try container.decodeIfPresent(Double.self, forKey: .downBiasMinAbsDy) ?? 0.08
            self.spreadToDistanceRatio = try container.decodeIfPresent(Double.self, forKey: .spreadToDistanceRatio) ?? 2.0
            self.liveTriggerDistance = try container.decodeIfPresent(Double.self, forKey: .liveTriggerDistance) ?? 0.06
        }

        static let defaults = SettingsConfig(
            debounceMs: 150, logLevel: "info",
            diagonalRejectRatio: 0.95, downBiasRatio: 0.35,
            spreadThreshold: 0.03, minSwipeDistance: 0.01,
            downBiasMinAbsDy: 0.08, spreadToDistanceRatio: 2.0,
            liveTriggerDistance: 0.06
        )
    }

    /// 旧版 schema v1 的默认配置，仅保留用于配置迁移和兼容性测试。
    static let defaults = AppConfig(
        gestures: [
            GestureMapping(name: "三指下滑关闭窗口", fingers: 3, direction: .down, minDistance: 0.22, keys: ["cmd", "w"]),
            GestureMapping(name: "三指左滑后退", fingers: 3, direction: .left, minDistance: 0.15, keys: ["cmd", "["]),
            GestureMapping(name: "三指右滑前进", fingers: 3, direction: .right, minDistance: 0.15, keys: ["cmd", "]"]),
            GestureMapping(name: "三指上滑刷新", fingers: 3, direction: .up, minDistance: 0.15, keys: ["cmd", "r"]),
            GestureMapping(name: "四指下滑隐藏", fingers: 4, direction: .down, minDistance: 0.12, keys: ["cmd", "h"]),
            GestureMapping(name: "四指上滑切换应用", fingers: 4, direction: .up, minDistance: 0.12, keys: ["cmd", "tab"])
        ],
        hotkeys: [
            HotkeyMapping(name: "Ctrl+Shift+A → Cmd+C", when: ["ctrl", "shift", "a"], send: ["cmd", "c"]),
            HotkeyMapping(name: "Ctrl+Shift+X → Cmd+V", when: ["ctrl", "shift", "x"], send: ["cmd", "v"]),
            HotkeyMapping(name: "Cmd+H → Left", when: ["cmd", "h"], send: ["left"]),
            HotkeyMapping(name: "Cmd+J → Down", when: ["cmd", "j"], send: ["down"]),
            HotkeyMapping(name: "Cmd+K → Up", when: ["cmd", "k"], send: ["up"]),
            HotkeyMapping(name: "Cmd+L → Right", when: ["cmd", "l"], send: ["right"])
        ],
        settings: .defaults
    )
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
        // 范围约束：负值/越界值 clamp 到合法区间，避免配置错误导致识别异常
        self.settings = AppConfig.SettingsConfig(
            debounceMs: max(0, config.settings.debounceMs),
            logLevel: config.settings.logLevel,
            diagonalRejectRatio: min(1.0, max(0.0, config.settings.diagonalRejectRatio)),
            downBiasRatio: min(1.0, max(0.0, config.settings.downBiasRatio)),
            spreadThreshold: max(0.0, config.settings.spreadThreshold),
            minSwipeDistance: max(0.0, config.settings.minSwipeDistance),
            downBiasMinAbsDy: max(0.0, config.settings.downBiasMinAbsDy),
            spreadToDistanceRatio: max(0.0, config.settings.spreadToDistanceRatio),
            liveTriggerDistance: max(0.0, config.settings.liveTriggerDistance)
        )
    }

    init(defaultConfig: Bool = true) {
        self.gestures = AppConfig.defaults.gestures
        self.hotkeys = AppConfig.defaults.hotkeys ?? []
        self.settings = AppConfig.defaults.settings
    }

    /// 默认配置的 JSON 文本（由 AppConfig.defaults 序列化，单一数据源）。
    static var defaultJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(AppConfig.defaults),
              let json = String(data: data, encoding: .utf8) else {
            return AppConfig.fallbackJSON
        }
        return json
    }
}

extension AppConfig {
    /// JSON 编码失败时的硬编码兜底（理论上不会用到）。
    static let fallbackJSON = """
{
  "gestures": [
    { "name": "三指下滑关闭窗口", "fingers": 3, "direction": "down", "minDistance": 0.22, "keys": ["cmd", "w"] },
    { "name": "三指左滑后退", "fingers": 3, "direction": "left", "minDistance": 0.15, "keys": ["cmd", "["] },
    { "name": "三指右滑前进", "fingers": 3, "direction": "right", "minDistance": 0.15, "keys": ["cmd", "]"] },
    { "name": "三指上滑刷新", "fingers": 3, "direction": "up", "minDistance": 0.15, "keys": ["cmd", "r"] },
    { "name": "四指下滑隐藏", "fingers": 4, "direction": "down", "minDistance": 0.12, "keys": ["cmd", "h"] },
    { "name": "四指上滑切换应用", "fingers": 4, "direction": "up", "minDistance": 0.12, "keys": ["cmd", "tab"] }
  ],
  "hotkeys": [
    { "name": "Ctrl+Shift+A → Cmd+C", "when": ["ctrl", "shift", "a"], "send": ["cmd", "c"] },
    { "name": "Ctrl+Shift+X → Cmd+V", "when": ["ctrl", "shift", "x"], "send": ["cmd", "v"] },
    { "name": "Cmd+H → Left", "when": ["cmd", "h"], "send": ["left"] },
    { "name": "Cmd+J → Down", "when": ["cmd", "j"], "send": ["down"] },
    { "name": "Cmd+K → Up", "when": ["cmd", "k"], "send": ["up"] },
    { "name": "Cmd+L → Right", "when": ["cmd", "l"], "send": ["right"] }
  ],
  "settings": {
    "debounceMs": 150,
    "logLevel": "info",
    "diagonalRejectRatio": 0.95,
    "downBiasRatio": 0.35,
    "spreadThreshold": 0.03,
    "minSwipeDistance": 0.01,
    "downBiasMinAbsDy": 0.08,
    "spreadToDistanceRatio": 2.0,
    "liveTriggerDistance": 0.06
  }
}
"""
}
