import Foundation

final class GestureDaemon {
    private let config: Config
    private let keySimulator: KeySimulator
    private let recognizer: GestureRecognizer
    private var touchListener: TouchListener?
    private var hotkeyListener: HotkeyListener?

    init(config: Config) {
        self.config = config
        self.keySimulator = KeySimulator(debounceMs: config.settings.debounceMs)
        self.recognizer = GestureRecognizer()
        self.recognizer.logLevel = config.settings.logLevel
        setupRecognizer()
    }

    private func setupRecognizer() {
        recognizer.onGesture = { [weak self] event in
            self?.handleGesture(event)
        }
    }

    func start() throws {
        print("[GestureDaemon] 正在启动...")
        print("[GestureDaemon] 已加载 \(config.gestures.count) 个手势映射, \(config.hotkeys.count) 个热键映射")

        touchListener = try TouchListener { [weak self] touches, timestamp in
            self?.recognizer.processTouches(touches, timestamp: timestamp)
        }

        hotkeyListener = HotkeyListener(mappings: config.hotkeys, keySimulator: keySimulator)
        hotkeyListener?.start()

        print("[GestureDaemon] 手势映射引擎已启动，监听触控板事件中...")
        print("[GestureDaemon] 按 Ctrl+C 退出")

        CFRunLoopRun()
    }

    private func handleGesture(_ event: GestureEvent) {
        for mapping in config.gestures {
            guard mapping.fingers == event.fingers else { continue }
            guard mapping.direction == event.direction else { continue }
            guard event.distance >= CGFloat(mapping.minDistance) else { continue }

            let triggered = keySimulator.trigger(
                keys: mapping.keys,
                gestureName: mapping.name
            )
            if triggered {
                print("[GestureDaemon] 手势触发: \(mapping.name) → \(mapping.keys.joined(separator: "+"))")
            }
            return
        }
    }
}
