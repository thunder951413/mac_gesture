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

    /// Only these modifier flags are considered when matching hotkeys.
    private static let relevantMods: CGEventFlags = [
        .maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn
    ]

    init(mappings: [HotkeyMapping], keySimulator: KeySimulator) {
        self.mappings = mappings
        self.keySimulator = keySimulator
        self.myPID = getpid()
    }

    func start() {
        guard !mappings.isEmpty else { return }

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
                let listener = Unmanaged<HotkeyListener>
                    .fromOpaque(refcon!)
                    .takeUnretainedValue()
                return listener.handleEvent(proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[HotkeyListener] ❌ EventTap 创建失败，热键功能不可用")
            return
        }

        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        print("[HotkeyListener] ✅ 已启动 (\(mappings.count) 个映射)")
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
        // Ignore invalid/abnormal events
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        // Loop prevention: events we posted carry our PID
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(myPID) {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged:
            activeFlags = event.flags
            return Unmanaged.passUnretained(event)

        case .keyDown:
            return evaluateMapping(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Check if this keyDown matches any configured hotkey mapping.
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
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                _ = keySimulator.trigger(keys: m.send, gestureName: "hotkey:\(m.name)")
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
