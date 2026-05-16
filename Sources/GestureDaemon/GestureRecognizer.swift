import Foundation
import CoreGraphics

struct GestureEvent {
    let fingers: Int
    let direction: GestureDirection
    let distance: CGFloat
    let dx: CGFloat
    let dy: CGFloat
}

final class GestureRecognizer {
    private var activeTouches: [Int: ActiveTouch] = [:]
    private var gestureStartCentroid: CGPoint?
    private var currentCentroid: CGPoint = .zero
    private var maxFingersSeen = 0
    private var gestureFingers = 0
    private var startSpread: CGFloat = 0
    private var endSpread: CGFloat = 0
    private var didTriggerCurrentGesture = false

    var onGesture: ((GestureEvent) -> Bool)?
    var logLevel: String = "info"
    var diagonalRejectRatio: Double = 0.95
    var downBiasRatio: Double = 0.35
    var liveTriggerDistance: CGFloat = 0.06

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
            evaluateGesture(fingers: gestureFingers > 0 ? gestureFingers : maxFingersSeen)
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

        if nowCount > gestureFingers && !didTriggerCurrentGesture {
            gestureFingers = nowCount
            gestureStartCentroid = currentCentroid
            startSpread = calculateSpread()
        }

        endSpread = calculateSpread()

        if !didTriggerCurrentGesture,
           let event = recognizeGesture(fingers: gestureFingers, logDiagnostics: false),
           event.distance >= liveTriggerDistance {
            didTriggerCurrentGesture = onGesture?(event) == true
        }
    }

    private func evaluateGesture(fingers: Int) {
        guard !didTriggerCurrentGesture,
              let event = recognizeGesture(fingers: fingers, logDiagnostics: true) else { return }

        didTriggerCurrentGesture = onGesture?(event) == true
    }

    private func recognizeGesture(fingers: Int, logDiagnostics: Bool) -> GestureEvent? {
        guard fingers >= 2, let start = gestureStartCentroid else { return nil }

        let dx = currentCentroid.x - start.x
        let dy = currentCentroid.y - start.y
        let totalDistance = sqrt(dx * dx + dy * dy)

        let spreadDelta = endSpread - startSpread
        let spreadSignificant = abs(spreadDelta) > 0.03

        var direction: GestureDirection
        if fingers >= 4 && spreadSignificant && abs(spreadDelta) > totalDistance * 2 {
            direction = spreadDelta > 0 ? .spread : .pinch
        } else if totalDistance > 0.01 {
            let absDx = abs(dx)
            let absDy = abs(dy)
            let minor = min(absDx, absDy)
            let major = max(absDx, absDy)

            if major > 0 && minor >= major * CGFloat(diagonalRejectRatio) {
                if logDiagnostics && fingers == 3 {
                    fputs("[三指诊断] 对角线忽略 | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 次轴/主轴=\(String(format: "%.2f", minor/major)) 需<\(String(format: "%.2f", diagonalRejectRatio)) | 距离=\(String(format: "%.3f", totalDistance))\n", stderr)
                }
                return nil
            }

            if absDx > absDy {
                direction = dx > 0 ? .right : .left
            } else {
                direction = dy > 0 ? .up : .down
            }

            if (direction == .left || direction == .right) && dy < 0 && absDy > absDx * CGFloat(downBiasRatio) && absDy > 0.08 {
                direction = .down
                if logDiagnostics && fingers == 3 {
                    fputs("[三指诊断] 下偏修正: left/right→down | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) |dy|/|dx|=\(String(format: "%.2f", absDx > 0 ? absDy/absDx : 0)) ≥\(String(format: "%.2f", downBiasRatio))\n", stderr)
                }
            }
        } else {
            if logDiagnostics && fingers == 3 {
                fputs("[三指诊断] 距离太短忽略 | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 距离=\(String(format: "%.4f", totalDistance)) 需>0.01\n", stderr)
            }
            return nil
        }

        if logDiagnostics && fingers == 3 {
            fputs("[三指诊断] 识别为 \(direction) | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 距离=\(String(format: "%.3f", totalDistance))\n", stderr)
        }

        if logDiagnostics && logLevel == "debug" {
            fputs("[Gesture] \(fingers)指 \(direction) 距离:\(String(format: "%.3f", totalDistance))\n", stderr)
        }

        return GestureEvent(fingers: fingers, direction: direction, distance: totalDistance, dx: dx, dy: dy)
    }

    private func reset() {
        activeTouches.removeAll()
        gestureStartCentroid = nil
        currentCentroid = .zero
        startSpread = 0
        endSpread = 0
        maxFingersSeen = 0
        gestureFingers = 0
        didTriggerCurrentGesture = false
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
