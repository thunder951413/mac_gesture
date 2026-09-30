import Foundation
import AppKit

// 调度状态由 condition 保护；按键模拟只在串行动作队列使用。
final class ActionExecutor: @unchecked Sendable {
    private var completionHandler: (@Sendable (String, String?) -> Void)?
    var onCompletion: (@Sendable (String, String?) -> Void)? {
        get { condition.lock(); defer { condition.unlock() }; return completionHandler }
        set { condition.lock(); completionHandler = newValue; condition.unlock() }
    }

    private let keySimulator: KeySimulator
    private let queue = DispatchQueue(label: "com.gesturedaemon.actions", qos: .userInitiated)
    private let condition = NSCondition()
    private let commandTimeout: TimeInterval
    private let maximumPendingExecutions: Int
    private var stopped = false
    private var pendingExecutions = 0
    private var activeProcess: Process?

    init(debounceMilliseconds: Int, commandTimeout: TimeInterval = 60, maximumPendingExecutions: Int = 32) {
        keySimulator = KeySimulator(debounceMs: debounceMilliseconds)
        self.commandTimeout = commandTimeout.isFinite ? min(60, max(0.05, commandTimeout)) : 60
        self.maximumPendingExecutions = maximumPendingExecutions
    }

    @discardableResult
    func execute(_ actions: [AutomationAction], ruleName: String) -> Bool {
        condition.lock()
        guard !stopped, pendingExecutions < maximumPendingExecutions else { condition.unlock(); return false }
        pendingExecutions += 1
        condition.unlock()
        queue.async {
            defer {
                self.condition.lock()
                self.pendingExecutions -= 1
                self.condition.unlock()
            }
            var failure: String?
            for action in actions {
                guard !self.isStopped else { return }
                switch action.kind {
                case .keyboardShortcut:
                    if !self.keySimulator.triggerImmediate(keys: action.keys) { failure = "无法发送快捷键" }
                case .delay:
                    if !self.wait(milliseconds: action.delayMilliseconds) { return }
                case .openURL:
                    guard let url = URL(string: action.value), url.scheme != nil else { failure = "无效网址"; break }
                    let opened = DispatchQueue.main.sync { !self.isStopped && NSWorkspace.shared.open(url) }
                    if !opened { failure = "无法打开网址" }
                case .launchApplication:
                    failure = self.launchApplication(action.value)
                case .shellScript:
                    failure = self.run(executable: "/bin/zsh", arguments: ["-lc", action.value])
                case .appleScript:
                    failure = self.run(executable: "/usr/bin/osascript", arguments: ["-e", action.value])
                }
                // 前一步失败时停止序列，避免继续执行依赖该步骤的动作。
                if failure != nil { break }
            }
            guard !self.isStopped else { return }
            DiagnosticLog.shared.write("[Action] \(ruleName)：\(failure ?? "执行完成")")
            self.onCompletion?(ruleName, failure)
        }
        return true
    }

    func cancel() {
        condition.lock()
        stopped = true
        let process = activeProcess
        condition.broadcast()
        condition.unlock()
        if let process { ManagedProcess.terminate(process) }
    }

    private var isStopped: Bool {
        condition.lock(); defer { condition.unlock() }
        return stopped
    }

    private func wait(milliseconds: Int) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + Double(max(0, milliseconds)) / 1_000
        condition.lock(); defer { condition.unlock() }
        while !stopped {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            // 使用单调时钟决定完成时间，每次等待有界，避免极大毫秒值溢出系统时间。
            _ = condition.wait(until: Date(timeIntervalSinceNow: min(remaining, 60)))
        }
        return !stopped
    }

    private func launchApplication(_ value: String) -> String? {
        let completed = DispatchSemaphore(value: 0)
        let result = ApplicationLaunchResult()
        DispatchQueue.main.sync {
            guard !isStopped else { completed.signal(); return }
            let url = value.hasPrefix("/")
                ? URL(fileURLWithPath: value)
                : NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
            guard let url else { result.failure = "找不到应用：\(value)"; completed.signal(); return }
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
                result.failure = error?.localizedDescription
                completed.signal()
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + commandTimeout
        while !isStopped {
            if completed.wait(timeout: .now() + 0.05) == .success {
                return result.failure
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { return "打开应用超时" }
        }
        return nil
    }

    private func run(executable: String, arguments: [String]) -> String? {
        let process = Process()
        let completed = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completed.signal() }
        condition.lock()
        guard !stopped else { condition.unlock(); return nil }
        do {
            try process.run()
            activeProcess = process
            condition.unlock()
        } catch {
            condition.unlock()
            return "无法运行命令：\(error.localizedDescription)"
        }
        defer {
            condition.lock()
            activeProcess = nil
            condition.unlock()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + commandTimeout
        while !isStopped {
            if completed.wait(timeout: .now() + 0.05) == .success {
                return process.terminationStatus == 0 ? nil : "命令退出码：\(process.terminationStatus)"
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                ManagedProcess.terminate(process)
                _ = completed.wait(timeout: .now() + 2.5)
                return "命令运行超时（\(Int(commandTimeout)) 秒）"
            }
        }
        ManagedProcess.terminate(process)
        return nil
    }
}

private final class ApplicationLaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: String?
    var failure: String? {
        get { lock.lock(); defer { lock.unlock() }; return storedFailure }
        set { lock.lock(); storedFailure = newValue; lock.unlock() }
    }
}
