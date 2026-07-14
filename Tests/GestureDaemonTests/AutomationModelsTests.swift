import XCTest
import GestureTouchCore
@testable import GestureDaemon

final class AutomationModelsTests: XCTestCase {
    func testConfigurationRoundTripPreservesRulesAndActions() throws {
        let original = AutomationConfiguration.defaults
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AutomationConfiguration.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testApplicationScopeModes() {
        let bundleID = "com.example.Editor"
        XCTAssertTrue(ApplicationScope().matches(bundleIdentifier: bundleID))
        XCTAssertTrue(ApplicationScope(mode: .include, bundleIdentifiers: [bundleID]).matches(bundleIdentifier: bundleID))
        XCTAssertFalse(ApplicationScope(mode: .include, bundleIdentifiers: [bundleID]).matches(bundleIdentifier: "com.example.Other"))
        XCTAssertFalse(ApplicationScope(mode: .exclude, bundleIdentifiers: [bundleID]).matches(bundleIdentifier: bundleID))
        XCTAssertTrue(ApplicationScope(mode: .exclude, bundleIdentifiers: [bundleID]).matches(bundleIdentifier: "com.example.Other"))
    }

    func testEveryDefaultRuleHasAnAction() {
        XCTAssertTrue(AutomationConfiguration.defaults.rules.allSatisfy { !$0.actions.isEmpty })
    }

    func testTriggerCategoryMatchesPayload() {
        XCTAssertEqual(AutomationTrigger.trackpad(TrackpadTrigger()).category, .trackpad)
        XCTAssertEqual(AutomationTrigger.keyboard(KeyboardTrigger()).category, .keyboard)
    }

    func testSettingsDecodeMissingNewFieldsUsesSafeDefaults() throws {
        let settings = try JSONDecoder().decode(EngineSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.hideDockIcon)
        XCTAssertFalse(settings.hideMenuBarIcon)
        XCTAssertFalse(settings.useCompatibilityTrackpadMode)
        XCTAssertEqual(settings.debounceMilliseconds, 150)
        XCTAssertEqual(settings.liveTriggerDistance, 0.06, accuracy: 0.0001)
    }

    func testAppearanceSettingsRoundTrip() throws {
        let settings = EngineSettings(hideDockIcon: true, hideMenuBarIcon: true)
        let decoded = try JSONDecoder().decode(EngineSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.hideDockIcon)
        XCTAssertTrue(decoded.hideMenuBarIcon)
    }

    func testTouchServiceMessageRoundTrip() throws {
        let touch = ActiveTouch(identifier: 7, state: 4, normalizedX: 0.25, normalizedY: 0.75)
        let message = TouchServiceMessage(kind: .frame, timestamp: 42, touches: [touch])
        let decoded = try JSONDecoder().decode(TouchServiceMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.kind, .frame)
        XCTAssertEqual(decoded.timestamp, 42)
        XCTAssertEqual(decoded.touches?.first?.identifier, 7)
        XCTAssertEqual(decoded.touches?.first?.normalizedX, 0.25)
    }

    func testValidatorWarnsAboutDuplicateAndEmptyActions() {
        var configuration = AutomationConfiguration.defaults
        configuration.rules[0].actions = []
        var duplicate = configuration.rules[0]
        duplicate.id = UUID()
        duplicate.name = "重复规则"
        duplicate.actions = [.keyboard(["space"])]
        configuration.rules.append(duplicate)
        let warnings = ConfigurationValidator.warnings(for: configuration)
        XCTAssertTrue(warnings.contains { $0.contains("没有执行动作") })
        XCTAssertTrue(warnings.contains { $0.contains("相同触发器") })
    }

    func testValidatorWarnsWhenAdvancedRuleIsUsedInCompatibilityMode() {
        var configuration = AutomationConfiguration.defaults
        configuration.settings.useCompatibilityTrackpadMode = true
        XCTAssertTrue(ConfigurationValidator.warnings(for: configuration).contains { $0.contains("需要高级触控板模式") })
    }
}
