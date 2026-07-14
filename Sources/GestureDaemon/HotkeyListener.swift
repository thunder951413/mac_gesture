import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

final class HotkeyListener {
    typealias RuleHandler = (AutomationRule) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let rules: [AutomationRule]
    private let onRule: RuleHandler
    private let myPID = getpid()
    private var activeFlags: CGEventFlags = []
    private var consumedKeys = Set<CGKeyCode>()
    private var pendingKeyUpRules: [CGKeyCode: AutomationRule] = [:]
    private var diagnosticEventCount = 0

    private static let relevantModifiers: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn
    ]

    init(rules: [AutomationRule], onRule: @escaping RuleHandler) {
        self.rules = rules.filter { $0.isEnabled && !$0.actions.isEmpty && $0.category == .keyboard }
        self.onRule = onRule
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard !rules.isEmpty else { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HotkeyListener>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let eventTap { CFMachPortInvalidate(eventTap) }
        runLoopSource = nil
        eventTap = nil
        consumedKeys.removeAll()
        pendingKeyUpRules.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(myPID) {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            activeFlags = event.flags
            trace("flagsChanged flags=\(event.flags.rawValue)")
            return Unmanaged.passUnretained(event)
        case .keyDown:
            trace("keyDown code=\(event.getIntegerValueField(.keyboardEventKeycode)) flags=\(event.flags.rawValue) repeat=\(event.getIntegerValueField(.keyboardEventAutorepeat)) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID))")
            return handleKeyDown(event)
        case .keyUp:
            return handleKeyUp(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if consumedKeys.contains(keyCode) {
            if isRepeat, let rule = matchingRule(keyCode: keyCode, flags: event.flags), case .keyboard(let trigger) = rule.trigger,
               trigger.allowRepeat, trigger.phase == .keyDown {
                onRule(rule)
            }
            return nil
        }

        guard let rule = matchingRule(keyCode: keyCode, flags: event.flags), case .keyboard(let trigger) = rule.trigger else {
            trace("未匹配 code=\(keyCode) relevantFlags=\(event.flags.intersection(Self.relevantModifiers).rawValue)")
            return Unmanaged.passUnretained(event)
        }
        DiagnosticLog.shared.write("[Keyboard] 匹配规则：\(rule.name)")
        consumedKeys.insert(keyCode)
        if trigger.phase == .keyDown {
            if !isRepeat || trigger.allowRepeat { onRule(rule) }
        } else {
            pendingKeyUpRules[keyCode] = rule
        }
        return nil
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard consumedKeys.remove(keyCode) != nil else { return Unmanaged.passUnretained(event) }
        if let rule = pendingKeyUpRules.removeValue(forKey: keyCode) { onRule(rule) }
        return nil
    }

    private func matchingRule(keyCode: CGKeyCode, flags: CGEventFlags) -> AutomationRule? {
        // keyDown 自身携带的 flags 比单独缓存 flagsChanged 更可靠，特别是快速组合键
        // 与合成事件；activeFlags 仅作为部分设备未附带 flags 时的回退。
        let eventModifiers = flags.intersection(Self.relevantModifiers)
        let current = eventModifiers.isEmpty ? activeFlags.intersection(Self.relevantModifiers) : eventModifiers
        return rules.first { rule in
            guard rule.applicationScope.matches(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) else { return false }
            guard case .keyboard(let trigger) = rule.trigger else { return false }
            let (mods, regular) = KeySimulator.classifyKeys(trigger.keys)
            guard regular.count == 1,
                  let target = KeySimulator.keyCodeFor(name: regular[0]),
                  target == keyCode else { return false }
            return KeySimulator.modifierFlags(for: mods) == current
        }
    }

    private func trace(_ message: String) {
        guard diagnosticEventCount < 40 else { return }
        diagnosticEventCount += 1
        DiagnosticLog.shared.write("[KeyboardTrace] \(message)")
    }
}
