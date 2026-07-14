import Foundation

enum ConfigurationValidator {
    static func warnings(for configuration: AutomationConfiguration) -> [String] {
        var warnings: [String] = []
        var triggerOwners: [String: String] = [:]

        for rule in configuration.rules where rule.isEnabled {
            let label = rule.name.isEmpty ? rule.id.uuidString : rule.name
            if rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                warnings.append("存在没有名称的规则")
            }
            if rule.actions.isEmpty { warnings.append("“\(label)”没有执行动作") }
            if rule.applicationScope.mode != .all && rule.applicationScope.bundleIdentifiers.isEmpty {
                warnings.append("“\(label)”选择了 App 范围，但没有指定 App")
            }

            switch rule.trigger {
            case .trackpad(let trigger):
                if !(2...5).contains(trigger.fingers) { warnings.append("“\(label)”的手指数必须为 2–5") }
                if trigger.minimumDistance <= 0 { warnings.append("“\(label)”的触发距离必须大于 0") }
                if configuration.settings.useCompatibilityTrackpadMode && trigger.fingers != 2 {
                    warnings.append("“\(label)”需要高级触控板模式，当前兼容模式不会触发该规则")
                }
            case .keyboard(let trigger):
                let (_, regular) = KeySimulator.classifyKeys(trigger.keys)
                if regular.count != 1 || KeySimulator.keyCodeFor(name: regular.first ?? "") == nil {
                    warnings.append("“\(label)”需要一个有效的普通按键，可附加修饰键")
                }
            }

            for action in rule.actions {
                switch action.kind {
                case .keyboardShortcut:
                    let (_, regular) = KeySimulator.classifyKeys(action.keys)
                    if regular.isEmpty || regular.contains(where: { KeySimulator.keyCodeFor(name: $0) == nil }) {
                        warnings.append("“\(label)”包含无效的快捷键动作")
                    }
                case .openURL:
                    if URL(string: action.value)?.scheme == nil { warnings.append("“\(label)”包含无效网址") }
                case .launchApplication, .shellScript, .appleScript:
                    if action.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        warnings.append("“\(label)”包含内容为空的“\(action.kind.title)”动作")
                    }
                case .delay:
                    if action.delayMilliseconds < 0 { warnings.append("“\(label)”的等待时间不能为负数") }
                }
            }

            let signature = triggerSignature(rule)
            if let owner = triggerOwners[signature] {
                warnings.append("“\(label)”与“\(owner)”使用相同触发器，列表靠前的规则会优先")
            } else {
                triggerOwners[signature] = label
            }
        }
        return warnings
    }

    private static func triggerSignature(_ rule: AutomationRule) -> String {
        let scope = rule.applicationScope.mode.rawValue + ":" + rule.applicationScope.bundleIdentifiers.sorted().joined(separator: ",")
        switch rule.trigger {
        case .trackpad(let trigger):
            return "trackpad:\(trigger.fingers):\(trigger.direction.rawValue):\(scope)"
        case .keyboard(let trigger):
            return "keyboard:\(trigger.keys.map { $0.lowercased() }.sorted().joined(separator: "+")):\(trigger.phase.rawValue):\(scope)"
        }
    }
}
