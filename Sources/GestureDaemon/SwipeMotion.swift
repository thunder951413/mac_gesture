import CoreGraphics

/// 多指滑动需要每根手指共同平移；掌缘只改变中心点，不能证明它参与了滑动。
enum SwipeMotion {
    static func isCoherent(start: [Int: CGPoint], end: [Int: CGPoint],
                           dx: CGFloat, dy: CGFloat, minimumDistance: CGFloat) -> Bool {
        let distance = hypot(dx, dy)
        guard distance > 0, start.count >= 3, start.keys.allSatisfy({ end[$0] != nil }),
              start.count == end.count else { return false }
        let ux = dx / distance
        let uy = dy / distance
        let motions = start.map { identifier, origin -> (along: CGFloat, across: CGFloat) in
            let point = end[identifier]!
            let x = point.x - origin.x
            let y = point.y - origin.y
            return (x * ux + y * uy, abs(x * uy - y * ux))
        }
        let projections = motions.map(\.along).sorted()
        let median = projections[projections.count / 2]
        let required = max(minimumDistance * 0.5, median * 0.5)
        return median > 0 && motions.allSatisfy { $0.along >= required && $0.across <= $0.along }
    }
}
