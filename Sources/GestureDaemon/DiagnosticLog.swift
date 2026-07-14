import Foundation

final class DiagnosticLog {
    static let shared = DiagnosticLog()
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gesture/gesture.log")

    private let queue = DispatchQueue(label: "com.gesture.diagnostic-log")
    private let formatter = ISO8601DateFormatter()

    private init() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    func write(_ message: String) {
        queue.async {
            let line = "\(self.formatter.string(from: Date())) \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: Self.url.path) {
                FileManager.default.createFile(atPath: Self.url.path, contents: data)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: Self.url) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf: data) } catch {}
        }
    }

    private func rotateIfNeeded() {
        guard let size = try? Self.url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_000_000 else { return }
        let old = Self.url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: Self.url, to: old)
    }
}
