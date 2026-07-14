import XCTest
import CoreGraphics
import GestureTouchCore
@testable import GestureDaemon

final class GestureRecognizerTests: XCTestCase {

    /// 辅助：构造一次完整手势（按下→滑动→抬起），返回识别出的事件。
    /// 识别器要求 ≥3 指需连续多帧稳定（extraFingerConfirmFrames=3, duration=18ms），
    /// 因此按下后发送若干稳定帧再开始滑动。
    private func recognizeSwipe(fingers: Int,
                                from start: CGPoint,
                                to end: CGPoint,
                                tuning: GestureTuning = GestureTuning()) -> GestureEvent? {
        let r = GestureRecognizer()
        r.tuning = tuning
        var captured: GestureEvent?
        r.onGesture = { event in captured = event; return true }

        // 初始帧：N 指落在起点
        let startTouches = (0..<fingers).map { i in
            ActiveTouch(identifier: i, state: 4,
                        normalizedX: start.x + CGFloat(i) * 0.001,
                        normalizedY: start.y)
        }
        r.processTouches(startTouches, timestamp: 0.0)

        // 稳定帧：保持起点不动，满足 extraFingerConfirmFrames/Duration（≥3 指需要）
        for f in 1...5 {
            r.processTouches(startTouches, timestamp: Double(f) * 0.005)
        }

        // 滑动帧：手指移动到终点
        let endTouches = (0..<fingers).map { i in
            ActiveTouch(identifier: i, state: 4,
                        normalizedX: end.x + CGFloat(i) * 0.001,
                        normalizedY: end.y)
        }
        r.processTouches(endTouches, timestamp: 0.05)

        // 抬起帧：空，触发 evaluateGesture
        r.processTouches([], timestamp: 0.1)

        return captured
    }

    // MARK: - 方向识别

    func testSwipeDown_threeFingers() {
        let event = recognizeSwipe(fingers: 3, from: CGPoint(x: 0.5, y: 0.5),
                                   to: CGPoint(x: 0.5, y: 0.1))
        XCTAssertEqual(event?.direction, .down)
        XCTAssertEqual(event?.fingers, 3)
        XCTAssertLessThan(event!.dy, 0)  // 向下 dy 为负
    }

    func testSwipeUp_threeFingers() {
        let event = recognizeSwipe(fingers: 3, from: CGPoint(x: 0.5, y: 0.1),
                                   to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(event?.direction, .up)
        XCTAssertEqual(event?.fingers, 3)
        XCTAssertGreaterThan(event!.dy, 0)
    }

    func testSwipeLeft_threeFingers() {
        let event = recognizeSwipe(fingers: 3, from: CGPoint(x: 0.8, y: 0.5),
                                   to: CGPoint(x: 0.2, y: 0.5))
        XCTAssertEqual(event?.direction, .left)
        XCTAssertLessThan(event!.dx, 0)
    }

    func testSwipeRight_threeFingers() {
        let event = recognizeSwipe(fingers: 3, from: CGPoint(x: 0.2, y: 0.5),
                                   to: CGPoint(x: 0.8, y: 0.5))
        XCTAssertEqual(event?.direction, .right)
        XCTAssertGreaterThan(event!.dx, 0)
    }

    // MARK: - 距离阈值

    func testSwipeTooShort_isIgnored() {
        // 距离 0.005 < 默认 minSwipeDistance 0.01
        let event = recognizeSwipe(fingers: 3, from: CGPoint(x: 0.5, y: 0.5),
                                   to: CGPoint(x: 0.5, y: 0.495))
        XCTAssertNil(event, "距离太短应被忽略")
    }

    func testSwipeJustAboveThreshold_isRecognized() {
        // 距离 0.02 > minSwipeDistance 0.01
        let event = recognizeSwipe(fingers: 3, from: CGPoint(x: 0.5, y: 0.5),
                                   to: CGPoint(x: 0.5, y: 0.48))
        XCTAssertEqual(event?.direction, .down)
    }

    // MARK: - 下偏修正

    func testDownBiasCorrection_leftWithDownwardComponent_becomesDown() {
        // 主要向左但有明显向下分量：|dy|/|dx| = 0.2/0.3 = 0.67 > downBiasRatio 0.35
        // 且 |dy|=0.2 > downBiasMinAbsDy 0.08
        var tuning = GestureTuning()
        tuning.downBiasRatio = 0.35
        tuning.downBiasMinAbsDy = 0.08
        let event = recognizeSwipe(fingers: 3,
                                   from: CGPoint(x: 0.7, y: 0.7),
                                   to: CGPoint(x: 0.4, y: 0.5),
                                   tuning: tuning)
        XCTAssertEqual(event?.direction, .down, "左滑伴随明显下偏应修正为 down")
    }

    func testDownBiasCorrection_insufficientDownward_staysLeft() {
        // 向左为主，向下分量极小：|dy|/|dx| = 0.05/0.4 = 0.125 < downBiasRatio 0.35
        var tuning = GestureTuning()
        tuning.downBiasRatio = 0.35
        tuning.downBiasMinAbsDy = 0.08
        let event = recognizeSwipe(fingers: 3,
                                   from: CGPoint(x: 0.7, y: 0.5),
                                   to: CGPoint(x: 0.3, y: 0.45),
                                   tuning: tuning)
        XCTAssertEqual(event?.direction, .left)
    }

    // MARK: - 对角线拒绝

    func testDiagonalSwipe_isRejected() {
        // 完全对角线：|dx|=|dy|，次轴/主轴 = 1.0 > diagonalRejectRatio 0.95
        var tuning = GestureTuning()
        tuning.diagonalRejectRatio = 0.95
        let event = recognizeSwipe(fingers: 3,
                                   from: CGPoint(x: 0.3, y: 0.3),
                                   to: CGPoint(x: 0.6, y: 0.6),
                                   tuning: tuning)
        XCTAssertNil(event, "严格对角线应被拒绝")
    }

    // MARK: - 最少手指数

    func testSingleFinger_doesNotRecognize() {
        let event = recognizeSwipe(fingers: 1, from: CGPoint(x: 0.2, y: 0.5),
                                   to: CGPoint(x: 0.8, y: 0.5))
        XCTAssertNil(event, "单指不应触发手势")
    }

    // MARK: - 手指数

    func testFourFingerSwipeUp() {
        let event = recognizeSwipe(fingers: 4, from: CGPoint(x: 0.5, y: 0.1),
                                   to: CGPoint(x: 0.5, y: 0.6))
        XCTAssertEqual(event?.direction, .up)
        XCTAssertEqual(event?.fingers, 4)
    }
}
