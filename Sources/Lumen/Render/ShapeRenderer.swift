import AppKit
import CoreImage
import ImageCratCore

enum PaintRenderer {
    /// CI-space image of a paint style covering doc rect `bounds` (gradient endpoints relative to `refBounds`).
    /// `placement` positions a pattern (Pattern Fill layers); nil tiles it from the canvas origin.
    static func image(_ paint: PaintStyle, bounds: CGRect, refBounds: CGRect? = nil, space: CanvasSpace, patterns: [PatternDef] = AppModel.shared.customPatterns,
                      placement: PatternPlacement? = nil) -> CIImage {
        let ciR = space.ciRect(bounds)
        switch paint {
        case .none:
            return CIImage.clearImage.cropped(to: ciR)
        case .color(let c):
            return CIImage.color(c, ciR)
        case .gradient(var gf):
            if let m = gf.method, m != .classic { gf.gradient = gf.gradient.interpolated(m) }
            if let sh = gf.activeShape { return GradientShapeRenderer.image(gf, sh, extent: ciR, refBounds: refBounds ?? bounds, space: space) }
            let (s, e) = gf.endpoints(in: refBounds ?? bounds)
            return Kernels.gradientImage(gf.gradient, type: gf.type, p0: space.ciPoint(s), p1: space.ciPoint(e), reverse: gf.reverse, extent: ciR)
        case .pattern(let id, let scale):
            guard let p = PatternLibrary.pattern(id: id, custom: patterns) else { return CIImage.clearImage.cropped(to: ciR) }
            let s = CGFloat(max(0.01, scale))
            if let pl = placement {
                // tile's top-left corner on the document's top-left corner, scaled, turned about it, then moved
                let h = CGFloat(p.image.height)
                let a = CGFloat((pl.angle.isFinite ? pl.angle : 0) * .pi / 180)
                let ox = pl.offset.x.isFinite ? pl.offset.x : 0, oy = pl.offset.y.isFinite ? pl.offset.y : 0
                let m = CGAffineTransform(translationX: 0, y: -h)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(rotationAngle: a))
                    .concatenating(CGAffineTransform(translationX: ox, y: CGFloat(space.height) - oy))
                let t = NSAffineTransform()
                t.transformStruct = NSAffineTransformStruct(m11: m.a, m12: m.b, m21: m.c, m22: m.d, tX: m.tx, tY: m.ty)
                return p.image.ciImage.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: t]).cropped(to: ciR)
            }
            let tile = p.image.ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
            return tile.applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()]).cropped(to: ciR)
        }
    }

    /// Pixels of a (non-recipe) fill layer over the canvas: gradients span the canvas, or the layer's mask with "Align
    /// with layer"; patterns follow the layer's placement; gradients with Dither get ±½ level of noise against banding.
    static func fillLayerImage(_ f: FillContent, layer: Layer, space: CanvasSpace) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: space.width, height: space.height)
        var ref = canvas
        if case .gradient(let g) = f.paint, g.alignWithLayer == true, let b = alignBounds(layer, canvas: canvas) { ref = b }
        var img = image(f.paint, bounds: canvas, refBounds: ref, space: space, placement: f.patternPlacement)
        if case .gradient(let g) = f.paint, g.dither, let k = ditherKernel {
            let noise = CIFilter(name: "CIRandomGenerator")?.outputImage?.cropped(to: img.extent)
            if let n = noise, let out = k.apply(extent: img.extent, arguments: [img, n]) { img = out }
        }
        return img
    }

    /// ±½ level of noise (premultiplied, never brighter than the alpha allows).
    static let ditherKernel = CIColorKernel(source: """
    kernel vec4 lumenDither(__sample c, __sample n) {
        vec3 d = (n.rgb - vec3(0.5)) * (1.0 / 255.0) * c.a;
        return vec4(clamp(c.rgb + d, vec3(0.0), vec3(c.a)), c.a);
    }
    """)

    /// The area a fill layer shows through its masks (doc space), for "Align with layer"; nil = the whole canvas.
    static func alignBounds(_ layer: Layer, canvas: CGRect) -> CGRect? {
        var r: CGRect? = nil
        if let vm = layer.vectorMask, layer.vectorMaskEnabled, !vm.isEmpty {
            let b = vm.bounds
            if b.width > 0.5, b.height > 0.5 { r = b }
        }
        if let m = layer.mask, m.isEnabled, m.outsideValue < 128, let ob = m.buffer.opaqueBounds() {
            let b = ob.offsetBy(dx: m.origin.x, dy: m.origin.y).cgRect
            r = r.map { $0.intersection(b) } ?? b
        }
        guard let out = r, !out.isNull, out.width > 0.5, out.height > 0.5 else { return nil }
        return out
    }

    /// Fills the current clip of a doc-space CG context with a paint.
    static func fillClip(_ ctx: CGContext, paint: PaintStyle, bounds: CGRect, refBounds: CGRect, space: CanvasSpace) {
        switch paint {
        case .none: return
        case .color(let c):
            ctx.setFillColor(c.cgColor)
            ctx.fill(bounds)
        default:
            let img = image(paint, bounds: bounds, refBounds: refBounds, space: space)
            guard let cg = RenderEngine.cgImage(img, rect: space.ciRect(bounds)) else { return }
            ctx.saveGState()
            ctx.translateBy(x: bounds.minX, y: bounds.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(origin: .zero, size: bounds.size))
            ctx.restoreGState()
        }
    }
}

enum ShapeRenderer {
    /// Padded rasterization area: the path plus a stroke width all round, widened to wherever the stroke really reaches
    /// (miter joins at sharp corners such as star points reach several stroke widths beyond the path).
    static func docBounds(_ s: ShapeContent) -> CGRect {
        let b = s.path.bounds
        let sw = s.stroke.paint.isNone ? 0 : s.stroke.width
        let r = b.insetBy(dx: -CGFloat(sw) - 2, dy: -CGFloat(sw) - 2)
        let sb = StrokeGeometry.strokeBounds(s)
        return sb.isNull ? r : r.union(sb.insetBy(dx: -2, dy: -2))
    }

    /// Area the shape is rasterized in (`docBounds`, which includes the stroke's full reach).
    static func rasterBounds(_ s: ShapeContent) -> CGRect { docBounds(s) }

    /// Bounds of what the shape draws: the path plus the part of the stroke outside it (none for an inside stroke,
    /// half the width for a centred one, more where miter joins stick out). `docBounds` is the padded rasterization area.
    static func visualBounds(_ s: ShapeContent) -> CGRect {
        let b = s.path.bounds
        guard !s.stroke.paint.isNone, s.stroke.width > 0 else { return b }
        let out: CGFloat
        switch s.stroke.alignment {
        case .inside: out = 0
        case .center: out = CGFloat(s.stroke.width) / 2
        case .outside: out = CGFloat(s.stroke.width)
        }
        let r = b.insetBy(dx: -out, dy: -out)
        let sb = StrokeGeometry.strokeBounds(s)
        return sb.isNull ? r : r.union(sb)
    }

    static func usesEvenOdd(_ p: VectorPath) -> Bool { p.resolved.evenOdd }

    /// Draws a shape into a CG context using doc coordinates (context CTM already maps doc → device).
    static func draw(_ s: ShapeContent, in ctx: CGContext, space: CanvasSpace) {
        let vp = s.path
        let (path, evenOdd) = vp.resolved
        let pathBounds = vp.bounds
        let drawBounds = rasterBounds(s)

        if !s.fill.isNone {
            ctx.saveGState()
            ctx.addPath(path)
            if evenOdd { ctx.clip(using: .evenOdd) } else { ctx.clip() }
            PaintRenderer.fillClip(ctx, paint: s.fill, bounds: drawBounds, refBounds: pathBounds, space: space)
            ctx.restoreGState()
        }

        if let plan = StrokeGeometry.plan(s) {
            ctx.saveGState()
            switch plan.clip {
            case .none: break
            case .inside:
                ctx.addPath(path)
                if evenOdd { ctx.clip(using: .evenOdd) } else { ctx.clip() }
            case .outside:
                ctx.addRect(drawBounds.insetBy(dx: -plan.lineWidth * 2, dy: -plan.lineWidth * 2))
                ctx.addPath(path)
                ctx.clip(using: .evenOdd)
            }
            ctx.setLineWidth(plan.lineWidth)
            ctx.setLineCap(plan.cap)
            ctx.setLineJoin(plan.join)
            ctx.setMiterLimit(plan.miterLimit)
            if let d = plan.dash { ctx.setLineDash(phase: d.phase, lengths: d.lengths) }
            ctx.addPath(plan.path)
            if case .color(let c) = s.stroke.paint {
                ctx.setStrokeColor(c.cgColor)
                ctx.strokePath()
            } else {
                ctx.replacePathWithStrokedPath()
                ctx.clip()
                PaintRenderer.fillClip(ctx, paint: s.stroke.paint, bounds: drawBounds.insetBy(dx: -plan.lineWidth, dy: -plan.lineWidth), refBounds: pathBounds, space: space)
            }
            ctx.restoreGState()
        }
    }

    static func render(_ s: ShapeContent, space: CanvasSpace) -> CIImage {
        let limit = CGRect(x: 0, y: 0, width: space.width, height: space.height).insetBy(dx: -64, dy: -64)
        let r = IRect(enclosing: rasterBounds(s).intersection(limit))
        if r.isEmpty { return CIImage.clearImage.cropped(to: .zero) }
        guard let ctx = makeDocContext(r) else { return CIImage.clearImage.cropped(to: .zero) }
        draw(s, in: ctx, space: space)
        guard let img = ctx.makeImage() else { return CIImage.clearImage.cropped(to: .zero) }
        return space.place(CIImage(cgImage: img), docOrigin: r.origin, size: (r.width, r.height))
    }

    /// RGBA context covering doc rect r, CTM set for doc coordinates (y-down).
    static func makeDocContext(_ r: IRect, gray: Bool = false) -> CGContext? {
        let ctx: CGContext?
        if gray {
            ctx = CGContext(data: nil, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: 0, space: graySpace,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        } else {
            ctx = CGContext(data: nil, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(r.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -CGFloat(r.x), y: -CGFloat(r.y))
        return ctx
    }

    /// Gray mask image (CI space) of a vector path over the canvas: white inside.
    static func renderMask(_ p: VectorPath, space: CanvasSpace) -> CIImage {
        let r = IRect(x: 0, y: 0, width: space.width, height: space.height)
        guard let ctx = makeDocContext(r, gray: true) else { return CIImage(color: .white).cropped(to: space.ciCanvas) }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(r.cgRect)
        ctx.setFillColor(gray: 1, alpha: 1)
        let (rp, eo) = p.resolved
        ctx.addPath(rp)
        if eo { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
        guard let img = ctx.makeImage() else { return CIImage(color: .white).cropped(to: space.ciCanvas) }
        return CIImage(cgImage: img)
    }
}
