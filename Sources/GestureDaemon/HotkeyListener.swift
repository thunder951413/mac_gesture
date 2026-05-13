import Foundation
import CoreGraphics
import ApplicationServices

final class HotkeyListener {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let keySimulator: KeySimulator
    private let mappings: [HotkeyMapping]
    private var activeFlags: CGEventFlags = []
    private let myPID: pid_t
    private var keyDownCount = 0

    /// Only these modifier flags are considered when matching hotkeys.
    private static let relevantMods: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn
    ]

    init(mappings: [HotkeyMapping], keySimulator: KeySimulator) {
        self.mappings = mappings
        self.keySimulator = keySimulator
        self.myPID = getpid()
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard !mappings.isEmpty else { return true }

        if !AXIsProcessTrusted() {
            print("[HotkeyListener] ⚠️ 需要辅助功能权限")
            print("[HotkeyListener] 请运行: sudo tccutil reset Accessibility")
            print("[HotkeyListener] 然后前往: 系统设置 → 隐私与安全性 → 辅助功能")
            print("[HotkeyListener] 将 Terminal 或 \(CommandLine.arguments[0]) 添加到列表中")
            print("[HotkeyListener] 添加后重新启动本程序")
        }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
                      | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>
                    .fromOpaque(refcon)
                    .takeUnretainedValue()
                return listener.handleEvent(proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyListener] ❌ EventTap 创建失败，热键功能不可用")
            return false
        }

        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        print("[HotkeyListener] ✅ 已启动 (\(mappings.count) 个映射)")

        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            var enabled = false
            if let tap = self.eventTap {
                enabled = CGEvent.tapIsEnabled(tap: tap)
                if !enabled {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            guard !enabled else { return }
            fputs("[HotkeyListener] ⚠️ tap 已恢复 enabled:\(enabled) keyDowns:\(self.keyDownCount)\n", stderr)
        }
        return true
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        print("[HotkeyListener] 已停止")
    }

    // MARK: - Event handling

    @inline(__always)
    private func handleEvent(_ proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(myPID) {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            activeFlags = event.flags
            return Unmanaged.passUnretained(event)

        case .keyDown:
            keyDownCount += 1
            return evaluateMapping(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Send replacement keys via CGEvent with explicit flags,
    /// avoiding physical modifier leakage from the original hotkey.
    private func postReplacement(keys: [String]) {
        let (mods, regularKeys) = KeySimulator.classifyKeys(keys)
        let flags = KeySimulator.modifierFlags(for: mods)
        let src = CGEventSource(stateID: .privateState)

        for key in regularKeys {
            guard let keyCode = KeySimulator.keyCodeFor(name: key) else { continue }

            let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
            down?.flags = flags
            down?.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(myPID))
            down?.setIntegerValueField(.keyboardEventKeyboardType, value: 58)
            down?.post(tap: .cgSessionEventTap)
            usleep(30000)

            let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
            up?.flags = flags
            up?.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(myPID))
            up?.setIntegerValueField(.keyboardEventKeyboardType, value: 58)
            up?.post(tap: .cgSessionEventTap)
        }

        fputs("[HotkeyListener] 替换发送: \(keys.joined(separator: "+")) flags:\(flags.rawValue)\n", stderr)
    }

    private func evaluateMapping(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        for m in mappings {
            let (mods, regular) = KeySimulator.classifyKeys(m.when)
            guard regular.count == 1 else { continue }
            guard let targetCode = KeySimulator.keyCodeFor(name: regular[0]) else { continue }
            guard CGKeyCode(keyCode) == targetCode else { continue }

            let requiredFlags = KeySimulator.modifierFlags(for: mods)
            let currentRelevant = activeFlags.intersection(Self.relevantMods)
            guard currentRelevant == requiredFlags else { continue }

            // Match! Suppress and replace.
            print("[HotkeyListener] 触发热键: \(m.name)  →  \(m.send.joined(separator: "+"))")
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.postReplacement(keys: m.send)
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
