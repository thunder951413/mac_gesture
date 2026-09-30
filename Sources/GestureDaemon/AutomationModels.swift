import Foundation

enum RuleCategory: String, Codable, CaseIterable, Identifiable {
    case trackpad
    case keyboard

    var id: String { rawValue }
    var title: String { self == .trackpad ? "触控板" : "键盘" }
    var systemImage: String { self == .trackpad ? "rectangle.and.hand.point.up.left" : "keyboard" }
}

enum TriggerPhase: String, Codable, CaseIterable, Identifiable {
    case keyDown
    case keyUp

    var id: String { rawValue }
    var title: String { self == .keyDown ? "按下时" : "松开时" }
}

struct TrackpadTrigger: Codable, Equatable {
    var fingers: Int = 3
    var direction: GestureDirection = .down
    var minimumDistance: Double = 0.15
}

struct KeyboardTrigger: Codable, Equatable {
    var keys: [String] = ["cmd", "j"]
    var phase: TriggerPhase = .keyDown
    var allowRepeat: Bool = false
}

enum AutomationTrigger: Codable, Equatable {
    case trackpad(TrackpadTrigger)
    case keyboard(KeyboardTrigger)

    private enum CodingKeys: String, CodingKey { case type, trackpad, keyboard }

    var category: RuleCategory {
        switch self {
        case .trackpad: return .trackpad
        case .keyboard: return .keyboard
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(RuleCategory.self, forKey: .type) {
        case .trackpad: self = .trackpad(try container.decode(TrackpadTrigger.self, forKey: .trackpad))
        case .keyboard: self = .keyboard(try container.decode(KeyboardTrigger.self, forKey: .keyboard))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .type)
        switch self {
        case .trackpad(let value): try container.encode(value, forKey: .trackpad)
        case .keyboard(let value): try container.encode(value, forKey: .keyboard)
        }
    }
}

enum ApplicationScopeMode: String, Codable, CaseIterable, Identifiable {
    case all
    case include
    case exclude

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "所有 App"
        case .include: return "仅指定 App"
        case .exclude: return "排除指定 App"
        }
    }
}

struct ApplicationScope: Codable, Equatable {
    var mode: ApplicationScopeMode = .all
    var bundleIdentifiers: [String] = []

    func matches(bundleIdentifier: String?) -> Bool {
        guard mode != .all else { return true }
        guard let bundleIdentifier else { return mode == .exclude }
        let contains = bundleIdentifiers.contains(bundleIdentifier)
        return mode == .include ? contains : !contains
    }
}

enum ActionKind: String, Codable, CaseIterable, Identifiable {
    case keyboardShortcut
    case openURL
    case launchApplication
    case shellScript
    case appleScript
    case delay

    var id: String { rawValue }
    var title: String {
        switch self {
        case .keyboardShortcut: return "发送快捷键"
        case .openURL: return "打开网址"
        case .launchApplication: return "打开应用"
        case .shellScript: return "运行 Shell 脚本"
        case .appleScript: return "运行 AppleScript"
        case .delay: return "等待"
        }
    }
}

struct AutomationAction: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: ActionKind = .keyboardShortcut
    var keys: [String] = ["cmd", "w"]
    var value: String = ""
    var delayMilliseconds: Int = 250

    static func keyboard(_ keys: [String]) -> AutomationAction {
        AutomationAction(kind: .keyboardShortcut, keys: keys)
    }
}

struct AutomationRule: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var isEnabled: Bool = true
    var trigger: AutomationTrigger
    var applicationScope = ApplicationScope()
    var actions: [AutomationAction]

    var category: RuleCategory { trigger.category }
}

struct EngineSettings: Codable, Equatable {
    var launchAtLogin = false
    var hideDockIcon = false
    var hideMenuBarIcon = false
    var useCompatibilityTrackpadMode = false
    var debounceMilliseconds = 150
    var logLevel = "info"
    var diagonalRejectRatio = 0.95
    var downBiasRatio = 0.35
    var spreadThreshold = 0.03
    var minimumSwipeDistance = 0.01
    var downBiasMinimumY = 0.08
    var spreadToDistanceRatio = 2.0
    var liveTriggerDistance = 0.06

    init(launchAtLogin: Bool = false, hideDockIcon: Bool = false, hideMenuBarIcon: Bool = false,
         useCompatibilityTrackpadMode: Bool = false,
         debounceMilliseconds: Int = 150, logLevel: String = "info",
         diagonalRejectRatio: Double = 0.95, downBiasRatio: Double = 0.35,
         spreadThreshold: Double = 0.03, minimumSwipeDistance: Double = 0.01,
         downBiasMinimumY: Double = 0.08, spreadToDistanceRatio: Double = 2.0,
         liveTriggerDistance: Double = 0.06) {
        self.launchAtLogin = launchAtLogin
        self.hideDockIcon = hideDockIcon
        self.hideMenuBarIcon = hideMenuBarIcon
        self.useCompatibilityTrackpadMode = useCompatibilityTrackpadMode
        self.debounceMilliseconds = max(0, debounceMilliseconds)
        self.logLevel = logLevel
        self.diagonalRejectRatio = diagonalRejectRatio.isFinite ? min(1, max(0, diagonalRejectRatio)) : 0.95
        self.downBiasRatio = downBiasRatio.isFinite ? min(1, max(0, downBiasRatio)) : 0.35
        self.spreadThreshold = spreadThreshold.isFinite ? max(0, spreadThreshold) : 0.03
        self.minimumSwipeDistance = minimumSwipeDistance.isFinite ? max(0, minimumSwipeDistance) : 0.01
        self.downBiasMinimumY = downBiasMinimumY.isFinite ? max(0, downBiasMinimumY) : 0.08
        self.spreadToDistanceRatio = spreadToDistanceRatio.isFinite ? max(0, spreadToDistanceRatio) : 2
        self.liveTriggerDistance = liveTriggerDistance.isFinite ? max(0, liveTriggerDistance) : 0.06
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, hideDockIcon, hideMenuBarIcon, useCompatibilityTrackpadMode, debounceMilliseconds, logLevel, diagonalRejectRatio, downBiasRatio
        case spreadThreshold, minimumSwipeDistance, downBiasMinimumY, spreadToDistanceRatio, liveTriggerDistance
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            launchAtLogin: try values.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false,
            hideDockIcon: try values.decodeIfPresent(Bool.self, forKey: .hideDockIcon) ?? false,
            hideMenuBarIcon: try values.decodeIfPresent(Bool.self, forKey: .hideMenuBarIcon) ?? false,
            useCompatibilityTrackpadMode: try values.decodeIfPresent(Bool.self, forKey: .useCompatibilityTrackpadMode) ?? false,
            debounceMilliseconds: try values.decodeIfPresent(Int.self, forKey: .debounceMilliseconds) ?? 150,
            logLevel: try values.decodeIfPresent(String.self, forKey: .logLevel) ?? "info",
            diagonalRejectRatio: try values.decodeIfPresent(Double.self, forKey: .diagonalRejectRatio) ?? 0.95,
            downBiasRatio: try values.decodeIfPresent(Double.self, forKey: .downBiasRatio) ?? 0.35,
            spreadThreshold: try values.decodeIfPresent(Double.self, forKey: .spreadThreshold) ?? 0.03,
            minimumSwipeDistance: try values.decodeIfPresent(Double.self, forKey: .minimumSwipeDistance) ?? 0.01,
            downBiasMinimumY: try values.decodeIfPresent(Double.self, forKey: .downBiasMinimumY) ?? 0.08,
            spreadToDistanceRatio: try values.decodeIfPresent(Double.self, forKey: .spreadToDistanceRatio) ?? 2.0,
            liveTriggerDistance: try values.decodeIfPresent(Double.self, forKey: .liveTriggerDistance) ?? 0.06
        )
    }

    var normalized: EngineSettings {
        EngineSettings(
            launchAtLogin: launchAtLogin, hideDockIcon: hideDockIcon, hideMenuBarIcon: hideMenuBarIcon,
            useCompatibilityTrackpadMode: useCompatibilityTrackpadMode,
            debounceMilliseconds: debounceMilliseconds, logLevel: logLevel,
            diagonalRejectRatio: diagonalRejectRatio, downBiasRatio: downBiasRatio,
            spreadThreshold: spreadThreshold, minimumSwipeDistance: minimumSwipeDistance,
            downBiasMinimumY: downBiasMinimumY, spreadToDistanceRatio: spreadToDistanceRatio,
            liveTriggerDistance: liveTriggerDistance
        )
    }
}

struct AutomationConfiguration: Codable, Equatable {
    var schemaVersion = 2
    var rules: [AutomationRule]
    var settings: EngineSettings

    init(schemaVersion: Int = 2, rules: [AutomationRule], settings: EngineSettings) {
        self.schemaVersion = schemaVersion
        self.rules = rules
        self.settings = settings
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, rules, settings }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 2
        guard schemaVersion == 2 else { throw ConfigurationError.unsupportedSchema(schemaVersion) }
        rules = try values.decode([AutomationRule].self, forKey: .rules)
        settings = try values.decodeIfPresent(EngineSettings.self, forKey: .settings) ?? EngineSettings()
    }

    func validateIdentity() throws {
        guard schemaVersion == 2 else { throw ConfigurationError.unsupportedSchema(schemaVersion) }
        guard Set(rules.map(\.id)).count == rules.count,
              rules.allSatisfy({ Set($0.actions.map(\.id)).count == $0.actions.count }) else {
            throw ConfigurationError.duplicateIdentity
        }
    }

    static let defaults = AutomationConfiguration(
        rules: [
            AutomationRule(name: "三指下滑关闭窗口", trigger: .trackpad(TrackpadTrigger(fingers: 3, direction: .down, minimumDistance: 0.22)), actions: [.keyboard(["cmd", "w"])]),
            AutomationRule(name: "三指左滑后退", trigger: .trackpad(TrackpadTrigger(fingers: 3, direction: .left, minimumDistance: 0.15)), actions: [.keyboard(["cmd", "["])]),
            AutomationRule(name: "三指右滑前进", trigger: .trackpad(TrackpadTrigger(fingers: 3, direction: .right, minimumDistance: 0.15)), actions: [.keyboard(["cmd", "]"])]),
            AutomationRule(name: "⌘J → 下方向键", trigger: .keyboard(KeyboardTrigger(keys: ["cmd", "j"])), actions: [.keyboard(["down"])]),
            AutomationRule(name: "⌘K → 上方向键", trigger: .keyboard(KeyboardTrigger(keys: ["cmd", "k"])), actions: [.keyboard(["up"])])
        ],
        settings: EngineSettings()
    )
}

extension GestureDirection: CaseIterable, Identifiable {
    static let allCases: [GestureDirection] = [.up, .down, .left, .right, .pinch, .spread]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .up: return "向上"
        case .down: return "向下"
        case .left: return "向左"
        case .right: return "向右"
        case .pinch: return "捏合"
        case .spread: return "张开"
        }
    }
}
