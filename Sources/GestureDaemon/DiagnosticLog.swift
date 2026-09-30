import Foundation

// 写入状态仅在串行 queue 上访问，初始化发生在 shared 发布之前。
final class DiagnosticLog: @unchecked Sendable {
    static let shared = DiagnosticLog()
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gesture/gesture.log")

    private static let maxBytes = 1_000_000

    private let queue = DispatchQueue(label: "com.gesture.diagnostic-log")
    private let formatter = ISO8601DateFormatter()
    // 句柄在队列上常驻复用；路径消失（如日志被手动删除）或写入失败时置空，
    // 下一条写入重新打开以自愈。
    private var handle: FileHandle?

    private init() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    deinit { try? handle?.close() }

    func write(_ message: String) {
        queue.async {
            let line = "\(self.formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            self.append(data)
        }
    }

    private func append(_ data: Data) {
        guard let handle = currentHandle() else { return }
        do {
            let offset = try handle.seekToEnd()
            if offset >= Self.maxBytes {
                try? handle.close()
                self.handle = nil
                swapToOldLog()
                guard let fresh = currentHandle() else { return }
                try fresh.write(contentsOf: data)
                return
            }
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func currentHandle() -> FileHandle? {
        if let handle {
            if FileManager.default.fileExists(atPath: Self.url.path) { return handle }
            try? handle.close()
            self.handle = nil
        }
        if !FileManager.default.fileExists(atPath: Self.url.path) {
            FileManager.default.createFile(atPath: Self.url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: Self.url) else { return nil }
        handle = opened
        return opened
    }

    private func rotateIfNeeded() {
        guard let size = try? Self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.maxBytes else { return }
        swapToOldLog()
    }

    private func swapToOldLog() {
        let old = Self.url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: Self.url, to: old)
    }
}
