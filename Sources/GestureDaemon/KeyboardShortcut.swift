import CoreGraphics

struct KeyboardShortcut: Equatable {
    let keyCode: CGKeyCode
    let modifiers: CGEventFlags

    static let relevantModifiers: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn]
    private static let functionCodes: Set<CGKeyCode> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
                                                       123, 124, 125, 126, 115, 119, 116, 121]

    init?(keys: [String]) {
        let (modifiers, regular) = KeySimulator.classifyKeys(keys)
        guard regular.count == 1, let code = KeySimulator.keyCodeFor(name: regular[0]) else { return nil }
        keyCode = code
        self.modifiers = Self.eventModifiers(KeySimulator.modifierFlags(for: modifiers), keyCode: code)
    }

    func matches(keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        self.keyCode == keyCode && modifiers == Self.eventModifiers(flags, keyCode: keyCode)
    }

    static func eventModifiers(_ flags: CGEventFlags, keyCode: CGKeyCode) -> CGEventFlags {
        var modifiers = flags.intersection(relevantModifiers)
        // macOS 对方向、导航和 F 键附加 function 标记，它们的物理键码已经区分了键位。
        if functionCodes.contains(keyCode) { modifiers.remove(.maskSecondaryFn) }
        return modifiers
    }
}
