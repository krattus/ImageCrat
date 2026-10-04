import AppKit
import CoreImage
import ImageCratCore

/// Shared healing / content-aware helpers.
enum Healing {
    static let kernel = CIColorKernel(source: """
    kernel vec4 healK(__sample s, __sample bd, __sample bk, __sample bs) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 D = bk.r > 0.001 ? bd.rgb / bk.r : bs.rgb;
        vec3 BS = bs.a > 0.0 ? bs.rgb / bs.a : vec3(0.0);
        vec3 r = clamp(S + (D - BS), 0.0, 1.0);
        return vec4(r * s.a, s.a);
    }
    """)

    /// Blends `source` into `dest` inside `mask` (gray, white = replace) matching the low-frequency color of the surroundings.
    static func heal(dest: CIImage, source: CIImage, mask: CIImage, radius: Double, extent: CGRect) -> CIImage {
        let keep = mask.inverted().cropped(to: extent)
        let destMasked = dest.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])
        let bd = destMasked.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        let bk = keep.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        let bs = source.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        let healed = kernel?.apply(extent: extent, arguments: [source.cropped(to: extent), bd, bk, bs]) ?? source
        return healed.mixed(with: dest, mask: mask.applyingGaussianBlur(sigma: 1).cropped(to: extent)).cropped(to: extent)
    }

    /// Content-aware fill of `hole` (canvas-size gray) on the active raster layer. Returns false if not applicable.
    @discardableResult
    static func contentAwareFill(_ d: Document, layerID: UUID, hole: PixelBuffer, sampleAll: Bool, name: String) -> Bool {
        guard let l = d.state.layer(layerID), l.isRaster, let (w, o) = d.beginPixelEdit(layerID: layerID, target: .content) else { return false }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let srcImg: CIImage = sampleAll ? Compositor.shared.composite(d.committedState) : space.place(w, at: o)
        let src = RenderEngine.renderBuffer(srcImg.cropped(to: space.ciCanvas), docRect: d.state.canvasRect, space: space)
        AppModel.shared.setStatus("Filling…")
        let filled = Inpainter.inpaint(src, hole: hole)
        // Write the filled pixels into the layer inside the (slightly feathered) hole
        let soft = SelectionOps.feather(hole, radius: 1)
        let ctx = w.context
        ctx.saveGState()
        w.clip(toMask: soft.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: d.state.width, height: d.state.height))
        if !sampleAll { ctx.setBlendMode(.copy) }
        w.drawImage(filled.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: d.state.width, height: d.state.height))
        ctx.restoreGState()
        w.markDirty()
        d.commit(name)
        AppModel.shared.setStatus("")
        return true
    }
}

// MARK: - Remove tool

/// Paint over an object; it is filled with surrounding content when you release.
final class RemoveTool: Tool {
    private var stroke: PaintStroke?
    private var placer = DabPlacer(spacing: 1, smoothing: 0)
    private var markBuffer: PixelBuffer?     // canvas-size gray of painted area
    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id) else { return }
        if !l.isRaster { AppActions.offerRasterize(layer: id); return }
        guard pixelsEditable(l) else { return }
        markBuffer = PixelBuffer(width: d.state.width, height: d.state.height, format: .gray)
        let s = app.removeBrush
        placer = DabPlacer(spacing: max(1, s.size * 0.1), smoothing: s.smoothing)
        for (p, pr) in placer.begin(e.doc, pressure: e.pressure) { mark(p, pr) }
        updatePreview()
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard markBuffer != nil else { return }
        for (p, pr) in placer.move(e.doc, pressure: e.pressure) { mark(p, pr) }
        updatePreview()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let id = d.activeLayerID, let m = markBuffer else { return }
        markBuffer = nil
        d.displayOverride = nil
        var hole = m
        if let sel = d.state.selection { hole = SelectionOps.combine(hole, sel, mode: .intersect) }
        hole = SelectionOps.expand(hole, by: 2)
        if let l = d.state.layer(id), l.locks.transparency, let r = l.raster {
            // Transparency lock: only opaque pixels are replaced, the alpha stays as it is.
            let alpha = PixelBuffer(width: d.state.width, height: d.state.height, format: .gray)
            alpha.copyPixels(from: r.buffer.toGray(useAlpha: true), at: r.origin)
            alpha.markDirty()
            hole = SelectionOps.combine(hole, SelectionOps.contract(alpha, by: 2), mode: .intersect)
            if hole.opaqueBounds() == nil { d.setNeedsRender(); return }
        }
        if GenAIToolHooks.removeTool(d, hole: hole) { d.setNeedsRender(); return }
        if NeuralRemove.removeStroke(d, layerID: id, hole: hole, sampleAll: app.removeSampleAll) { d.setNeedsRender(); return }
        Healing.contentAwareFill(d, layerID: id, hole: hole, sampleAll: app.removeSampleAll, name: "Remove")
        d.setNeedsRender()
    }

    private func mark(_ p: CGPoint, _ pressure: Double) {
        guard let m = markBuffer else { return }
        let s = app.removeBrush
        let r = s.size / 2 * (s.pressureSize ? max(0.1, pressure) : 1)
        m.context.setFillColor(gray: 1, alpha: 1)
        m.context.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        m.markDirty()
    }

    private func updatePreview() {
        guard let d = doc, let m = markBuffer else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let overlay = CIImage.color(RGBA(r: 1, g: 0.2, b: 0.4, a: 0.45), space.ciCanvas).masked(byGray: m.ciImage)
        d.displayOverride = { overlay.composited(over: $0) }
        d.setNeedsRender()
    }

    override func drawOverlay(_ ctx: CGContext) { drawBrushCursor(ctx, size: app.removeBrush.size) }
    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}

// MARK: - Patch tool

final class PatchTool: SelectionToolBase {
    private var lassoPts: [CGPoint] = []
    private var dragStart: CGPoint?
    private var dragDelta: CGPoint = .zero

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if insideSelection(e.doc), d.state.selection != nil, !e.shift, !e.option {
            dragStart = e.doc
            dragDelta = .zero
            return
        }
        combine = combineMode(e)
        lassoPts = [e.doc]
    }

    override func mouseDragged(_ e: ToolEvent) {
        if let s = dragStart {
            dragDelta = e.doc - s
            preview()
            return
        }
        if !lassoPts.isEmpty { lassoPts.append(e.doc) }
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc else { return }
        if dragStart != nil {
            dragStart = nil
            d.displayOverride = nil
            if dragDelta.length > 1 { applyPatch(d, delta: dragDelta) }
            d.setNeedsRender()
            return
        }
        defer { lassoPts = [] }
        guard lassoPts.count > 2 else { return }
        let p = CGMutablePath(); p.addLines(between: lassoPts); p.closeSubpath()
        apply(SelectionOps.mask(fromPath: p, width: d.state.width, height: d.state.height), name: "Patch Selection")
    }

    private func healedImage(_ d: Document, delta: CGPoint) -> (CIImage, CIImage)? {
        guard let id = d.activeLayerID, let l = d.state.layer(id), l.isRaster, let sel = d.state.selection else { return nil }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let layerImg = Compositor.shared.contentImage(l, space: space)!.cropped(to: space.ciCanvas).composited(over: CIImage.clearImage.cropped(to: space.ciCanvas))
        let t = CGAffineTransform(translationX: delta.x, y: -delta.y)
        let selImg = sel.ciImage
        if app.patchMode == .source {
            // fill the selection with pixels from the dragged-to area
            let src = layerImg.clampedToExtent().transformed(by: t.inverted()).cropped(to: space.ciCanvas)
            return (Healing.heal(dest: layerImg, source: src, mask: selImg, radius: max(3, Double(sel.opaqueBounds()?.width ?? 20) / 8), extent: space.ciCanvas), selImg)
        } else {
            // copy the selection to the dragged-to area
            let movedMask = selImg.transformed(by: t).composited(over: CIImage.color(.black, space.ciCanvas)).cropped(to: space.ciCanvas)
            let src = layerImg.clampedToExtent().transformed(by: t).cropped(to: space.ciCanvas)
            return (Healing.heal(dest: layerImg, source: src, mask: movedMask, radius: max(3, Double(sel.opaqueBounds()?.width ?? 20) / 8), extent: space.ciCanvas), movedMask)
        }
    }

    private func preview() {
        guard let d = doc, let id = d.activeLayerID else { return }
        _ = id
        let delta = dragDelta
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        guard let sel = d.state.selection else { return }
        let t = CGAffineTransform(translationX: delta.x, y: -delta.y)
        let outline = CIImage.color(RGBA(r: 1, g: 1, b: 1, a: 0.35), space.ciCanvas).masked(byGray: sel.ciImage.transformed(by: t).composited(over: CIImage.color(.black, space.ciCanvas)).cropped(to: space.ciCanvas))
        d.displayOverride = { outline.composited(over: $0) }
        d.setNeedsRender()
    }

    private func applyPatch(_ d: Document, delta: CGPoint) {
        guard let id = d.activeLayerID, let l = d.state.layer(id) else { return }
        guard pixelsEditable(l) else { return }
        guard let (img, _) = healedImage(d, delta: delta), let (w, o) = d.beginPixelEdit(layerID: id, target: .content) else { NSSound.beep(); return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let placed = space.place(w, at: o)
        let result = img.composited(over: placed)
        RenderEngine.render(result, into: w, docOrigin: o, space: space)
        d.commit("Patch")
    }
}

// MARK: - Content-Aware Move

final class ContentAwareMoveTool: SelectionToolBase {
    private var lassoPts: [CGPoint] = []
    private var dragStart: CGPoint?
    private var dragDelta: CGPoint = .zero

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if insideSelection(e.doc), d.state.selection != nil {
            dragStart = e.doc; dragDelta = .zero
            return
        }
        combine = combineMode(e)
        lassoPts = [e.doc]
    }

    override func mouseDragged(_ e: ToolEvent) {
        if let s = dragStart {
            dragDelta = e.doc - s
            preview()
            return
        }
        if !lassoPts.isEmpty { lassoPts.append(e.doc) }
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc else { return }
        if dragStart != nil {
            dragStart = nil
            d.displayOverride = nil
            if dragDelta.length > 1 { applyMove(d, delta: dragDelta) }
            d.setNeedsRender()
            return
        }
        defer { lassoPts = [] }
        guard lassoPts.count > 2 else { return }
        let p = CGMutablePath(); p.addLines(between: lassoPts); p.closeSubpath()
        apply(SelectionOps.mask(fromPath: p, width: d.state.width, height: d.state.height), name: "Content-Aware Move Selection")
    }

    private func preview() {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id), let sel = d.state.selection else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        guard let content = Compositor.shared.contentImage(l, space: space) else { return }
        let t = CGAffineTransform(translationX: dragDelta.x, y: -dragDelta.y)
        let moved = content.masked(byGray: sel.ciImage.composited(over: CIImage.color(.black, content.extent.union(space.ciCanvas)))).transformed(by: t)
        d.displayOverride = { moved.composited(over: $0) }
        d.setNeedsRender()
    }

    private func applyMove(_ d: Document, delta: CGPoint) {
        guard let id = d.activeLayerID, let l = d.state.layer(id), l.isRaster, let sel = d.state.selection else { NSSound.beep(); return }
        guard pixelsEditable(l) else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let layerImg = Compositor.shared.contentImage(l, space: space)!.cropped(to: space.ciCanvas).composited(over: CIImage.clearImage.cropped(to: space.ciCanvas))
        let t = CGAffineTransform(translationX: delta.x, y: -delta.y)
        let movedMask = sel.ciImage.transformed(by: t).composited(over: CIImage.color(.black, space.ciCanvas)).cropped(to: space.ciCanvas)
        // 1. Fill the original area (move mode)
        var base = layerImg
        if app.contentAwareMoveMode == .move {
            let src = RenderEngine.renderBuffer(layerImg, docRect: d.state.canvasRect, space: space)
            let filled = Inpainter.inpaint(src, hole: SelectionOps.expand(sel, by: 2))
            base = space.place(filled, at: .zero)
        }
        // 2. Blend the moved content at the destination
        let movedContent = layerImg.clampedToExtent().transformed(by: t).cropped(to: space.ciCanvas)
        let result = Healing.heal(dest: base, source: movedContent, mask: movedMask, radius: max(3, Double(sel.opaqueBounds()?.width ?? 20) / 10), extent: space.ciCanvas)
        guard let (w, o) = d.beginPixelEdit(layerID: id, target: .content) else { return }
        RenderEngine.render(result.composited(over: space.place(w, at: o)), into: w, docOrigin: o, space: space)
        // selection follows the moved content
        let newSel = PixelBuffer(width: sel.width, height: sel.height, format: .gray)
        newSel.copyPixels(from: sel, at: IPoint(x: Int(delta.x.rounded()), y: Int(delta.y.rounded())))
        newSel.markDirty()
        d.state.selection = newSel
        d.commit("Content-Aware Move")
    }
}

// MARK: - Red Eye

final class RedEyeTool: Tool {
    override var cursor: NSCursor { .crosshair }
    private var start: CGPoint?
    private var current: CGPoint?

    override func mouseDown(_ e: ToolEvent) { start = e.doc; current = e.doc }
    override func mouseDragged(_ e: ToolEvent) { current = e.doc }

    override func mouseUp(_ e: ToolEvent) {
        defer { start = nil; current = nil }
        guard let (d, id, tgt) = requirePixelTarget(), tgt == .content, let s = start, let c = current else { return }
        // click: search a region scaled to the view; drag: explicit region
        var region = CGRect(p1: s, p2: c)
        if region.width < 4 {
            let r = 60 / canvas.zoom
            region = CGRect(x: s.x - r, y: s.y - r, width: 2 * r, height: 2 * r)
        }
        guard let (w, o) = d.beginPixelEdit(layerID: id, target: .content) else { return }
        let rr = IRect(enclosing: region.offsetBy(dx: CGFloat(-o.x), dy: CGFloat(-o.y))).intersection(w.bounds)
        if rr.isEmpty { d.revertUncommitted(); return }
        let p = w.data.assumingMemoryBound(to: UInt8.self)
        let pupil = app.redEyePupil / 100, darken = app.redEyeDarken / 100
        let cx = Double(rr.x) + Double(rr.width) / 2, cy = Double(rr.y) + Double(rr.height) / 2
        let rad = Double(min(rr.width, rr.height)) / 2
        var changed = 0
        for y in rr.minY..<rr.maxY {
            for x in rr.minX..<rr.maxX {
                let i = y * w.bytesPerRow + x * 4
                let a = Double(p[i + 3]); if a == 0 { continue }
                let r = Double(p[i]) / a, g = Double(p[i + 1]) / a, b = Double(p[i + 2]) / a
                let redness = r - max(g, b)
                if redness < 0.12 || r < 0.25 { continue }
                let dist = sqrt(pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2)) / max(1, rad)
                if dist > 0.4 + pupil * 0.6 { continue }
                let k = clamp(redness * 3, 0, 1) * (1 - clamp((dist - 0.8) * 5, 0, 1))
                let gray = (g + b) / 2 * (1 - darken * 0.8)
                let nr = r + (gray - r) * k, ng = g + (gray - g) * k * 0.3, nb = b + (gray - b) * k * 0.3
                p[i] = UInt8(clamp(nr, 0, 1) * a); p[i + 1] = UInt8(clamp(ng, 0, 1) * a); p[i + 2] = UInt8(clamp(nb, 0, 1) * a)
                changed += 1
            }
        }
        if changed == 0 { d.revertUncommitted(); status("No red eye found."); return }
        w.markDirty()
        d.commit("Red Eye")
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let s = start, let c = current, s.distance(to: c) > 2 else { return }
        OverlayStyle.contrastStroke(ctx, CGPath(rect: canvas.docToView(CGRect(p1: s, p2: c)), transform: nil), dashed: true)
    }
}

// MARK: - Color Replacement

final class ColorReplacementTool: Tool {
    private var working: PixelBuffer?
    private var origin: IPoint = .zero
    private var placer = DabPlacer(spacing: 1, smoothing: 0)
    private var sampled: (Double, Double, Double)?
    private var d: Document?
    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let (doc, id, target) = requirePixelTarget(), target == .content, let (w, o) = doc.beginPixelEdit(layerID: id, target: .content) else { return }
        d = doc; working = w; origin = o
        let s = app.colorReplace
        sampled = nil
        if s.sampling == .backgroundSwatch { let b = app.background; sampled = (b.r, b.g, b.b) } else { sampled = sample(e.doc) }
        let bs = app.colorReplaceBrush
        placer = DabPlacer(spacing: max(1, bs.size * 0.12), smoothing: bs.smoothing)
        for (p, pr) in placer.begin(e.doc, pressure: e.pressure) { dab(p, pr) }
        w.markDirty(); doc.setNeedsRender()
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let w = working else { return }
        for (p, pr) in placer.move(e.doc, pressure: e.pressure) {
            if app.colorReplace.sampling == .continuous { sampled = sample(p) }
            dab(p, pr)
        }
        w.markDirty(); d?.setNeedsRender()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard working != nil else { return }
        d?.commit("Color Replacement")
        working = nil; d = nil
    }

    private func sample(_ p: CGPoint) -> (Double, Double, Double)? {
        guard let w = working else { return nil }
        let (r, g, b, a) = w.pixel(Int(p.x) - origin.x, Int(p.y) - origin.y)
        if a == 0 { return nil }
        return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
    }

    private func dab(_ p: CGPoint, _ pressure: Double) {
        guard let w = working, let ref = sampled else { return }
        let bs = app.colorReplaceBrush
        let s = app.colorReplace
        let radius = bs.size / 2 * (bs.pressureSize ? max(0.1, pressure) : 1)
        let cx = Double(p.x) - Double(origin.x), cy = Double(p.y) - Double(origin.y)
        let x0 = max(0, Int(cx - radius)), x1 = min(w.width - 1, Int(cx + radius))
        let y0 = max(0, Int(cy - radius)), y1 = min(w.height - 1, Int(cy + radius))
        if x1 < x0 || y1 < y0 { return }
        let data = w.data.assumingMemoryBound(to: UInt8.self)
        let fg = app.foreground
        let fgHSL = fg.hsl
        let tol = s.tolerance / 100 * 1.2
        let sel = d?.state.selection
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let dist = sqrt(dx * dx + dy * dy) / radius
                if dist > 1 { continue }
                var wgt = dist <= bs.hardness ? 1.0 : 1 - (dist - bs.hardness) / max(0.001, 1 - bs.hardness)
                if let sel {
                    let gx = x + origin.x, gy = y + origin.y
                    if gx < 0 || gy < 0 || gx >= sel.width || gy >= sel.height { continue }
                    wgt *= Double(sel.alpha(gx, gy)) / 255
                }
                let i = y * w.bytesPerRow + x * 4
                let a = Double(data[i + 3]); if a == 0 { continue }
                let r = Double(data[i]) / a, g = Double(data[i + 1]) / a, b = Double(data[i + 2]) / a
                let diff = abs(r - ref.0) + abs(g - ref.1) + abs(b - ref.2)
                if diff > tol { continue }
                wgt *= 1 - max(0, diff - tol * 0.7) / (tol * 0.3 + 0.0001) * 0   // soft edge near tolerance
                let hsl = RGBA(r: r, g: g, b: b).hsl
                var out: RGBA
                switch s.mode {
                case .hue: out = RGBA(h: fgHSL.h, s: hsl.s, l: hsl.l)
                case .saturation: out = RGBA(h: hsl.h, s: fgHSL.s, l: hsl.l)
                case .luminosity: out = RGBA(h: hsl.h, s: hsl.s, l: fgHSL.l)
                default: out = RGBA(h: fgHSL.h, s: fgHSL.s, l: hsl.l)
                }
                let k = wgt * bs.opacity
                data[i] = UInt8(clamp(r + (out.r - r) * k, 0, 1) * a)
                data[i + 1] = UInt8(clamp(g + (out.g - g) * k, 0, 1) * a)
                data[i + 2] = UInt8(clamp(b + (out.b - b) * k, 0, 1) * a)
            }
        }
    }

    override func drawOverlay(_ ctx: CGContext) {
        drawBrushCursor(ctx, size: app.colorReplaceBrush.size)
        if let m = canvas.lastMouseView {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.move(to: CGPoint(x: m.x - 3, y: m.y)); ctx.addLine(to: CGPoint(x: m.x + 3, y: m.y))
            ctx.move(to: CGPoint(x: m.x, y: m.y - 3)); ctx.addLine(to: CGPoint(x: m.x, y: m.y + 3))
            ctx.strokePath()
        }
    }
    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}

// MARK: - Mixer Brush

final class MixerBrushTool: Tool {
    private var working: PixelBuffer?
    private var origin: IPoint = .zero
    private var placer = DabPlacer(spacing: 1, smoothing: 0)
    private var reservoir: RGBA = .black
    private var loadLeft: Double = 1
    private var d: Document?
    private var composite: PixelBuffer?
    private var lockAlpha = false
    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let (doc, id, target) = requirePixelTarget(), target == .content, let (w, o) = doc.beginPixelEdit(layerID: id, target: .content) else { return }
        d = doc; working = w; origin = o
        lockAlpha = doc.state.layer(id)?.locks.transparency ?? false
        let m = app.mixer
        if m.loadEachStroke || loadLeft <= 0.01 { reservoir = app.foreground; loadLeft = 1 }
        composite = m.sampleAll ? AppActions.sampleSource(allLayers: true) : nil
        let bs = app.mixerBrushSettings
        placer = DabPlacer(spacing: max(1, bs.size * bs.spacing), smoothing: bs.smoothing)
        for (p, pr) in placer.begin(e.doc, pressure: e.pressure) { dab(p, pr) }
        w.markDirty(); doc.setNeedsRender()
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let w = working else { return }
        for (p, pr) in placer.move(e.doc, pressure: e.pressure) { dab(p, pr) }
        w.markDirty(); d?.setNeedsRender()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard working != nil else { return }
        d?.commit("Mixer Brush")
        if app.mixer.cleanEachStroke { loadLeft = 0 }
        working = nil; d = nil; composite = nil
    }

    private func canvasColor(_ p: CGPoint, radius: Double) -> RGBA? {
        let src: PixelBuffer? = composite ?? working
        guard let b = src else { return nil }
        let ox = composite == nil ? origin.x : 0, oy = composite == nil ? origin.y : 0
        var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0, n = 0.0
        let r = max(1, Int(radius / 2))
        let cx = Int(p.x) - ox, cy = Int(p.y) - oy
        var yy = cy - r
        while yy <= cy + r {
            var xx = cx - r
            while xx <= cx + r {
                let (pr, pg, pb, pa) = b.pixel(xx, yy)
                if pa > 0 { sr += Double(pr); sg += Double(pg); sb += Double(pb); sa += Double(pa); n += 1 }
                xx += max(1, r / 3)
            }
            yy += max(1, r / 3)
        }
        guard n > 0 else { return nil }
        return RGBA(r: sr / n / 255, g: sg / n / 255, b: sb / n / 255, a: sa / n / 255)
    }

    private func dab(_ p: CGPoint, _ pressure: Double) {
        guard let w = working else { return }
        let bs = app.mixerBrushSettings
        let m = app.mixer
        let size = bs.size * (bs.pressureSize ? max(0.1, pressure) : 1)
        let wet = m.wet / 100, mix = m.mix / 100
        if let under = canvasColor(p, radius: size / 2) {
            // pick up canvas paint into the reservoir
            reservoir = reservoir.mix(under.withAlpha(1), wet * mix * 0.5)
        }
        let loadRate = 1 - m.load / 100
        loadLeft = max(0, loadLeft - loadRate * 0.01)
        let paintAlpha = bs.flow * (0.3 + 0.7 * (1 - wet * 0.5)) * max(0.05, loadLeft)
        guard let mask = BrushTips.mask(diameter: size, hardness: bs.hardness, roundness: bs.roundness, angle: bs.angle, tipID: bs.tipID),
              let img = BrushTips.colored(mask, color: reservoir) else { return }
        let c = CGPoint(x: p.x - CGFloat(origin.x), y: p.y - CGFloat(origin.y))
        let r = CGRect(x: c.x - CGFloat(img.width) / 2, y: c.y - CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height))
        let ctx = w.context
        ctx.saveGState()
        if let sel = d?.state.selection { w.clip(toMask: sel.makeCGImage(), in: CGRect(x: -origin.x, y: -origin.y, width: sel.width, height: sel.height)) }
        w.drawImage(img, in: r, alpha: CGFloat(paintAlpha * bs.opacity), blend: lockAlpha ? .sourceAtop : .normal)
        ctx.restoreGState()
    }

    override func drawOverlay(_ ctx: CGContext) { drawBrushCursor(ctx, size: app.mixerBrushSettings.size) }
    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}

// MARK: - Rotate View

final class RotateViewTool: Tool {
    private var startAngle: CGFloat = 0
    private var startRotation: Double = 0
    override var cursor: NSCursor { .openHand }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if e.clickCount == 2 { canvas.setRotation(0); return }
        let c = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        startAngle = (e.view - c).angle
        startRotation = d.viewRotation
    }

    override func mouseDragged(_ e: ToolEvent) {
        let c = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        var a = startRotation + Double((e.view - c).angle - startAngle)
        if e.shift { a = (a / (.pi / 12)).rounded() * (.pi / 12) }
        canvas.setRotation(a)
        status(String(format: "Rotation: %.0f°", a * 180 / .pi))
    }

    override func keyDown(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { canvas.setRotation(0); return true }
        return false
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let d = doc else { return }
        let c = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        let a = CGFloat(-d.viewRotation) - .pi / 2
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + cos(a) * 60, y: c.y + sin(a) * 60)); ctx.strokePath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.strokeEllipse(in: CGRect(x: c.x - 60, y: c.y - 60, width: 120, height: 120))
    }
}
