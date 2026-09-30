import AppKit

struct PublicGestureAccumulator {
    private var scrollDX: CGFloat = 0
    private var scrollDY: CGFloat = 0
    private var magnification: CGFloat = 0

    mutating func scroll(dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase = []) -> GestureEvent? {
        guard momentum.isEmpty else { return nil }
        if phase.contains(.began) { scrollDX = 0; scrollDY = 0 }
        if phase.contains(.cancelled) { scrollDX = 0; scrollDY = 0; return nil }
        // 无阶段的鼠标滚动不参与两指手势累计。
        guard !phase.isEmpty else { return nil }
        scrollDX += dx
        scrollDY += dy
        guard phase.contains(.ended) else { return nil }
        defer { scrollDX = 0; scrollDY = 0 }
        return Self.swipe(dx: scrollDX, dy: scrollDY)
    }

    mutating func magnify(_ delta: CGFloat, phase: NSEvent.Phase) -> GestureEvent? {
        if phase.contains(.began) { magnification = 0 }
        if phase.contains(.cancelled) { magnification = 0; return nil }
        guard !phase.isEmpty else { return nil }
        magnification += delta
        guard phase.contains(.ended) else { return nil }
        defer { magnification = 0 }
        guard magnification.isFinite, abs(magnification) >= 0.01 else { return nil }
        return GestureEvent(fingers: 2, direction: magnification >= 0 ? .spread : .pinch, distance: abs(magnification), dx: 0, dy: 0)
    }

    static func swipe(dx: CGFloat, dy: CGFloat) -> GestureEvent? {
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance >= 0.01 else { return nil }
        let direction: GestureDirection
        if abs(dx) > abs(dy) { direction = dx > 0 ? .right : .left }
        else { direction = dy > 0 ? .up : .down }
        return GestureEvent(fingers: 2, direction: direction, distance: distance, dx: dx, dy: dy)
    }
}
