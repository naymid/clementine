import SwiftUI

/// Geometry of the radial wheel. Angles are measured clockwise from 12 o'clock,
/// in a y-down coordinate space centered on the wheel.
struct WheelGeometry {
    var count: Int
    var diameter: CGFloat

    var radius: CGFloat { diameter / 2 }
    var rim: CGFloat { diameter * 0.027 }
    var outerRadius: CGFloat { radius - rim }
    var centerRadius: CGFloat { diameter * 0.17 }
    var innerRadius: CGFloat { centerRadius + diameter * 0.02 }
    var gap: CGFloat { diameter * 0.026 }
    var cornerRadius: CGFloat { diameter * 0.07 }
    var step: CGFloat { 2 * .pi / CGFloat(max(count, 1)) }
    var capsuleSize: CGSize { CGSize(width: diameter * 0.285, height: diameter * 0.14) }

    static func diameter(for count: Int) -> CGFloat {
        switch count {
        case ...8: return 300
        case 9...10: return 320
        default: return 344
        }
    }

    func centerAngle(of index: Int) -> CGFloat { CGFloat(index) * step }

    /// Unit direction for an angle, in y-down coordinates.
    func direction(_ angle: CGFloat) -> CGPoint { CGPoint(x: sin(angle), y: -cos(angle)) }

    func labelPosition(of index: Int, center: CGPoint) -> CGPoint {
        let r = (innerRadius + outerRadius) / 2 + diameter * 0.012
        let d = direction(centerAngle(of: index))
        return CGPoint(x: center.x + d.x * r, y: center.y + d.y * r)
    }

    enum Hit: Equatable {
        case center
        case petal(Int)
        case outside
    }

    /// Which part of the wheel a point (relative to the wheel's center) falls on.
    func hit(_ point: CGPoint) -> Hit {
        let distance = hypot(point.x, point.y)
        if distance < innerRadius { return .center }
        if distance > radius + 28 || count == 0 { return .outside }
        var angle = atan2(point.x, -point.y)
        if angle < 0 { angle += 2 * .pi }
        let index = Int(((angle + step / 2) / step).rounded(.down)) % count
        return .petal(index)
    }

    /// A rounded annular sector with uniform gaps between neighbours.
    func petalPath(index: Int, center: CGPoint) -> Path {
        if count == 1 {
            // A single action fills the whole ring.
            var ring = Path()
            ring.addEllipse(in: CGRect(x: center.x - outerRadius, y: center.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
            ring.addEllipse(in: CGRect(x: center.x - innerRadius, y: center.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2))
            return ring
        }
        let mid = centerAngle(of: index)
        let a = mid - step / 2
        let b = mid + step / 2
        let halfGap = gap / 2
        let r1 = innerRadius
        let r2 = outerRadius

        func dir(_ angle: CGFloat) -> CGPoint { direction(angle) }
        // Normals pointing into the petal from each side boundary.
        let nA = CGPoint(x: cos(a), y: sin(a))
        let nB = CGPoint(x: -cos(b), y: -sin(b))
        let uA = dir(a)
        let uB = dir(b)

        let outerCorner = cornerRadius
        let innerHalfWidth = r1 * sin(step / 2) - halfGap
        let innerCorner = max(2, min(cornerRadius * 0.55, innerHalfWidth * 0.7))

        struct Corner { var center: CGPoint; var sidePoint: CGPoint; var arcPoint: CGPoint; var radius: CGFloat }

        func corner(normal n: CGPoint, along u: CGPoint, circleRadius: CGFloat, outer: Bool, radius rc: CGFloat) -> Corner {
            let offset = halfGap + rc
            let distance = outer ? circleRadius - rc : circleRadius + rc
            let t = sqrt(max(0, distance * distance - offset * offset))
            let c = CGPoint(x: n.x * offset + u.x * t, y: n.y * offset + u.y * t)
            let side = CGPoint(x: c.x - n.x * rc, y: c.y - n.y * rc)
            let length = hypot(c.x, c.y)
            let arc = CGPoint(x: c.x / length * circleRadius, y: c.y / length * circleRadius)
            return Corner(center: c, sidePoint: side, arcPoint: arc, radius: rc)
        }

        let outerA = corner(normal: nA, along: uA, circleRadius: r2, outer: true, radius: outerCorner)
        let outerB = corner(normal: nB, along: uB, circleRadius: r2, outer: true, radius: outerCorner)
        let innerA = corner(normal: nA, along: uA, circleRadius: r1, outer: false, radius: innerCorner)
        let innerB = corner(normal: nB, along: uB, circleRadius: r1, outer: false, radius: innerCorner)

        func shifted(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + center.x, y: p.y + center.y) }
        func angle(_ p: CGPoint, around c: CGPoint) -> CGFloat { atan2(p.y - c.y, p.x - c.x) }
        func shortest(_ from: CGFloat, _ to: CGFloat) -> CGFloat {
            var delta = to - from
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            return delta
        }
        func addFillet(_ path: inout Path, _ corner: Corner, from: CGPoint, to: CGPoint) {
            let start = angle(from, around: corner.center)
            let end = angle(to, around: corner.center)
            path.addRelativeArc(center: shifted(corner.center), radius: corner.radius,
                                startAngle: .radians(start), delta: .radians(shortest(start, end)))
        }

        var path = Path()
        path.move(to: shifted(innerA.sidePoint))
        path.addLine(to: shifted(outerA.sidePoint))
        addFillet(&path, outerA, from: outerA.sidePoint, to: outerA.arcPoint)
        let outerStart = atan2(outerA.arcPoint.y, outerA.arcPoint.x)
        let outerEnd = atan2(outerB.arcPoint.y, outerB.arcPoint.x)
        var outerDelta = outerEnd - outerStart
        while outerDelta < 0 { outerDelta += 2 * .pi }
        path.addRelativeArc(center: center, radius: r2, startAngle: .radians(outerStart), delta: .radians(outerDelta))
        addFillet(&path, outerB, from: outerB.arcPoint, to: outerB.sidePoint)
        path.addLine(to: shifted(innerB.sidePoint))
        addFillet(&path, innerB, from: innerB.sidePoint, to: innerB.arcPoint)
        let innerStart = atan2(innerB.arcPoint.y, innerB.arcPoint.x)
        let innerEnd = atan2(innerA.arcPoint.y, innerA.arcPoint.x)
        var innerDelta = innerEnd - innerStart
        while innerDelta > 0 { innerDelta -= 2 * .pi }
        path.addRelativeArc(center: center, radius: r1, startAngle: .radians(innerStart), delta: .radians(innerDelta))
        addFillet(&path, innerA, from: innerA.arcPoint, to: innerA.sidePoint)
        path.closeSubpath()
        return path
    }
}

/// A petal as a SwiftUI shape, laid out in its own frame.
struct PetalShape: Shape {
    var geometry: WheelGeometry
    var index: Int

    func path(in rect: CGRect) -> Path {
        let path = geometry.petalPath(index: index, center: CGPoint(x: rect.midX, y: rect.midY))
        // The single-petal ring is two ellipses; even-odd keeps the hole open.
        return geometry.count == 1 ? path.normalized(eoFill: true) : path
    }
}
