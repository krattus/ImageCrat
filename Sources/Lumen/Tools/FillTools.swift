import AppKit
import CoreImage
import ImageCratCore

final class GradientTool: Tool {
    private var start: CGPoint?
    private var end: CGPoint?
    private var target: (Document, UUID, EditTarget)?

    override var cursor: NSCursor { .crosshair }

    var effectiveGradient: ColorGradient {
        let s = app.gradientTool
        if s.useForegroundBackground {
            if s.gradient.name == "Black, White" { return .twoColor(app.foreground, app.background, name: "Foreground to Background") }
            if s.gradient.name == "Foreground to Transparent" { return .twoColor(app.foreground, app.foreground.withAlpha(0), name: s.gradient.name) }
        }
        return s.gradient
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let t = requirePixelTarget() else { return }
        target = t
        start = e.doc
        end = e.doc
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let s = start else { return }
        var p = e.doc
        if e.shift {
            let d = p - s
            let a = (atan2(d.y, d.x) / (.pi / 4)).rounded() * (.pi / 4)
            p = s + CGPoint(x: cos(a) * d.length, y: sin(a) * d.length)
        }
        end = p
        updatePreview()
    }

    override func mouseUp(_ e: ToolEvent) {
        defer { start = nil; end = nil; target = nil }
        guard let (d, id, tgt) = target, let s = start, let en = end, s.distance(to: en) > 1 else {
            target.map { $0.0.contentOverrides.removeValue(forKey: $0.1) }
            return
        }
        d.contentOverrides.removeValue(forKey: id)
        guard let (working, origin) = d.beginPixelEdit(layerID: id, target: tgt) else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let base = space.place(working, at: origin)
        let result = compose(base: base, s: s, e: en, space: space, doc: d, mask: tgt.isMask)
        RenderEngine.render(result, into: working, docOrigin: origin, space: space)
        d.commit("Gradient")
    }

    private func gradientImage(_ s: CGPoint, _ e: CGPoint, space: CanvasSpace, gray: Bool) -> CIImage {
        var g = effectiveGradient
        if gray { g.stops = g.stops.map { var st = $0; st.color = RGBA(gray: st.color.luminance, a: st.color.a); return st } }
        return Kernels.gradientImage(g, type: app.gradientTool.type, p0: space.ciPoint(s), p1: space.ciPoint(e),
                                     reverse: app.gradientTool.reverse, extent: space.ciCanvas.insetBy(dx: -8000, dy: -8000))
    }

    private func compose(base: CIImage, s: CGPoint, e: CGPoint, space: CanvasSpace, doc: Document, mask: Bool) -> CIImage {
        var grad = gradientImage(s, e, space: space, gray: mask).cropped(to: base.extent.union(space.ciCanvas))
        if let sel = doc.editSelection { grad = grad.masked(byGray: sel.ciImage.composited(over: CIImage.color(.black, grad.extent))) }
        if let l = doc.state.layer(target?.1), l.locks.transparency, !mask {
            grad = grad.masked(byAlphaOf: base)
        }
        grad = grad.withOpacity(app.gradientTool.opacity)
        return grad.blended(over: base, mode: app.gradientTool.blendMode)
    }

    private func updatePreview() {
        guard let (d, id, tgt) = target, let s = start, let e = end else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        if tgt.isMask { return }
        let grad = gradientImage(s, e, space: space, gray: false)
        let sel = d.state.selection?.ciImage
        let opacity = app.gradientTool.opacity, mode = app.gradientTool.blendMode
        let lockT = d.state.layer(id)?.locks.transparency ?? false
        d.contentOverrides[id] = { img in
            var g = grad.cropped(to: img.extent.union(space.ciCanvas))
            if let sel { g = g.masked(byGray: sel.composited(over: CIImage.color(.black, g.extent))) }
            if lockT { g = g.masked(byAlphaOf: img) }
            return g.withOpacity(opacity).blended(over: img, mode: mode)
        }
        d.setNeedsRender()
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let s = start, let e = end else { return }
        let a = canvas.docToView(s), b = canvas.docToView(e)
        let p = CGMutablePath()
        p.move(to: a); p.addLine(to: b)
        OverlayStyle.contrastStroke(ctx, p)
        OverlayStyle.circleHandle(ctx, at: a, size: 8)
        OverlayStyle.circleHandle(ctx, at: b, size: 8, filled: true)
    }
}

final class PaintBucketTool: Tool {
    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let (d, id, tgt) = requirePixelTarget() else { return }
        let seed = IPoint(x: Int(floor(e.doc.x)), y: Int(floor(e.doc.y)))
        guard seed.x >= 0, seed.y >= 0, seed.x < d.state.width, seed.y < d.state.height else { return }
        let s = app.bucket
        // (Quick Mask: the flood follows the mask's own values, as the bucket does on any channel)
        guard let src = tgt == .quickMask ? AppActions.quickMaskSample(d) : AppActions.sampleSource(allLayers: s.sampleAllLayers) else { return }
        var mask = SelectionOps.floodMask(src: src, seed: seed, tolerance: s.tolerance, contiguous: s.contiguous, antialias: s.antialias)
        if let sel = d.editSelection { mask = SelectionOps.combine(mask, sel, mode: .intersect) }
        guard let (working, origin) = d.beginPixelEdit(layerID: id, target: tgt) else { return }
        let ctx = working.context
        let canvasInBuf = CGRect(x: -origin.x, y: -origin.y, width: d.state.width, height: d.state.height)
        ctx.saveGState()
        working.clip(toMask: mask.makeCGImage(), in: canvasInBuf)
        ctx.setAlpha(CGFloat(s.opacity))
        var mode = s.blendMode.cgBlendMode
        if tgt == .content, d.state.layer(id)?.locks.transparency == true { mode = .sourceAtop }
        ctx.setBlendMode(mode)
        if s.usePattern, let p = PatternLibrary.pattern(id: s.patternID, custom: app.customPatterns) {
            let img = p.image.makeCGImage()
            ctx.translateBy(x: canvasInBuf.minX, y: canvasInBuf.minY)
            ctx.scaleBy(x: 1, y: -1)   // undo the buffer flip so tiles are upright
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height), byTiling: true)
        } else {
            let c = tgt.isMask ? RGBA(gray: app.foreground.luminance) : app.foreground
            ctx.setFillColor(c.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: working.width, height: working.height))
        }
        ctx.restoreGState()
        working.markDirty()
        d.commit("Paint Bucket")
    }
}

final class MagicEraserTool: Tool {
    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let (d, id, tgt) = requirePixelTarget(), tgt == .content else { return }
        let seed = IPoint(x: Int(floor(e.doc.x)), y: Int(floor(e.doc.y)))
        guard seed.x >= 0, seed.y >= 0, seed.x < d.state.width, seed.y < d.state.height else { return }
        guard let src = AppActions.sampleSource(allLayers: false) else { return }
        var mask = SelectionOps.floodMask(src: src, seed: seed, tolerance: app.magicEraserTolerance, contiguous: true, antialias: true)
        if let sel = d.state.selection { mask = SelectionOps.combine(mask, sel, mode: .intersect) }
        guard let (working, origin) = d.beginPixelEdit(layerID: id, target: .content) else { return }
        let ctx = working.context
        ctx.saveGState()
        working.clip(toMask: mask.makeCGImage(), in: CGRect(x: -origin.x, y: -origin.y, width: d.state.width, height: d.state.height))
        if d.state.layer(id)?.locks.transparency == true {
            // transparency lock: the pixels change to the background colour instead of becoming transparent
            ctx.setBlendMode(.sourceAtop)
            ctx.setFillColor(app.background.cgColor)
        } else {
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(RGBA.black.cgColor)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: working.width, height: working.height))
        ctx.restoreGState()
        working.markDirty()
        d.commit("Magic Eraser")
    }
}
