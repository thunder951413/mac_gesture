import XCTest
import CoreGraphics
import GestureTouchCore
@testable import GestureDaemon

final class PalmRejectionTests: XCTestCase {
    private func finger(_ id: Int, x: CGFloat, y: CGFloat = 0.5,
                        major: CGFloat = 8, minor: CGFloat = 7, size: CGFloat = 0.5,
                        state: Int = 4) -> ActiveTouch {
        ActiveTouch(identifier: id, state: state, normalizedX: x, normalizedY: y,
                    majorAxis: major, minorAxis: minor, contactSize: size)
    }

    private func palm(x: CGFloat = 0.96, major: CGFloat = 21,
                      minor: CGFloat = 12, size: CGFloat = 4) -> ActiveTouch {
        finger(9, x: x, y: 0.12, major: major, minor: minor, size: size)
    }

    func testPalmAndTwoMovingFingersProduceTwoFingerGesturesWhilePalmRemains() {
        let recognizer = GestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0); return true }
        recognizer.processTouches([palm()], timestamp: 0)
        for gesture in 0..<2 {
            let base = Double(gesture) + 0.1
            for frame in 0..<12 {
                let x = 0.3 + CGFloat(max(0, frame - 3)) * 0.015
                recognizer.processTouches([palm(), finger(1, x: x), finger(2, x: x + 0.1)],
                                          timestamp: base + Double(frame) * 0.01)
            }
            // 掌缘仍贴着，真实手指全部抬起应结束手势、保留过滤状态。
            recognizer.processTouches([palm(major: 8, minor: 7, size: 0.2)], timestamp: base + 0.2)
            XCTAssertEqual(recognizer.acceptedTouchCount, 0)
            XCTAssertEqual(recognizer.rejectedPalmCount, 1)
        }
        XCTAssertEqual(events.map(\.fingers), [2, 2])
        XCTAssertEqual(events.map(\.direction), [.right, .right])
    }

    func testLatePalmClassificationDiscardsPreviouslyConfirmedThreeFingerCount() {
        let recognizer = GestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0); return true }
        for frame in 0..<5 {
            recognizer.processTouches([palm(major: 8, minor: 7, size: 0.5),
                                      finger(1, x: 0.3), finger(2, x: 0.4)],
                                     timestamp: Double(frame) * 0.01)
        }
        for frame in 5..<20 {
            let x = 0.3 + CGFloat(max(0, frame - 8)) * 0.015
            recognizer.processTouches([palm(), finger(1, x: x), finger(2, x: x + 0.1)],
                                     timestamp: Double(frame) * 0.01)
        }
        recognizer.processTouches([], timestamp: 0.3)
        XCTAssertEqual(events.map(\.fingers), [2])
    }

    func testBroadPalmDoesNotRequireStartingAtEdgeAndDeviceUnitsCanScale() {
        for scale: CGFloat in [0.01, 1, 100] {
            var filter = PalmRejectionFilter()
            let touches = [finger(1, x: 0.3, major: 8 * scale, minor: 7 * scale, size: 0.5 * scale),
                           finger(2, x: 0.4, major: 8 * scale, minor: 7 * scale, size: 0.5 * scale),
                           palm(x: 0.7, major: 21 * scale, minor: 12 * scale, size: 4 * scale)]
            _ = filter.filter(touches, timestamp: 0)
            XCTAssertEqual(filter.filter(touches, timestamp: 0.01).map(\.identifier), [1, 2])
        }
    }

    func testOneDistortedFrameDoesNotLatchNormalFingerAsPalm() {
        var filter = PalmRejectionFilter()
        let normal = [finger(1, x: 0.3), finger(2, x: 0.4), finger(9, x: 0.5)]
        _ = filter.filter(Array(normal.prefix(2)) + [palm()], timestamp: 0)
        XCTAssertEqual(filter.filter(normal, timestamp: 0.01).count, 3)
        XCTAssertEqual(filter.filter(normal, timestamp: 0.02).count, 3)
    }

    func testPartialRestingPalmIsRejectedWithoutRemovingMovingThumb() {
        for edge in [true, false] {
            var filter = PalmRejectionFilter()
            for frame in 0..<12 {
                let movement = CGFloat(frame) * 0.01
                let touches = [finger(1, x: 0.3 + movement), finger(2, x: 0.4 + movement),
                               palm(x: edge ? 0.96 : 0.7, major: 21, minor: 8, size: 2)]
                let accepted = filter.filter(touches, timestamp: Double(frame) * 0.01)
                if frame == 11 { XCTAssertEqual(accepted.count, 2) }
            }
        }
        var filter = PalmRejectionFilter()
        for frame in 0..<12 {
            let movement = CGFloat(frame) * 0.01
            let touches = [finger(1, x: 0.3 + movement), finger(2, x: 0.4 + movement),
                           finger(9, x: 0.6 + movement, y: 0.3, major: 21, minor: 8, size: 2)]
            XCTAssertEqual(filter.filter(touches, timestamp: Double(frame) * 0.01).count, 3)
        }
    }

    func testNormalThreeFingersAndEdgeThumbRemainAccepted() {
        var filter = PalmRejectionFilter()
        for frame in 0..<12 {
            let movement = CGFloat(frame) * 0.01
            let touches = [finger(1, x: 0.3 + movement), finger(2, x: 0.4 + movement),
                           finger(3, x: 0.5 + movement)]
            XCTAssertEqual(filter.filter(touches, timestamp: Double(frame) * 0.01).count, 3)
        }
        filter.reset()
        for frame in 0..<12 {
            let touches = [finger(1, x: 0.3), finger(2, x: 0.4), finger(3, x: 0.5),
                           finger(4, x: 0.48, y: 0.02, major: 15, minor: 7.5, size: 1)]
            XCTAssertEqual(filter.filter(touches, timestamp: Double(frame) * 0.01).count, 4,
                           "自然捏合中静止的边缘拇指也必须保留")
        }
    }

    func testSplitPalmContactsAreBothRejected() {
        let recognizer = GestureRecognizer()
        var events: [GestureEvent] = []
        recognizer.onGesture = { events.append($0); return true }
        for frame in 0..<16 {
            let movement = CGFloat(max(0, frame - 4)) * 0.01
            let contacts = [palm(), finger(1, x: 0.3 + movement), finger(2, x: 0.4 + movement),
                            finger(8, x: 0.6, y: 0.2 + movement / 2,
                                   major: 21, minor: 9, size: 1.8)]
            recognizer.processTouches(contacts, timestamp: Double(frame) * 0.01)
        }
        XCTAssertEqual(recognizer.rejectedPalmCount, 2)
        recognizer.processTouches([], timestamp: 0.2)
        XCTAssertEqual(events.map(\.fingers), [2])
    }

    func testPalmLabelClearsOnRawLiftResetOrReusedContactLifecycle() {
        for ending in 0..<3 {
            var filter = PalmRejectionFilter()
            let touches = [finger(1, x: 0.3), finger(2, x: 0.4), palm()]
            _ = filter.filter(touches, timestamp: 0)
            XCTAssertEqual(filter.filter(touches, timestamp: 0.01).count, 2)
            if ending == 0 { _ = filter.filter([], timestamp: 0.02) }
            else if ending == 1 { filter.reset() }
            else { _ = filter.filter([finger(9, x: 0.96, state: 7)], timestamp: 0.02) }
            let next = [finger(1, x: 0.3), finger(2, x: 0.4), finger(9, x: 0.5, state: 1)]
            XCTAssertEqual(filter.filter(next, timestamp: 0.03).count, 3)
        }
    }

    func testMissingShapeMetricsPreserveLegacyProtocol() {
        var filter = PalmRejectionFilter()
        let touches = (1...3).map {
            ActiveTouch(identifier: $0, state: 4, normalizedX: CGFloat($0) / 4, normalizedY: 0.5)
        }
        for frame in 0..<10 {
            XCTAssertEqual(filter.filter(touches, timestamp: Double(frame) * 0.01).count, 3)
        }
    }
}
