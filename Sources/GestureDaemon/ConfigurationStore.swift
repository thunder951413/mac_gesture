import Foundation
import Combine

@MainActor
final class ConfigurationStore: ObservableObject {
    @Published var configuration: AutomationConfiguration
    @Published private(set) var lastError: String?
    @Published private(set) var hasUnsavedChanges = false

    let url: URL
    private var baseline: AutomationConfiguration
    private var observer: AnyCancellable?
    private var loadFailed = false

    init(url: URL = ConfigurationStore.defaultURL) {
        self.url = url
        let loaded: AutomationConfiguration
        if FileManager.default.fileExists(atPath: url.path) {
            do { loaded = try Self.load(from: url) }
            catch {
                loaded = .defaults
                lastError = "配置文件无法读取，当前使用内置默认值：\(error.localizedDescription)"
                loadFailed = true
            }
        } else {
            loaded = .defaults
        }
        configuration = loaded
        baseline = loaded
        observer = $configuration.dropFirst().sink { [weak self] value in
            self?.hasUnsavedChanges = value != self?.baseline
        }
    }

    nonisolated static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["GESTURE_CONFIG_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gesture", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    func save() throws {
        var saved = configuration
        saved.settings = saved.settings.normalized
        try persist(saved)
        baseline = saved
        configuration = saved
        hasUnsavedChanges = false
        loadFailed = false
        lastError = nil
    }

    /// 外观自动保存只写入已保存配置中的对应字段，保留其他未应用的编辑。
    func saveAppearance(_ keyPath: WritableKeyPath<EngineSettings, Bool>, value: Bool) throws {
        guard !loadFailed else { throw ConfigurationError.unreadableOriginal }
        var saved = baseline
        saved.settings[keyPath: keyPath] = value
        try persist(saved)
        baseline = saved
        configuration.settings[keyPath: keyPath] = value
        hasUnsavedChanges = configuration != baseline
        lastError = nil
    }

    func reportError(_ error: Error) { lastError = error.localizedDescription }

    private func persist(_ saved: AutomationConfiguration) throws {
        try saved.validateIdentity()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(saved)
        try data.write(to: url, options: .atomic)
    }

    func saveReportingError() {
        do { try save() } catch { lastError = error.localizedDescription }
    }

    func clearError() { lastError = nil }

    func reload() {
        do {
            let loaded = FileManager.default.fileExists(atPath: url.path) ? try Self.load(from: url) : baseline
            baseline = loaded
            configuration = loaded
            hasUnsavedChanges = false
            lastError = nil
            loadFailed = false
        } catch { lastError = error.localizedDescription }
    }

    private static func load(from url: URL) throws -> AutomationConfiguration {
        let data = try Data(contentsOf: url)
        let header = try JSONDecoder().decode(ConfigurationHeader.self, from: data)
        if !header.isLegacy || (header.schemaVersion != nil && header.schemaVersion != 1) {
            let current = try JSONDecoder().decode(AutomationConfiguration.self, from: data)
            try current.validateIdentity()
            return current
        }
        let legacy = try JSONDecoder().decode(AppConfig.self, from: data)
        return migrate(legacy)
    }

    private static func migrate(_ legacy: AppConfig) -> AutomationConfiguration {
        var rules = legacy.gestures.map { mapping in
            AutomationRule(
                name: mapping.name,
                trigger: .trackpad(TrackpadTrigger(fingers: mapping.fingers, direction: mapping.direction, minimumDistance: mapping.minDistance)),
                actions: [.keyboard(mapping.keys)]
            )
        }
        rules += (legacy.hotkeys ?? []).map { mapping in
            AutomationRule(name: mapping.name, trigger: .keyboard(KeyboardTrigger(keys: mapping.when)), actions: [.keyboard(mapping.send)])
        }
        let old = legacy.settings
        let settings = EngineSettings(
            debounceMilliseconds: max(0, old.debounceMs), logLevel: old.logLevel,
            diagonalRejectRatio: old.diagonalRejectRatio, downBiasRatio: old.downBiasRatio,
            spreadThreshold: old.spreadThreshold, minimumSwipeDistance: old.minSwipeDistance,
            downBiasMinimumY: old.downBiasMinAbsDy, spreadToDistanceRatio: old.spreadToDistanceRatio,
            liveTriggerDistance: old.liveTriggerDistance
        )
        return AutomationConfiguration(rules: rules, settings: settings)
    }
}

private struct ConfigurationHeader: Decodable {
    let schemaVersion: Int?
    let isLegacy: Bool
    private enum CodingKeys: String, CodingKey { case schemaVersion, gestures }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion)
        isLegacy = values.contains(.gestures)
    }
}

enum ConfigurationError: LocalizedError {
    case unsupportedSchema(Int)
    case duplicateIdentity
    case unreadableOriginal

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): return "不支持配置版本 \(version)，请使用兼容的 Gesture 版本"
        case .duplicateIdentity: return "配置中存在重复的规则或动作 ID"
        case .unreadableOriginal: return "原配置无法读取，请先检查配置文件，或点击“保存并应用”明确保存当前配置"
        }
    }
}
