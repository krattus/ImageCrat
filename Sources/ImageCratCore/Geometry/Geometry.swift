import Foundation

// MARK: - Integer geometry

package struct IPoint: Codable, Equatable, Hashable {
    package var x: Int
    package var y: Int
    package static let zero = IPoint(x: 0, y: 0)
    @inlinable package var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    @inlinable package init(x: Int, y: Int) {
        self.x = x; self.y = y
    }
}

package struct IRect: Codable, Equatable, Hashable {
    package var x: Int
    package var y: Int
    package var width: Int
    package var height: Int

    package static let zero = IRect(x: 0, y: 0, width: 0, height: 0)

    @inlinable package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// Smallest integer rect enclosing a CGRect.
    @inlinable package init(enclosing r: CGRect) {
        if r.isNull || r.isInfinite || r.isEmpty {
            self = .zero
            return
        }
        // Int(…) traps on NaN and on values beyond Int.max (rects from extreme transforms / typed numbers).
        guard r.minX.isFinite, r.minY.isFinite, r.maxX.isFinite, r.maxY.isFinite else { self = .zero; return }
        let lim: CGFloat = 1_000_000_000
        let x0 = Int(floor(max(-lim, min(lim, r.minX)))), y0 = Int(floor(max(-lim, min(lim, r.minY))))
        let x1 = Int(ceil(max(-lim, min(lim, r.maxX)))), y1 = Int(ceil(max(-lim, min(lim, r.maxY))))
        self.init(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    @inlinable package var isEmpty: Bool { width <= 0 || height <= 0 }
    @inlinable package var minX: Int { x }
    @inlinable package var minY: Int { y }
    @inlinable package var maxX: Int { x + width }
    @inlinable package var maxY: Int { y + height }
    @inlinable package var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    @inlinable package var origin: IPoint { IPoint(x: x, y: y) }

    @inlinable package func intersection(_ o: IRect) -> IRect {
        let x0 = max(minX, o.minX), y0 = max(minY, o.minY)
        let x1 = min(maxX, o.maxX), y1 = min(maxY, o.maxY)
        if x1 <= x0 || y1 <= y0 { return .zero }
        return IRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    @inlinable package func union(_ o: IRect) -> IRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        let x0 = min(minX, o.minX), y0 = min(minY, o.minY)
        let x1 = max(maxX, o.maxX), y1 = max(maxY, o.maxY)
        return IRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    @inlinable package func offsetBy(dx: Int, dy: Int) -> IRect { IRect(x: x + dx, y: y + dy, width: width, height: height) }
    @inlinable package func insetBy(_ d: Int) -> IRect { IRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d) }
    @inlinable package func contains(_ p: IPoint) -> Bool { p.x >= minX && p.x < maxX && p.y >= minY && p.y < maxY }
}

// MARK: - CGPoint math

extension CGPoint {
    @inlinable package static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    @inlinable package static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    @inlinable package static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }
    @inlinable package static func / (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x / s, y: a.y / s) }
    @inlinable package static prefix func - (a: CGPoint) -> CGPoint { CGPoint(x: -a.x, y: -a.y) }
    @inlinable package var length: CGFloat { sqrt(x * x + y * y) }
    @inlinable package func distance(to p: CGPoint) -> CGFloat { (self - p).length }
    @inlinable package var normalized: CGPoint { let l = length; return l > 0 ? self / l : .zero }
    @inlinable package func lerp(_ to: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: x + (to.x - x) * t, y: y + (to.y - y) * t) }
    @inlinable package func rotated(by angle: CGFloat, around c: CGPoint = .zero) -> CGPoint {
        let d = self - c
        let cs = cos(angle), sn = sin(angle)
        return CGPoint(x: c.x + d.x * cs - d.y * sn, y: c.y + d.x * sn + d.y * cs)
    }
    @inlinable package func dot(_ o: CGPoint) -> CGFloat { x * o.x + y * o.y }
    @inlinable package var angle: CGFloat { atan2(y, x) }
    @inlinable package var rounded: CGPoint { CGPoint(x: x.rounded(), y: y.rounded()) }
}

extension CGRect {
    @inlinable package var center: CGPoint { CGPoint(x: midX, y: midY) }
    @inlinable package init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
    }
    @inlinable package var corners: [CGPoint] { [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)] }
    @inlinable package static func bounding(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var x0 = f.x, y0 = f.y, x1 = f.x, y1 = f.y
        for p in pts { x0 = min(x0, p.x); y0 = min(y0, p.y); x1 = max(x1, p.x); y1 = max(y1, p.y) }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension CGSize {
    @inlinable package static func * (a: CGSize, s: CGFloat) -> CGSize { CGSize(width: a.width * s, height: a.height * s) }
}

@inlinable package func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }
/// Floating-point overloads: NaN compares false with everything, so `min(max(v, lo), hi)` would pass it through.
@inlinable package func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v.isNaN ? lo : min(max(v, lo), hi) }
@inlinable package func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { v.isNaN ? lo : min(max(v, lo), hi) }
/// A closed range that never traps: `a...b` requires a <= b and finite bounds, which data-derived slider ranges
/// (shape size, font axes, pixel statistics) cannot always guarantee.
@inlinable package func safeRange(_ a: Double, _ b: Double) -> ClosedRange<Double> {
    guard a.isFinite, b.isFinite else { return 0...1 }
    return min(a, b)...max(a, b)
}

// MARK: - Quad & projective transform

/// Four corners in doc space: top-left, top-right, bottom-right, bottom-left.
package struct Quad: Codable, Equatable {
    package var tl: CGPoint
    package var tr: CGPoint
    package var br: CGPoint
    package var bl: CGPoint

    @inlinable package init(tl: CGPoint, tr: CGPoint, br: CGPoint, bl: CGPoint) {
        self.tl = tl; self.tr = tr; self.br = br; self.bl = bl
    }
    @inlinable package init(rect r: CGRect) {
        tl = CGPoint(x: r.minX, y: r.minY); tr = CGPoint(x: r.maxX, y: r.minY)
        br = CGPoint(x: r.maxX, y: r.maxY); bl = CGPoint(x: r.minX, y: r.maxY)
    }
    @inlinable package var points: [CGPoint] {
        get { [tl, tr, br, bl] }
        set { tl = newValue[0]; tr = newValue[1]; br = newValue[2]; bl = newValue[3] }
    }
    @inlinable package var bounds: CGRect { CGRect.bounding(points) }
    @inlinable package var center: CGPoint { (tl + tr + br + bl) / 4 }
    @inlinable package func applying(_ t: CGAffineTransform) -> Quad {
        Quad(tl: tl.applying(t), tr: tr.applying(t), br: br.applying(t), bl: bl.applying(t))
    }
    @inlinable package func mapped(_ f: (CGPoint) -> CGPoint) -> Quad { Quad(tl: f(tl), tr: f(tr), br: f(br), bl: f(bl)) }
    @inlinable package var isAffine: Bool {
        // parallelogram check
        let a = (tl + br) , b = (tr + bl)
        return a.distance(to: b) < 0.01
    }
}

/// 3x3 projective transform (homography), row-major, maps (x,y,1).
package struct Homography: Equatable, Codable {
    package var m: [Double] // 9

    package static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    @inlinable package init(m: [Double]) { self.m = m }

    @inlinable package init(affine t: CGAffineTransform) {
        m = [Double(t.a), Double(t.c), Double(t.tx), Double(t.b), Double(t.d), Double(t.ty), 0, 0, 1]
    }

    /// Homography mapping quad `from` onto quad `to`.
    @inlinable package init?(from: Quad, to: Quad) {
        guard let a = Homography.squareToQuad(from), let b = Homography.squareToQuad(to), let ai = a.inverted else { return nil }
        self = b.concat(ai)
    }

    /// Maps unit square (0,0),(1,0),(1,1),(0,1) to the quad.
    @inlinable package static func squareToQuad(_ q: Quad) -> Homography? {
        let x0 = Double(q.tl.x), y0 = Double(q.tl.y)
        let x1 = Double(q.tr.x), y1 = Double(q.tr.y)
        let x2 = Double(q.br.x), y2 = Double(q.br.y)
        let x3 = Double(q.bl.x), y3 = Double(q.bl.y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        var a, b, c, d, e, f, g, h: Double
        if abs(dx3) < 1e-10 && abs(dy3) < 1e-10 {
            a = x1 - x0; b = x2 - x1; c = x0
            d = y1 - y0; e = y2 - y1; f = y0
            g = 0; h = 0
        } else {
            let den = dx1 * dy2 - dx2 * dy1
            if abs(den) < 1e-12 { return nil }
            g = (dx3 * dy2 - dx2 * dy3) / den
            h = (dx1 * dy3 - dx3 * dy1) / den
            a = x1 - x0 + g * x1
            b = x3 - x0 + h * x3
            c = x0
            d = y1 - y0 + g * y1
            e = y3 - y0 + h * y3
            f = y0
        }
        return Homography(m: [a, b, c, d, e, f, g, h, 1])
    }

    @inlinable package func concat(_ o: Homography) -> Homography {
        // self * o
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                var s = 0.0
                for k in 0..<3 { s += m[i * 3 + k] * o.m[k * 3 + j] }
                r[i * 3 + j] = s
            }
        }
        return Homography(m: r)
    }

    @inlinable package var inverted: Homography? {
        let a = m
        let det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        if abs(det) < 1e-14 { return nil }
        let id = 1 / det
        return Homography(m: [
            (a[4] * a[8] - a[5] * a[7]) * id, (a[2] * a[7] - a[1] * a[8]) * id, (a[1] * a[5] - a[2] * a[4]) * id,
            (a[5] * a[6] - a[3] * a[8]) * id, (a[0] * a[8] - a[2] * a[6]) * id, (a[2] * a[3] - a[0] * a[5]) * id,
            (a[3] * a[7] - a[4] * a[6]) * id, (a[1] * a[6] - a[0] * a[7]) * id, (a[0] * a[4] - a[1] * a[3]) * id,
        ])
    }

    @inlinable package func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        let iw = abs(w) < 1e-12 ? 1e12 : 1 / w
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) * iw, y: (m[3] * x + m[4] * y + m[5]) * iw)
    }

    @inlinable package var isAffine: Bool { abs(m[6]) < 1e-12 && abs(m[7]) < 1e-12 }

    @inlinable package var affine: CGAffineTransform {
        let s = m[8]
        return CGAffineTransform(a: m[0] / s, b: m[3] / s, c: m[1] / s, d: m[4] / s, tx: m[2] / s, ty: m[5] / s)
    }

    @inlinable package func mapRect(_ r: CGRect) -> Quad { Quad(rect: r).mapped(apply) }
}

extension CGAffineTransform {
    @inlinable package var scaleFactor: CGFloat { sqrt(abs(a * d - b * c)) }
    @inlinable package var rotationAngle: CGFloat { atan2(b, a) }
}
