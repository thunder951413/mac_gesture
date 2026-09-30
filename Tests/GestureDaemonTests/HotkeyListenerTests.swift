import XCTest
import CoreGraphics
@testable import GestureDaemon

final class HotkeyListenerTests: XCTestCase {
    private func event(_ code: CGKeyCode = 38, flags: CGEventFlags = [], repeatKey: Bool = false) -> CGEvent {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .privateState), virtualKey: code, keyDown: true)!
        event.flags = flags
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return event
    }

    private func rule(keys: [String] = ["cmd", "j"], phase: TriggerPhase = .keyDown, repeatKey: Bool = false) -> AutomationRule {
        AutomationRule(name: "测试", trigger: .keyboard(KeyboardTrigger(keys: keys, phase: phase, allowRepeat: repeatKey)), actions: [.keyboard(["down"])])
    }

    func testRecordingPassesShortcutThroughWithoutExecuting() {
        var recording = true
        var count = 0
        let listener = HotkeyListener(rules: [rule()], shouldHandleEvents: { !recording }) { _ in count += 1 }
        XCTAssertTrue(listener.handle(type: .keyDown, event: event(flags: .maskCommand)) != nil)
        XCTAssertEqual(count, 0)
        recording = false
        XCTAssertTrue(listener.handle(type: .keyDown, event: event(flags: .maskCommand)) == nil)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(listener.handle(type: .keyUp, event: event()) == nil)
    }

    func testKeyUpRemembersShortcutAfterModifierReleased() {
        var count = 0
        let listener = HotkeyListener(rules: [rule(phase: .keyUp)]) { _ in count += 1 }
        XCTAssertTrue(listener.handle(type: .keyDown, event: event(flags: .maskCommand)) == nil)
        XCTAssertEqual(count, 0)
        XCTAssertTrue(listener.handle(type: .flagsChanged, event: event()) != nil)
        XCTAssertTrue(listener.handle(type: .keyUp, event: event()) == nil)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(listener.handle(type: .keyUp, event: event()) != nil)
        XCTAssertEqual(count, 1)
    }

    func testRepeatKeepsOriginalRuleAndRequiresOriginalModifiers() {
        var triggered: [UUID] = []
        let commandRule = rule(repeatKey: true)
        let plainRule = rule(keys: ["j"], repeatKey: true)
        let listener = HotkeyListener(rules: [commandRule, plainRule]) { triggered.append($0.id) }
        XCTAssertTrue(listener.handle(type: .keyDown, event: event(flags: .maskCommand)) == nil)
        XCTAssertTrue(listener.handle(type: .keyDown, event: event(flags: .maskCommand, repeatKey: true)) == nil)
        XCTAssertTrue(listener.handle(type: .keyDown, event: event(repeatKey: true)) == nil)
        XCTAssertEqual(triggered, [commandRule.id, commandRule.id])
    }

    func testUnownedRepeatAndStaleFlagsDoNotTrigger() {
        var count = 0
        let listener = HotkeyListener(rules: [rule()]) { _ in count += 1 }
        XCTAssertTrue(listener.handle(type: .flagsChanged, event: event(flags: .maskCommand)) != nil)
        XCTAssertTrue(listener.handle(type: .keyDown, event: event()) != nil)
        XCTAssertTrue(listener.handle(type: .keyDown, event: event(flags: .maskCommand, repeatKey: true)) != nil)
        XCTAssertEqual(count, 0)
    }

    func testOwnSyntheticEventsAreIgnored() {
        var count = 0
        let listener = HotkeyListener(rules: [rule()]) { _ in count += 1 }
        let synthetic = event(flags: .maskCommand)
        synthetic.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
        XCTAssertTrue(listener.handle(type: .keyDown, event: synthetic) != nil)
        XCTAssertEqual(count, 0)
    }

    func testAliasesAndIntrinsicFunctionFlagsMatch() {
        XCTAssertEqual(KeyboardShortcut(keys: ["command", "enter"]), KeyboardShortcut(keys: ["cmd", "return"]))
        XCTAssertTrue(KeyboardShortcut(keys: ["cmd", "up"])!.matches(keyCode: 126, flags: [.maskCommand, .maskSecondaryFn, .maskNumericPad]))
        XCTAssertFalse(KeyboardShortcut(keys: ["j"])!.matches(keyCode: 38, flags: .maskSecondaryFn))
        XCTAssertTrue(KeyboardShortcut(keys: ["fn", "j"])!.matches(keyCode: 38, flags: .maskSecondaryFn))
        XCTAssertNil(KeyboardShortcut(keys: ["cmd"]))
        XCTAssertNil(KeyboardShortcut(keys: ["cmd", "unknown"]))
    }
}
