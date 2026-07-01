import Foundation
import CoreGraphics

struct GestureEvent {
    let fingers: Int
    let direction: GestureDirection
    let distance: CGFloat
    let dx: CGFloat
    let dy: CGFloat
}

/// 手势识别调优参数（由 Config 注入，魔法数字集中于此）。
struct GestureTuning {
    var diagonalRejectRatio: CGFloat = 0.95
    var downBiasRatio: CGFloat = 0.35
    var spreadThreshold: CGFloat = 0.03          // 捏合/张开最小 spread 变化量
    var minSwipeDistance: CGFloat = 0.01         // 滑动最小识别距离
    var downBiasMinAbsDy: CGFloat = 0.08         // 下偏修正触发的最小 |dy|
    var spreadToDistanceRatio: CGFloat = 2.0     // spread 判定优先于距离的倍数
    var liveTriggerDistance: CGFloat = 0.06      // 实时触发距离（手指未抬起时）
    var extraFingerConfirmFrames: Int = 3
    var extraFingerConfirmDuration: Double = 0.018
    var logLevel: String = "info"
}

final class GestureRecognizer {
    private var activeTouches: [Int: ActiveTouch] = [:]
    private var gestureStartCentroid: CGPoint?
    private var currentCentroid: CGPoint = .zero
    private var maxGestureDx: CGFloat = 0
    private var maxGestureDy: CGFloat = 0
    private var maxGestureDistance: CGFloat = 0
    private var maxFingersSeen = 0
    private var gestureFingers = 0
    private var startSpread: CGFloat = 0
    private var endSpread: CGFloat = 0
    private var didTriggerCurrentGesture = false
    private var lastObservedFingerCount = 0
    private var lastObservedFingerTimestamp: Double = 0
    private var observedFingerFrames = 0

    var onGesture: ((GestureEvent) -> Bool)?
    var tuning = GestureTuning()

    /// 兼容旧接口：逐字段 setter，由 GestureDaemon 从 Config 注入
    var logLevel: String {
        get { tuning.logLevel }
        set { tuning.logLevel = newValue }
    }
    var diagonalRejectRatio: Double {
        get { Double(tuning.diagonalRejectRatio) }
        set { tuning.diagonalRejectRatio = CGFloat(newValue) }
    }
    var downBiasRatio: Double {
        get { Double(tuning.downBiasRatio) }
        set { tuning.downBiasRatio = CGFloat(newValue) }
    }
    var liveTriggerDistance: CGFloat {
        get { tuning.liveTriggerDistance }
        set { tuning.liveTriggerDistance = newValue }
    }

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
        updateObservedFingerCount(nowCount, timestamp: timestamp)
        let effectiveCount = effectiveFingerCount(for: nowCount, timestamp: timestamp)
        maxFingersSeen = max(maxFingersSeen, effectiveCount)

        if nowCount == 0 && prevCount > 0 {
            evaluateGesture(fingers: gestureFingers > 0 ? gestureFingers : maxFingersSeen)
            reset()
            return
        }

        guard effectiveCount >= 2 else {
            if nowCount == 0 { reset() }
            return
        }

        if gestureFingers > 0 && nowCount < gestureFingers {
            if tuning.logLevel == "debug" {
                fputs("[Gesture] 手指部分抬起，冻结中心点 | 当前=\(nowCount) 指 期望=\(gestureFingers) 指\n", stderr)
            }
            return
        }

        updateCentroid()

        if gestureStartCentroid == nil {
            gestureStartCentroid = currentCentroid
            startSpread = calculateSpread()
            resetMaxGestureDisplacement()
        }

        if effectiveCount > gestureFingers && !didTriggerCurrentGesture {
            gestureFingers = effectiveCount
            gestureStartCentroid = currentCentroid
            startSpread = calculateSpread()
            resetMaxGestureDisplacement()
        }

        updateMaxGestureDisplacement()
        endSpread = calculateSpread()

        if !didTriggerCurrentGesture,
           let event = recognizeGesture(fingers: gestureFingers, logDiagnostics: false),
           event.distance >= tuning.liveTriggerDistance {
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

        let currentDx = currentCentroid.x - start.x
        let currentDy = currentCentroid.y - start.y
        let currentDistance = sqrt(currentDx * currentDx + currentDy * currentDy)
        let dx = maxGestureDistance > currentDistance ? maxGestureDx : currentDx
        let dy = maxGestureDistance > currentDistance ? maxGestureDy : currentDy
        let totalDistance = max(maxGestureDistance, currentDistance)

        let spreadDelta = endSpread - startSpread
        let spreadSignificant = abs(spreadDelta) > tuning.spreadThreshold

        var direction: GestureDirection
        if fingers >= 4 && spreadSignificant && abs(spreadDelta) > totalDistance * tuning.spreadToDistanceRatio {
            direction = spreadDelta > 0 ? .spread : .pinch
        } else if totalDistance > tuning.minSwipeDistance {
            let absDx = abs(dx)
            let absDy = abs(dy)
            let minor = min(absDx, absDy)
            let major = max(absDx, absDy)

            if major > 0 && minor >= major * tuning.diagonalRejectRatio {
                if logDiagnostics {
                    fputs("[Gesture] \(fingers)指 对角线忽略 | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 次轴/主轴=\(String(format: "%.2f", minor/major)) 需<\(String(format: "%.2f", tuning.diagonalRejectRatio)) | 距离=\(String(format: "%.3f", totalDistance))\n", stderr)
                }
                return nil
            }

            if absDx > absDy {
                direction = dx > 0 ? .right : .left
            } else {
                direction = dy > 0 ? .up : .down
            }

            // 下偏修正：左右滑动中若伴随明显向下分量，修正为 down，
            // 解决三指下滑易被判成 left/right 的误判。
            if (direction == .left || direction == .right) && dy < 0
                && absDy > absDx * tuning.downBiasRatio
                && absDy > tuning.downBiasMinAbsDy {
                direction = .down
                if logDiagnostics {
                    fputs("[Gesture] \(fingers)指 下偏修正: left/right→down | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) |dy|/|dx|=\(String(format: "%.2f", absDx > 0 ? absDy/absDx : 0)) ≥\(String(format: "%.2f", tuning.downBiasRatio))\n", stderr)
                }
            }
        } else {
            if logDiagnostics {
                fputs("[Gesture] \(fingers)指 距离太短忽略 | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 距离=\(String(format: "%.4f", totalDistance)) 需>\(String(format: "%.4f", tuning.minSwipeDistance))\n", stderr)
            }
            return nil
        }

        if logDiagnostics {
            fputs("[Gesture] \(fingers)指 识别为 \(direction) | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 距离=\(String(format: "%.3f", totalDistance))\n", stderr)
        }

        if logDiagnostics && tuning.logLevel == "debug" {
            fputs("[Gesture] \(fingers)指 \(direction) 距离:\(String(format: "%.3f", totalDistance))\n", stderr)
        }

        return GestureEvent(fingers: fingers, direction: direction, distance: totalDistance, dx: dx, dy: dy)
    }

    private func reset() {
        activeTouches.removeAll()
        gestureStartCentroid = nil
        currentCentroid = .zero
        resetMaxGestureDisplacement()
        startSpread = 0
        endSpread = 0
        maxFingersSeen = 0
        gestureFingers = 0
        didTriggerCurrentGesture = false
        lastObservedFingerCount = 0
        lastObservedFingerTimestamp = 0
        observedFingerFrames = 0
    }

    private func updateObservedFingerCount(_ count: Int, timestamp: Double) {
        if count == lastObservedFingerCount {
            observedFingerFrames += 1
            return
        }
        lastObservedFingerCount = count
        lastObservedFingerTimestamp = timestamp
        observedFingerFrames = 1
    }

    private func effectiveFingerCount(for observedCount: Int, timestamp: Double) -> Int {
        guard observedCount >= 3 else { return observedCount }

        let stableDuration = timestamp - lastObservedFingerTimestamp
        let isStable = observedFingerFrames >= tuning.extraFingerConfirmFrames
            && stableDuration >= tuning.extraFingerConfirmDuration
        if isStable {
            return observedCount
        }

        if tuning.logLevel == "debug" {
            fputs("[Gesture] 忽略瞬时第\(observedCount)指 | 帧数=\(observedFingerFrames) 时长=\(String(format: "%.4f", stableDuration))\n", stderr)
        }

        if gestureFingers >= 2 {
            return gestureFingers
        }
        return 0
    }

    private func updateCentroid() {
        guard !activeTouches.isEmpty else { return }
        let sum = activeTouches.values.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.normalizedX, y: $0.y + $1.normalizedY)
        }
        let n = CGFloat(activeTouches.count)
        currentCentroid = CGPoint(x: sum.x / n, y: sum.y / n)
    }

    private func updateMaxGestureDisplacement() {
        guard let start = gestureStartCentroid else { return }
        let dx = currentCentroid.x - start.x
        let dy = currentCentroid.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        if distance > maxGestureDistance {
            maxGestureDx = dx
            maxGestureDy = dy
            maxGestureDistance = distance
        }
    }

    private func resetMaxGestureDisplacement() {
        maxGestureDx = 0
        maxGestureDy = 0
        maxGestureDistance = 0
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
