import XCTest
import CoreGraphics
import GestureTouchCore
@testable import GestureDaemon

/// 2026-10-02 真实触控板采样：掌缘+两指、掌缘分成两个触点、正常三指及4/5指捏合。
/// contacts 的列为 ID、状态、x、y、长轴、短轴、面积代理值；0 表示指标缺失。
final class CapturedPalmRegressionTests: XCTestCase {
    private struct Capture: Decodable {
        let name: String
        let expectedFingers: [Int]
        let expectedDirections: [GestureDirection]
        let frames: [Frame]
    }

    private struct Frame: Decodable {
        let timestamp: Double
        let contacts: [[Double]]

        var touches: [ActiveTouch] {
            contacts.map {
                ActiveTouch(identifier: Int($0[0]), state: Int($0[1]),
                            normalizedX: CGFloat($0[2]), normalizedY: CGFloat($0[3]),
                            majorAxis: $0[4] > 0 ? CGFloat($0[4]) : nil,
                            minorAxis: $0[5] > 0 ? CGFloat($0[5]) : nil,
                            contactSize: $0[6] > 0 ? CGFloat($0[6]) : nil)
            }
        }
    }

    func testCapturedPalmAndNormalGestureFrames() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "palm-and-gestures", withExtension: "json"))
        let captures = try JSONDecoder().decode([Capture].self, from: Data(contentsOf: url))
        XCTAssertEqual(captures.count, 9)
        for capture in captures {
            let recognizer = GestureRecognizer()
            var events: [GestureEvent] = []
            var maximumRejected = 0
            recognizer.onGesture = {
                guard $0.distance >= 0.06 else { return false }
                events.append($0)
                return true
            }
            for frame in capture.frames {
                XCTAssertTrue(frame.contacts.allSatisfy { $0.count == 7 }, capture.name)
                recognizer.processTouches(frame.touches, timestamp: frame.timestamp)
                maximumRejected = max(maximumRejected, recognizer.rejectedPalmCount)
            }
            XCTAssertEqual(events.map(\.fingers), capture.expectedFingers, capture.name)
            XCTAssertEqual(events.map(\.direction), capture.expectedDirections, capture.name)
            let expectedRejected = capture.name == "palm-40" ? 2 : (capture.name.hasPrefix("palm-") ? 1 : 0)
            XCTAssertEqual(maximumRejected, expectedRejected, capture.name)
        }
    }

    // 2026-10-02 第二轮现场采样：第三触点在顶部悬停约3.6秒；旧版会
    // 按真实用户规则（仅3指向下、dy>=0.08）触发关闭窗口。
    func testCapturedHoveringPalmCannotTriggerWindowCloseRule() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "hover-palm-scroll", withExtension: "json"))
        let frames = try JSONDecoder().decode([Frame].self, from: Data(contentsOf: url))
        let recognizer = GestureRecognizer()
        var closeAttempts = 0
        var maximumAccepted = 0
        recognizer.onGesture = { event in
            guard event.fingers == 3 && event.direction == .down && -event.dy >= 0.08 else { return false }
            closeAttempts += 1
            return true
        }
        for frame in frames {
            recognizer.processTouches(frame.touches, timestamp: frame.timestamp)
            maximumAccepted = max(maximumAccepted, recognizer.acceptedTouchCount)
        }
        XCTAssertGreaterThan(frames.count, 400)
        XCTAssertEqual(maximumAccepted, 2)
        XCTAssertEqual(closeAttempts, 0)
    }
}
