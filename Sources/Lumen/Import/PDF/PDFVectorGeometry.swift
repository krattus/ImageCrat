import Foundation
import CoreGraphics
import ImageCratCore

/// Path helpers for the PDF importer.
enum PDFVectorGeometry {
    /// Anchor points of each subpath, with whether it was closed.
    private static func polylines(_ p: CGPath, limit: Int = 16) -> [(points: [CGPoint], closed: Bool, curved: Bool)]? {
        var out: [(points: [CGPoint], closed: Bool, curved: Bool)] = []
        var cur: [CGPoint] = []
        var curved = false
        var tooMany = false
        p.applyWithBlock { e in
            if tooMany { return }
            switch e.pointee.type {
            case .moveToPoint:
                if !cur.isEmpty { out.append((cur, false, curved)) }
                cur = [e.pointee.points[0]]; curved = false
            case .addLineToPoint: cur.append(e.pointee.points[0])
            case .addQuadCurveToPoint: cur.append(e.pointee.points[1]); curved = true
            case .addCurveToPoint: cur.append(e.pointee.points[2]); curved = true
            case .closeSubpath:
                if !cur.isEmpty { out.append((cur, true, curved)) }
                cur = []; curved = false
            @unknown default: break
            }
            if cur.count > limit || out.count > limit { tooMany = true }
        }
        if tooMany { return nil }
        if !cur.isEmpty { out.append((cur, false, curved)) }
        return out
    }

    /// The rectangle a path describes when it is a single axis-aligned rectangle.
    static func axisAlignedRect(_ p: CGPath) -> CGRect? {
        guard let subs = polylines(p, limit: 6), subs.count == 1, !subs[0].curved else { return nil }
        var pts = subs[0].points
        if pts.count == 5, hypot(pts[4].x - pts[0].x, pts[4].y - pts[0].y) < 0.01 { pts.removeLast() }
        guard pts.count == 4 else { return nil }
        let tol: CGFloat = 0.01
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4]
            let horizontal = abs(a.y - b.y) < tol, vertical = abs(a.x - b.x) < tol
            if horizontal == vertical { return nil }
            let c = pts[(i + 2) % 4]
            if horizontal ? abs(b.x - c.x) >= tol : abs(b.y - c.y) >= tol { return nil }   // must turn at every corner
        }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        return r.width > 0 && r.height > 0 ? r : nil
    }

    static func subpathCount(_ p: CGPath) -> Int {
        var n = 0
        p.applyWithBlock { e in if e.pointee.type == .moveToPoint { n += 1 } }
        return n
    }

    /// Closed subpaths with more than two points (the ones Lumen's shape renderer treats as filled regions).
    static func closedSubpathCount(_ p: CGPath) -> Int {
        var n = 0, pts = 0
        p.applyWithBlock { e in
            switch e.pointee.type {
            case .moveToPoint: pts = 1
            case .closeSubpath: if pts > 2 { n += 1 }; pts = 0
            default: pts += 1
            }
        }
        return n
    }

    /// Length of a path's control polygon (an upper bound of its length, cheap to get).
    static func roughLength(_ p: CGPath) -> CGFloat {
        var total: CGFloat = 0
        var cur = CGPoint.zero, start = CGPoint.zero
        func add(_ q: CGPoint) { total += hypot(q.x - cur.x, q.y - cur.y); cur = q }
        p.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: cur = pts[0]; start = cur
            case .addLineToPoint: add(pts[0])
            case .addQuadCurveToPoint: add(pts[0]); add(pts[1])
            case .addCurveToPoint: add(pts[0]); add(pts[1]); add(pts[2])
            case .closeSubpath: add(start)
            @unknown default: break
            }
        }
        return total
    }

    static func elementCount(_ p: CGPath) -> Int {
        var n = 0
        p.applyWithBlock { _ in n += 1 }
        return n
    }

    /// True when some corner of the path is mitered under one of the two miter limits but bevelled under the other.
    static func hasCornerBetween(_ p: CGPath, _ l1: Double, _ l2: Double) -> Bool {
        let lo = min(l1, l2), hi = max(l1, l2)
        if hi - lo < 0.01 { return false }
        var found = false
        var first: CGPoint? = nil, firstOut: CGPoint? = nil
        var cur = CGPoint.zero
        var lastIn: CGPoint? = nil
        func dir(_ a: CGPoint, _ b: CGPoint) -> CGPoint? {
            let dx = b.x - a.x, dy = b.y - a.y
            let l = hypot(dx, dy)
            return l > 1e-9 ? CGPoint(x: dx / l, y: dy / l) : nil
        }
        func corner(_ i: CGPoint?, _ o: CGPoint?) {
            guard let i, let o else { return }
            // angle between the segments at the join; miter length / width = 1 / sin(angle / 2)
            let cosTurn = Double(i.x * o.x + i.y * o.y)
            let phi = Double.pi - acos(max(-1, min(1, cosTurn)))
            let s = sin(phi / 2)
            guard s > 1e-6 else { found = true; return }
            let ratio = 1 / s
            if ratio > lo && ratio <= hi { found = true }
        }
        func segment(start: CGPoint, outDir: CGPoint?, inDir: CGPoint?, end: CGPoint) {
            if first != nil, firstOut == nil { firstOut = outDir }
            corner(lastIn, outDir)
            lastIn = inDir
            cur = end
        }
        p.applyWithBlock { e in
            if found { return }
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint:
                first = pts[0]; firstOut = nil; lastIn = nil; cur = pts[0]
            case .addLineToPoint:
                let d = dir(cur, pts[0])
                segment(start: cur, outDir: d, inDir: d, end: pts[0])
            case .addQuadCurveToPoint:
                segment(start: cur, outDir: dir(cur, pts[0]) ?? dir(cur, pts[1]), inDir: dir(pts[0], pts[1]) ?? dir(cur, pts[1]), end: pts[1])
            case .addCurveToPoint:
                let o = dir(cur, pts[0]) ?? dir(cur, pts[1]) ?? dir(cur, pts[2])
                let i = dir(pts[1], pts[2]) ?? dir(pts[0], pts[2]) ?? dir(cur, pts[2])
                segment(start: cur, outDir: o, inDir: i, end: pts[2])
            case .closeSubpath:
                if let f = first {
                    if let d = dir(cur, f) { corner(lastIn, d); lastIn = d }
                    corner(lastIn, firstOut)
                }
                first = nil; firstOut = nil; lastIn = nil
            @unknown default: break
            }
        }
        return found
    }

    /// Outline of a stroke drawn with a pen defined in user space (exact for non-uniform scaling and dash phases).
    /// `path` is in document space.
    static func strokeOutline(_ path: CGPath, ctm: CGAffineTransform, width: Double, cap: Int, join: Int, miter: Double, dash: [Double], phase: Double) -> CGPath? {
        let det = ctm.a * ctm.d - ctm.b * ctm.c
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        var inv = ctm.inverted()
        guard var user = path.copy(using: &inv) else { return nil }
        if !dash.isEmpty, dash.contains(where: { $0 > 0 }) {
            // a dash pattern far finer than the path is long would make an outline of millions of pieces
            let period = dash.reduce(0, +)
            let b = user.boundingBoxOfPath
            guard period > 0, Double(b.width + b.height) * 4 * Double(max(1, elementCount(user))) / period < 20_000 else { return nil }
            user = user.copy(dashingWithPhase: CGFloat(phase), lengths: dash.map { CGFloat($0) })
        }
        let w = width > 0 ? CGFloat(width) : 1 / sqrt(abs(det))
        let caps: [CGLineCap] = [.butt, .round, .square]
        let joins: [CGLineJoin] = [.miter, .round, .bevel]
        let outline = user.copy(strokingWithWidth: w, lineCap: caps[max(0, min(2, cap))], lineJoin: joins[max(0, min(2, join))], miterLimit: CGFloat(miter), transform: ctm)
        if outline.isEmpty { return nil }
        return normalized(outline, using: .winding) ?? outline
    }

    /// `CGPath.normalized` for paths of a sane size: the clipper behind it is quadratic in the worst case and can
    /// take tens of seconds on a path with tens of thousands of crossing segments. nil = too large to normalize.
    static func normalized(_ p: CGPath, using rule: CGPathFillRule, limit: Int = 4000) -> CGPath? {
        var n = 0
        p.applyWithBlock { e in n += e.pointee.type == .addCurveToPoint || e.pointee.type == .addQuadCurveToPoint ? 4 : 1 }
        // curves are flattened in proportion to their size: a path far larger than any canvas is as bad as a long one
        let b = p.boundingBoxOfPath
        guard n <= limit, !b.isNull, b.width.isFinite, b.height.isFinite, b.width < 100_000, b.height < 100_000 else { return nil }
        return p.normalized(using: rule)
    }

    /// Rewrites closed subpaths as open ones that start and end in the middle of their first segment. Stroked, they
    /// look the same (the two ends meet flush on a smooth stretch), but several of them can share one shape layer
    /// without the renderer merging their outlines.
    static func openingClosedSubpaths(_ p: CGPath) -> CGPath {
        struct Seg { var type: CGPathElementType; var pts: [CGPoint] }
        let out = CGMutablePath()
        var start = CGPoint.zero
        var segs: [Seg] = []
        var has = false
        func flush(closed: Bool) {
            guard has, !segs.isEmpty else { segs = []; has = false; return }
            defer { segs = []; has = false }
            var cur = start
            var all = segs
            if closed, let lastEnd = all.last?.pts.last, hypot(lastEnd.x - start.x, lastEnd.y - start.y) > 1e-6 { all.append(Seg(type: .addLineToPoint, pts: [start])) }
            guard closed, all.count >= 2 else {
                out.move(to: start)
                for s in segs { add(s) }
                if closed { out.closeSubpath() }
                return
            }
            // split the first segment at its midpoint
            let f = all[0]
            var head: Seg, tail: Seg
            let mid: CGPoint
            switch f.type {
            case .addCurveToPoint:
                let p0 = cur, p1 = f.pts[0], p2 = f.pts[1], p3 = f.pts[2]
                let a = mp(p0, p1), b = mp(p1, p2), c = mp(p2, p3), d = mp(a, b), e = mp(b, c)
                mid = mp(d, e)
                head = Seg(type: .addCurveToPoint, pts: [a, d, mid]); tail = Seg(type: .addCurveToPoint, pts: [e, c, p3])
            case .addQuadCurveToPoint:
                let p0 = cur, p1 = f.pts[0], p2 = f.pts[1]
                let a = mp(p0, p1), b = mp(p1, p2)
                mid = mp(a, b)
                head = Seg(type: .addQuadCurveToPoint, pts: [a, mid]); tail = Seg(type: .addQuadCurveToPoint, pts: [b, p2])
            default:
                mid = mp(cur, f.pts[0])
                head = Seg(type: .addLineToPoint, pts: [mid]); tail = Seg(type: .addLineToPoint, pts: [f.pts[0]])
            }
            out.move(to: mid)
            add(tail)
            for s in all.dropFirst() { add(s) }
            add(head)
            cur = mid
        }
        func mp(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        func add(_ s: Seg) {
            switch s.type {
            case .addLineToPoint: out.addLine(to: s.pts[0])
            case .addQuadCurveToPoint: out.addQuadCurve(to: s.pts[1], control: s.pts[0])
            case .addCurveToPoint: out.addCurve(to: s.pts[2], control1: s.pts[0], control2: s.pts[1])
            default: break
            }
        }
        p.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: flush(closed: false); start = pts[0]; has = true
            case .addLineToPoint: segs.append(Seg(type: .addLineToPoint, pts: [pts[0]]))
            case .addQuadCurveToPoint: segs.append(Seg(type: .addQuadCurveToPoint, pts: [pts[0], pts[1]]))
            case .addCurveToPoint: segs.append(Seg(type: .addCurveToPoint, pts: [pts[0], pts[1], pts[2]]))
            case .closeSubpath:
                let s = start
                flush(closed: true)
                start = s; has = true   // drawing may continue from the start point
            @unknown default: break
            }
        }
        if has && !segs.isEmpty { flush(closed: false) }
        return out
    }

    /// Path construction operators for `p` transformed by `t`.
    static func pathOperators(_ p: CGPath, _ t: CGAffineTransform) -> String {
        var out = ""
        func pt(_ q: CGPoint) -> String { let r = q.applying(t); return PDFVectorWriter.number(Double(r.x)) + " " + PDFVectorWriter.number(Double(r.y)) }
        var cur = CGPoint.zero
        p.applyWithBlock { e in
            let pts = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint: out += pt(pts[0]) + " m\n"; cur = pts[0]
            case .addLineToPoint: out += pt(pts[0]) + " l\n"; cur = pts[0]
            case .addQuadCurveToPoint:
                let c1 = CGPoint(x: cur.x + (pts[0].x - cur.x) * 2 / 3, y: cur.y + (pts[0].y - cur.y) * 2 / 3)
                let c2 = CGPoint(x: pts[1].x + (pts[0].x - pts[1].x) * 2 / 3, y: pts[1].y + (pts[0].y - pts[1].y) * 2 / 3)
                out += pt(c1) + " " + pt(c2) + " " + pt(pts[1]) + " c\n"; cur = pts[1]
            case .addCurveToPoint: out += pt(pts[0]) + " " + pt(pts[1]) + " " + pt(pts[2]) + " c\n"; cur = pts[2]
            case .closeSubpath: out += "h\n"
            @unknown default: break
            }
        }
        return out
    }


    // MARK: Text geometry

    /// Offset from `p` to `q` measured along and across the baseline of a text basis, and the basis' em size in pixels.
    static func offset(from p: CGPoint, to q: CGPoint, basis b: CGAffineTransform) -> (along: CGFloat, across: CGFloat, size: CGFloat) {
        let lx = hypot(b.a, b.b), ly = hypot(b.c, b.d)
        guard lx > 1e-9, ly > 1e-9 else { return (0, 0, 0) }
        let dx = q.x - p.x, dy = q.y - p.y
        return ((dx * b.a + dy * b.b) / lx, (dx * b.c + dy * b.d) / ly, ly)
    }

    /// Same baseline direction and upright direction (sizes may differ).
    static func sameDirection(_ a: CGAffineTransform, _ b: CGAffineTransform) -> Bool {
        let ax = hypot(a.a, a.b), ay = hypot(a.c, a.d), bx = hypot(b.a, b.b), by = hypot(b.c, b.d)
        guard ax > 1e-9, ay > 1e-9, bx > 1e-9, by > 1e-9 else { return false }
        return (a.a * b.a + a.b * b.b) / (ax * bx) > 0.9995 && (a.c * b.c + a.d * b.d) / (ay * by) > 0.9995
    }

    /// The path as Lumen's anchors. A closed loop made of one curve comes out of `VectorPath.from` as a single
    /// anchor, which the shape renderer cannot draw: such loops get a second anchor half way round.
    static func vectorPath(_ cg: CGPath) -> VectorPath {
        var vp = VectorPath.from(cgPath: cg)
        for k in vp.subpaths.indices where vp.subpaths[k].closed && vp.subpaths[k].points.count == 1 && vp.subpaths[k].points[0].hasHandles {
            let p = vp.subpaths[k].points[0]
            func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
            let a = mid(p.anchor, p.outControl), b = mid(p.outControl, p.inControl), c = mid(p.inControl, p.anchor)
            let ab = mid(a, b), bc = mid(b, c)
            vp.subpaths[k].points = [PathPoint(anchor: p.anchor, inControl: c, outControl: a, isSmooth: false),
                                     PathPoint(anchor: mid(ab, bc), inControl: ab, outControl: bc, isSmooth: true)]
        }
        vp.subpaths.removeAll { $0.points.count < 2 }
        return vp
    }
}
