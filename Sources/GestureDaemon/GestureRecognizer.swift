import Foundation
import CoreGraphics

struct GestureEvent {
    let fingers: Int
    let direction: GestureDirection
    let distance: CGFloat
}

final class GestureRecognizer {
    private var activeTouches: [Int: ActiveTouch] = [:]
    private var gestureStartCentroid: CGPoint?
    private var currentCentroid: CGPoint = .zero
    private var maxFingersSeen = 0
    private var startSpread: CGFloat = 0
    private var endSpread: CGFloat = 0

    var onGesture: ((GestureEvent) -> Void)?
    var logLevel: String = "info"

    func processTouches(_ touches: [ActiveTouch], timestamp: Double) {
        let activeSet = Set(touches.map { $0.identifier })
        let prevCount = activeTouches.count

        // Remove released touches, keep only still-active ones
        activeTouches = activeTouches.filter { activeSet.contains($0.key) }
        // Add/update current touches
        for t in touches {
            activeTouches[t.identifier] = t
        }

        let nowCount = activeTouches.count
        maxFingersSeen = max(maxFingersSeen, nowCount)

        if nowCount == 0 && prevCount > 0 {
            evaluateGesture()
            reset()
            return
        }

        guard nowCount >= 2 else {
            if nowCount == 0 { reset() }
            return
        }

        updateCentroid()

        if gestureStartCentroid == nil {
            gestureStartCentroid = currentCentroid
            startSpread = calculateSpread()
        }

        endSpread = calculateSpread()
    }

    private func evaluateGesture() {
        let fingers = maxFingersSeen
        guard fingers >= 2, let start = gestureStartCentroid else { return }

        let dx = currentCentroid.x - start.x
        let dy = currentCentroid.y - start.y
        let totalDistance = sqrt(dx * dx + dy * dy)

        let spreadDelta = endSpread - startSpread
        let spreadSignificant = abs(spreadDelta) > 0.03

        var direction: GestureDirection
        if fingers >= 4 && spreadSignificant && abs(spreadDelta) > totalDistance * 2 {
            direction = spreadDelta > 0 ? .spread : .pinch
        } else if totalDistance > 0.015 {
            if abs(dx) > abs(dy) {
                direction = dx > 0 ? .right : .left
            } else {
                direction = dy > 0 ? .down : .up
            }
        } else {
            return
        }

        if logLevel == "debug" {
            fputs("[Gesture] \(fingers)指 \(direction) 距离:\(String(format: "%.3f", totalDistance))\n", stderr)
        }

        onGesture?(GestureEvent(fingers: fingers, direction: direction, distance: totalDistance))
    }

    private func reset() {
        activeTouches.removeAll()
        gestureStartCentroid = nil
        currentCentroid = .zero
        startSpread = 0
        endSpread = 0
        maxFingersSeen = 0
    }

    private func updateCentroid() {
        guard !activeTouches.isEmpty else { return }
        let sum = activeTouches.values.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.normalizedX, y: $0.y + $1.normalizedY)
        }
        let n = CGFloat(activeTouches.count)
        currentCentroid = CGPoint(x: sum.x / n, y: sum.y / n)
    }

    private func calculateSpread() -> CGFloat {
        guard activeTouches.count >= 2 else { return 0 }
        let values = Array(activeTouches.values)
        let c = currentCentroid
        var total: CGFloat = 0
        for t in values {
            let dx = t.normalizedX - c.x
            let dy = t.normalizedY - c.y
            total += sqrt(dx * dx + dy * dy)
        }
        return total / CGFloat(values.count)
    }
}
