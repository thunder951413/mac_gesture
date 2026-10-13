import XCTest
import CoreGraphics
import GestureTouchCore
@testable import GestureDaemon

/// 误触防护：随手移动的掌根、滑动中途新增/擦过的触点、手搭在触控板上的缓慢漂移。
/// 规则与本机真实配置一致：仅三指向下、dy ≥ 0.08 时关闭窗口。
final class MisfireGuardTests: XCTestCase {
    private func closeWindowCount(_ frames: [(Double, [ActiveTouch])]) -> Int {
        let recognizer = GestureRecognizer()
        var count = 0
        recognizer.onGesture = { event in
            guard event.fingers == 3 && event.direction == .down && -event.dy >= 0.08 else { return false }
            count += 1
            return true
        }
        for (timestamp, touches) in frames { recognizer.processTouches(touches, timestamp: timestamp) }
        recognizer.processTouches([], timestamp: (frames.last?.0 ?? 0) + 0.01)
        return count
    }

    private func touch(_ id: Int, _ x: CGFloat, _ y: CGFloat) -> ActiveTouch {
        ActiveTouch(identifier: id, state: 4, normalizedX: x, normalizedY: y)
    }

    private func threeFingers(_ movement: CGFloat) -> [ActiveTouch] {
        [touch(1, 0.50, 0.80 - movement), touch(2, 0.60, 0.85 - movement), touch(3, 0.70, 0.80 - movement)]
    }

    func testFingerSizedPalmMovingWithTwoFingerScrollIsNotAThirdFinger() {
        // 掌根与指尖一样大且随手移动，旧版共同移动检查无法排除它。
        let frames = (0..<40).map { frame -> (Double, [ActiveTouch]) in
            let movement = CGFloat(frame) * 0.006
            var touches = [touch(1, 0.45, 0.75 - movement), touch(2, 0.58, 0.78 - movement)]
            if frame >= 2 { touches.append(touch(3, 0.95, 0.15 - CGFloat(frame) * 0.004)) }
            return (Double(frame) * 0.008, touches)
        }
        XCTAssertEqual(closeWindowCount(frames), 0)
    }

    func testContactLandingDuringMovingThreeFingerSwipeDoesNotUpgradeIt() {
        let frames = (0..<60).map { frame -> (Double, [ActiveTouch]) in
            let movement = CGFloat(max(0, frame - 3)) * 0.004
            var touches = threeFingers(movement)
            if frame >= 20 { touches.append(touch(4, 0.62, 0.60 - movement * 0.2)) }
            return (Double(frame) * 0.008, touches)
        }
        XCTAssertEqual(closeWindowCount(frames), 1)
    }

    func testBriefBrushDuringThreeFingerSwipeDoesNotFreezeIt() {
        let frames = (0..<60).map { frame -> (Double, [ActiveTouch]) in
            var touches = threeFingers(CGFloat(max(0, frame - 4)) * 0.004)
            if (7..<13).contains(frame) { touches.append(touch(4, 0.62, 0.62)) }
            return (Double(frame) * 0.008, touches)
        }
        XCTAssertEqual(closeWindowCount(frames), 1)
    }

    func testRestingHandSlowDriftDoesNotAccumulateIntoSwipe() {
        let frames = (0..<180).map { frame -> (Double, [ActiveTouch]) in
            let timestamp = Double(frame) * 0.008
            let movement: Double
            switch timestamp {
            case ..<0.2: movement = 0
            case ..<0.45: movement = (timestamp - 0.2) / 0.25 * 0.045
            case ..<1.05: movement = 0.045
            case ..<1.3: movement = 0.045 + (timestamp - 1.05) / 0.25 * 0.045
            default: movement = 0.09
            }
            return (timestamp, threeFingers(CGFloat(movement)))
        }
        XCTAssertEqual(closeWindowCount(frames), 0)
    }

    func testHoldingStillThenSwipingStillTriggers() {
        let frames = (0..<160).map { frame -> (Double, [ActiveTouch]) in
            (Double(frame) * 0.008, threeFingers(CGFloat(max(0, frame - 140)) * 0.012))
        }
        XCTAssertEqual(closeWindowCount(frames), 1)
    }

    func testNormalFastThreeFingerSwipeStillTriggers() {
        let frames = (0..<20).map { frame -> (Double, [ActiveTouch]) in
            (Double(frame) * 0.008, threeFingers(CGFloat(max(0, frame - 3)) * 0.012))
        }
        XCTAssertEqual(closeWindowCount(frames), 1)
    }
}

final class IsolatedContactFilterTests: XCTestCase {
    private func touch(_ id: Int, _ x: CGFloat, _ y: CGFloat, state: Int = 4) -> ActiveTouch {
        ActiveTouch(identifier: id, state: state, normalizedX: x, normalizedY: y)
    }

    func testDistantContactBesideTwoFingersIsRejectedWithoutShapeData() {
        var filter = PalmRejectionFilter()
        let touches = [touch(1, 0.45, 0.75), touch(2, 0.58, 0.78), touch(3, 0.95, 0.15)]
        XCTAssertEqual(filter.filter(touches, timestamp: 0).count, 3)
        XCTAssertEqual(filter.filter(touches, timestamp: 0.008).count, 3)
        XCTAssertEqual(filter.filter(touches, timestamp: 0.016).map(\.identifier), [1, 2])
        // 标记保持到该触点抬起，即使它之后靠近手指。
        let closer = [touch(1, 0.45, 0.75), touch(2, 0.58, 0.78), touch(3, 0.6, 0.6)]
        XCTAssertEqual(filter.filter(closer, timestamp: 0.024).map(\.identifier), [1, 2])
    }

    func testNormalThreeFingerSpacingIsKept() {
        // 本机最宽的真实三指间距约 0.31（横向按 1.5 倍折算）。
        var filter = PalmRejectionFilter()
        let touches = [touch(1, 0.30, 0.60), touch(2, 0.45, 0.80), touch(3, 0.62, 0.92)]
        for frame in 0..<10 {
            XCTAssertEqual(filter.filter(touches, timestamp: Double(frame) * 0.008).count, 3)
        }
    }

    func testPinchThumbIsKeptAfterFourContactsWereSeen() {
        var filter = PalmRejectionFilter()
        let thumb = touch(9, 0.5, 0.05)
        let fingers = [touch(1, 0.40, 0.60), touch(2, 0.50, 0.65), touch(3, 0.60, 0.60)]
        for frame in 0..<5 {
            XCTAssertEqual(filter.filter(fingers + [thumb], timestamp: Double(frame) * 0.008).count, 4)
        }
        // 抬手过程中只剩拇指与两指，拇指不能被追认为掌缘。
        for frame in 5..<12 {
            XCTAssertEqual(filter.filter(Array(fingers.prefix(2)) + [thumb], timestamp: Double(frame) * 0.008).count, 3)
        }
    }
}
