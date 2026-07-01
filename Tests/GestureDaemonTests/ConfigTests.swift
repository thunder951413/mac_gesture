import XCTest
@testable import GestureDaemon

final class ConfigTests: XCTestCase {

    // MARK: - 默认配置一致性（单一数据源）

    func testDefaultConfig_matchesAppConfigDefaults() {
        // 内存兜底配置应与 AppConfig.defaults 完全一致
        let cfg = Config(defaultConfig: true)
        XCTAssertEqual(cfg.gestures.count, AppConfig.defaults.gestures.count)
        XCTAssertEqual(cfg.hotkeys.count, AppConfig.defaults.hotkeys?.count ?? 0)
        XCTAssertEqual(cfg.settings.debounceMs, AppConfig.defaults.settings.debounceMs)
    }

    func testDefaultJSON_decodesBackToSameConfig() throws {
        // defaultJSON 序列化后能完整解码回来
        let json = Config.defaultJSON
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded.gestures.count, AppConfig.defaults.gestures.count)
        XCTAssertEqual(decoded.hotkeys?.count, AppConfig.defaults.hotkeys?.count)
        XCTAssertEqual(decoded.settings.debounceMs, AppConfig.defaults.settings.debounceMs)
        XCTAssertEqual(decoded.settings.spreadThreshold, AppConfig.defaults.settings.spreadThreshold, accuracy: 1e-9)
    }

    // MARK: - 默认值回退

    func testPartialSettings_usesDefaults() throws {
        // 仅提供 debounceMs，其余字段应回退到默认值
        let json = """
        {
          "gestures": [],
          "settings": { "debounceMs": 300 }
        }
        """
        let tmp = NSTemporaryDirectory() + "test_\(UUID().uuidString).json"
        try json.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let cfg = try Config(path: tmp)
        XCTAssertEqual(cfg.settings.debounceMs, 300)
        XCTAssertEqual(cfg.settings.logLevel, "info")
        XCTAssertEqual(cfg.settings.diagonalRejectRatio, 0.95, accuracy: 1e-9)
        XCTAssertEqual(cfg.settings.downBiasRatio, 0.35, accuracy: 1e-9)
        XCTAssertEqual(cfg.settings.spreadThreshold, 0.03, accuracy: 1e-9)
        XCTAssertEqual(cfg.settings.minSwipeDistance, 0.01, accuracy: 1e-9)
        XCTAssertEqual(cfg.settings.liveTriggerDistance, 0.06, accuracy: 1e-9)
    }

    // MARK: - 范围 clamp

    func testNegativeDebounce_isClampedToZero() throws {
        let json = """
        {
          "gestures": [],
          "settings": { "debounceMs": -50 }
        }
        """
        let tmp = NSTemporaryDirectory() + "test_\(UUID().uuidString).json"
        try json.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let cfg = try Config(path: tmp)
        XCTAssertEqual(cfg.settings.debounceMs, 0)
    }

    func testOutOfRangeRatios_areClamped() throws {
        let json = """
        {
          "gestures": [],
          "settings": { "diagonalRejectRatio": 1.5, "downBiasRatio": -0.3 }
        }
        """
        let tmp = NSTemporaryDirectory() + "test_\(UUID().uuidString).json"
        try json.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let cfg = try Config(path: tmp)
        XCTAssertEqual(cfg.settings.diagonalRejectRatio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(cfg.settings.downBiasRatio, 0.0, accuracy: 1e-9)
    }

    // MARK: - hotkeys 可选

    func testMissingHotkeys_defaultsToEmpty() throws {
        let json = """
        {
          "gestures": [],
          "settings": {}
        }
        """
        let tmp = NSTemporaryDirectory() + "test_\(UUID().uuidString).json"
        try json.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let cfg = try Config(path: tmp)
        XCTAssertTrue(cfg.hotkeys.isEmpty)
    }
}
