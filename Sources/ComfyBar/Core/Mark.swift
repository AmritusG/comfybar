import CoreGraphics
import Foundation

/// The ComfyBar mark (the maintainer's "2f equal margins"): an open C with a B inside.
/// Source: assets/ComfyBar-2f-nest-balanced-menubar.svg (100x100 viewBox). The path strings
/// and stroke widths below are copied verbatim from that file and a unit test checks they
/// still match it - the mark is scaled and rasterised, never redrawn.
enum Mark {
    static let viewBox: CGFloat = 100
    /// C: arc centre (46,50) r 38, open on the right, stroke 9.5, round caps.
    static let cPath = "M75.94,26.60 A38,38 0 1 0 75.94,73.40"
    static let cStroke: CGFloat = 9.5
    /// B: stroke 8.5, round caps and joins.
    static let bPath = "M36.454026695337575,73.0 V27.0 H48.63 A10.81,10.81 0 0 1 48.63,48.62 H36.454026695337575 M48.63,48.62 H52.69 A12.19,12.19 0 0 1 52.69,73.0 H36.454026695337575"
    static let bStroke: CGFloat = 8.5

    static let c: CGPath = SVGPath.parse(cPath)
    static let b: CGPath = SVGPath.parse(bPath)
}

/// Minimal SVG path-data reader for the commands the mark uses: M L H V A Z (absolute).
/// Arcs are converted with the W3C endpoint-to-centre method (SVG 1.1 appendix F.6.5) and
/// emitted as cubic Béziers of at most 90 degrees each.
enum SVGPath {
    enum PathError: Error { case unsupported(Character) }

    static func tokens(_ d: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in d {
            if ch.isLetter && ch != "e" && ch != "E" {
                if !cur.isEmpty { out.append(cur); cur = "" }
                out.append(String(ch))
            } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
                if !cur.isEmpty { out.append(cur); cur = "" }
            } else if ch == "-" && !cur.isEmpty && cur.last != "e" && cur.last != "E" {
                out.append(cur); cur = "-"
            } else {
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        let t = tokens(d)
        var i = 0
        var cmd: Character = "M"
        var p = CGPoint.zero
        var start = CGPoint.zero
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(t[i]) ?? 0) }
        while i < t.count {
            if let c = t[i].first, t[i].count == 1, c.isLetter { cmd = c; i += 1 }
            switch cmd {
            case "M":
                p = CGPoint(x: num(), y: num()); start = p; path.move(to: p); cmd = "L"
            case "L":
                p = CGPoint(x: num(), y: num()); path.addLine(to: p)
            case "H":
                p = CGPoint(x: num(), y: p.y); path.addLine(to: p)
            case "V":
                p = CGPoint(x: p.x, y: num()); path.addLine(to: p)
            case "A":
                let rx = num(), ry = num(), rot = num(), large = num() != 0, sweep = num() != 0
                let end = CGPoint(x: num(), y: num())
                arc(path, from: p, to: end, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                p = end
            case "Z", "z":
                path.closeSubpath(); p = start
            default:
                i += 1   // unsupported command: skip its token (the mark uses none)
            }
        }
        return path
    }

    /// SVG 1.1 F.6.5 (circles and ellipses; the mark only has circles).
    static func arc(_ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                    rotation: CGFloat, large: Bool, sweep: Bool) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy
        let y1 = -sinP * dx + cosP * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let rx2: CGFloat = rx * rx, ry2: CGFloat = ry * ry
        let x12: CGFloat = x1 * x1, y12: CGFloat = y1 * y1
        let num: CGFloat = rx2 * ry2 - rx2 * y12 - ry2 * x12
        let den: CGFloat = rx2 * y12 + ry2 * x12
        var coef = sqrt(max(0, num / den))
        if large == sweep { coef = -coef }
        let cx1 = coef * rx * y1 / ry
        let cy1 = -coef * ry * x1 / rx
        let cx = cosP * cx1 - sinP * cy1 + (p0.x + p1.x) / 2
        let cy = sinP * cx1 + cosP * cy1 + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy)
            return a
        }
        let theta1 = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var dTheta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }
        let segments = Int(ceil(abs(dTheta) / (.pi / 2)))
        let delta = dTheta / CGFloat(segments)
        let k = 4.0 / 3.0 * tan(delta / 4)
        var th = theta1
        func pt(_ a: CGFloat) -> CGPoint {
            let ca: CGFloat = cos(a), sa: CGFloat = sin(a)
            let x: CGFloat = cx + rx * ca * cosP - ry * sa * sinP
            let y: CGFloat = cy + rx * ca * sinP + ry * sa * cosP
            return CGPoint(x: x, y: y)
        }
        func deriv(_ a: CGFloat) -> CGPoint {
            let ca: CGFloat = cos(a), sa: CGFloat = sin(a)
            let x: CGFloat = -rx * sa * cosP - ry * ca * sinP
            let y: CGFloat = -rx * sa * sinP + ry * ca * cosP
            return CGPoint(x: x, y: y)
        }
        for s in 0..<segments {
            let a0 = th, a1 = th + delta
            let s0 = pt(a0), e0 = s == segments - 1 ? p1 : pt(a1)
            let d0 = deriv(a0), d1 = deriv(a1)
            let c1 = CGPoint(x: s0.x + k * d0.x, y: s0.y + k * d0.y)
            let c2 = CGPoint(x: e0.x - k * d1.x, y: e0.y - k * d1.y)
            path.addCurve(to: e0, control1: c1, control2: c2)
            th = a1
        }
    }
}
