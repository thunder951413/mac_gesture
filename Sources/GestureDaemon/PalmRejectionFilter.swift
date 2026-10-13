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
        var isolatedFrames = 0
        var isolatedSince: Double = 0
        var isPalm = false

        var beganAtEdge: Bool {
            origin.x < 0.08 || origin.x > 0.92 || origin.y < 0.08 || origin.y > 0.92
        }
    }

    private var contacts: [Int: Contact] = [:]
    /// 本次接触会话（从首个触点落下到全部抬起）中同时接触的最大触点数。
    private var sessionMaximumTouching = 0

    mutating func reset() {
        contacts.removeAll()
        sessionMaximumTouching = 0
    }

    mutating func filter(_ touches: [ActiveTouch], timestamp: Double) -> [ActiveTouch] {
        let identifiers = Set(touches.map(\.identifier))
        contacts = contacts.filter { identifiers.contains($0.key) }
        // 已确认的掌缘不计入；新触点尚无记录，按普通手指计。
        let touchingCount = touches.filter { $0.isTouching && contacts[$0.identifier]?.isPalm != true }.count
        sessionMaximumTouching = touchingCount == 0 ? 0 : max(sessionMaximumTouching, touchingCount)
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
        markIsolatedContact(in: touches, timestamp: timestamp)
        return touches.filter { contacts[$0.identifier]?.isPalm != true }
    }

    // MARK: - 远离手指组的孤立触点

    /// 触控板长宽比约 1.4–1.6，横向归一化距离乘以该系数后近似物理距离。
    static let horizontalScale: CGFloat = 1.5
    /// 第三个触点与另外两指的最近距离超过此值，且两指彼此靠近时视为掌根/拇指。
    /// 2026-10-10 至 10-13 本机 121 次真实三指滑动中，最远的手指间最近距离为 0.31；
    /// 掌缘采样为 0.41–0.63。0.32–0.45 之间均无误判，取中间值留出余量。
    static let isolationDistance: CGFloat = 0.40
    static let fingerPairDistance: CGFloat = 0.36

    static func scaledDistance(_ a: ActiveTouch, _ b: ActiveTouch) -> CGFloat {
        hypot((a.normalizedX - b.normalizedX) * horizontalScale, a.normalizedY - b.normalizedY)
    }

    /// 三指滑动的手指总是彼此相邻；掌根或搁着的拇指与两根手指相距较远，
    /// 即使它随手一起移动、尺寸也与指尖相近。只在恰好三个接触点时判断：
    /// 四/五指捏合中的拇指同样远离其它手指，因此本次会话出现过四个及以上
    /// 接触点后不再新增标记。连续 3 帧且至少 16 ms 才确认，落指过程中的
    /// 瞬时排列不会被锁定。
    private mutating func markIsolatedContact(in touches: [ActiveTouch], timestamp: Double) {
        let candidates = touches.filter { $0.isTouching && contacts[$0.identifier]?.isPalm == false }
        var isolated: Int?
        if candidates.count == 3, sessionMaximumTouching <= 3 {
            for touch in candidates {
                let others = candidates.filter { $0.identifier != touch.identifier }
                let nearest = others.map { Self.scaledDistance(touch, $0) }.min() ?? 0
                if nearest > Self.isolationDistance,
                   Self.scaledDistance(others[0], others[1]) < Self.fingerPairDistance {
                    isolated = touch.identifier
                    break
                }
            }
        }
        for touch in candidates {
            guard var contact = contacts[touch.identifier] else { continue }
            if touch.identifier == isolated {
                if contact.isolatedFrames == 0 { contact.isolatedSince = timestamp }
                contact.isolatedFrames += 1
                if contact.isolatedFrames >= 3 && timestamp - contact.isolatedSince >= 0.016 {
                    contact.isPalm = true
                }
            } else {
                contact.isolatedFrames = 0
            }
            contacts[touch.identifier] = contact
        }
    }
}
