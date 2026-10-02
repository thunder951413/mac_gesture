import Foundation
import CoreGraphics

// 私有 MTContact 的归一化坐标位于 32/36，但完整记录还包含绝对坐标、
// 椭圆及压力字段，arm64 的数组步长是 96。误用 64 只会正确读取首个触点。
// 布局参考：https://github.com/calftrail/TrackMagic/blob/master/MultitouchSupport.h
// 每帧仍校验字段；未来系统更改布局时交由辅助进程熔断并降级。
enum MTContactDecoder {
    static let stride = 96

    static func decode(_ buffer: UnsafeRawBufferPointer, count: Int) throws -> [ActiveTouch] {
        guard (0...20).contains(count), buffer.count >= count * stride else {
            throw TouchError("触点数组长度异常")
        }
        var touches = [ActiveTouch]()
        var identifiers = Set<Int>()
        for index in 0..<count {
            let base = index * stride
            let identifier = Int(buffer.loadUnaligned(fromByteOffset: base + 16, as: Int32.self))
            let state = Int(buffer.loadUnaligned(fromByteOffset: base + 20, as: Int32.self))
            let x = CGFloat(buffer.loadUnaligned(fromByteOffset: base + 32, as: Float.self))
            let y = CGFloat(buffer.loadUnaligned(fromByteOffset: base + 36, as: Float.self))
            guard (-1...128).contains(identifier), identifiers.insert(identifier).inserted,
                  (0...7).contains(state), x.isFinite, y.isFinite,
                  (-0.2...1.2).contains(x), (-0.2...1.2).contains(y) else {
                throw TouchError("触点字段异常（索引 \(index)）；私有结构体布局可能已变化")
            }
            func metric(at offset: Int) -> CGFloat? {
                let value = CGFloat(buffer.loadUnaligned(fromByteOffset: base + offset, as: Float.self))
                return value.isFinite && value > 0 ? value : nil
            }
            touches.append(ActiveTouch(identifier: identifier, state: state, normalizedX: x, normalizedY: y,
                                       majorAxis: metric(at: 60), minorAxis: metric(at: 64),
                                       contactSize: metric(at: 48)))
        }
        return touches
    }
}
