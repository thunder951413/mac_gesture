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
        self.recognizer.diagonalRejectRatio = config.settings.diagonalRejectRatio
        self.recognizer.downBiasRatio = config.settings.downBiasRatio
        setupRecognizer()
    }

    private func setupRecognizer() {
        recognizer.onGesture = { [weak self] event in
            self?.handleGesture(event) == true
        }
    }

    func start() throws {
        print("[GestureDaemon] 正在启动...")
        print("[GestureDaemon] 已加载 \(config.gestures.count) 个手势映射, \(config.hotkeys.count) 个热键映射")

        // 检查辅助功能权限（CGEventPostToPid / CGEvent.tapCreate 都需要）
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
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

    private func handleGesture(_ event: GestureEvent) -> Bool {
        for mapping in config.gestures {
            guard mapping.fingers == event.fingers else { continue }
            guard mapping.direction == event.direction || isFlexibleDownMatch(event, mapping: mapping) else { continue }
            guard event.distance >= CGFloat(mapping.minDistance) else {
                if event.fingers == 3 && mapping.direction == .down {
                    fputs("[三指诊断] 距离不足未触发\"\(mapping.name)\" | 实际=\(String(format: "%.3f", event.distance)) 需≥\(String(format: "%.2f", mapping.minDistance))\n", stderr)
                }
                continue
            }

            let name = mapping.name
            let keys = mapping.keys
            if keySimulator.trigger(keys: keys, gestureName: name) {
                print("[GestureDaemon] 手势触发: \(name) → \(keys.joined(separator: "+"))")
                return true
            }
            return false
        }

        if event.fingers == 3 {
            let downMapping = config.gestures.first { $0.fingers == 3 && $0.direction == .down }
            if downMapping != nil {
                fputs("[三指诊断] 方向不匹配 | 识别为:\(event.direction) 需:down | dx=\(String(format: "%.4f", event.dx)) dy=\(String(format: "%.4f", event.dy))\n", stderr)
            }
        }
        return false
    }

    private func isFlexibleDownMatch(_ event: GestureEvent, mapping: GestureMapping) -> Bool {
        guard mapping.direction == .down, event.fingers == mapping.fingers else { return false }
        guard abs(event.dy) >= CGFloat(mapping.minDistance) else { return false }
        return abs(event.dy) >= abs(event.dx) * CGFloat(config.settings.downBiasRatio)
    }
}
