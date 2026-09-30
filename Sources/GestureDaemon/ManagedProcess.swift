import Foundation

enum ManagedProcess {
    /// 不在主线程等待退出；不响应 SIGTERM 的进程会在宽限期后被强制结束。
    static func terminate(_ process: Process, gracePeriod: TimeInterval = 2) {
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + gracePeriod) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
