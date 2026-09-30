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

extension GestureRecognizerTests {
    private func pair(x: CGFloat, y: CGFloat = 0.5) -> [ActiveTouch] {
        [ActiveTouch(identifier: 1, state: 4, normalizedX: x, normalizedY: y),
         ActiveTouch(identifier: 2, state: 4, normalizedX: x + 0.01, normalizedY: y)]
    }

    func testTransientExtraFingerCannotCreateFalseSwipe() {
        let recognizer = GestureRecognizer()
        var count = 0
        recognizer.onGesture = { _ in count += 1; return true }
        recognizer.processTouches(pair(x: 0.2), timestamp: 0)
        let extra = ActiveTouch(identifier: 3, state: 4, normalizedX: 1, normalizedY: 0.5)
        recognizer.processTouches(pair(x: 0.2) + [extra], timestamp: 0.005)
        recognizer.processTouches(pair(x: 0.2), timestamp: 0.01)
        recognizer.processTouches([], timestamp: 0.02)
        XCTAssertEqual(count, 0)
    }

    func testAcceptedLiveGestureOnlyFiresOnceAndNextGestureStillWorks() {
        let recognizer = GestureRecognizer()
        var count = 0
        recognizer.onGesture = { _ in count += 1; return true }
        for offset in [0.0, 1.0] {
            recognizer.processTouches(pair(x: 0.2), timestamp: offset)
            recognizer.processTouches(pair(x: 0.4), timestamp: offset + 0.01)
            recognizer.processTouches(pair(x: 0.6), timestamp: offset + 0.02)
            recognizer.processTouches([], timestamp: offset + 0.03)
        }
        XCTAssertEqual(count, 2)
    }

    func testReleasePreservesMaximumExcursionAndPartialLiftDoesNotMoveCentroid() {
        let recognizer = GestureRecognizer()
        recognizer.liveTriggerDistance = 1
        var captured: GestureEvent?
        recognizer.onGesture = { captured = $0; return true }
        recognizer.processTouches(pair(x: 0.2), timestamp: 0)
        recognizer.processTouches(pair(x: 0.5), timestamp: 0.01)
        recognizer.processTouches(pair(x: 0.25), timestamp: 0.02)
        recognizer.processTouches([ActiveTouch(identifier: 1, state: 4, normalizedX: 1, normalizedY: 1)], timestamp: 0.03)
        recognizer.processTouches([], timestamp: 0.04)
        XCTAssertEqual(captured?.direction, .right)
        XCTAssertEqual(captured!.distance, 0.3, accuracy: 0.0001)
    }

    func testFourFingerSpreadUsesSpreadDistance() {
        let recognizer = GestureRecognizer()
        var captured: GestureEvent?
        recognizer.onGesture = { captured = $0; return true }
        func square(_ radius: CGFloat) -> [ActiveTouch] {
            [(-1.0, -1.0), (-1.0, 1.0), (1.0, -1.0), (1.0, 1.0)].enumerated().map { index, point in
                ActiveTouch(identifier: index, state: 4, normalizedX: 0.5 + CGFloat(point.0) * radius, normalizedY: 0.5 + CGFloat(point.1) * radius)
            }
        }
        for frame in 0...5 { recognizer.processTouches(square(0.1), timestamp: Double(frame) * 0.005) }
        recognizer.processTouches(square(0.2), timestamp: 0.05)
        recognizer.processTouches([], timestamp: 0.1)
        XCTAssertEqual(captured?.direction, .spread)
        XCTAssertEqual(captured!.distance, sqrt(2) * 0.1, accuracy: 0.0001)
    }

    func testInvalidFrameDoesNotEndAnActiveGesture() {
        let recognizer = GestureRecognizer()
        recognizer.liveTriggerDistance = 1
        var count = 0
        recognizer.onGesture = { _ in count += 1; return true }
        recognizer.processTouches(pair(x: 0.2), timestamp: 0)
        recognizer.processTouches(pair(x: 0.5), timestamp: 0.01)
        recognizer.processTouches([], timestamp: .nan)
        XCTAssertEqual(count, 0)
        recognizer.processTouches([], timestamp: 0.02)
        XCTAssertEqual(count, 1)
    }
}

extension GestureRecognizerTests {
    func testReplacingFingerRebasesInsteadOfCreatingFalseSwipe() {
        let recognizer = GestureRecognizer()
        var count = 0
        recognizer.onGesture = { _ in count += 1; return true }
        recognizer.processTouches(pair(x: 0.2), timestamp: 0)
        recognizer.processTouches([ActiveTouch(identifier: 1, state: 4, normalizedX: 0.2, normalizedY: 0.5)], timestamp: 0.01)
        recognizer.processTouches([
            ActiveTouch(identifier: 1, state: 4, normalizedX: 0.2, normalizedY: 0.5),
            ActiveTouch(identifier: 3, state: 4, normalizedX: 0.8, normalizedY: 0.5)
        ], timestamp: 0.02)
        recognizer.processTouches([], timestamp: 0.03)
        XCTAssertEqual(count, 0)
    }
}

final class AnchoredPinchTests: XCTestCase {
    private func contacts(fingers: Int, scale: CGFloat, translation: CGFloat = 0) -> [ActiveTouch] {
        let points: [CGPoint] = [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.4, y: 0.7),
                                CGPoint(x: 0.6, y: 0.8), CGPoint(x: 0.8, y: 0.7), CGPoint(x: 0.9, y: 0.5)]
        return points.prefix(fingers).enumerated().map { index, point in
            ActiveTouch(identifier: index + 1, state: 4,
                        normalizedX: 0.2 + (point.x - 0.2) * scale,
                        normalizedY: 0.2 + (point.y - 0.2) * scale + translation)
        }
    }

    func testFourAndFiveFingerPinchWithStationaryThumb() {
        for fingers in [4, 5] {
            let recognizer = GestureRecognizer()
            var events = [GestureEvent]()
            recognizer.onGesture = { event in
                guard event.distance >= 0.06 else { return false }
                events.append(event); return true
            }
            recognizer.processTouches(contacts(fingers: fingers, scale: 1), timestamp: 0)
            for step in 1...20 {
                recognizer.processTouches(contacts(fingers: fingers, scale: 1 - CGFloat(step) * 0.03), timestamp: Double(step) * 0.01)
            }
            recognizer.processTouches([], timestamp: 0.3)
            XCTAssertEqual(events.map(\.direction), [.pinch])
            XCTAssertEqual(events.first?.fingers, fingers)
        }
    }

    func testFourAndFiveFingerSpreadWithStationaryThumb() {
        for fingers in [4, 5] {
            let recognizer = GestureRecognizer()
            var events = [GestureEvent]()
            recognizer.onGesture = { event in
                guard event.distance >= 0.06 else { return false }
                events.append(event); return true
            }
            recognizer.processTouches(contacts(fingers: fingers, scale: 0.4), timestamp: 0)
            for step in 1...20 {
                recognizer.processTouches(contacts(fingers: fingers, scale: 0.4 + CGFloat(step) * 0.03), timestamp: Double(step) * 0.01)
            }
            recognizer.processTouches([], timestamp: 0.3)
            XCTAssertEqual(events.map(\.direction), [.spread])
            XCTAssertEqual(events.first?.fingers, fingers)
        }
    }

    func testSharedTranslationRemainsSwipe() {
        let recognizer = GestureRecognizer()
        var events = [GestureEvent]()
        recognizer.onGesture = { events.append($0); return true }
        recognizer.processTouches(contacts(fingers: 4, scale: 0.5), timestamp: 0)
        for step in 1...20 {
            recognizer.processTouches(contacts(fingers: 4, scale: 0.5, translation: CGFloat(step) * 0.01), timestamp: Double(step) * 0.01)
        }
        recognizer.processTouches([], timestamp: 0.3)
        XCTAssertEqual(events.map(\.direction), [.up])
    }
}

final class CapturedPinchRegressionTests: XCTestCase {
    // 本机 2026-10-01 实测触点的起止位置；所有手指均移动，中心点也偏移。
    func testAsymmetricFourAndFiveFingerPinchAndSpread() {
        let samples: [([CGPoint], [CGPoint], GestureDirection)] = [
            ([CGPoint(x: 0.385109, y: 0.803938), CGPoint(x: 0.553266, y: 0.914038), CGPoint(x: 0.683774, y: 0.884290), CGPoint(x: 0.308904, y: 0.197332)],
             [CGPoint(x: 0.341563, y: 0.562884), CGPoint(x: 0.484707, y: 0.565636), CGPoint(x: 0.608087, y: 0.537900), CGPoint(x: 0.415241, y: 0.341414)], .pinch),
            ([CGPoint(x: 0.614373, y: 0.591361), CGPoint(x: 0.366965, y: 0.606818), CGPoint(x: 0.504342, y: 0.604700), CGPoint(x: 0.412131, y: 0.346496)],
             [CGPoint(x: 0.767561, y: 0.958924), CGPoint(x: 0.442846, y: 0.896782), CGPoint(x: 0.629860, y: 0.991001), CGPoint(x: 0.250454, y: 0.124285)], .spread),
            ([CGPoint(x: 0.656104, y: 0.918484), CGPoint(x: 0.196280, y: 0.133072), CGPoint(x: 0.526374, y: 0.955007), CGPoint(x: 0.804368, y: 0.755029), CGPoint(x: 0.349857, y: 0.837286)],
             [CGPoint(x: 0.573613, y: 0.607135), CGPoint(x: 0.334629, y: 0.331569), CGPoint(x: 0.450168, y: 0.627673), CGPoint(x: 0.683320, y: 0.543193), CGPoint(x: 0.311366, y: 0.565954)], .pinch),
            ([CGPoint(x: 0.571864, y: 0.617192), CGPoint(x: 0.308774, y: 0.322465), CGPoint(x: 0.449067, y: 0.648740), CGPoint(x: 0.679368, y: 0.553779), CGPoint(x: 0.317781, y: 0.597290)],
             [CGPoint(x: 0.676452, y: 0.948550), CGPoint(x: 0.153642, y: 0.036206), CGPoint(x: 0.542379, y: 0.979568), CGPoint(x: 0.846099, y: 0.750688), CGPoint(x: 0.357050, y: 0.865763)], .spread),
        ]
        for (start, end, direction) in samples {
            let recognizer = GestureRecognizer()
            var events = [GestureEvent]()
            recognizer.onGesture = { event in
                guard event.distance >= 0.06 else { return false }
                events.append(event); return true
            }
            for step in 0...40 {
                let fraction = CGFloat(step) / 40
                let contacts = start.enumerated().map { index, point in
                    ActiveTouch(identifier: index + 1, state: 4,
                                normalizedX: point.x + (end[index].x - point.x) * fraction,
                                normalizedY: point.y + (end[index].y - point.y) * fraction)
                }
                recognizer.processTouches(contacts, timestamp: Double(step) * 0.01)
            }
            recognizer.processTouches([], timestamp: 0.5)
            XCTAssertEqual(events.map(\.direction), [direction])
            XCTAssertEqual(events.first?.fingers, start.count)
        }
    }
}
