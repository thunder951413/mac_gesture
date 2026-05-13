import Foundation
import CoreGraphics

final class KeySimulator {
    private var lastTriggerTime: [String: TimeInterval] = [:]
    private let debounceSeconds: TimeInterval
    private static let eventSource = CGEventSource(stateID: .hidSystemState)

    init(debounceMs: Int) {
        self.debounceSeconds = TimeInterval(debounceMs) / 1000.0
    }

    func trigger(keys: [String], gestureName: String) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTriggerTime[gestureName], now - last < debounceSeconds {
            return false
        }
        lastTriggerTime[gestureName] = now

        let (modifiers, regularKeys) = Self.classifyKeys(keys)
        guard !regularKeys.isEmpty else { return false }

        for (i, key) in regularKeys.enumerated() {
            guard let keyCode = Self.keyCodeFor(name: key) else {
                fputs("[KeySimulator] 未知按键: \(key)\n", stderr)
                continue
            }
            let flags = Self.modifierFlags(for: modifiers)
            let isLast = (i == regularKeys.count - 1)

            postKey(code: keyCode, flags: flags, keyDown: true)
            if isLast {
                usleep(30000)
            }
            postKey(code: keyCode, flags: flags, keyDown: false)
        }
        return true
    }

    static func classifyKeys(_ keys: [String]) -> ([String], [String]) {
        let modifierSet: Set<String> = ["cmd", "command", "shift", "option", "opt", "alt",
                                         "ctrl", "control", "fn", "function"]
        var modifiers: [String] = []
        var regular: [String] = []
        for key in keys {
            if modifierSet.contains(key.lowercased()) {
                modifiers.append(key.lowercased())
            } else {
                regular.append(key)
            }
        }
        return (modifiers, regular)
    }

    static func modifierFlags(for mods: [String]) -> CGEventFlags {
        var flags: CGEventFlags = []
        for m in mods {
            switch m {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "option", "opt", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn", "function": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    static func keyCodeFor(name: String) -> CGKeyCode? {
        let lower = name.lowercased()
        // Character keys
        if lower.count == 1, let ascii = lower.first?.asciiValue {
            switch ascii {
            case 97...122:  // a-z
                return CGKeyCode(ascii - 97)
            case 48...57:   // 0-9
                return CGKeyCode(ascii - 48 + 29)
            case 32: return 49  // space
            case 45: return 27  // -
            case 61: return 24  // =
            case 91: return 33  // [
            case 93: return 30  // ]
            case 92: return 42  // \
            case 59: return 41  // ;
            case 39: return 39  // '
            case 44: return 43  // ,
            case 46: return 47  // .
            case 47: return 44  // /
            case 96: return 50  // `
            default: break
            }
        }
        // Special key names
        let specialKeys: [String: CGKeyCode] = [
            "return": 36, "enter": 36,
            "tab": 48,
            "space": 49,
            "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118,
            "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "volume_up": 0x48, "volume_down": 0x49, "mute": 0x4A
        ]
        return specialKeys[lower]
    }

    private func postKey(code: CGKeyCode, flags: CGEventFlags, keyDown: Bool) {
        let event = CGEvent(keyboardEventSource: Self.eventSource, virtualKey: code, keyDown: keyDown)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }
}
