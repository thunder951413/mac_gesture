import XCTest
import CoreGraphics
import GestureTouchCore
@testable import GestureDaemon

final class SwipeGuardTests: XCTestCase {
    private func touches(movement: CGFloat, thirdFraction: CGFloat = 1,
                         thirdState: Int = 4) -> [ActiveTouch] {
        [ActiveTouch(identifier: 1, state: 4, normalizedX: 0.3, normalizedY: 0.8 - movement),
         ActiveTouch(identifier: 2, state: 4, normalizedX: 0.4, normalizedY: 0.8 - movement),
         ActiveTouch(identifier: 3, state: thirdState, normalizedX: 0.5,
                     normalizedY: 0.8 - movement * thirdFraction,
                     majorAxis: 9, minorAxis: 7, contactSize: 0.5)]
    }

    func testFingerSizedPalmThatDoesNotMoveCannotTriggerThreeFingerSwipe() {
        for thirdFraction: CGFloat in [0, 0.1, 0.3, -0.5] {
            let recognizer = GestureRecognizer()
            var events: [GestureEvent] = []
            var traces: [GestureTrace] = []
            recognizer.onGesture = { events.append($0); return true }
            recognizer.onTrace = { traces.append($0) }
            for frame in 0..<30 {
                let movement = CGFloat(max(0, frame - 4)) * 0.01
                recognizer.processTouches(touches(movement: movement, thirdFraction: thirdFraction),
                                          timestamp: Double(frame) * 0.01)
            }
            // 抬起后的坐标突变不能补造第三根手指的滑动证据。
            recognizer.processTouches(touches(movement: 0.4, thirdState: 5), timestamp: 0.31)
            recognizer.processTouches([], timestamp: 0.32)
            XCTAssertTrue(events.isEmpty, "thirdFraction=\(thirdFraction)")
            XCTAssertEqual(traces.filter { $0.decision == .rejectedIncoherentSwipe }.count, 1)
            XCTAssertEqual(traces.first?.motions.count, 3)
            XCTAssertFalse(traces.first?.frames.isEmpty ?? true)
        }
    }

    func testUnevenButSharedThreeFingerSwipeRemainsValid() {
        let recognizer = GestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0); return true }
        for frame in 0..<20 {
            recognizer.processTouches(touches(movement: CGFloat(max(0, frame - 4)) * 0.01,
                                              thirdFraction: 0.7), timestamp: Double(frame) * 0.01)
        }
        recognizer.processTouches([], timestamp: 0.21)
        XCTAssertEqual(events.map(\.fingers), [3])
        XCTAssertEqual(events.map(\.direction), [.down])
    }

    func testThreeFingerPeakRemainsValidAfterReturnAndPartialLift() {
        let recognizer = GestureRecognizer()
        recognizer.liveTriggerDistance = 1
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0); return true }
        for frame in 0...4 { recognizer.processTouches(touches(movement: 0), timestamp: Double(frame) * 0.01) }
        recognizer.processTouches(touches(movement: 0.2), timestamp: 0.05)
        recognizer.processTouches(touches(movement: 0.02), timestamp: 0.06)
        recognizer.processTouches(Array(touches(movement: 0.4).prefix(2)), timestamp: 0.07)
        recognizer.processTouches([], timestamp: 0.08)
        XCTAssertEqual(events.map(\.fingers), [3])
        XCTAssertEqual(events.first!.distance, 0.2, accuracy: 0.00001)
    }

    func testLateContactCannotUpgradeAnAlreadyMovingTwoFingerScroll() {
        let recognizer = GestureRecognizer()
        var threeFingerActions = 0
        var traces: [GestureTrace] = []
        recognizer.onTrace = { traces.append($0) }
        recognizer.onGesture = { event in
            guard event.fingers == 3 && event.distance >= 0.08 else { return false }
            threeFingerActions += 1
            return true
        }
        for frame in 0..<30 {
            let movement = CGFloat(frame) * 0.01
            let all = touches(movement: movement)
            recognizer.processTouches(frame < 12 ? Array(all.prefix(2)) : all,
                                      timestamp: Double(frame) * 0.01)
            if frame >= 12 { XCTAssertEqual(recognizer.acceptedTouchCount, 2) }
        }
        recognizer.processTouches([], timestamp: 0.31)
        XCTAssertEqual(threeFingerActions, 0)
        XCTAssertEqual(traces.filter { $0.decision == .ignoredLateContact }.count, 1)
    }

    func testInitialStaggeredThirdFingerAndNextGestureAreStillAccepted() {
        let recognizer = GestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0); return true }
        for gesture in 0..<2 {
            let base = Double(gesture)
            for frame in 0..<20 {
                let all = touches(movement: CGFloat(max(0, frame - 6)) * 0.01)
                recognizer.processTouches(frame < 3 ? Array(all.prefix(2)) : all,
                                          timestamp: base + Double(frame) * 0.01)
            }
            recognizer.processTouches([], timestamp: base + 0.21)
        }
        XCTAssertEqual(events.map(\.fingers), [3, 3])
    }

    func testHoverAndLingeringContactsDoNotCountAsThirdFinger() {
        for state in [0, 1, 2, 5, 6, 7] {
            let recognizer = GestureRecognizer()
            var events: [GestureEvent] = []
            recognizer.onGesture = { events.append($0); return true }
            for frame in 0..<20 {
                recognizer.processTouches(touches(movement: CGFloat(frame) * 0.01, thirdState: state),
                                          timestamp: Double(frame) * 0.01)
            }
            recognizer.processTouches([], timestamp: 0.21)
            XCTAssertEqual(events.map(\.fingers), [2], "state=\(state)")
        }
    }
}
