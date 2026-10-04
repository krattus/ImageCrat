import Foundation
import CoreGraphics
import ImageCratCore

// SVG import, part 5: element geometry (basic shapes, viewBox mapping, fill-rule and stroke conversions) and names.

struct SVGImportShape {
    enum Kind { case rect(CGRect, radius: Double), ellipse(CGRect), path }
    /// Outline in the element's user space.
    var path: CGPath
    var kind: Kind
    var defaultName: String
}

enum SVGImportGeometry {
    // MARK: Basic shapes

    static func shape(_ n: SVGImportNode, style: SVGImportStyle, viewport: CGSize) -> SVGImportShape? {
        let vw = Double(viewport.width), vh = Double(viewport.height), vd = ((vw * vw + vh * vh) / 2).squareRoot()
        func len(_ name: String, _ ref: Double) -> Double? {
            // geometry may also come from CSS (SVG 2: x, y, width, r … are properties)
            guard let l = SVGImportValue.length(n.attrs[name] ?? n.decls[name]) else { return nil }
            let v = l.resolve(percentOf: ref, fontSize: style.fontSize)
            return v.isFinite ? v : nil
        }
        switch n.tag {
        case "path":
            var d = n.attrs["d"]
            if d == nil, let css = n.decls["d"], let a = css.range(of: "path(") {       // CSS `d: path("…")`
                d = css[a.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " \"')"))
            }
            let p = SVGImportValue.withDrawableDots(SVGImportValue.path(d))
            return p.isEmpty ? nil : SVGImportShape(path: p, kind: .path, defaultName: "Path")
        case "rect":
            guard let w = len("width", vw), let h = len("height", vh), w > 0, h > 0 else { return nil }
            let x = len("x", vw) ?? 0, y = len("y", vh) ?? 0
            var rx = len("rx", vw), ry = len("ry", vh)
            if let v = rx, v < 0 { rx = nil }
            if let v = ry, v < 0 { ry = nil }
            var ex = rx ?? ry ?? 0, ey = ry ?? rx ?? 0
            ex = min(ex, w / 2); ey = min(ey, h / 2)
            let r = CGRect(x: x, y: y, width: w, height: h)
            if abs(ex - ey) < 1e-9 || ex <= 0 || ey <= 0 {
                let rad = ex <= 0 || ey <= 0 ? 0 : ex
                return SVGImportShape(path: VectorPath.rect(r, radius: rad).cgPath, kind: .rect(r, radius: rad), defaultName: rad > 0 ? "Rounded Rectangle" : "Rectangle")
            }
            let p = CGMutablePath()
            p.addRoundedRect(in: r, cornerWidth: CGFloat(ex), cornerHeight: CGFloat(ey))
            return SVGImportShape(path: p, kind: .path, defaultName: "Rounded Rectangle")
        case "circle":
            guard let r = len("r", vd), r > 0 else { return nil }
            let cx = len("cx", vw) ?? 0, cy = len("cy", vh) ?? 0
            let rect = CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)
            return SVGImportShape(path: ellipsePath(rect), kind: .ellipse(rect), defaultName: "Ellipse")
        case "ellipse":
            var rx = len("rx", vw), ry = len("ry", vh)
            if rx == nil { rx = ry }
            if ry == nil { ry = rx }
            guard let a = rx, let b = ry, a > 0, b > 0 else { return nil }
            let cx = len("cx", vw) ?? 0, cy = len("cy", vh) ?? 0
            let rect = CGRect(x: cx - a, y: cy - b, width: 2 * a, height: 2 * b)
            return SVGImportShape(path: ellipsePath(rect), kind: .ellipse(rect), defaultName: "Ellipse")
        case "line":
            let p = CGMutablePath()
            p.move(to: CGPoint(x: len("x1", vw) ?? 0, y: len("y1", vh) ?? 0))
            p.addLine(to: CGPoint(x: len("x2", vw) ?? 0, y: len("y2", vh) ?? 0))
            return SVGImportShape(path: p, kind: .path, defaultName: "Line")
        case "polyline", "polygon":
            let pts = SVGImportValue.points(n.attrs["points"])
            guard pts.count >= 2 else { return nil }
            let p = CGMutablePath()
            p.move(to: pts[0])
            for q in pts.dropFirst() { p.addLine(to: q) }
            if n.tag == "polygon" { p.closeSubpath() }
            return SVGImportShape(path: p, kind: .path, defaultName: n.tag == "polygon" ? "Polygon" : "Polyline")
        default:
            return nil
        }
    }

    /// Ellipse as SVG draws it: starting at the right-most point, clockwise on screen (dash patterns depend on it).
    static func ellipsePath(_ r: CGRect) -> CGPath {
        let k: CGFloat = 0.5522847498
        let cx = r.midX, cy = r.midY, rx = r.width / 2, ry = r.height / 2
        let p = CGMutablePath()
        p.move(to: CGPoint(x: cx + rx, y: cy))
        p.addCurve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + ry * k), control2: CGPoint(x: cx + rx * k, y: cy + ry))
        p.addCurve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - rx * k, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + ry * k))
        p.addCurve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - ry * k), control2: CGPoint(x: cx - rx * k, y: cy - ry))
        p.addCurve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + rx * k, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - ry * k))
        p.closeSubpath()
        return p
    }

    // MARK: viewBox

    /// Transform from viewBox coordinates into `viewport` (a rect in the parent's user space), per preserveAspectRatio.
    static func viewBoxTransform(_ vb: CGRect, _ par: String?, viewport: CGRect) -> CGAffineTransform {
        guard vb.width > 0, vb.height > 0 else { return CGAffineTransform(translationX: viewport.minX, y: viewport.minY) }
        var sx = viewport.width / vb.width, sy = viewport.height / vb.height
        let tokens = (par ?? "xMidYMid meet").split(separator: " ").map(String.init).filter { $0 != "defer" }
        let align = tokens.first ?? "xMidYMid"
        let slice = tokens.count > 1 && tokens[1] == "slice"
        var tx = viewport.minX - vb.minX * sx, ty = viewport.minY - vb.minY * sy
        if align != "none" {
            let s = slice ? max(sx, sy) : min(sx, sy)
            sx = s; sy = s
            let fx: CGFloat = align.contains("xMid") ? 0.5 : (align.contains("xMax") ? 1 : 0)
            let fy: CGFloat = align.contains("YMid") ? 0.5 : (align.contains("YMax") ? 1 : 0)
            tx = viewport.minX - vb.minX * s + (viewport.width - vb.width * s) * fx
            ty = viewport.minY - vb.minY * s + (viewport.height - vb.height * s) * fy
        }
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: tx, ty: ty)
    }

    static func viewBox(_ n: SVGImportNode) -> CGRect? {
        let v = SVGImportValue.numbers(n.attrs["viewBox"])
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }

    // MARK: Path utilities

    /// Transformed copy with every coordinate finite and inside ±`limit` (enormous coordinates would poison the
    /// rasterizers with NaN); nil when nothing drawable is left.
    static func docPath(_ p: CGPath, _ t: CGAffineTransform, limit: CGFloat = 4_000_000) -> CGPath? {
        var tt = t
        guard t.isFinite, let moved = p.copy(using: &tt) else { return nil }
        let b = moved.boundingBoxOfPath
        if b.isNull { return nil }
        if b.minX.isFinite, b.minY.isFinite, b.maxX.isFinite, b.maxY.isFinite, b.minX > -limit, b.minY > -limit, b.maxX < limit, b.maxY < limit { return moved }
        let out = CGMutablePath()
        func c(_ q: CGPoint) -> CGPoint { CGPoint(x: q.x.isFinite ? max(-limit, min(limit, q.x)) : 0, y: q.y.isFinite ? max(-limit, min(limit, q.y)) : 0) }
        moved.applyWithBlock { ep in
            let e = ep.pointee
            switch e.type {
            case .moveToPoint: out.move(to: c(e.points[0]))
            case .addLineToPoint: out.addLine(to: c(e.points[0]))
            case .addQuadCurveToPoint: out.addQuadCurve(to: c(e.points[1]), control: c(e.points[0]))
            case .addCurveToPoint: out.addCurve(to: c(e.points[2]), control1: c(e.points[0]), control2: c(e.points[1]))
            case .closeSubpath: out.closeSubpath()
            @unknown default: break
            }
        }
        return out
    }

    /// Absolute area of the region a path fills (flattened; for comparing regions, not for measuring).
    static func area(_ p: CGPath, evenOdd: Bool = false) -> Double {
        let n = p.normalized(using: evenOdd ? .evenOdd : .winding)
        var total = 0.0
        var start = CGPoint.zero, cur = CGPoint.zero
        var acc = 0.0
        func seg(_ a: CGPoint, _ b: CGPoint) { acc += Double(a.x * b.y - b.x * a.y) }
        func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) {
            var prev = a
            for i in 1...12 {
                let t = CGFloat(i) / 12, u = 1 - t
                let q = CGPoint(x: u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x,
                                y: u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y)
                seg(prev, q); prev = q
            }
        }
        n.applyWithBlock { ep in
            let e = ep.pointee
            switch e.type {
            case .moveToPoint: seg(cur, start); total += acc / 2; acc = 0; start = e.points[0]; cur = start
            case .addLineToPoint: seg(cur, e.points[0]); cur = e.points[0]
            case .addQuadCurveToPoint:
                let c = e.points[0], q = e.points[1]
                cubic(cur, cur + (c - cur) * (2.0 / 3.0), q + (c - q) * (2.0 / 3.0), q); cur = q
            case .addCurveToPoint: cubic(cur, e.points[0], e.points[1], e.points[2]); cur = e.points[2]
            case .closeSubpath: seg(cur, start); cur = start
            @unknown default: break
            }
        }
        seg(cur, start); total += acc / 2
        return abs(total)
    }

    /// True when the two paths fill (non-zero) the same region, within a small tolerance.
    static func sameRegion(_ a: CGPath, _ b: CGPath) -> Bool {
        let ref = max(area(a), area(b))
        if ref <= 1e-9 { return true }
        let diff = a.symmetricDifference(b, using: .winding)
        return area(diff) <= ref * 2e-3
    }

    /// A path that fills under the non-zero rule the way `p` fills under even-odd. Keeps `p` itself when the two rules
    /// already agree (most icons), so the anchors stay as authored.
    static func nonZeroEquivalent(ofEvenOdd p: CGPath) -> CGPath {
        var subpaths = 0
        p.applyWithBlock { if $0.pointee.type == .moveToPoint { subpaths += 1 } }
        let eo = p.normalized(using: .evenOdd)
        if subpaths > 600 { return eo }      // region comparison on huge compound paths costs more than it saves
        if sameRegion(eo, p.normalized(using: .winding)) { return p }
        return eo
    }

    /// Stroke outline (what the stroke paints) in the path's own coordinates.
    static func strokeOutline(_ p: CGPath, width: Double, cap: LineCapStyle, join: LineJoinStyle, miter: Double, dash: [Double], phase: Double) -> CGPath {
        var src = p
        if !dash.isEmpty {
            var d = dash.map { CGFloat($0) }
            if d.count % 2 == 1 { d += d }
            let period = d.reduce(0, +)
            var ph = period > 0 ? CGFloat(phase).truncatingRemainder(dividingBy: period) : 0
            if ph < 0 { ph += period }
            src = p.copy(dashingWithPhase: ph, lengths: d)
        }
        return src.copy(strokingWithWidth: CGFloat(width), lineCap: cap.cg, lineJoin: join.cg, miterLimit: CGFloat(max(1, miter)))
    }

    /// Whether stroking `a` and `b` with the same pen gives visibly different results (coarse coverage comparison).
    static func strokesDiffer(_ a: CGPath, _ b: CGPath, width: Double, cap: LineCapStyle, join: LineJoinStyle, miter: Double) -> Bool {
        let bounds = a.boundingBoxOfPath.union(b.boundingBoxOfPath).insetBy(dx: -CGFloat(width) * 2 - 1, dy: -CGFloat(width) * 2 - 1)
        guard !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return false }
        let side = 160
        let s = min(CGFloat(side) / bounds.width, CGFloat(side) / bounds.height)
        func render(_ p: CGPath) -> [UInt8]? {
            var buf = [UInt8](repeating: 0, count: side * side)
            let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side, space: graySpace,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.scaleBy(x: s, y: s)
                ctx.translateBy(x: -bounds.minX, y: -bounds.minY)
                ctx.setStrokeColor(gray: 1, alpha: 1)
                // never thinner than a pixel of this small bitmap, or thin strokes would all look alike
                ctx.setLineWidth(max(CGFloat(width), 1.5 / s))
                ctx.setLineCap(cap.cg); ctx.setLineJoin(join.cg); ctx.setMiterLimit(CGFloat(max(1, miter)))
                ctx.addPath(p)
                ctx.strokePath()
                return true
            }
            return ok ? buf : nil
        }
        guard let ia = render(a), let ib = render(b) else { return false }
        var diff = 0, sum = 0
        for i in 0..<(side * side) { diff += abs(Int(ia[i]) - Int(ib[i])); sum += Int(max(ia[i], ib[i])) }
        return sum > 0 && Double(diff) > Double(sum) * 0.02
    }

    /// Number of closed subpaths with more than two points (the ones `PathBoolean` resolves).
    static func closedSubpathCount(_ vp: VectorPath) -> Int { vp.subpaths.filter { $0.closed && $0.points.count > 2 }.count }
}

// MARK: - Layer names

enum SVGImportNames {
    /// Decodes Illustrator's `_x20_` escapes and tidies whitespace.
    static func clean(_ raw: String) -> String {
        var s = raw
        if s.contains("_x") {
            var out = ""
            var i = s.startIndex
            while i < s.endIndex {
                if s[i] == "_", let close = s[s.index(after: i)...].firstIndex(of: "_"), s.distance(from: i, to: close) <= 7,
                   s[s.index(after: i)] == "x", let code = UInt32(s[s.index(i, offsetBy: 2)..<close], radix: 16), let u = Unicode.Scalar(code) {
                    out.unicodeScalars.append(u)
                    i = s.index(after: close)
                } else {
                    out.append(s[i]); i = s.index(after: i)
                }
            }
            s = out
        }
        s = s.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ").trimmingCharacters(in: .whitespaces)
        return String(s.prefix(120))
    }

    /// Ids that tools generate (no information for the user).
    static func isGenerated(_ id: String) -> Bool {
        let l = id.lowercased()
        let prefixes = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "text", "tspan", "image", "use",
                        "xmlid_", "svgid_", "shape", "clip", "mask", "a", "symbol", "object", "el", "id", "_", "svg_", "flowroot", "flowpara", "stop", "defs"]
        for p in prefixes where l.hasPrefix(p) {
            let rest = l.dropFirst(p.count)
            if rest.isEmpty { return true }
            if rest.allSatisfy({ $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }) { return true }
        }
        // hashes ("a1b2c3d4-…", "sk9x2")
        if l.count >= 8, l.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return true }
        return false
    }

    /// Name for the layer made from `n`, and whether the file chose it (as opposed to a kind name).
    static func name(_ n: SVGImportNode, fallback: String) -> (String, Bool) {
        for key in ["inkscape:label", "data-name", "aria-label", "sketch:name", "serif:id"] {
            if let v = n.attrs[key].map(clean), !v.isEmpty { return (v, true) }
        }
        if let t = n.child("title")?.textContent.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return (clean(t), true) }
        if let id = n.id {
            let c = clean(id)
            if !c.isEmpty, !isGenerated(id) { return (c, true) }
        }
        return (fallback, false)
    }
}
