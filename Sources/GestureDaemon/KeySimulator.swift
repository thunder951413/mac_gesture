import Foundation
import CoreGraphics
import ApplicationServices

final class KeySimulator {
    private var lastTriggerTime: [String: TimeInterval] = [:]
    private let debounceSeconds: TimeInterval
    private let lock = NSLock()

    init(debounceMs: Int) {
        self.debounceSeconds = TimeInterval(debounceMs) / 1000.0
    }

    func trigger(keys: [String], gestureName: String) -> Bool {
        lock.lock()
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastTriggerTime[gestureName], now - last < debounceSeconds {
            lock.unlock()
            return false
        }
        lastTriggerTime[gestureName] = now
        lock.unlock()

        let (modifiers, regularKeys) = Self.classifyKeys(keys)
        guard !regularKeys.isEmpty else { return false }

        if !AXIsProcessTrusted() {
            fputs("[KeySimulator] ❌ 无辅助功能权限\n", stderr)
            return false
        }

        let modFlag = Self.applescriptModifier(for: modifiers)
        var allOk = true
        for key in regularKeys {
            guard let scriptCmd = Self.appleScriptForKey(key, modFlag: modFlag) else {
                fputs("[KeySimulator] 无法生成 AppleScript for key: \(key)\n", stderr)
                allOk = false
                continue
            }
            if !Self.runAppleScript(scriptCmd) {
                allOk = false
            }
        }

        fputs("[KeySimulator] \(keys.joined(separator: "+"))\n", stderr)
        return allOk
    }

    private static var appleScriptCache = [String: NSAppleScript]()

    private static func runAppleScript(_ source: String) -> Bool {
        let script: NSAppleScript
        if let cached = appleScriptCache[source] {
            script = cached
        } else {
            guard let s = NSAppleScript(source: source) else {
                // NSAppleScript 不可用，回退到 osascript 子进程
                return runAppleScriptViaProcess(source)
            }
            appleScriptCache[source] = s
            script = s
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            fputs("[KeySimulator] AppleScript error: \(msg)\n", stderr)
            return false
        }
        return true
    }

    private static func runAppleScriptViaProcess(_ source: String) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", source]
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.launch()
        task.waitUntilExit()
        return task.terminationStatus == 0
    }

    private static func applescriptModifier(for mods: [String]) -> String {
        var parts: [String] = []
        for m in mods {
            switch m.lowercased() {
            case "cmd", "command": parts.append("command down")
            case "shift": parts.append("shift down")
            case "option", "opt", "alt": parts.append("option down")
            case "ctrl", "control": parts.append("control down")
            default: break
            }
        }
        return parts.joined(separator: ", ")
    }

    private static func appleScriptForKey(_ key: String, modFlag: String) -> String? {
        let lower = key.lowercased()
        let isChar = lower.count == 1 && lower.first!.isASCII
            && (lower.first!.isLetter || lower.first!.isNumber
                || " -=[\\];',./`".contains(lower.first!))

        if isChar {
            let cmd = modFlag.isEmpty
                ? "keystroke \"\(key)\""
                : "keystroke \"\(key)\" using \(modFlag)"
            return "tell application \"System Events\" to \(cmd)"
        }

        guard let keyCode = keyCodeFor(name: key) else { return nil }
        let cmd = modFlag.isEmpty
            ? "key code \(keyCode)"
            : "key code \(keyCode) using \(modFlag)"
        return "tell application \"System Events\" to \(cmd)"
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
        // 字符键的 macOS 虚拟键码（QWERTY 硬件布局）
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
