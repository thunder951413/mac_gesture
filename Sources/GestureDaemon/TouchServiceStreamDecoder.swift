import Foundation
import GestureTouchCore

/// 每次启动服务使用独立解析器，旧进程的数据不会混入新会话。
// 可跨线程传递，解析状态由 lock 保护。
final class TouchServiceStreamDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maximumLineBytes = 64 * 1_024
    private var lastTimestamp: Double?

    func consume(_ data: Data) throws -> [TouchServiceMessage] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var messages: [TouchServiceMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard line.count <= maximumLineBytes else { throw ProviderError("触点消息超过大小限制") }
            if line.isEmpty { continue }
            let message: TouchServiceMessage
            do { message = try JSONDecoder().decode(TouchServiceMessage.self, from: line) }
            catch { throw ProviderError("触点消息不是有效的 JSON") }
            if message.kind == .frame {
                guard let touches = message.touches, let timestamp = message.timestamp,
                      timestamp.isFinite, timestamp >= 0,
                      lastTimestamp.map({ timestamp >= $0 }) ?? true,
                      TouchFrameValidator.isValid(touches) else { throw ProviderError("触点帧数据无效") }
                lastTimestamp = timestamp
            }
            messages.append(message)
        }
        guard buffer.count <= maximumLineBytes else { throw ProviderError("触点消息缺少换行或超过大小限制") }
        return messages
    }
}
