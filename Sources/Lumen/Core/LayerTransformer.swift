import Foundation
import CoreImage
import ImageCratCore

/// Applies geometric transforms (affine or projective, in doc space) to layers.
enum LayerTransformer {
    /// Warps a buffer image (extent 0,0,w,h) placed at docRect through H. Returns CI-space image.
    static func warp(_ img: CIImage, docRect: IRect, h: Homography, space: CanvasSpace, nearest: Bool = false) -> CIImage {
        let placed = space.place(img, docOrigin: docRect.origin, size: (docRect.width, docRect.height))
        let src = nearest ? placed.samplingNearest() : placed
        if h.isAffine {
            let t = space.ciTransform(h.affine)
            return src.transformed(by: t, highQualityDownsample: true)
        }
        let q = h.mapRect(docRect.cgRect).mapped { space.ciPoint($0) }
        return src.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: q.tl), "inputTopRight": CIVector(cgPoint: q.tr),
            "inputBottomRight": CIVector(cgPoint: q.br), "inputBottomLeft": CIVector(cgPoint: q.bl),
        ])
    }

    static func warpBuffer(_ buf: PixelBuffer, origin: IPoint, h: Homography, space: CanvasSpace, nearest: Bool = false, limitToCanvas: Bool = true) -> (PixelBuffer, IPoint) {
        let rect = IRect(x: origin.x, y: origin.y, width: buf.width, height: buf.height)
        let img = warp(buf.ciImage, docRect: rect, h: h, space: space, nearest: nearest)
        var docR = IRect(enclosing: space.docRect(img.extent))
        // Limit to a sane area around the canvas.
        if limitToCanvas {
            docR = docR.intersection(IRect(x: -space.width * 2, y: -space.height * 2, width: space.width * 5, height: space.height * 5))
        }
        if docR.isEmpty { return (PixelBuffer(width: 1, height: 1, format: buf.format), .zero) }
        let out = RenderEngine.renderBuffer(img, docRect: docR, space: space, format: buf.format)
        return (out, docR.origin)
    }

    /// `document` = whole-document transform (image size, rotate canvas): no size limits and masks move even if unlinked.
    /// `strokeScale`: factor for live shape strokes (Image Size scales them with the artwork, with or without "Scale Styles").
    static func apply(_ h: Homography, to layer: Layer, space: CanvasSpace, scaleEffects: Double? = nil, nearest: Bool = false, document: Bool = false,
                      strokeScale: Double? = nil) -> Layer {
        var l = layer
        switch layer.content {
        case .raster(var r):
            let (b, o) = warpBuffer(r.buffer, origin: r.origin, h: h, space: space, nearest: nearest, limitToCanvas: !document)
            r.buffer = b; r.origin = o
            l.content = .raster(r)
        case .text(var t):
            if h.isAffine {
                t.transform = t.transform.concatenating(h.affine)
            } else {
                let q = TextRenderer.docQuad(t)
                let a = affineFrom3(q.tl, q.tr, q.bl, h.apply(q.tl), h.apply(q.tr), h.apply(q.bl))
                t.transform = t.transform.concatenating(a)
            }
            l.content = .text(t)
        case .shape(var s):
            if h.isAffine && s.perspective == nil {
                s.transform = s.transform.concatenating(h.affine)
            } else {
                // keep live shape parameters: accumulate the projective part separately
                s.perspective = h.concat(s.perspective ?? .identity)
            }
            if let k = strokeScale ?? scaleEffects { s.stroke.width *= k }
            // a gradient with placed end points (imported vector artwork) is transformed with its shape
            if case .gradient(var g) = s.fill, let a = g.start, let b = g.end { g.start = h.apply(a); g.end = h.apply(b); s.fill = .gradient(g) }
            if document, h.isAffine {   // gradients without placed end points follow a rotated / flipped canvas by their angle
                if case .gradient(var g) = s.fill, g.start == nil || g.end == nil { g.angle = mappedAngle(g.angle, h.affine); s.fill = .gradient(g) }
                if case .gradient(var g) = s.stroke.paint, g.start == nil || g.end == nil { g.angle = mappedAngle(g.angle, h.affine); s.stroke.paint = .gradient(g) }
            }
            l.content = .shape(s)
        case .smartObject(var so):
            so.quad = so.quad.mapped(h.apply)
            so.warp = so.warp?.mapped(h.apply)
            for i in so.filters.indices {   // filter masks are linked to the layer
                guard var m = so.filters[i].mask else { continue }
                let (b, o) = warpMask(m, h: h, space: space)
                m.buffer = b; m.origin = o
                so.filters[i].mask = m
            }
            l.content = .smartObject(so)
        case .fill(var f):
            if case .gradient(var g) = f.paint {
                if let s = g.start, let e = g.end { g.start = h.apply(s); g.end = h.apply(e) }
                else if document, h.isAffine { g.angle = mappedAngle(g.angle, h.affine) }
                f.paint = .gradient(g)
            }
            l.content = .fill(f)
        case .group(var g):
            g.children = g.children.map { apply(h, to: $0, space: space, scaleEffects: scaleEffects, nearest: nearest, document: document, strokeScale: strokeScale) }
            if let ab = g.artboard {
                // round (not `integral`): float noise such as 440.00000000000006 must not grow the artboard by a pixel
                let q = h.mapRect(ab.rect).bounds
                g.artboard?.rect = CGRect(x: q.minX.rounded(), y: q.minY.rounded(), width: max(1, q.width.rounded()), height: max(1, q.height.rounded()))
            }
            l.content = .group(g)
        case .adjustment:
            break
        }
        if var m = layer.mask, m.isLinked || document {
            let (b, o) = warpMask(m, h: h, space: space)
            m.buffer = b; m.origin = o
            l.mask = m
        }
        if let vm = layer.vectorMask { l.vectorMask = vm.mapped(h.apply) }
        if let k = scaleEffects { l.effects = scaled(l.effects, k) }
        return l
    }

    /// Gradient angle (degrees, counter-clockwise, as in `GradientFill.endpoints`) after the linear part of `t`.
    static func mappedAngle(_ angle: Double, _ t: CGAffineTransform) -> Double {
        // only rotations / mirrors (with uniform scale) turn the angle; a non-uniform resize leaves the setting alone
        let lu = hypot(t.a, t.b), lv = hypot(t.c, t.d)
        guard lu > 1e-9, abs(lu - lv) < 1e-6 * max(lu, lv), abs(t.a * t.c + t.b * t.d) < 1e-6 * lu * lv else { return angle }
        let rad = angle * .pi / 180
        let d = CGPoint(x: cos(rad), y: -sin(rad))
        let m = CGPoint(x: t.a * d.x + t.c * d.y, y: t.b * d.x + t.d * d.y)
        guard m.length > 1e-9 else { return angle }
        let out = atan2(-Double(m.y), Double(m.x)) * 180 / .pi
        return abs(out - angle) < 1e-9 ? angle : out
    }

    static func warpMask(_ m: LayerMask, h: Homography, space: CanvasSpace) -> (PixelBuffer, IPoint) {
        // Composite over outside value so edges blend correctly.
        let rect = IRect(x: m.origin.x, y: m.origin.y, width: m.buffer.width, height: m.buffer.height)
        let img = warp(m.buffer.ciImage, docRect: rect, h: h, space: space)
        let target = IRect(enclosing: space.docRect(img.extent)).union(IRect(x: 0, y: 0, width: space.width, height: space.height))
        let bg = CIImage.color(RGBA(gray: Double(m.outsideValue) / 255), space.ciRect(target))
        let out = RenderEngine.renderBuffer(img.composited(over: bg), docRect: target, space: space, format: .gray)
        return (out, target.origin)
    }

    static func affineFrom3(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ a2: CGPoint, _ b2: CGPoint, _ c2: CGPoint) -> CGAffineTransform {
        // Solve for T such that T(a)=a2, T(b)=b2, T(c)=c2
        let src = CGAffineTransform(a: b.x - a.x, b: b.y - a.y, c: c.x - a.x, d: c.y - a.y, tx: a.x, ty: a.y)
        let dst = CGAffineTransform(a: b2.x - a2.x, b: b2.y - a2.y, c: c2.x - a2.x, d: c2.y - a2.y, tx: a2.x, ty: a2.y)
        return src.inverted().concatenating(dst)
    }

    static func scaled(_ fx: LayerEffects, _ k: Double) -> LayerEffects {
        var f = fx
        f.dropShadow.distance *= k; f.dropShadow.size *= k
        f.innerShadow.distance *= k; f.innerShadow.size *= k
        f.outerGlow.size *= k; f.innerGlow.size *= k
        f.bevel.size *= k; f.bevel.soften *= k
        f.satin.distance *= k; f.satin.size *= k
        f.stroke.size *= k
        f.patternOverlay.scale *= k
        for i in f.extraDropShadows.indices { f.extraDropShadows[i].distance *= k; f.extraDropShadows[i].size *= k }
        for i in f.extraInnerShadows.indices { f.extraInnerShadows[i].distance *= k; f.extraInnerShadows[i].size *= k }
        for i in f.extraStrokes.indices { f.extraStrokes[i].size *= k }
        return f
    }
}
