import XCTest
import CoreGraphics
@testable import GestureDaemon

final class KeySimulatorTests: XCTestCase {

    func testClassifyKeys_separatesModifiersAndRegular() {
        let (mods, regular) = KeySimulator.classifyKeys(["cmd", "w"])
        XCTAssertEqual(mods, ["cmd"])
        XCTAssertEqual(regular, ["w"])
    }

    func testClassifyKeys_multipleModifiers() {
        let (mods, regular) = KeySimulator.classifyKeys(["ctrl", "shift", "a"])
        XCTAssertEqual(mods, ["ctrl", "shift"])
        XCTAssertEqual(regular, ["a"])
    }

    func testClassifyKeys_modifierAliases() {
        // 所有修饰键别名都应被识别
        let aliases = ["cmd", "command", "shift", "option", "opt", "alt",
                       "ctrl", "control", "fn", "function"]
        for a in aliases {
            let (mods, regular) = KeySimulator.classifyKeys([a])
            XCTAssertEqual(mods, [a], "别名 \(a) 未被识别为修饰键")
            XCTAssertTrue(regular.isEmpty, "别名 \(a) 不应进入普通键列表")
        }
    }

    func testClassifyKeys_caseInsensitive() {
        let (mods, regular) = KeySimulator.classifyKeys(["Cmd", "W"])
        XCTAssertEqual(mods, ["cmd"])
        XCTAssertEqual(regular, ["W"])  // 普通键保留原样
    }

    func testClassifyKeys_noModifiers() {
        let (mods, regular) = KeySimulator.classifyKeys(["space"])
        XCTAssertTrue(mods.isEmpty)
        XCTAssertEqual(regular, ["space"])
    }

    // MARK: - keyCodeFor

    func testKeyCodeFor_letters() {
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "a"), 0)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "s"), 1)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "w"), 13)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "z"), 6)
    }

    func testKeyCodeFor_caseInsensitive() {
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "A"), 0)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "W"), 13)
    }

    func testKeyCodeFor_specialKeys() {
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "return"), 36)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "enter"), 36)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "space"), 49)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "escape"), 53)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "esc"), 53)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "tab"), 48)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "delete"), 51)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "backspace"), 51)
    }

    func testKeyCodeFor_arrows() {
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "left"), 123)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "right"), 124)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "down"), 125)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "up"), 126)
    }

    func testKeyCodeFor_functionKeys() {
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "f1"), 122)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "f12"), 111)
    }

    func testKeyCodeFor_numbers() {
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "1"), 18)
        XCTAssertEqual(KeySimulator.keyCodeFor(name: "0"), 29)
    }

    func testKeyCodeFor_unknownReturnsNil() {
        XCTAssertNil(KeySimulator.keyCodeFor(name: "nonexistent"))
        XCTAssertNil(KeySimulator.keyCodeFor(name: ""))
    }

    // MARK: - modifierFlags

    func testModifierFlags_single() {
        let flags = KeySimulator.modifierFlags(for: ["cmd"])
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertFalse(flags.contains(.maskShift))
    }

    func testModifierFlags_aliases() {
        XCTAssertEqual(KeySimulator.modifierFlags(for: ["cmd"]),
                       KeySimulator.modifierFlags(for: ["command"]))
        XCTAssertEqual(KeySimulator.modifierFlags(for: ["option"]),
                       KeySimulator.modifierFlags(for: ["opt"]))
        XCTAssertEqual(KeySimulator.modifierFlags(for: ["opt"]),
                       KeySimulator.modifierFlags(for: ["alt"]))
        XCTAssertEqual(KeySimulator.modifierFlags(for: ["ctrl"]),
                       KeySimulator.modifierFlags(for: ["control"]))
        XCTAssertEqual(KeySimulator.modifierFlags(for: ["fn"]),
                       KeySimulator.modifierFlags(for: ["function"]))
    }

    func testModifierFlags_combined() {
        let flags = KeySimulator.modifierFlags(for: ["cmd", "shift", "ctrl"])
        XCTAssertTrue(flags.contains(.maskCommand))
        XCTAssertTrue(flags.contains(.maskShift))
        XCTAssertTrue(flags.contains(.maskControl))
        XCTAssertFalse(flags.contains(.maskAlternate))
    }

    func testModifierFlags_empty() {
        let flags = KeySimulator.modifierFlags(for: [])
        XCTAssertTrue(flags.isEmpty)
    }

    // MARK: - modKeyCode

    func testModKeyCode_values() {
        XCTAssertEqual(KeySimulator.modKeyCode(name: "cmd"), 55)
        XCTAssertEqual(KeySimulator.modKeyCode(name: "shift"), 56)
        XCTAssertEqual(KeySimulator.modKeyCode(name: "option"), 58)
        XCTAssertEqual(KeySimulator.modKeyCode(name: "ctrl"), 59)
        XCTAssertEqual(KeySimulator.modKeyCode(name: "fn"), 63)
    }

    func testModKeyCode_unknownReturnsNil() {
        XCTAssertNil(KeySimulator.modKeyCode(name: "x"))
        XCTAssertNil(KeySimulator.modKeyCode(name: "space"))
    }
}
