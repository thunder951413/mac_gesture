import XCTest
@testable import GestureTouchCore

final class MTContactDecoderTests: XCTestCase {
    private func records(count: Int) -> Data {
        var data = Data(repeating: 0, count: count * 96)
        for index in 0..<count {
            let base = index * 96
            data.withUnsafeMutableBytes { buffer in
                buffer.storeBytes(of: Int32(index + 1), toByteOffset: base + 16, as: Int32.self)
                buffer.storeBytes(of: Int32(4), toByteOffset: base + 20, as: Int32.self)
                buffer.storeBytes(of: Float(index + 1) / 10, toByteOffset: base + 32, as: Float.self)
                buffer.storeBytes(of: Float(index + 2) / 10, toByteOffset: base + 36, as: Float.self)
                // 64 字节步长会把绝对坐标等尾部字段误当作下一个触点。
                buffer.storeBytes(of: Float(73.5), toByteOffset: base + 80, as: Float.self)
            }
        }
        return data
    }

    func testReadsEveryContactInTwoAndFiveFingerFrames() throws {
        for count in [2, 5] {
            let data = records(count: count)
            let touches = try data.withUnsafeBytes { try MTContactDecoder.decode($0, count: count) }
            XCTAssertEqual(touches.map(\.identifier), Array(1...count))
            for (index, touch) in touches.enumerated() {
                XCTAssertEqual(touch.state, 4)
                XCTAssertEqual(touch.normalizedX, CGFloat(index + 1) / 10, accuracy: 0.00001)
                XCTAssertEqual(touch.normalizedY, CGFloat(index + 2) / 10, accuracy: 0.00001)
            }
        }
    }

    func testRejectsTruncatedAndInvalidContactFrames() {
        let data = records(count: 2)
        XCTAssertThrowsError(try data.prefix(128).withUnsafeBytes { try MTContactDecoder.decode($0, count: 2) })
        var invalid = data
        invalid.withUnsafeMutableBytes { $0.storeBytes(of: Float.nan, toByteOffset: 96 + 32, as: Float.self) }
        XCTAssertThrowsError(try invalid.withUnsafeBytes { try MTContactDecoder.decode($0, count: 2) })
        XCTAssertThrowsError(try data.withUnsafeBytes { try MTContactDecoder.decode($0, count: -1) })
    }
}
