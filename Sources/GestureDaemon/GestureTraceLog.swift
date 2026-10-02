import Foundation
import GestureTouchCore

struct GestureTrace: Codable, Sendable {
    enum Decision: String, Codable, Sendable { case rejectedIncoherentSwipe, ignoredLateContact, ruleTriggered }
    struct Motion: Codable, Sendable {
        let identifier: Int
        let startX: Double
        let startY: Double
        let endX: Double
        let endY: Double
    }
    let decision: Decision
    let fingers: Int
    let direction: GestureDirection
    let distance: Double
    let dx: Double
    let dy: Double
    let motions: [Motion]
    let frames: [TouchServiceMessage]
}

struct GestureTraceBuffer {
    private(set) var frames: [TouchServiceMessage] = []
    mutating func append(_ touches: [ActiveTouch], timestamp: Double) {
        frames.append(TouchServiceMessage(kind: .frame, timestamp: timestamp, touches: touches))
        let expired = frames.prefix { ($0.timestamp ?? 0) < timestamp - 2 }.count
        let excess = max(expired, frames.count - 192)
        if excess > 0 { frames.removeFirst(excess) }
    }
    mutating func reset() { frames.removeAll() }
}

/// 只在多指滑动被拒绝或规则真正入队时保存触点证据；两份文件各不超过 5 MiB。
final class GestureTraceLog: @unchecked Sendable {
    static let shared: GestureTraceLog = {
        if let configurationPath = ProcessInfo.processInfo.environment["GESTURE_CONFIG_PATH"],
           !configurationPath.isEmpty {
            return GestureTraceLog(directoryURL: URL(fileURLWithPath: configurationPath)
                .deletingLastPathComponent().appendingPathComponent("diagnostics"))
        }
        return GestureTraceLog(directoryURL: DiagnosticLog.url.deletingLastPathComponent())
    }()
    let url: URL
    private let maximumBytes: Int
    private let queue = DispatchQueue(label: "com.gesture.touch-traces")

    init(directoryURL: URL, maximumBytes: Int = 5 * 1_024 * 1_024) {
        url = directoryURL.appendingPathComponent("touch-traces.jsonl")
        self.maximumBytes = maximumBytes
    }

    func write(_ trace: GestureTrace) {
        queue.async {
            struct Record: Encodable { let recordedAt: Date; let trace: GestureTrace }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var data = try? encoder.encode(Record(recordedAt: Date(), trace: trace)),
                  data.count + 1 <= self.maximumBytes else { return }
            data.append(0x0A)
            let manager = FileManager.default
            do {
                try manager.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                // URL.resourceValues 会缓存属性；每次追加前读取当前文件大小。
                let attributes = try? manager.attributesOfItem(atPath: self.url.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
                if size + data.count > self.maximumBytes {
                    let old = self.url.deletingPathExtension().appendingPathExtension("old.jsonl")
                    if manager.fileExists(atPath: old.path) { try manager.removeItem(at: old) }
                    try manager.moveItem(at: self.url, to: old)
                }
                if !manager.fileExists(atPath: self.url.path) {
                    manager.createFile(atPath: self.url.path, contents: nil,
                                       attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: self.url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                DiagnosticLog.shared.write("[GestureTrace] 无法保存触点诊断：\(error.localizedDescription)")
            }
        }
    }

    func flush() { queue.sync {} }
}
