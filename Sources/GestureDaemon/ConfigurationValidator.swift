import Foundation

extension ApplicationScope {
    func overlaps(_ other: ApplicationScope) -> Bool {
        let own = Set(bundleIdentifiers)
        let theirs = Set(other.bundleIdentifiers)
        switch (mode, other.mode) {
        case (.all, .include): return !theirs.isEmpty
        case (.include, .all): return !own.isEmpty
        case (.all, _), (_, .all), (.exclude, .exclude): return true
        case (.include, .include): return !own.isDisjoint(with: theirs)
        case (.include, .exclude): return !own.subtracting(theirs).isEmpty
        case (.exclude, .include): return !theirs.subtracting(own).isEmpty
        }
    }
}

enum ConfigurationValidator {
    static func warnings(for configuration: AutomationConfiguration) -> [String] {
        var warnings: [String] = []
        var earlierRules: [AutomationRule] = []
        for rule in configuration.rules where rule.isEnabled {
            let label = rule.name.isEmpty ? rule.id.uuidString : rule.name
            if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { warnings.append("存在没有名称的规则") }
            if rule.actions.isEmpty { warnings.append("“\(label)”没有执行动作") }
            if rule.applicationScope.mode != .all && rule.applicationScope.bundleIdentifiers.isEmpty {
                warnings.append("“\(label)”选择了 App 范围，但没有指定 App")
            }
            switch rule.trigger {
            case .trackpad(let trigger):
                if !(2...5).contains(trigger.fingers) { warnings.append("“\(label)”的手指数必须为 2–5") }
                if !trigger.minimumDistance.isFinite || trigger.minimumDistance <= 0 { warnings.append("“\(label)”的触发距离必须大于 0 且为有限值") }
                if configuration.settings.useCompatibilityTrackpadMode && trigger.fingers != 2 {
                    warnings.append("“\(label)”需要高级触控板模式，当前兼容模式不会触发该规则")
                } else if !configuration.settings.useCompatibilityTrackpadMode && trigger.fingers < 4 && [.pinch, .spread].contains(trigger.direction) {
                    warnings.append("“\(label)”在高级模式下的捏合/张开需要 4–5 指；两指捏合请使用兼容模式")
                }
            case .keyboard(let trigger):
                if KeyboardShortcut(keys: trigger.keys) == nil { warnings.append("“\(label)”需要一个有效的普通按键，可附加修饰键") }
            }
            for action in rule.actions where !isValid(action) {
                warnings.append("“\(label)”包含无效的“\(action.kind.title)”动作")
            }
            if let earlier = earlierRules.first(where: { sameTrigger($0.trigger, rule.trigger) && $0.applicationScope.overlaps(rule.applicationScope) }) {
                warnings.append("“\(label)”与“\(earlier.name)”使用相同触发器且 App 范围重叠，列表靠前的规则会优先")
            }
            earlierRules.append(rule)
        }
        // 多个相同错误使用一条提示，避免 SwiftUI ForEach 的重复标识。
        var seen = Set<String>()
        return warnings.filter { seen.insert($0).inserted }
    }

    static func isExecutable(_ rule: AutomationRule) -> Bool {
        guard rule.isEnabled, !rule.actions.isEmpty, rule.actions.allSatisfy(isValid) else { return false }
        if rule.applicationScope.mode == .include && rule.applicationScope.bundleIdentifiers.isEmpty { return false }
        switch rule.trigger {
        case .trackpad(let trigger):
            return (2...5).contains(trigger.fingers) && trigger.minimumDistance.isFinite && trigger.minimumDistance > 0
        case .keyboard(let trigger): return KeyboardShortcut(keys: trigger.keys) != nil
        }
    }

    static func isValid(_ action: AutomationAction) -> Bool {
        switch action.kind {
        case .keyboardShortcut:
            let (_, regular) = KeySimulator.classifyKeys(action.keys)
            return !regular.isEmpty && regular.allSatisfy { KeySimulator.keyCodeFor(name: $0) != nil }
        case .openURL: return URL(string: action.value)?.scheme != nil
        case .launchApplication, .shellScript, .appleScript: return !action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .delay: return action.delayMilliseconds >= 0
        }
    }

    private static func sameTrigger(_ lhs: AutomationTrigger, _ rhs: AutomationTrigger) -> Bool {
        switch (lhs, rhs) {
        case (.trackpad(let a), .trackpad(let b)): return a.fingers == b.fingers && a.direction == b.direction
        case (.keyboard(let a), .keyboard(let b)):
            guard let first = KeyboardShortcut(keys: a.keys), let second = KeyboardShortcut(keys: b.keys) else { return false }
            return first == second // 同一次按键按下/松开均会被列表靠前的规则占用。
        default: return false
        }
    }
}
