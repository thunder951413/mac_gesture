import Foundation
import CoreGraphics
import GestureTouchCore

/// MTContact 的尺寸单位随设备变化，比较同一帧内的触点，避免固定毫米/压力阈值。
/// 参考 libinput 的接触面积、边缘起点及抬手前保留掌缘标记策略：
/// https://wayland.freedesktop.org/libinput/doc/latest/palm-detection.html
struct PalmRejectionFilter {
    private struct Contact {
        let origin: CGPoint
        let beganAt: Double
        var maximumMotion: CGFloat = 0
        var lastState: Int
        var candidateFrames = 0
        var candidateSince: Double = 0
        var isPalm = false

        var beganAtEdge: Bool {
            origin.x < 0.08 || origin.x > 0.92 || origin.y < 0.08 || origin.y > 0.92
        }
    }

    private var contacts: [Int: Contact] = [:]

    mutating func reset() { contacts.removeAll() }

    mutating func filter(_ touches: [ActiveTouch], timestamp: Double) -> [ActiveTouch] {
        let identifiers = Set(touches.map(\.identifier))
        contacts = contacts.filter { identifiers.contains($0.key) }
        for touch in touches {
            // 标识符可以复用；新的接触生命周期不能继承上一次的掌缘标记。
            if contacts[touch.identifier] == nil ||
                (touch.state == 1 && (contacts[touch.identifier]?.lastState ?? 0) >= 5) {
                contacts[touch.identifier] = Contact(
                    origin: CGPoint(x: touch.normalizedX, y: touch.normalizedY),
                    beganAt: timestamp, lastState: touch.state
                )
            }
            guard var contact = contacts[touch.identifier] else { continue }
            contact.maximumMotion = max(contact.maximumMotion,
                hypot(touch.normalizedX - contact.origin.x, touch.normalizedY - contact.origin.y))
            contact.lastState = touch.state
            contacts[touch.identifier] = contact
        }

        // 至少两个普通指尖作参照；缺失形状数据时保持旧协议的识别行为。
        let shapedTouches = touches.filter {
            contacts[$0.identifier]?.isPalm == false && $0.majorAxis != nil && $0.minorAxis != nil
        }.sorted { ($0.majorAxis! * $0.minorAxis!) < ($1.majorAxis! * $1.minorAxis!) }
        if shapedTouches.count >= 3 {
            let reference = Array(shapedTouches.prefix(2))
            let area = reference.reduce(CGFloat.zero) { $0 + $1.majorAxis! * $1.minorAxis! } / 2
            let major = reference.reduce(CGFloat.zero) { $0 + $1.majorAxis! } / 2
            let minor = reference.reduce(CGFloat.zero) { $0 + $1.minorAxis! } / 2
            let sizes = reference.compactMap(\.contactSize)
            let size = sizes.count == 2 ? sizes.reduce(0, +) / 2 : nil
            let peerMotion = reference.compactMap { contacts[$0.identifier]?.maximumMotion }.min() ?? 0

            for touch in shapedTouches.dropFirst(2) {
                guard var contact = contacts[touch.identifier],
                      let touchMajor = touch.majorAxis, let touchMinor = touch.minorAxis else { continue }
                let areaRatio = touchMajor * touchMinor / area
                let majorRatio = touchMajor / major
                let minorRatio = touchMinor / minor
                let sizeRatio = size.flatMap { baseline in touch.contactSize.map { $0 / baseline } } ?? 0

                // 宽掌缘在两个轴上都明显大于指尖；拇指通常只在长轴上更大。
                let broadPalm = areaRatio >= 2.5 && majorRatio >= 1.6 && minorRatio >= 1.4
                // 部分掌缘可能呈狭长椭圆，需同时满足面积代理值及位置/停留条件。
                // 正常三指共同滑动、捏合中的大拇指不能仅因接触较大而被排除。
                let resting = contact.maximumMotion < 0.03 && peerMotion >= 0.04
                    && timestamp - contact.beganAt >= 0.06
                // 掌缘分成两个触点时，较窄的一处也可能随手掌移动；三个尺寸
                // 信号都极端时无需依赖边缘位置或静止条件。
                let largePartialPalm = areaRatio >= 3.2 && majorRatio >= 2.2 && sizeRatio >= 3
                let partialPalm = areaRatio >= 2.5 && majorRatio >= 1.8 && sizeRatio >= 3
                    && (contact.beganAtEdge || resting)
                if broadPalm || partialPalm || largePartialPalm {
                    if contact.candidateFrames == 0 { contact.candidateSince = timestamp }
                    contact.candidateFrames += 1
                    // 比三指确认窗口更早确认，但一帧变形不能永久排除正常手指。
                    if contact.candidateFrames >= 2 && timestamp - contact.candidateSince >= 0.008 {
                        contact.isPalm = true
                    }
                } else {
                    contact.candidateFrames = 0
                }
                contacts[touch.identifier] = contact
            }
            // 不在候选集合中的普通指尖，也要结束此前的连续候选计数。
            for touch in reference {
                contacts[touch.identifier]?.candidateFrames = 0
            }
        } else {
            for touch in shapedTouches { contacts[touch.identifier]?.candidateFrames = 0 }
        }
        return touches.filter { contacts[$0.identifier]?.isPalm != true }
    }
}
