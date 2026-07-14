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

    init(url: URL = ConfigurationStore.defaultURL) {
        self.url = url
        let loaded: AutomationConfiguration
        if FileManager.default.fileExists(atPath: url.path) {
            do { loaded = try Self.load(from: url) }
            catch {
                loaded = .defaults
                lastError = "配置文件无法读取，当前使用内置默认值：\(error.localizedDescription)"
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
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: .atomic)
        baseline = configuration
        hasUnsavedChanges = false
        lastError = nil
    }

    func saveReportingError() {
        do { try save() } catch { lastError = error.localizedDescription }
    }

    func clearError() { lastError = nil }

    func reload() {
        do {
            let loaded = try Self.load(from: url)
            baseline = loaded
            configuration = loaded
            hasUnsavedChanges = false
            lastError = nil
        } catch { lastError = error.localizedDescription }
    }

    private static func load(from url: URL) throws -> AutomationConfiguration {
        let data = try Data(contentsOf: url)
        if let current = try? JSONDecoder().decode(AutomationConfiguration.self, from: data) {
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
