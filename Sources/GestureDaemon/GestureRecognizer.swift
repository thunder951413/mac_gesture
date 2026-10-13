import Foundation
import CoreGraphics
import GestureTouchCore

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
    /// 手势已移动该距离并持续下列时长后固定手指组，之后新增的触点不计入。
    var lockMotionDistance: CGFloat = 0.03
    var twoFingerLockDelay: Double = 0.08
    /// 三指及以上落指常错开数十毫秒（五指捏合实测第五指晚 64 ms），窗口更宽。
    var multiFingerLockDelay: Double = 0.12
    /// 短暂擦碰：中途加入、存在时间短于此值即抬起的触点不应冻结原手势。
    var brushContactMaxDuration: Double = 0.15
    var brushContactMinJoinDelay: Double = 0.04
    /// 所有触点在该时长内移动都不超过容差时，以当前位置重新作为起点，
    /// 避免手搭在触控板上时缓慢漂移累积成一次滑动。
    var stillnessRebaseDuration: Double = 0.3
    var stillnessMotionTolerance: CGFloat = 0.01
    var logLevel: String = "info"
}

final class GestureRecognizer {
    private var palmFilter = PalmRejectionFilter()
    private var traceBuffer = GestureTraceBuffer()
    private var recordedRejectedSwipe = false
    private var recordedIgnoredLateTouch = false
    private var gestureBeganTimestamp: Double = 0
    private var lockedTouchIdentifiers: Set<Int>?
    private var currentGesturePositions: [Int: CGPoint] = [:]
    private var maxGesturePositions: [Int: CGPoint] = [:]
    private var maxSwipePositions: [Int: CGPoint] = [:]
    private var maxSwipeDx: CGFloat = 0
    private var maxSwipeDy: CGFloat = 0
    private var maxSwipeDistance: CGFloat = 0
    private(set) var acceptedTouchCount = 0
    private(set) var rejectedPalmCount = 0
    private var activeTouches: [Int: ActiveTouch] = [:]
    private var gestureStartCentroid: CGPoint?
    private var currentCentroid: CGPoint = .zero
    private var maxGestureDx: CGFloat = 0
    private var maxGestureDy: CGFloat = 0
    private var maxGestureDistance: CGFloat = 0
    private var maxFingersSeen = 0
    private var gestureFingers = 0
    private var gestureStartPositions: [Int: CGPoint] = [:]
    private var maxCoherentTranslationDistance: CGFloat = 0
    private var startSpread: CGFloat = 0
    private var endSpread: CGFloat = 0
    private var didTriggerCurrentGesture = false
    private var lastObservedFingerCount = 0
    private var lastObservedFingerTimestamp: Double = 0
    private var observedFingerFrames = 0
    private var gestureTouchIdentifiers = Set<Int>()
    /// 每个有效触点首次出现的时间（跨手势保留，触点抬起时移除）。
    private var contactFirstSeen: [Int: Double] = [:]
    private var stillnessAnchor: [Int: CGPoint] = [:]
    private var stillnessAnchorTimestamp: Double?

    var onGesture: ((GestureEvent) -> Bool)?
    var onTrace: ((GestureTrace) -> Void)?
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

    func processTouches(_ rawTouches: [ActiveTouch], timestamp: Double) {
        guard timestamp.isFinite, TouchFrameValidator.isValid(rawTouches) else { return }
        if onTrace != nil { traceBuffer.append(rawTouches, timestamp: timestamp) }
        let nonPalms = palmFilter.filter(rawTouches, timestamp: timestamp)
        let rejected = Set(rawTouches.map(\.identifier)).subtracting(nonPalms.map(\.identifier))
        var touches = nonPalms.filter(\.isTouching)
        // 已经持续移动的多指手势固定原手指组；中途贴上的掌缘或第三/四根手指
        // 不能把两指滚动升级为三指、把三指滑动升级为四指捏合。初始落指留出
        // 组合窗口（两指 80 ms，三指及以上 120 ms），尚未移动的手势仍可增加手指。
        let lockDelay = gestureFingers >= 3 ? tuning.multiFingerLockDelay : tuning.twoFingerLockDelay
        if lockedTouchIdentifiers == nil, gestureFingers >= 2,
           maxGestureDistance >= tuning.lockMotionDistance, timestamp - gestureBeganTimestamp >= lockDelay {
            lockedTouchIdentifiers = gestureTouchIdentifiers
        }
        if let lockedTouchIdentifiers {
            let previousCount = touches.count
            touches = touches.filter { lockedTouchIdentifiers.contains($0.identifier) }
            if previousCount > touches.count, !recordedIgnoredLateTouch {
                recordedIgnoredLateTouch = true
                let direction: GestureDirection = abs(maxGestureDx) > abs(maxGestureDy)
                    ? (maxGestureDx > 0 ? .right : .left) : (maxGestureDy > 0 ? .up : .down)
                emitTrace(decision: .ignoredLateContact,
                          event: GestureEvent(fingers: gestureFingers, direction: direction,
                                              distance: maxGestureDistance, dx: maxGestureDx, dy: maxGestureDy),
                          positions: currentGesturePositions)
            }
        }
        let activeSet = Set(touches.map { $0.identifier })
        let previousFirstSeen = contactFirstSeen
        contactFirstSeen = contactFirstSeen.filter { activeSet.contains($0.key) }
        for identifier in activeSet where contactFirstSeen[identifier] == nil {
            contactFirstSeen[identifier] = timestamp
        }
        // 掌缘被确认时移除它对指数量、中心点和位移的影响；真实手指已有
        // 起点时保留其轨迹，避免过滤较晚的掌缘吞掉正常两指滑动。
        // 已触发的手势不重置：否则剩余手指可在同一次接触中再次触发规则。
        if !didTriggerCurrentGesture, !rejected.isDisjoint(with: activeTouches.keys) {
            let origins = gestureStartPositions.filter { activeSet.contains($0.key) }
            if touches.count >= 2 && origins.count == touches.count {
                let count = CGFloat(origins.count)
                let origin = origins.values.reduce(CGPoint.zero) {
                    CGPoint(x: $0.x + $1.x / count, y: $0.y + $1.y / count)
                }
                gestureStartCentroid = origin
                gestureFingers = touches.count
                maxFingersSeen = touches.count
                gestureTouchIdentifiers = activeSet
                startSpread = origins.values.reduce(CGFloat.zero) {
                    $0 + hypot($1.x - origin.x, $1.y - origin.y) / count
                }
                resetMaxGestureDisplacement(startPositions: origins)
                stillnessAnchorTimestamp = nil
            } else {
                resetGesture()
            }
        }
        acceptedTouchCount = touches.count
        if tuning.logLevel == "debug", rejected.count > rejectedPalmCount {
            fputs("[Palm] 已过滤 \(rejected.count) 个掌缘触点，保留 \(touches.count) 个手指触点\n", stderr)
        }
        rejectedPalmCount = rejected.count
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
            resetGesture()
            return
        }

        guard effectiveCount >= 2 else {
            if nowCount == 0 { resetGesture() }
            return
        }

        // 尚未确认的新手指不能进入中心点计算，否则一次轻触就会产生虚假位移。
        guard nowCount <= effectiveCount else { return }

        if gestureFingers > 0 && nowCount < gestureFingers {
            // 中途擦过的掌缘/手指被确认后很快离开：回到剩余手指继续识别，
            // 不能把原本的三指滑动冻结成一次不会触发的“四指手势”。
            guard isBrushDeparture(activeSet: activeSet, previousFirstSeen: previousFirstSeen,
                                   timestamp: timestamp) else {
                if tuning.logLevel == "debug" {
                    fputs("[Gesture] 手指部分抬起，冻结中心点 | 当前=\(nowCount) 指 期望=\(gestureFingers) 指\n", stderr)
                }
                return
            }
            if tuning.logLevel == "debug" {
                fputs("[Gesture] 短暂擦碰的触点已离开，按剩余 \(nowCount) 指重新开始\n", stderr)
            }
        }

        updateCentroid()

        if gestureStartCentroid == nil {
            gestureBeganTimestamp = timestamp
            gestureStartCentroid = currentCentroid
            startSpread = calculateSpread()
            resetMaxGestureDisplacement()
            stillnessAnchorTimestamp = nil
        }

        if !didTriggerCurrentGesture && (effectiveCount > gestureFingers || activeSet != gestureTouchIdentifiers) {
            gestureBeganTimestamp = timestamp
            gestureFingers = effectiveCount
            gestureTouchIdentifiers = activeSet
            gestureStartCentroid = currentCentroid
            startSpread = calculateSpread()
            resetMaxGestureDisplacement()
            stillnessAnchorTimestamp = nil
        }

        rebaseIfResting(timestamp: timestamp)
        updateMaxGestureDisplacement()
        // 捏合可能伴随中心点移动；先用每个触点相对中心的位移估计
        // 形变，再比较剩余的共同平移。所有手指同向移动时形变接近零。
        if let start = gestureStartCentroid, !activeTouches.isEmpty {
            let dx = currentCentroid.x - start.x
            let dy = currentCentroid.y - start.y
            let squaredDeformation = activeTouches.values.reduce(CGFloat.zero) { total, touch in
                guard let origin = gestureStartPositions[touch.identifier] else { return total }
                let relativeX = touch.normalizedX - origin.x - dx
                let relativeY = touch.normalizedY - origin.y - dy
                return total + relativeX * relativeX + relativeY * relativeY
            }
            let deformation = sqrt(squaredDeformation / CGFloat(activeTouches.count))
            let minimumTouchMotion = activeTouches.values.compactMap { touch -> CGFloat? in
                guard let origin = gestureStartPositions[touch.identifier] else { return nil }
                return hypot(touch.normalizedX - origin.x, touch.normalizedY - origin.y)
            }.min() ?? hypot(dx, dy)
            let coherentMotion = min(minimumTouchMotion, max(0, hypot(dx, dy) - deformation))
            maxCoherentTranslationDistance = max(maxCoherentTranslationDistance, coherentMotion)
        }
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
        var dx = maxGestureDistance > currentDistance ? maxGestureDx : currentDx
        var dy = maxGestureDistance > currentDistance ? maxGestureDy : currentDy
        var totalDistance = max(maxGestureDistance, currentDistance)

        let spreadDelta = endSpread - startSpread
        let spreadSignificant = abs(spreadDelta) > tuning.spreadThreshold

        var direction: GestureDirection
        if fingers >= 4 && spreadSignificant && abs(spreadDelta) > min(totalDistance, maxCoherentTranslationDistance) * tuning.spreadToDistanceRatio {
            direction = spreadDelta > 0 ? .spread : .pinch
        } else if totalDistance > tuning.minSwipeDistance {
            if fingers >= 3 {
                // 只使用每根手指共同运动时的峰值，不能用两指+静止掌缘的
                // 中心点峰值触发规则，也不能在抬手时绕过这道检查。
                if !recordedRejectedSwipe, totalDistance >= tuning.liveTriggerDistance,
                   maxSwipeDistance < tuning.liveTriggerDistance {
                    recordedRejectedSwipe = true
                    let direction: GestureDirection = abs(dx) > abs(dy)
                        ? (dx > 0 ? .right : .left) : (dy > 0 ? .up : .down)
                    emitTrace(decision: .rejectedIncoherentSwipe,
                              event: GestureEvent(fingers: fingers, direction: direction,
                                                  distance: totalDistance, dx: dx, dy: dy),
                              positions: maxGestureDistance > currentDistance ? maxGesturePositions : currentGesturePositions)
                }
                guard maxSwipeDistance > tuning.minSwipeDistance else { return nil }
                dx = maxSwipeDx
                dy = maxSwipeDy
                totalDistance = maxSwipeDistance
            }
            let absDx = abs(dx)
            let absDy = abs(dy)
            let minor = min(absDx, absDy)
            let major = max(absDx, absDy)

            if major > 0 && minor >= major * tuning.diagonalRejectRatio {
                if logDiagnostics && tuning.logLevel == "debug" {
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
                if logDiagnostics && tuning.logLevel == "debug" {
                    fputs("[Gesture] \(fingers)指 下偏修正: left/right→down | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) |dy|/|dx|=\(String(format: "%.2f", absDx > 0 ? absDy/absDx : 0)) ≥\(String(format: "%.2f", tuning.downBiasRatio))\n", stderr)
                }
            }
        } else {
            if logDiagnostics && tuning.logLevel == "debug" {
                fputs("[Gesture] \(fingers)指 距离太短忽略 | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 距离=\(String(format: "%.4f", totalDistance)) 需>\(String(format: "%.4f", tuning.minSwipeDistance))\n", stderr)
            }
            return nil
        }

        if logDiagnostics && tuning.logLevel == "debug" {
            fputs("[Gesture] \(fingers)指 识别为 \(direction) | dx=\(String(format: "%.4f", dx)) dy=\(String(format: "%.4f", dy)) 距离=\(String(format: "%.3f", totalDistance))\n", stderr)
        }

        let recognizedDistance: CGFloat = (direction == .pinch || direction == .spread)
            ? abs(spreadDelta) : totalDistance
        return GestureEvent(fingers: fingers, direction: direction, distance: recognizedDistance, dx: dx, dy: dy)
    }

    func reset() {
        palmFilter.reset()
        traceBuffer.reset()
        contactFirstSeen.removeAll()
        acceptedTouchCount = 0
        rejectedPalmCount = 0
        resetGesture()
    }

    // 手指抬起后掌缘可能仍在，不能在每个手势结束时清除掌缘生命周期。
    private func resetGesture() {
        recordedRejectedSwipe = false
        recordedIgnoredLateTouch = false
        lockedTouchIdentifiers = nil
        gestureBeganTimestamp = 0
        activeTouches.removeAll()
        gestureStartCentroid = nil
        gestureStartPositions.removeAll()
        maxCoherentTranslationDistance = 0
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
        gestureTouchIdentifiers.removeAll()
        stillnessAnchor.removeAll()
        stillnessAnchorTimestamp = nil
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

    /// 抬起的触点都是“晚到且短暂”的：比剩余最早的手指晚至少 40 ms 落下，
    /// 且接触不足 150 ms。正常抬手时离开的是从一开始就参与手势的手指。
    private func isBrushDeparture(activeSet: Set<Int>, previousFirstSeen: [Int: Double],
                                  timestamp: Double) -> Bool {
        guard !didTriggerCurrentGesture, activeSet.count >= 2,
              activeSet.isSubset(of: gestureTouchIdentifiers),
              let earliestRemaining = activeSet.compactMap({ contactFirstSeen[$0] }).min() else { return false }
        let departed = gestureTouchIdentifiers.subtracting(activeSet)
        return !departed.isEmpty && departed.allSatisfy { identifier in
            guard let began = previousFirstSeen[identifier] else { return false }
            return timestamp - began < tuning.brushContactMaxDuration
                && began - earliestRemaining >= tuning.brushContactMinJoinDelay
        }
    }

    /// 手指搭在触控板上几乎不动时把起点移到当前位置。只看每个触点自身的位移，
    /// 捏合时中心点不动但触点在动，不会被误判为静止。
    private func rebaseIfResting(timestamp: Double) {
        guard !didTriggerCurrentGesture, gestureStartCentroid != nil else { return }
        let positions = activeTouches.mapValues { CGPoint(x: $0.normalizedX, y: $0.normalizedY) }
        guard let anchorTimestamp = stillnessAnchorTimestamp,
              Set(stillnessAnchor.keys) == Set(positions.keys) else {
            stillnessAnchor = positions
            stillnessAnchorTimestamp = timestamp
            return
        }
        let motion = positions.map { identifier, point -> CGFloat in
            let anchor = stillnessAnchor[identifier]!
            return hypot(point.x - anchor.x, point.y - anchor.y)
        }.max() ?? 0
        if motion > tuning.stillnessMotionTolerance {
            stillnessAnchor = positions
            stillnessAnchorTimestamp = timestamp
        } else if timestamp - anchorTimestamp >= tuning.stillnessRebaseDuration {
            if maxGestureDistance > tuning.stillnessMotionTolerance, tuning.logLevel == "debug" {
                fputs("[Gesture] 手指停顿 \(String(format: "%.2f", timestamp - anchorTimestamp))s，丢弃此前 \(String(format: "%.3f", maxGestureDistance)) 的缓慢位移\n", stderr)
            }
            gestureStartCentroid = currentCentroid
            startSpread = calculateSpread()
            resetMaxGestureDisplacement()
            stillnessAnchor = positions
            stillnessAnchorTimestamp = timestamp
        }
    }

    private func effectiveFingerCount(for observedCount: Int, timestamp: Double) -> Int {
        // 手指减少无需确认：保留旧数量会让剩余手指被当作更多手指处理。
        if gestureFingers >= 2 && observedCount < gestureFingers { return observedCount }
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
        currentGesturePositions = activeTouches.mapValues { CGPoint(x: $0.normalizedX, y: $0.normalizedY) }
        let dx = currentCentroid.x - start.x
        let dy = currentCentroid.y - start.y
        let distance = sqrt(dx * dx + dy * dy)
        if distance > maxGestureDistance {
            maxGestureDx = dx
            maxGestureDy = dy
            maxGestureDistance = distance
            maxGesturePositions = currentGesturePositions
        }
        if distance > maxSwipeDistance,
           SwipeMotion.isCoherent(start: gestureStartPositions, end: currentGesturePositions,
                                  dx: dx, dy: dy, minimumDistance: tuning.minSwipeDistance) {
            maxSwipeDx = dx
            maxSwipeDy = dy
            maxSwipeDistance = distance
            maxSwipePositions = currentGesturePositions
        }
    }

    private func resetMaxGestureDisplacement(startPositions: [Int: CGPoint]? = nil) {
        gestureStartPositions = startPositions ?? activeTouches.mapValues {
            CGPoint(x: $0.normalizedX, y: $0.normalizedY)
        }
        currentGesturePositions = gestureStartPositions
        maxGesturePositions = gestureStartPositions
        maxSwipePositions = [:]
        maxSwipeDx = 0
        maxSwipeDy = 0
        maxSwipeDistance = 0
        maxCoherentTranslationDistance = 0
        maxGestureDx = 0
        maxGestureDy = 0
        maxGestureDistance = 0
    }

    func recordTriggeredGesture(_ event: GestureEvent) {
        let isSwipe = event.direction != .pinch && event.direction != .spread && event.fingers >= 3
        emitTrace(decision: .ruleTriggered, event: event,
                  positions: isSwipe ? maxSwipePositions : currentGesturePositions)
    }

    private func emitTrace(decision: GestureTrace.Decision, event: GestureEvent,
                           positions: [Int: CGPoint]) {
        guard let onTrace else { return }
        let motions = gestureStartPositions.keys.sorted().compactMap { identifier -> GestureTrace.Motion? in
            guard let origin = gestureStartPositions[identifier], let end = positions[identifier] else { return nil }
            return GestureTrace.Motion(identifier: identifier,
                                       startX: Double(origin.x), startY: Double(origin.y),
                                       endX: Double(end.x), endY: Double(end.y))
        }
        onTrace(GestureTrace(decision: decision, fingers: event.fingers, direction: event.direction,
                             distance: Double(event.distance), dx: Double(event.dx), dy: Double(event.dy),
                             motions: motions, frames: traceBuffer.frames))
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
