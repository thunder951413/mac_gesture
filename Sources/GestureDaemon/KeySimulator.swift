import Foundation
import CoreGraphics
import ApplicationServices

final class KeySimulator {
    private var lastTriggerTime: [String: TimeInterval] = [:]
    private let debounceSeconds: TimeInterval
    private let lock = NSLock()
    private let myPID: pid_t

    init(debounceMs: Int) {
        self.debounceSeconds = TimeInterval(debounceMs) / 1000.0
        self.myPID = getpid()
    }

    func trigger(keys: [String], gestureName: String) -> Bool {
        trigger(keys: keys, gestureName: gestureName, useDebounce: true)
    }

    func triggerImmediate(keys: [String]) -> Bool {
        trigger(keys: keys, gestureName: nil, useDebounce: false)
    }

    private func trigger(keys: [String], gestureName: String?, useDebounce: Bool) -> Bool {
        let (modifiers, regularKeys) = Self.classifyKeys(keys)
        guard !regularKeys.isEmpty else { return false }

        if !AXIsProcessTrusted() {
            fputs("[KeySimulator] ❌ 无辅助功能权限\n", stderr)
            return false
        }

        if useDebounce, let gestureName {
            lock.lock()
            let now = ProcessInfo.processInfo.systemUptime
            if let last = lastTriggerTime[gestureName], now - last < debounceSeconds {
                lock.unlock()
                return false
            }
            lock.unlock()
        }

        let source = CGEventSource(stateID: .hidSystemState)
        var allOk = true
        var modifierKeyCodes: [CGKeyCode] = []

        for mod in modifiers {
            guard let keyCode = Self.modKeyCode(name: mod) else {
                fputs("[KeySimulator] 未知修饰键: \(mod)\n", stderr)
                allOk = false
                continue
            }
            modifierKeyCodes.append(keyCode)
        }

        guard allOk else { return false }

        for keyCode in modifierKeyCodes {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
                fputs("[KeySimulator] 创建修饰键按下事件失败: \(keyCode)\n", stderr)
                allOk = false
                continue
            }
            down.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(myPID))
            down.post(tap: .cghidEventTap)
            usleep(6000)
        }

        for key in regularKeys {
            guard let keyCode = Self.keyCodeFor(name: key) else {
                fputs("[KeySimulator] 未知按键: \(key)\n", stderr)
                allOk = false
                continue
            }

            guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                fputs("[KeySimulator] 创建 CGEvent 失败: \(key)\n", stderr)
                allOk = false
                continue
            }

            down.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(myPID))
            up.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(myPID))
            down.post(tap: .cghidEventTap)
            usleep(10000)
            up.post(tap: .cghidEventTap)
            usleep(6000)
        }

        for keyCode in modifierKeyCodes.reversed() {
            guard let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
                fputs("[KeySimulator] 创建修饰键抬起事件失败: \(keyCode)\n", stderr)
                allOk = false
                continue
            }
            up.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(myPID))
            up.post(tap: .cghidEventTap)
            usleep(6000)
        }

        guard allOk else { return false }

        if useDebounce, let gestureName {
            lock.lock()
            lastTriggerTime[gestureName] = ProcessInfo.processInfo.systemUptime
            lock.unlock()
        }

        fputs("[KeySimulator] \(keys.joined(separator: "+"))\n", stderr)
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

    static func modKeyCode(name: String) -> CGKeyCode? {
        switch name.lowercased() {
        case "cmd", "command": return 55
        case "shift": return 56
        case "option", "opt", "alt": return 58
        case "ctrl", "control": return 59
        case "fn", "function": return 63
        default: return nil
        }
    }

    static func keyCodeFor(name: String) -> CGKeyCode? {
        let lower = name.lowercased()
        let charCodes: [Character: CGKeyCode] = [
            "a": 0,   "s": 1,   "d": 2,   "f": 3,   "h": 4,   "g": 5,
            "z": 6,   "x": 7,   "c": 8,   "v": 9,   "b": 11,  "q": 12,
            "w": 13,  "e": 14,  "r": 15,  "y": 16,  "t": 17,
            "1": 18,  "2": 19,  "3": 20,  "4": 21,  "6": 22,  "5": 23,
            "=": 24,  "9": 25,  "7": 26,  "-": 27,  "8": 28,  "0": 29,
            "]": 30,  "o": 31,  "u": 32,  "[": 33,  "i": 34,  "p": 35,
            "l": 37,  "j": 38,  "'": 39,  "k": 40,  ";": 41,  "\\": 42,
            ",": 43,  "/": 44,  "n": 45,  "m": 46,  ".": 47,  " ": 49,
            "`": 50
        ]
        if lower.count == 1, let code = charCodes[lower.first!] {
            return code
        }
        let specialKeys: [String: CGKeyCode] = [
            "return": 36, "enter": 36, "tab": 48, "space": 49,
            "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118,
            "f5": 96, "f6": 97, "f7": 98, "f8": 100,
            "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "left": 123, "right": 124, "down": 125, "up": 126,
            "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        ]
        return specialKeys[lower]
    }
}
