import Foundation
import CoreGraphics
import ImageCratCore

/// Geometry of shape strokes: what path is stroked how (`plan`), dashes laid out along a path with a dash centred on
/// every corner (`alignedDashes`), the contours inside / outside dashed strokes run along (`offsetContours`), and the
/// exact area a stroke covers, miter spikes included (`strokeBounds`).
///
/// Solid inside / outside strokes are drawn twice as wide and clipped to the shape (exact, cheap). Dashed ones are
/// drawn along a contour half a stroke width inside / outside the shape instead, so dashes and round dots keep their
/// shape rather than being cut in half by the clip.
enum StrokeGeometry {
    enum Clip { case none, inside, outside }

    struct Plan {
        /// The path to stroke (the shape outline, an offset contour, or ready-made dash pieces).
        var path: CGPath
        var lineWidth: CGFloat
        /// Core Graphics dash to set while stroking (exact dashes); nil when `path` is already dashed or the stroke is solid.
        var dash: (phase: CGFloat, lengths: [CGFloat])?
        var clip: Clip
        var cap: CGLineCap
        var join: CGLineJoin
        var miterLimit: CGFloat
    }

    /// Core Graphics' default, which Lumen strokes use when `StrokeStyle.miterLimit` is nil.
    static let defaultMiterLimit: CGFloat = 10

    /// Dash lengths in px (stroke widths × width), nil when the stroke is solid (no dashes, or a pattern of zero length).
    static func dashLengths(_ st: StrokeStyle) -> [CGFloat]? {
        guard !st.dash.isEmpty else { return nil }
        let w = max(0, st.width)
        let l = st.dash.map { CGFloat(max(0, $0.isFinite ? $0 : 0) * w) }
        guard l.reduce(0, +) > 0.01 else { return nil }
        return l.count % 2 == 1 ? l + l : l
    }

    /// How the stroke of `s` is drawn; nil when it has none.
    static func plan(_ s: ShapeContent) -> Plan? {
        let st = s.stroke
        guard !st.paint.isNone, st.width > 0, st.width.isFinite else { return nil }
        let (path, evenOdd) = s.path.resolved
        let w = CGFloat(st.width)
        let miter = CGFloat(max(1, st.miterLimit ?? Double(defaultMiterLimit)))
        guard let lengths = dashLengths(st) else {
            switch st.alignment {
            case .center: return Plan(path: path, lineWidth: w, dash: nil, clip: .none, cap: st.cap.cg, join: st.join.cg, miterLimit: miter)
            case .inside: return Plan(path: path, lineWidth: w * 2, dash: nil, clip: .inside, cap: st.cap.cg, join: st.join.cg, miterLimit: miter)
            case .outside: return Plan(path: path, lineWidth: w * 2, dash: nil, clip: .outside, cap: st.cap.cg, join: st.join.cg, miterLimit: miter)
            }
        }
        var base = path
        if st.alignment != .center {
            base = offsetContours(path, evenOdd: evenOdd, distance: w / 2, inside: st.alignment == .inside, join: st.join.cg, miterLimit: miter)
        }
        let phase = CGFloat((st.dashPhase ?? 0).isFinite ? (st.dashPhase ?? 0) : 0) * w
        if st.dashAlignment == .corners, let dashed = alignedDashes(base, lengths: lengths, phase: phase) {
            return Plan(path: dashed, lineWidth: w, dash: nil, clip: .none, cap: st.cap.cg, join: st.join.cg, miterLimit: miter)
        }
        return Plan(path: base, lineWidth: w, dash: (phase, lengths), clip: .none, cap: st.cap.cg, join: st.join.cg, miterLimit: miter)
    }

    // MARK: Bounds

    private static var boundsCache: [(ShapeContent, CGRect)] = []
    private static let lock = NSLock()

    /// Doc-space area the stroke of `s` covers (`.null` without a stroke): the stroked outline, so miter joins at sharp
    /// corners (stars, triangles) count with their full reach.
    static func strokeBounds(_ s: ShapeContent) -> CGRect {
        guard !s.stroke.paint.isNone, s.stroke.width > 0 else { return .null }
        lock.lock()
        if let hit = boundsCache.first(where: { $0.0 == s }) { lock.unlock(); return hit.1 }
        lock.unlock()
        var r = CGRect.null
        if let p = plan(s) {
            let outline = p.path.copy(strokingWithWidth: p.lineWidth, lineCap: p.cap, lineJoin: p.join, miterLimit: p.miterLimit)
            r = outline.boundingBoxOfPath
            if p.clip == .inside { r = r.intersection(s.path.bounds) }
            if r.isNull || !r.origin.x.isFinite || !r.width.isFinite { r = .null }
        }
        lock.lock()
        boundsCache.append((s, r))
        if boundsCache.count > 64 { boundsCache.removeFirst() }
        lock.unlock()
        return r
    }

    // MARK: Path walking

    enum Seg {
        case line(CGPoint, CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint, CGPoint)

        var start: CGPoint { switch self { case .line(let a, _): return a; case .cubic(let a, _, _, _): return a } }
        var end: CGPoint { switch self { case .line(_, let b): return b; case .cubic(_, _, _, let b): return b } }

        func point(_ t: CGFloat) -> CGPoint {
            switch self {
            case .line(let a, let b): return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            case .cubic(let p0, let p1, let p2, let p3):
                let u = 1 - t
                let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
            }
        }

        /// Unit tangent at t (falls back to the chord where the curve's derivative vanishes).
        func tangent(_ t: CGFloat) -> CGPoint {
            var d: CGPoint
            switch self {
            case .line(let a, let b): d = CGPoint(x: b.x - a.x, y: b.y - a.y)
            case .cubic(let p0, let p1, let p2, let p3):
                let u = 1 - t
                d = CGPoint(x: 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x),
                            y: 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y))
                if hypot(d.x, d.y) < 1e-9 {
                    // a handle sits on its anchor: look a little further along
                    let q = point(min(1, max(0, t < 0.5 ? t + 0.001 : t - 0.001)))
                    let p = point(t)
                    d = t < 0.5 ? CGPoint(x: q.x - p.x, y: q.y - p.y) : CGPoint(x: p.x - q.x, y: p.y - q.y)
                    if hypot(d.x, d.y) < 1e-12 { d = CGPoint(x: p3.x - p0.x, y: p3.y - p0.y) }
                }
            }
            let l = hypot(d.x, d.y)
            return l > 0 ? CGPoint(x: d.x / l, y: d.y / l) : CGPoint(x: 1, y: 0)
        }

        /// The part between t0 and t1 (t0 < t1).
        func slice(_ t0: CGFloat, _ t1: CGFloat) -> Seg {
            switch self {
            case .line: return .line(point(t0), point(t1))
            case .cubic(let p0, let p1, let p2, let p3):
                // left part up to t1, then the right part of that from t0 / t1
                func split(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint, _ t: CGFloat) -> ((CGPoint, CGPoint, CGPoint, CGPoint), (CGPoint, CGPoint, CGPoint, CGPoint)) {
                    func l(_ p: CGPoint, _ q: CGPoint) -> CGPoint { CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t) }
                    let ab = l(a, b), bc = l(b, c), cd = l(c, d), abc = l(ab, bc), bcd = l(bc, cd), m = l(abc, bcd)
                    return ((a, ab, abc, m), (m, bcd, cd, d))
                }
                let left = split(p0, p1, p2, p3, t1).0
                let s = t1 > 1e-9 ? t0 / t1 : 0
                let r = split(left.0, left.1, left.2, left.3, s).1
                return .cubic(r.0, r.1, r.2, r.3)
            }
        }

        func add(to p: CGMutablePath) {
            switch self {
            case .line(_, let b): p.addLine(to: b)
            case .cubic(_, let c1, let c2, let b): p.addCurve(to: b, control1: c1, control2: c2)
            }
        }
    }

    /// One subpath, measured: cumulative arc length per segment and a t → length table for each curve.
    struct Measured {
        var segs: [Seg]
        var closed: Bool
        var starts: [CGFloat] = []      // arc length at each segment's start
        var lengths: [CGFloat] = []
        var tables: [[CGFloat]] = []    // cumulative length at t = i / (n - 1)
        var total: CGFloat = 0

        static let samples = 33

        init(_ segs: [Seg], closed: Bool) {
            self.segs = segs
            self.closed = closed
            for s in segs {
                starts.append(total)
                switch s {
                case .line(let a, let b):
                    let l = hypot(b.x - a.x, b.y - a.y)
                    lengths.append(l); tables.append([0, l])
                case .cubic:
                    var acc: CGFloat = 0
                    var tab: [CGFloat] = [0]
                    var prev = s.point(0)
                    for i in 1..<Measured.samples {
                        let q = s.point(CGFloat(i) / CGFloat(Measured.samples - 1))
                        acc += hypot(q.x - prev.x, q.y - prev.y)
                        tab.append(acc)
                        prev = q
                    }
                    lengths.append(acc); tables.append(tab)
                }
                total += lengths.last!
            }
        }

        /// Segment index and parameter at arc length `s` (clamped to the subpath).
        func locate(_ s: CGFloat) -> (Int, CGFloat) {
            guard !segs.isEmpty else { return (0, 0) }
            let x = min(max(0, s), total)
            var i = segs.count - 1
            for k in 0..<segs.count where x < starts[k] + lengths[k] { i = k; break }
            let local = x - starts[i]
            let tab = tables[i]
            guard lengths[i] > 0 else { return (i, 0) }
            if tab.count == 2 { return (i, min(1, local / lengths[i])) }
            var j = 1
            while j < tab.count - 1 && tab[j] < local { j += 1 }
            let a = tab[j - 1], b = tab[j]
            let f = b > a ? (local - a) / (b - a) : 0
            return (i, min(1, (CGFloat(j - 1) + f) / CGFloat(tab.count - 1)))
        }

        func point(at s: CGFloat) -> CGPoint { let (i, t) = locate(s); return segs[i].point(t) }
        func tangent(at s: CGFloat) -> CGPoint { let (i, t) = locate(s); return segs[i].tangent(t) }

        /// Appends the stretch from arc length a to b (a ≤ b, both within the subpath) as a new subpath of `p`.
        func append(from a: CGFloat, to b: CGFloat, to p: CGMutablePath) {
            let (i0, t0) = locate(a), (i1, t1) = locate(b)
            p.move(to: segs[i0].point(t0))
            if i0 == i1 {
                if t1 > t0 { segs[i0].slice(t0, t1).add(to: p) }
                return
            }
            if t0 < 1 { segs[i0].slice(t0, 1).add(to: p) }
            if i1 > i0 + 1 { for k in (i0 + 1)..<i1 { segs[k].add(to: p) } }
            if t1 > 0 { segs[i1].slice(0, t1).add(to: p) }
        }
    }

    /// The subpaths of a CG path as segments (quadratics raised to cubics, zero-length pieces dropped).
    static func subpaths(_ path: CGPath) -> [Measured] {
        var out: [Measured] = []
        var segs: [Seg] = []
        var start = CGPoint.zero, cur = CGPoint.zero
        func flush(closed: Bool) {
            if !segs.isEmpty { out.append(Measured(segs, closed: closed)) }
            segs = []
        }
        func push(_ s: Seg) {
            switch s {
            case .line(let a, let b): if hypot(b.x - a.x, b.y - a.y) < 1e-6 { return }
            case .cubic(let a, let c1, let c2, let b):
                if hypot(b.x - a.x, b.y - a.y) < 1e-6 && hypot(c1.x - a.x, c1.y - a.y) < 1e-6 && hypot(c2.x - a.x, c2.y - a.y) < 1e-6 { return }
            }
            segs.append(s)
        }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                flush(closed: false)
                start = e.points[0]; cur = start
            case .addLineToPoint:
                push(.line(cur, e.points[0])); cur = e.points[0]
            case .addQuadCurveToPoint:
                let q = e.points[0], b = e.points[1]
                let c1 = CGPoint(x: cur.x + (q.x - cur.x) * 2 / 3, y: cur.y + (q.y - cur.y) * 2 / 3)
                let c2 = CGPoint(x: b.x + (q.x - b.x) * 2 / 3, y: b.y + (q.y - b.y) * 2 / 3)
                push(.cubic(cur, c1, c2, b)); cur = b
            case .addCurveToPoint:
                push(.cubic(cur, e.points[0], e.points[1], e.points[2])); cur = e.points[2]
            case .closeSubpath:
                push(.line(cur, start))
                flush(closed: true)
                cur = start
            @unknown default: break
            }
        }
        flush(closed: false)
        return out
    }

    // MARK: Dashes aligned to corners

    /// Turning angle above which an anchor counts as a corner.
    static let cornerAngle: CGFloat = 12 * .pi / 180

    /// Arc lengths of the corners of a subpath (closed: every sharp anchor; open: the sharp inner anchors).
    static func corners(_ m: Measured) -> [CGFloat] {
        var out: [CGFloat] = []
        let n = m.segs.count
        guard n > 1 || m.closed else { return [] }
        let cosLimit = cos(cornerAngle)
        for i in 0..<n {
            if i == 0 && !m.closed { continue }
            let prev = m.segs[(i - 1 + n) % n], next = m.segs[i]
            let a = prev.tangent(1), b = next.tangent(0)
            if a.x * b.x + a.y * b.y < cosLimit { out.append(m.starts[i]) }
        }
        return out
    }

    /// Dash pieces of `path` with the pattern stretched or squeezed (by as little as possible) so that a dash is centred
    /// on every corner, closed paths without corners repeat seamlessly, and open paths start and end with a whole dash.
    /// Zero-length dashes come out as tiny pieces along the path, so round caps draw them as round dots and square caps
    /// as squares turned with the path. nil when the pattern is too fine to lay out piece by piece.
    static func alignedDashes(_ path: CGPath, lengths pattern: [CGFloat], phase: CGFloat = 0) -> CGPath? {
        let period = pattern.reduce(0, +)
        guard period > 0.01 else { return nil }
        let out = CGMutablePath()
        var pieces = 0
        // dash intervals of one period: [start, end] in pattern units
        var dashes: [(CGFloat, CGFloat)] = []
        var u: CGFloat = 0
        for (k, l) in pattern.enumerated() {
            if k % 2 == 0 { dashes.append((u, u + l)) }
            u += l
        }
        let d0 = pattern[0]
        for m in subpaths(path) where m.total > 0.01 {
            // runs between corners: (start, end, half dash at start, half dash at end)
            var runs: [(CGFloat, CGFloat, Bool, Bool)] = []
            let cs = corners(m)
            if m.closed {
                if cs.isEmpty {
                    runs = [(0, m.total, true, true)]
                } else {
                    for (k, c) in cs.enumerated() {
                        let next = k + 1 < cs.count ? cs[k + 1] : cs[0] + m.total
                        runs.append((c, next, true, true))
                    }
                }
            } else {
                let b = [CGFloat(0)] + cs + [m.total]
                for k in 0..<(b.count - 1) { runs.append((b[k], b[k + 1], k > 0, k < b.count - 2)) }
            }
            var intervals: [(CGFloat, CGFloat)] = []
            for (s0, s1, halfStart, halfEnd) in runs {
                let L = s1 - s0
                guard L > 1e-6 else { continue }
                let u0 = halfStart ? d0 / 2 : 0
                let extra = (halfEnd ? d0 / 2 : d0) - u0
                var n = ((L - extra) / period).rounded()
                if n < 0 { n = 0 }
                if n == 0 && extra <= 1e-9 { n = 1 }
                let covered = n * period + extra
                guard covered > 1e-9 else { intervals.append((s0, s1)); continue }
                let k = L / covered
                let u1 = u0 + covered
                if n > 20_000 { return nil }
                var rep: CGFloat = 0
                while rep * period <= u1 + 1e-9 {
                    for (a, b) in dashes {
                        let da = rep * period + a, db = rep * period + b
                        let lo = max(da, u0), hi = min(db, u1)
                        // a zero-length dash exactly at a run end still counts (dots on corners and path ends)
                        if hi < lo - 1e-9 || (hi <= lo && (db > da) ) { continue }
                        if da > u1 + 1e-9 || db < u0 - 1e-9 { continue }
                        intervals.append((s0 + (lo - u0) * k, s0 + (hi - u0) * k))
                    }
                    rep += 1
                }
            }
            _ = phase   // aligned dashes are anchored to the corners; the offset does not apply
            // merge pieces that meet (across corners, and around the start of a closed path)
            intervals.sort { $0.0 < $1.0 }
            var merged: [(CGFloat, CGFloat)] = []
            for iv in intervals {
                if var last = merged.last, iv.0 <= last.1 + 1e-6 {
                    last.1 = max(last.1, iv.1)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(iv)
                }
            }
            // closed path: intervals are in [c0, c0 + total); wrap them into [0, total) and join across the seam
            if m.closed {
                var wrapped: [(CGFloat, CGFloat)] = []
                for (a, b) in merged {
                    var a2 = a, b2 = b
                    while a2 >= m.total - 1e-9 { a2 -= m.total; b2 -= m.total }
                    wrapped.append((a2, b2))
                }
                wrapped.sort { $0.0 < $1.0 }
                merged = []
                for iv in wrapped {
                    if var last = merged.last, iv.0 <= last.1 + 1e-6 { last.1 = max(last.1, iv.1); merged[merged.count - 1] = last } else { merged.append(iv) }
                }
                if merged.count > 1, let first = merged.first, let last = merged.last, last.1 >= m.total - 1e-6 && first.0 <= 1e-6 {
                    merged.removeFirst()
                    merged[merged.count - 1].1 = m.total + first.1
                }
                if merged.count == 1, merged[0].1 - merged[0].0 >= m.total - 1e-6 {
                    // one dash all the way round: the whole closed outline (keeps the join at the start point)
                    for s in m.segs.indices {
                        if s == 0 { out.move(to: m.segs[0].start) }
                        m.segs[s].add(to: out)
                    }
                    out.closeSubpath()
                    pieces += 1
                    continue
                }
            }
            for (a, b) in merged {
                pieces += 1
                if b - a < 0.01 {
                    // a dot: a tiny piece along the path, so caps point the right way
                    let c = (a + b) / 2
                    let s = m.closed ? c.truncatingRemainder(dividingBy: m.total) : min(max(c, 0), m.total)
                    let p = m.point(at: s), t = m.tangent(at: s)
                    out.move(to: CGPoint(x: p.x - t.x * 0.005, y: p.y - t.y * 0.005))
                    out.addLine(to: CGPoint(x: p.x + t.x * 0.005, y: p.y + t.y * 0.005))
                } else if b > m.total + 1e-9 {
                    m.append(from: a, to: m.total, to: out)
                    // continue the same piece past the seam
                    let tail = CGMutablePath()
                    m.append(from: 0, to: b - m.total, to: tail)
                    var first = true
                    tail.applyWithBlock { el in
                        let e = el.pointee
                        switch e.type {
                        case .moveToPoint: if !first { out.move(to: e.points[0]) }; first = false
                        case .addLineToPoint: out.addLine(to: e.points[0])
                        case .addCurveToPoint: out.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
                        case .addQuadCurveToPoint: out.addQuadCurve(to: e.points[1], control: e.points[0])
                        default: break
                        }
                    }
                } else {
                    m.append(from: a, to: b, to: out)
                }
            }
            if pieces > 50_000 { return nil }
        }
        return out
    }

    // MARK: Offset contours

    /// The closed subpaths of `path` moved `distance` inward or outward (with `join` corners), plus its open subpaths
    /// unchanged: the line an inside / outside dashed stroke is centred on.
    static func offsetContours(_ path: CGPath, evenOdd: Bool, distance: CGFloat, inside: Bool, join: CGLineJoin, miterLimit: CGFloat) -> CGPath {
        let closed = CGMutablePath(), open = CGMutablePath()
        for m in subpaths(path) {
            let target = m.closed ? closed : open
            guard let first = m.segs.first else { continue }
            target.move(to: first.start)
            for s in m.segs { s.add(to: target) }
            if m.closed { target.closeSubpath() }
        }
        let out = CGMutablePath()
        if !closed.isEmpty, distance > 0 {
            let ring = closed.copy(strokingWithWidth: distance * 2, lineCap: .butt, lineJoin: join, miterLimit: miterLimit).normalized(using: .winding)
            let rule: CGPathFillRule = evenOdd ? .evenOdd : .winding
            for m in subpaths(ring) where m.closed {
                guard let probe = m.segs.first?.point(0.5) ?? m.segs.first?.start else { continue }
                let isInside = path.contains(probe, using: rule)
                guard isInside == inside else { continue }
                out.move(to: m.segs[0].start)
                for s in m.segs { s.add(to: out) }
                out.closeSubpath()
            }
        }
        out.addPath(open)
        return out
    }
}
