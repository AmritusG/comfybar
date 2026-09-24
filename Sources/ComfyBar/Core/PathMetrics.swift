import CoreGraphics

/// Path length and bounds, for the progress dash along the C and the mark's tests.
/// (Written as small, explicitly typed helpers: one large closure here was too slow for
/// older Swift compilers to type-check.)
enum PathMetrics {
    /// Sum of segment lengths; curves sampled at 64 steps (sub-0.01% error for these arcs).
    static func length(_ path: CGPath) -> CGFloat {
        var total: CGFloat = 0
        var cur = CGPoint.zero
        var start = CGPoint.zero
        path.applyWithBlock { (el: UnsafePointer<CGPathElement>) in
            let e: CGPathElement = el.pointee
            switch e.type {
            case .moveToPoint:
                cur = e.points[0]
                start = cur
            case .addLineToPoint:
                total += distance(cur, e.points[0])
                cur = e.points[0]
            case .addQuadCurveToPoint:
                total += quadLength(cur, e.points[0], e.points[1])
                cur = e.points[1]
            case .addCurveToPoint:
                total += cubicLength(cur, e.points[0], e.points[1], e.points[2])
                cur = e.points[2]
            case .closeSubpath:
                total += distance(cur, start)
                cur = start
            @unknown default:
                break
            }
        }
        return total
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(b.x - a.x, b.y - a.y)
    }

    static func quadPoint(_ t: CGFloat, _ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint) -> CGPoint {
        let u: CGFloat = 1 - t
        let a: CGFloat = u * u
        let b: CGFloat = 2 * u * t
        let d: CGFloat = t * t
        return CGPoint(x: a * p0.x + b * c.x + d * p1.x, y: a * p0.y + b * c.y + d * p1.y)
    }

    static func cubicPoint(_ t: CGFloat, _ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint) -> CGPoint {
        let u: CGFloat = 1 - t
        let a: CGFloat = u * u * u
        let b: CGFloat = 3 * u * u * t
        let c: CGFloat = 3 * u * t * t
        let d: CGFloat = t * t * t
        let x: CGFloat = a * p0.x + b * c1.x + c * c2.x + d * p1.x
        let y: CGFloat = a * p0.y + b * c1.y + c * c2.y + d * p1.y
        return CGPoint(x: x, y: y)
    }

    static func quadLength(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint) -> CGFloat {
        sampled { t in quadPoint(t, p0, c, p1) }
    }

    static func cubicLength(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint) -> CGFloat {
        sampled { t in cubicPoint(t, p0, c1, c2, p1) }
    }

    private static func sampled(_ f: (CGFloat) -> CGPoint) -> CGFloat {
        var len: CGFloat = 0
        var prev: CGPoint = f(0)
        for i in 1...64 {
            let p: CGPoint = f(CGFloat(i) / 64)
            len += distance(prev, p)
            prev = p
        }
        return len
    }
}
