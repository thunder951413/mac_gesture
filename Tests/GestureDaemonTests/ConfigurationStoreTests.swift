import XCTest
@testable import GestureDaemon

final class ConfigurationStoreTests: XCTestCase {
    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("config.json")
    }

    func testAppearanceSavePreservesDraftRulesAndOtherSettings() async throws {
        try await MainActor.run {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let store = ConfigurationStore(url: url)
            try store.save()
            let savedName = store.configuration.rules[0].name
            store.configuration.rules[0].name = "未应用的规则"
            store.configuration.settings.launchAtLogin = true
            XCTAssertTrue(store.hasUnsavedChanges)
            try store.saveAppearance(\.hideDockIcon, value: true)
            let disk = try JSONDecoder().decode(AutomationConfiguration.self, from: Data(contentsOf: url))
            XCTAssertEqual(disk.rules[0].name, savedName)
            XCTAssertFalse(disk.settings.launchAtLogin)
            XCTAssertTrue(disk.settings.hideDockIcon)
            XCTAssertEqual(store.configuration.rules[0].name, "未应用的规则")
            XCTAssertTrue(store.hasUnsavedChanges)
            store.reload()
            XCTAssertEqual(store.configuration, disk)
            XCTAssertFalse(store.hasUnsavedChanges)
        }
    }

    func testCorruptOriginalIsPreservedUntilExplicitSave() async throws {
        try await MainActor.run {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("{invalid JSON".utf8)
            try original.write(to: url)
            let store = ConfigurationStore(url: url)
            XCTAssertNotNil(store.lastError)
            XCTAssertThrowsError(try store.saveAppearance(\.hideDockIcon, value: true))
            XCTAssertEqual(try Data(contentsOf: url), original)
            try store.save()
            XCTAssertNil(store.lastError)
            XCTAssertNoThrow(try JSONDecoder().decode(AutomationConfiguration.self, from: Data(contentsOf: url)))
        }
    }

    func testFutureSchemaAndDuplicateIDsDoNotOverwriteOriginal() async throws {
        try await MainActor.run {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let original = Data("{\"schemaVersion\":99,\"rules\":[],\"settings\":{}}".utf8)
            try original.write(to: url)
            let store = ConfigurationStore(url: url)
            XCTAssertTrue(store.lastError?.contains("99") == true)
            store.configuration.rules.append(store.configuration.rules[0])
            XCTAssertThrowsError(try store.save())
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }

    func testLegacyMigrationAndSettingsNormalization() async throws {
        try await MainActor.run {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("""
            {"schemaVersion":1,"gestures":[{"name":"旧规则","fingers":3,"direction":"left","minDistance":0.15,"keys":["cmd","["]}],
             "hotkeys":[{"name":"旧快捷键","when":["control","a"],"send":["down"]}],
             "settings":{"debounceMs":-10,"diagonalRejectRatio":5,"downBiasRatio":-1}}
            """.utf8).write(to: url)
            let store = ConfigurationStore(url: url)
            XCTAssertNil(store.lastError)
            XCTAssertEqual(store.configuration.rules.count, 2)
            XCTAssertEqual(store.configuration.settings.debounceMilliseconds, 0)
            XCTAssertEqual(store.configuration.settings.diagonalRejectRatio, 1)
            store.configuration.settings.diagonalRejectRatio = -3
            store.configuration.settings.liveTriggerDistance = .infinity
            try store.save()
            XCTAssertEqual(store.configuration.settings.diagonalRejectRatio, 0)
            XCTAssertEqual(store.configuration.settings.liveTriggerDistance, 0.06)
            XCTAssertEqual(ConfigurationStore(url: url).configuration, store.configuration)
        }
    }

    func testRestoreBeforeFirstSaveUsesBaseline() async {
        await MainActor.run {
            let store = ConfigurationStore(url: temporaryURL())
            let baseline = store.configuration
            store.configuration.rules.removeAll()
            store.reload()
            XCTAssertEqual(store.configuration, baseline)
            XCTAssertNil(store.lastError)
        }
    }

    func testLegacyWithoutVersionMigrates() async throws {
        try await MainActor.run {
            let url = temporaryURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(AppConfig.defaults).write(to: url)
            let store = ConfigurationStore(url: url)
            XCTAssertNil(store.lastError)
            XCTAssertEqual(store.configuration.schemaVersion, 2)
            XCTAssertEqual(store.configuration.rules.count, AppConfig.defaults.gestures.count + (AppConfig.defaults.hotkeys?.count ?? 0))
        }
    }
}
