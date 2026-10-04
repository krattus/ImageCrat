import Foundation
import CoreImage
import CoreGraphics
import ImageCratCore

// SVG import, part 4: gradients. `GradientShapeRenderer` draws a `GradientFill` that carries a `GradientShape`
// (any affine placement, focal point, reflect / repeat); `SVGImportGradient` turns SVG paint servers into fills.

enum GradientShapeRenderer {
    static let lutWidth = 1024

    private static let kernel = CIKernel(source: """
    kernel vec4 gradientShape(sampler lut, vec3 ru, vec3 rv, vec4 opt, vec3 focal) {
        vec2 d = destCoord();
        float u = dot(ru.xy, d) + ru.z;
        float v = dot(rv.xy, d) + rv.z;
        float t = u;
        float valid = 1.0;
        if (opt.x > 0.5) {
            if (opt.z > 0.5) {
                vec2 f = focal.xy;
                float fr = focal.z;
                vec2 pd = vec2(u, v) - f;
                vec2 cd = -f;
                float dr = 1.0 - fr;
                float a = dot(cd, cd) - dr * dr;
                float b = dot(pd, cd) + fr * dr;
                float c = dot(pd, pd) - fr * fr;
                if (abs(a) < 0.000001) {
                    t = abs(b) > 0.000000001 ? c / (2.0 * b) : 0.0;
                    if (fr + t * dr < 0.0) { valid = 0.0; }
                } else {
                    float disc = b * b - a * c;
                    if (disc < 0.0) { valid = 0.0; t = 0.0; }
                    else {
                        float sq = sqrt(disc);
                        float t1 = (b + sq) / a;
                        float t2 = (b - sq) / a;
                        t = max(t1, t2);
                        if (fr + t * dr < 0.0) {
                            t = min(t1, t2);
                            if (fr + t * dr < 0.0) { valid = 0.0; }
                        }
                    }
                }
            } else {
                t = length(vec2(u, v));
            }
        }
        if (opt.y < 0.5) { t = clamp(t, 0.0, 1.0); }
        else if (opt.y < 1.5) { float m = mod(t, 2.0); t = m > 1.0 ? 2.0 - m : m; }
        else { t = fract(t); }
        return sample(lut, samplerTransform(lut, vec2(t * (opt.w - 1.0) + 0.5, 0.5))) * valid;
    }
    """)

    private static var lutCache: [(ColorGradient, Bool, CIImage)] = []
    private static let lock = NSLock()

    /// Premultiplied colour ramp, 1024 px wide (hard stops stay crisp on long gradients).
    static func lut(_ g: ColorGradient, reverse: Bool) -> CIImage {
        lock.lock()
        if let hit = lutCache.first(where: { $0.0 == g && $0.1 == reverse }) { lock.unlock(); return hit.2 }
        lock.unlock()
        let grad = reverse ? g.reversed() : g
        let w = lutWidth
        let buf = PixelBuffer(width: w, height: 1)
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            let c = grad.color(at: Double(x) / Double(w - 1))
            let a = clamp(c.a, 0, 1)
            p[x * 4] = UInt8((clamp(c.r * a, 0, 1) * 255).rounded())
            p[x * 4 + 1] = UInt8((clamp(c.g * a, 0, 1) * 255).rounded())
            p[x * 4 + 2] = UInt8((clamp(c.b * a, 0, 1) * 255).rounded())
            p[x * 4 + 3] = UInt8((a * 255).rounded())
        }
        buf.markDirty()
        let img = buf.ciImage
        lock.lock()
        lutCache.append((g, reverse, img))
        if lutCache.count > 32 { lutCache.removeFirst() }
        lock.unlock()
        return img
    }

    /// Unit square → `bounds`; a degenerate side (the bounds of a straight line) counts as 1 px so the map stays invertible.
    static func boundsMap(_ r: CGRect) -> CGAffineTransform {
        CGAffineTransform(a: r.width > 1e-6 ? r.width : 1, b: 0, c: 0, d: r.height > 1e-6 ? r.height : 1, tx: r.minX, ty: r.minY)
    }

    /// CI-space image of the gradient over `extent` (CI rect); `refBounds` is the painted shape's bounds in doc space.
    static func image(_ gf: GradientFill, _ sh: GradientShape, extent: CGRect, refBounds: CGRect, space: CanvasSpace) -> CIImage {
        let toCI = sh.matrix.concatenating(boundsMap(refBounds)).concatenating(space.flip)
        guard let k = kernel, toCI.isFinite, abs(toCI.determinant) > 1e-12 else {
            let (s, e) = gf.endpoints(in: refBounds)
            return Kernels.gradientImage(gf.gradient, type: gf.type, p0: space.ciPoint(s), p1: space.ciPoint(e), reverse: gf.reverse, extent: extent)
        }
        let inv = toCI.inverted()
        let ramp = lut(gf.gradient, reverse: gf.reverse)
        let rampExt = ramp.extent
        let spread: CGFloat = sh.spread == .pad ? 0 : (sh.spread == .reflect ? 1 : 2)
        let f = sh.focal ?? .zero
        let hasFocal = gf.type == .radial && (sh.focal.map { abs($0.x) > 1e-6 || abs($0.y) > 1e-6 } ?? false || sh.focalRadius > 1e-6)
        let out = k.apply(extent: extent, roiCallback: { _, _ in rampExt }, arguments: [
            ramp,
            CIVector(x: inv.a, y: inv.c, z: inv.tx), CIVector(x: inv.b, y: inv.d, z: inv.ty),
            CIVector(x: gf.type == .radial ? 1 : 0, y: spread, z: hasFocal ? 1 : 0, w: CGFloat(lutWidth)),
            CIVector(x: f.x, y: f.y, z: CGFloat(clamp(sh.focalRadius, 0, 0.999))),
        ])
        return out ?? CIImage.clearImage.cropped(to: extent)
    }
}

enum SVGImportGradient {
    struct Resolved {
        var radial = false
        var stops: [GradientStop] = []
        /// Unit gradient → the gradient's own coordinate system (before gradientTransform).
        var unit = CGAffineTransform.identity
        var transform = CGAffineTransform.identity
        var objectBBox = true
        var spread = GradientShape.Spread.pad
        var focal: CGPoint? = nil
        var focalRadius = 0.0
        var degenerate = false
        var name = "Gradient"
    }

    /// Collects attributes and stops along the href chain.
    static func resolve(_ node: SVGImportNode, doc: SVGImportDocument, style: SVGImportStyle, viewport: CGSize, opacity: Double) -> Resolved? {
        guard node.tag == "linearGradient" || node.tag == "radialGradient" else { return nil }
        var chain: [SVGImportNode] = []
        var cur: SVGImportNode? = node
        while let c = cur, chain.count < 16, !chain.contains(where: { $0 === c }) {
            chain.append(c)
            cur = doc.target(c.href).flatMap { $0.tag == "linearGradient" || $0.tag == "radialGradient" ? $0 : nil }
        }
        func attr(_ name: String, sameKind: Bool = false) -> String? {
            for c in chain where !sameKind || c.tag == node.tag { if let v = c.attrs[name] { return v } }
            return nil
        }
        var r = Resolved()
        r.radial = node.tag == "radialGradient"
        r.name = node.id.map { SVGImportNames.clean($0) } ?? "Gradient"
        r.objectBBox = (attr("gradientUnits") ?? "objectBoundingBox") != "userSpaceOnUse"
        // CSS `transform` on the gradient element is not a thing; gradientTransform is
        r.transform = SVGImportValue.transform(attr("gradientTransform")) ?? .identity
        switch (attr("spreadMethod") ?? "pad").lowercased() {
        case "reflect": r.spread = .reflect
        case "repeat": r.spread = .repeat
        default: r.spread = .pad
        }
        // stops: the first element in the chain that has any
        guard let owner = chain.first(where: { $0.children.contains { $0.tag == "stop" && $0.isSVG } }) else { return r }
        var last = 0.0
        for s in owner.children where s.tag == "stop" && s.isSVG {
            var off = SVGImportValue.number(s.attrs["offset"]) ?? 0
            off = clamp(off, 0, 1)
            off = max(off, last); last = off
            var color = RGBA.black
            if let v = s.decls["stop-color"].map({ style.substitute($0) }) {
                if v.lowercased() == "currentcolor" { color = inheritedColor(s) ?? style.color }
                else if let c = SVGImportValue.color(v) { color = c }
            }
            let so = clamp(s.decls["stop-opacity"].flatMap { SVGImportValue.number(style.substitute($0)) } ?? 1, 0, 1)
            color.a *= so * opacity
            r.stops.append(GradientStop(location: off, color: color))
            if r.stops.count >= 1024 { break }
        }
        // strictly increasing locations keep hard stops in order whatever the sort does with ties
        let eps = 1e-5
        for i in r.stops.indices.dropFirst() { r.stops[i].location = max(r.stops[i].location, r.stops[i - 1].location + eps) }
        if let n = r.stops.indices.last {
            r.stops[n].location = min(1, r.stops[n].location)
            for i in stride(from: n - 1, through: 0, by: -1) { r.stops[i].location = min(r.stops[i].location, r.stops[i + 1].location - eps) }
        }
        // geometry
        let em = style.fontSize
        func coord(_ name: String, _ def: String, _ ref: Double) -> Double {
            let raw = attr(name, sameKind: true) ?? def
            guard let l = SVGImportValue.length(raw) else { return SVGImportValue.length(def)?.resolve(percentOf: r.objectBBox ? 1 : ref, fontSize: em) ?? 0 }
            return l.resolve(percentOf: r.objectBBox ? 1 : ref, fontSize: em)
        }
        let vw = Double(viewport.width), vh = Double(viewport.height), vd = ((vw * vw + vh * vh) / 2).squareRoot()
        if r.radial {
            let cx = coord("cx", "50%", vw), cy = coord("cy", "50%", vh), rad = coord("r", "50%", vd)
            let fx = attr("fx", sameKind: true) != nil ? coord("fx", "50%", vw) : cx
            let fy = attr("fy", sameKind: true) != nil ? coord("fy", "50%", vh) : cy
            let fr = max(0, coord("fr", "0%", vd))
            guard rad > 1e-9 else { r.degenerate = true; return r }
            r.unit = CGAffineTransform(a: rad, b: 0, c: 0, d: rad, tx: cx, ty: cy)
            var f = CGPoint(x: (fx - cx) / rad, y: (fy - cy) / rad)
            let frn = min(fr / rad, 0.999)
            // a focal point outside the end circle is moved just inside it (SVG 1.1 behaviour)
            let lim = CGFloat(max(0, 0.999 - frn))
            if f.length > lim { f = f.normalized * lim }
            if f.length > 1e-6 || frn > 1e-6 { r.focal = f; r.focalRadius = frn }
        } else {
            let x1 = coord("x1", "0%", vw), y1 = coord("y1", "0%", vh), x2 = coord("x2", "100%", vw), y2 = coord("y2", "0%", vh)
            let dx = x2 - x1, dy = y2 - y1
            guard dx * dx + dy * dy > 1e-18 else { r.degenerate = true; return r }
            r.unit = CGAffineTransform(a: dx, b: dy, c: -dy, d: dx, tx: x1, ty: y1)
        }
        return r
    }

    /// `color` as the stop element would inherit it.
    private static func inheritedColor(_ n: SVGImportNode) -> RGBA? {
        var cur: SVGImportNode? = n
        while let c = cur {
            if let v = c.decls["color"], let col = SVGImportValue.color(v) { return col }
            cur = c.parent
        }
        return nil
    }

    /// Paint for a gradient server applied to a shape whose geometry has bounding box `bbox` in user space, drawn
    /// through `ctm`; `refBounds` is the final path's bounds in document space.
    static func paint(_ node: SVGImportNode, doc: SVGImportDocument, style: SVGImportStyle, viewport: CGSize, opacity: Double,
                      bbox: CGRect, ctm: CGAffineTransform, refBounds: CGRect) -> PaintStyle? {
        guard let r = resolve(node, doc: doc, style: style, viewport: viewport, opacity: opacity) else { return nil }
        guard let lastStop = r.stops.last else { return PaintStyle.none }
        if r.stops.count == 1 || r.degenerate { return .color(lastStop.color) }
        // objectBoundingBox units on a box without area paint nothing
        if r.objectBBox && (bbox.width <= 0 || bbox.height <= 0 || bbox.isNull) { return PaintStyle.none }
        let box = r.objectBBox ? CGAffineTransform(a: bbox.width, b: 0, c: 0, d: bbox.height, tx: bbox.minX, ty: bbox.minY) : .identity
        let toDoc = r.unit.concatenating(r.transform).concatenating(box).concatenating(ctm)
        guard toDoc.isFinite, abs(toDoc.determinant) > 1e-12 else { return .color(lastStop.color) }
        let toBounds = GradientShapeRenderer.boundsMap(refBounds)
        guard abs(toBounds.determinant) > 1e-12 else { return .color(lastStop.color) }
        let gradient = ColorGradient(name: r.name, stops: r.stops)
        var gf = GradientFill(gradient: gradient, type: r.radial ? .radial : .linear)
        gf.dither = false
        // the closest angle / scale settings (exact for the common cases; exporters and the gradient UI read these)
        let w = Double(refBounds.width), h = Double(refBounds.height)
        let c = refBounds.center
        var exact = r.spread == .pad && r.focal == nil
        if r.radial {
            let centre = CGPoint.zero.applying(toDoc)
            let radius = Double(toDoc.meanScale)
            gf.angle = 0
            gf.scale = w > 1e-6 ? 2 * radius / w : 1
            let tol = max(0.02, 1e-4 * max(w, h))
            if !toDoc.isSimilarity || Double(centre.distance(to: c)) > tol || w <= 1e-6 { exact = false }
        } else {
            let p0 = CGPoint.zero.applying(toDoc), p1 = CGPoint(x: 1, y: 0).applying(toDoc)
            // colour is constant along the image of the unit y axis; the ramp runs along its normal
            let along = CGPoint(x: toDoc.c, y: toDoc.d).normalized
            var nrm = CGPoint(x: -along.y, y: along.x)
            var len = Double((p1 - p0).dot(nrm))
            if len < 0 { nrm = -nrm; len = -len }
            guard len > 1e-9 else { return .color(lastStop.color) }
            gf.angle = atan2(-Double(nrm.y), Double(nrm.x)) * 180 / .pi
            let span = abs(Double(nrm.x)) * w + abs(Double(nrm.y)) * h
            gf.scale = span > 1e-6 ? len / span : 1
            let mid = p0 + nrm * CGFloat(len / 2)
            let tol = max(0.02, 1e-4 * max(w, h))
            if abs(Double((mid - c).dot(nrm))) > tol || span <= 1e-6 { exact = false }
        }
        if !exact {
            gf.shape = GradientShape(matrix: toDoc.concatenating(toBounds.inverted()), focal: r.focal, focalRadius: r.focalRadius, spread: r.spread, key: gf.geometryKey)
        }
        return .gradient(gf)
    }
}
