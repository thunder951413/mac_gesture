import Foundation
import ApplicationServices

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

        // 检查辅助功能权限（CGEventPostToPid / CGEvent.tapCreate 都需要）
        let trusted = AXIsProcessTrusted()
        if !trusted {
            print("[GestureDaemon] ⚠️ 需要辅助功能权限才能发送按键")
            print("[GestureDaemon] 前往: 系统设置 → 隐私与安全性 → 辅助功能")
            print("[GestureDaemon] 添加以下路径后重新运行:")
            print("[GestureDaemon]   \(CommandLine.arguments[0])")
        }

        touchListener = try TouchListener { [weak self] touches, timestamp in
            self?.recognizer.processTouches(touches, timestamp: timestamp)
        }

        hotkeyListener = HotkeyListener(mappings: config.hotkeys, keySimulator: keySimulator)
        let hotkeyOk = hotkeyListener?.start() ?? true
        if !hotkeyOk {
            print("[GestureDaemon] ⚠️ 热键功能启动失败，将继续提供手势功能")
        }

        print("[GestureDaemon] 手势映射引擎已启动，监听触控板事件中...")
        print("[GestureDaemon] 按 Ctrl+C 退出")

        CFRunLoopRun()
    }

    private func handleGesture(_ event: GestureEvent) {
        for mapping in config.gestures {
            guard mapping.fingers == event.fingers else { continue }
            guard mapping.direction == event.direction else { continue }
            guard event.distance >= CGFloat(mapping.minDistance) else { continue }

            let name = mapping.name
            let keys = mapping.keys
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                if self?.keySimulator.trigger(keys: keys, gestureName: name) == true {
                    print("[GestureDaemon] 手势触发: \(name) → \(keys.joined(separator: "+"))")
                }
            }
            return
        }
    }
}
