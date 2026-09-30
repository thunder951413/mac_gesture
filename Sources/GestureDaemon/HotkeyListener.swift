import Foundation
import CoreGraphics
import ApplicationServices
import AppKit

final class HotkeyListener {
    typealias RuleHandler = (AutomationRule) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let rules: [(rule: AutomationRule, shortcut: KeyboardShortcut)]
    private let onRule: RuleHandler
    private let shouldHandleEvents: () -> Bool
    private let logDebug: Bool
    private let myPID = getpid()
    private var pressedRules: [CGKeyCode: (rule: AutomationRule, shortcut: KeyboardShortcut)] = [:]
    private var diagnosticEventCount = 0

    init(rules: [AutomationRule], logDebug: Bool = false, shouldHandleEvents: @escaping () -> Bool = { true }, onRule: @escaping RuleHandler) {
        self.rules = rules.compactMap { rule in
            guard rule.isEnabled, !rule.actions.isEmpty, case .keyboard(let trigger) = rule.trigger,
                  let shortcut = KeyboardShortcut(keys: trigger.keys) else { return nil }
            return (rule, shortcut)
        }
        self.shouldHandleEvents = shouldHandleEvents
        self.logDebug = logDebug
        self.onRule = onRule
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        stop()
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
        pressedRules.removeAll()
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(myPID) {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
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

        if let pressed = pressedRules[keyCode] {
            if shouldHandleEvents(), isRepeat, pressed.shortcut.matches(keyCode: keyCode, flags: event.flags),
               pressed.rule.applicationScope.matches(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier),
               case .keyboard(let trigger) = pressed.rule.trigger, trigger.allowRepeat, trigger.phase == .keyDown {
                onRule(pressed.rule)
            }
            return nil
        }

        guard shouldHandleEvents(), !isRepeat,
              let match = matchingRule(keyCode: keyCode, flags: event.flags), case .keyboard(let trigger) = match.rule.trigger else {
            return Unmanaged.passUnretained(event)
        }
        let rule = match.rule
        DiagnosticLog.shared.write("[Keyboard] 匹配规则：\(rule.name)")
        pressedRules[keyCode] = match
        if trigger.phase == .keyDown {
            if !isRepeat || trigger.allowRepeat { onRule(rule) }
        }
        return nil
    }

    private func handleKeyUp(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard let pressed = pressedRules.removeValue(forKey: keyCode) else { return Unmanaged.passUnretained(event) }
        if shouldHandleEvents(), case .keyboard(let trigger) = pressed.rule.trigger, trigger.phase == .keyUp,
           pressed.rule.applicationScope.matches(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier) {
            onRule(pressed.rule)
        }
        return nil
    }

    private func matchingRule(keyCode: CGKeyCode, flags: CGEventFlags) -> (rule: AutomationRule, shortcut: KeyboardShortcut)? {
        let bundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return rules.first { match in
            match.rule.applicationScope.matches(bundleIdentifier: bundleIdentifier)
                && match.shortcut.matches(keyCode: keyCode, flags: flags)
        }
    }

    private func trace(_ message: String) {
        guard logDebug, diagnosticEventCount < 40 else { return }
        diagnosticEventCount += 1
        DiagnosticLog.shared.write("[KeyboardTrace] \(message)")
    }
}
