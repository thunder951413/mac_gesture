import Foundation
import AppKit

final class ActionExecutor {
    private let keySimulator: KeySimulator
    private let queue = DispatchQueue(label: "com.gesturedaemon.actions", qos: .userInitiated)

    init(debounceMilliseconds: Int) {
        keySimulator = KeySimulator(debounceMs: debounceMilliseconds)
    }

    func execute(_ actions: [AutomationAction], ruleName: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for action in actions {
                switch action.kind {
                case .keyboardShortcut:
                    _ = self.keySimulator.triggerImmediate(keys: action.keys)
                case .delay:
                    usleep(useconds_t(max(0, action.delayMilliseconds) * 1_000))
                case .openURL:
                    guard let url = URL(string: action.value) else { continue }
                    _ = DispatchQueue.main.sync { NSWorkspace.shared.open(url) }
                case .launchApplication:
                    let value = action.value
                    DispatchQueue.main.sync {
                        if value.contains(".") && !value.hasPrefix("/") {
                            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: value) {
                                NSWorkspace.shared.openApplication(at: url, configuration: .init())
                            }
                        } else {
                            NSWorkspace.shared.open(URL(fileURLWithPath: value))
                        }
                    }
                case .shellScript:
                    self.run(executable: "/bin/zsh", arguments: ["-lc", action.value])
                case .appleScript:
                    self.run(executable: "/usr/bin/osascript", arguments: ["-e", action.value])
                }
            }
            fputs("[ActionExecutor] 已执行：\(ruleName)\n", stderr)
        }
    }

    private func run(executable: String, arguments: [String]) {
        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.terminationHandler = { _ in completed.signal() }
        do {
            try process.run()
            if completed.wait(timeout: .now() + 60) == .timedOut {
                process.terminate()
                _ = completed.wait(timeout: .now() + 2)
                fputs("[ActionExecutor] 命令运行超过 60 秒，已终止\n", stderr)
                return
            }
            if process.terminationStatus != 0 {
                fputs("[ActionExecutor] 命令退出码：\(process.terminationStatus)\n", stderr)
            }
        } catch {
            fputs("[ActionExecutor] 无法运行命令：\(error.localizedDescription)\n", stderr)
        }
    }
}
