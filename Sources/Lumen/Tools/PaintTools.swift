import AppKit
import CoreImage
import ImageCratCore

// MARK: - Brush / Pencil / Eraser / History Brush

final class BrushTool: Tool {
    private var stroke: PaintStroke?
    private var engine: BrushDynamicsEngine?
    private var lastStrokeEnd: CGPoint?
    private var historySource: (PixelBuffer, IPoint)?
    private var sampling = false
    private var airbrushTimer: Timer?
    private var blockDab: CGImage?

    override var cursor: NSCursor { .crosshair }

    private var settings: BrushSettings { app.brushSettings(for: kind) }

    private var isPencilLike: Bool { kind == .pencil || (kind == .eraser && app.eraserMode != .brush) }

    override func mouseDown(_ e: ToolEvent) {
        // Alt-click with brush/pencil samples color
        if e.option && (kind == .brush || kind == .pencil) {
            sampling = true
            sampleColor(e)
            return
        }
        guard let (d, id, target) = requirePixelTarget() else { return }
        let s = settings
        var blend = s.blendMode.cgBlendMode
        var paint = BrushDynamicsEngine.Paint.dynamic(fg: app.foreground, bg: app.background)
        if kind == .eraser {
            if target.isMask {
                blend = .normal
                paint = .fixed(app.background)
            } else if let l = d.state.layer(id), l.locks.transparency {
                blend = .normal
                paint = .fixed(app.background)
            } else {
                blend = .destinationOut
                paint = .fixed(.black)
            }
        }
        guard let st = PaintStroke(doc: d, layerID: id, target: target, opacity: s.opacity, blend: blend) else { return }
        st.setPreviewBlend(kind == .eraser ? .normal : s.blendMode)
        stroke = st
        if kind == .historyBrush {
            historySource = historyBuffer(d, id)
            if historySource == nil { status("History state has no pixels for this layer."); stroke = nil; d.revertUncommitted(); return }
        }
        let eng = BrushDynamicsEngine(settings: s, target: st.strokeBuf, origin: st.origin, paint: paint,
                                      aliased: isPencilLike, grayOutput: target.isMask)
        if kind == .historyBrush {
            eng.customStamp = { [weak self] dab in self?.historyDab(dab) }
        } else if kind == .eraser && app.eraserMode == .block {
            eng.customStamp = { [weak self] dab in self?.blockDab(at: dab.center) }
        }
        engine = eng
        st.dynamics = eng
        blockDab = nil
        if e.shift, let last = lastStrokeEnd {
            // Shift-click: a straight line from the end of the last stroke (no smoothing on it)
            var p0 = PenSample(e)
            p0.p = last
            eng.begin(p0)
            var p1 = PenSample(e)
            p1.direct = true
            eng.move(p1)
        } else {
            eng.begin(PenSample(e))
        }
        st.flush()
        if s.airbrush && kind != .historyBrush {
            let t = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in self?.airbrushTick() }
            RunLoop.main.add(t, forMode: .common)
            airbrushTimer = t
        }
    }

    override func mouseDragged(_ e: ToolEvent) {
        if sampling { sampleColor(e); return }
        guard let st = stroke, let eng = engine else { return }
        eng.move(PenSample(e))
        st.flush()
    }

    override func mouseUp(_ e: ToolEvent) {
        if sampling { sampling = false; app.pushRecent(app.foreground); return }
        stopAirbrush()
        guard let st = stroke, let eng = engine else { return }
        eng.move(PenSample(e), final: true)
        lastStrokeEnd = e.doc
        st.finish(name: kind.displayName.replacingOccurrences(of: " Tool", with: ""))
        stroke = nil
        engine = nil
        historySource = nil
    }

    override func cancel() {
        stopAirbrush()
        super.cancel()
    }

    override func deactivate() {
        stopAirbrush()
        super.deactivate()
    }

    private func airbrushTick() {
        guard let st = stroke, let eng = engine else { stopAirbrush(); return }
        eng.airbrushTick()
        st.flush()
    }

    private func stopAirbrush() {
        airbrushTimer?.invalidate()
        airbrushTimer = nil
    }

    private func sampleColor(_ e: ToolEvent) {
        guard let b = AppActions.sampleSource(allLayers: true), let c = EyedropperTool.average(b, at: e.doc, size: 1) else { return }
        app.foreground = c
    }

    private func historyBuffer(_ d: Document, _ id: UUID) -> (PixelBuffer, IPoint)? {
        let idx = app.historyBrushSource ?? 0
        let h = d.history.indices.contains(idx) ? d.history[idx] : d.history[0]
        if let l = h.state.layer(id), let r = l.raster { return (r.buffer, r.origin) }
        return nil
    }

    /// History brush: paints pixels of a history state through the (dynamic) dab mask.
    private func historyDab(_ dab: BrushDynamicsEngine.DabInstance) {
        guard let st = stroke, let (src, so) = historySource else { return }
        let s = settings
        guard let m = BrushTips.mask(diameter: dab.diameter, hardness: s.hardness, roundness: dab.roundness,
                                     angle: dab.angle.rounded(), tipID: s.tipID) else { return }
        st.maskedDab(mask: m, at: dab.center, source: src, sourceOrigin: so, offset: .zero, alpha: dab.alpha)
    }

    /// Eraser block mode: a fixed-size square in screen pixels.
    private func blockDab(at p: CGPoint) {
        guard let st = stroke else { return }
        if blockDab == nil {
            let side = max(1, 16 / max(0.1, canvas.zoom))
            let b = PixelBuffer(width: Int(side), height: Int(side))
            b.context.setFillColor(RGBA.black.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: side, height: side))
            blockDab = b.makeCGImage()
        }
        st.dab(blockDab!, at: p, alpha: 1, snap: true)
    }

    override func drawOverlay(_ ctx: CGContext) {
        drawBrushCursor(ctx, size: settings.size, hardness: settings.hardness)
    }

    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }

    static func handleBracketKeys(_ e: NSEvent) -> Bool { BrushKeys.handleBrackets(e) }
}

// MARK: - Clone stamp / Healing brush / Spot healing

final class CloneTool: Tool {
    private var stroke: PaintStroke?
    private var placer = DabPlacer(spacing: 1, smoothing: 0)
    // Source point / offset live in the Clone Source panel's active slot (Edits/CloneSources.swift).
    private var sourcePoint: CGPoint? {
        get { CloneSources.shared.slot.point }
        set { CloneSources.shared.define(newValue, doc: doc) }
    }
    private var spotOffset: CGPoint?
    private var offset: CGPoint? {
        get { kind == .spotHealing ? spotOffset : CloneSources.shared.toolOffset }
        set { if kind == .spotHealing { spotOffset = newValue } else { CloneSources.shared.toolOffset = newValue } }
    }
    private var sourceBuffer: (PixelBuffer, IPoint)?
    private var strokeStart: CGPoint?
    private var currentPoint: CGPoint?
    private var dynamics = DabDynamics()

    override var cursor: NSCursor { .crosshair }

    private var settings: BrushSettings { app.brushSettings(for: kind) }

    override func mouseDown(_ e: ToolEvent) {
        if e.option && kind != .spotHealing {
            sourcePoint = e.doc
            offset = nil
            status("Clone source set at \(Int(e.doc.x)), \(Int(e.doc.y)).")
            return
        }
        if kind != .spotHealing && sourcePoint == nil {
            status("Option-click to define a source point to clone from.")
            Beep.play()
            return
        }
        guard let (d, id, target) = requirePixelTarget() else { return }
        let s = settings
        guard let st = PaintStroke(doc: d, layerID: id, target: target, opacity: s.opacity, blend: kind == .cloneStamp ? s.blendMode.cgBlendMode : .normal) else { return }
        st.setPreviewBlend(kind == .cloneStamp ? s.blendMode : .normal)
        stroke = st
        if app.cloneSampleAll && kind == .cloneStamp && target == .content, let comp = AppActions.sampleSource(allLayers: true) {
            sourceBuffer = (comp, .zero)
        } else {
            sourceBuffer = (st.base, st.origin)
        }
        if kind != .spotHealing, let ext = CloneSources.shared.externalSource(for: d) { sourceBuffer = ext }
        if kind == .spotHealing {
            offset = .zero   // decided at end
        } else if offset == nil || !app.cloneAligned {
            offset = sourcePoint! - e.doc
        }
        strokeStart = e.doc
        placer = DabPlacer(spacing: max(1, s.size * max(0.05, s.spacing)), smoothing: s.smoothing)
        dynamics = DabDynamics()
        for smp in placer.begin(PenSample(e)) { place(smp) }
        st.flush()
    }

    override func mouseDragged(_ e: ToolEvent) {
        currentPoint = e.doc
        guard let st = stroke else { return }
        for smp in placer.move(PenSample(e)) { place(smp) }
        st.flush()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let st = stroke else { return }
        for smp in placer.move(PenSample(e), final: true) { place(smp) }
        st.flush()
        st.applyToWorking()
        if kind == .healing || kind == .spotHealing {
            heal(st)
        }
        st.finish(name: kind.displayName.replacingOccurrences(of: " Tool", with: ""))
        stroke = nil
        currentPoint = nil
    }

    private func place(_ smp: PenSample) {
        guard let st = stroke, let (src, so) = sourceBuffer else { return }
        let s = settings
        let p = smp.p
        let dab = dynamics.dab(smp, s)   // size / angle / roundness / opacity from pressure, tilt, rotation, …
        guard let m = BrushTips.mask(diameter: dab.size, hardness: s.hardness, roundness: dab.roundness, angle: dab.angle, tipID: s.tipID) else { return }
        if kind == .spotHealing {
            // paint a marker (the region to heal); pixels are filled at the end
            if let img = BrushTips.colored(m, color: RGBA(r: 0.5, g: 0.5, b: 0.5)) { st.dab(img, at: p, alpha: 1) }
            return
        }
        if CloneSources.shared.needsTransform, let t = CloneSources.shared.slot.destToSource {
            st.transformedDab(mask: m, at: p, source: src, sourceOrigin: so, destToSource: t, alpha: s.flow * dab.alpha)
            return
        }
        st.maskedDab(mask: m, at: p, source: src, sourceOrigin: so, offset: offset ?? .zero, alpha: s.flow * dab.alpha)
    }

    /// Low-frequency color matching (healing) of the stroke area.
    private func heal(_ st: PaintStroke) {
        let r = st.totalDirty.insetBy(-Int(settings.size)).intersection(st.working.bounds)
        if r.isEmpty { return }
        let space = CanvasSpace(width: st.working.width, height: st.working.height)
        let full = space.ciCanvas
        let region = space.ciRect(r)
        let base = st.base.ciImage
        let strokeAlpha = st.strokeBuf.ciImage.alphaAsGray
        let radius = max(2, settings.size / 3)

        var source: CIImage
        if kind == .spotHealing {
            // Content-aware: PatchMatch-fill the painted area, then colour-match it to the surroundings.
            let boosted = strokeAlpha.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0),
                                                                                    "inputGVector": CIVector(x: 4, y: 0, z: 0, w: 0),
                                                                                    "inputBVector": CIVector(x: 4, y: 0, z: 0, w: 0)]).cropped(to: full)
            let hole = SelectionOps.expand(RenderEngine.renderBuffer(boosted, docRect: IRect(x: 0, y: 0, width: st.working.width, height: st.working.height), space: space, format: .gray), by: 1)
            source = Inpainter.inpaint(st.base, hole: hole).ciImage
        } else {
            // The cloned pixels are the stroke content
            source = st.working.ciImage
        }
        // Normalized convolution of the destination excluding the stroke area
        let keep = strokeAlpha.inverted()
        let destMasked = base.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])
        let blurDest = destMasked.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: full)
        let blurKeep = keep.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: full)
        let blurSrc = source.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: full)
        guard let k = CloneTool.healKernel else { return }
        let healed = k.apply(extent: full, arguments: [source, blurDest, blurKeep, blurSrc]) ?? source
        let result = healed.mixed(with: base, mask: strokeAlpha.applyingGaussianBlur(sigma: 1).cropped(to: full))
        let img = result.cropped(to: region)
        // Render back into the working buffer region
        let sub = RenderEngine.renderBuffer(img, docRect: r, space: space)
        st.working.copyPixels(from: sub, at: r.origin)
        if let sel = st.selectionMask {
            // Respect selection: restore unselected pixels
            let restored = PixelBuffer(width: r.width, height: r.height)
            restored.copyPixels(from: st.base, at: IPoint(x: -r.x, y: -r.y))
            let ctx = restored.context
            ctx.saveGState()
            restored.clip(toMask: sel, in: st.canvasRectInBuffer.offsetBy(dx: CGFloat(-r.x), dy: CGFloat(-r.y)))
            restored.drawImage(sub.makeCGImage(), in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
            ctx.restoreGState()
            st.working.copyPixels(from: restored, at: r.origin)
        }
        st.working.markDirty()
        st.doc.setNeedsRender()
    }

    static let healKernel = CIColorKernel(source: """
    kernel vec4 heal(__sample s, __sample bd, __sample bk, __sample bs) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 D = bk.r > 0.001 ? bd.rgb / bk.r : bs.rgb;
        vec3 BS = bs.a > 0.0 ? bs.rgb / bs.a : vec3(0.0);
        vec3 r = clamp(S + (D - BS), 0.0, 1.0);
        return vec4(r * s.a, s.a);
    }
    """)

    override func drawOverlay(_ ctx: CGContext) {
        if kind != .spotHealing { CloneSources.shared.drawOverlay(ctx, canvas: canvas, brushSize: settings.size, painting: stroke != nil) }
        drawBrushCursor(ctx, size: settings.size, hardness: settings.hardness)
        // Show source crosshair
        if kind != .spotHealing, let off = offset, let c = currentPoint ?? canvas.lastMouseView.map({ canvas.viewToDoc($0) }), stroke != nil {
            drawCross(ctx, canvas.docToView(CloneSources.shared.sourcePoint(forDest: c) ?? c + off))
        } else if let sp = sourcePoint, stroke == nil, kind != .spotHealing {
            if let off = offset, let m = canvas.lastMouseView, app.cloneAligned {
                drawCross(ctx, canvas.docToView(canvas.viewToDoc(m) + off))
            } else {
                drawCross(ctx, canvas.docToView(sp))
            }
        }
    }

    private func drawCross(_ ctx: CGContext, _ v: CGPoint) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: v.x - 8, y: v.y)); p.addLine(to: CGPoint(x: v.x + 8, y: v.y))
        p.move(to: CGPoint(x: v.x, y: v.y - 8)); p.addLine(to: CGPoint(x: v.x, y: v.y + 8))
        OverlayStyle.contrastStroke(ctx, p)
    }

    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}

// MARK: - Blur / Sharpen / Smudge / Dodge / Burn / Sponge

final class RetouchTool: Tool {
    private var working: PixelBuffer?
    private var origin: IPoint = .zero
    private var placer = DabPlacer(spacing: 1, smoothing: 0)
    private var selection: PixelBuffer?
    private var pickup: [Float] = []
    private var pickupSize = 0
    private var d: Document?
    /// Transparency lock: Blur and Smudge change colours only, the alpha stays.
    private var lockAlpha = false
    private var dynamics = DabDynamics()
    private var brush: BrushSettings { app.brushSettings(for: kind) }

    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let (doc, id, target) = requirePixelTarget() else { return }
        guard let (w, o) = doc.beginPixelEdit(layerID: id, target: target) else { return }
        d = doc
        lockAlpha = target == .content && (doc.state.layer(id)?.locks.transparency ?? false)
        working = w
        origin = o
        selection = target == .quickMask ? nil : doc.state.selection
        pickup = []
        let s = brush
        placer = DabPlacer(spacing: max(1, s.size * 0.15), smoothing: s.smoothing)
        dynamics = DabDynamics()
        for smp in placer.begin(PenSample(e)) { process(smp) }
        w.markDirty()
        doc.setNeedsRender()
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let w = working else { return }
        for smp in placer.move(PenSample(e)) { process(smp) }
        w.markDirty()
        d?.setNeedsRender()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let w = working else { return }
        for smp in placer.move(PenSample(e), final: true) { process(smp) }   // the stroke ends where the pen does
        w.markDirty()
        d?.commit(kind.displayName.replacingOccurrences(of: " Tool", with: ""))
        working = nil
        d = nil
    }

    private func process(_ smp: PenSample) {
        guard let w = working else { return }
        let p = smp.p
        let s = brush
        let rs = app.retouch
        let dab = dynamics.dab(smp, s)
        let size = dab.size
        let radius = size / 2
        let cx = Double(p.x) - Double(origin.x), cy = Double(p.y) - Double(origin.y)
        let x0 = max(0, Int(floor(cx - radius))), x1 = min(w.width - 1, Int(ceil(cx + radius)))
        let y0 = max(0, Int(floor(cy - radius))), y1 = min(w.height - 1, Int(ceil(cy + radius)))
        if x1 < x0 || y1 < y0 { return }
        let isGray = w.format == .gray
        let bpp = isGray ? 1 : 4
        let data = w.data.assumingMemoryBound(to: UInt8.self)
        let bpr = w.bytesPerRow
        let hard = s.hardness
        let strength = rs.strength * dab.alpha

        // snapshot for neighborhood ops
        let rw = x1 - x0 + 1, rh = y1 - y0 + 1
        var snap = [UInt8](repeating: 0, count: rw * rh * bpp)
        for y in 0..<rh { for x in 0..<(rw * bpp) { snap[y * rw * bpp + x] = data[(y0 + y) * bpr + x0 * bpp + x] } }
        @inline(__always) func sp(_ x: Int, _ y: Int, _ c: Int) -> Double {
            let xx = clamp(x - x0, 0, rw - 1), yy = clamp(y - y0, 0, rh - 1)
            return Double(snap[(yy * rw + xx) * bpp + c])
        }

        if kind == .smudge && pickup.isEmpty {
            pickupSize = Int(ceil(radius * 2)) + 1
            pickup = [Float](repeating: 0, count: pickupSize * pickupSize * 4)
            for y in 0..<pickupSize {
                for x in 0..<pickupSize {
                    let bx = Int(cx - radius) + x, by = Int(cy - radius) + y
                    guard bx >= 0, by >= 0, bx < w.width, by < w.height else { continue }
                    for c in 0..<bpp { pickup[(y * pickupSize + x) * 4 + c] = Float(data[by * bpr + bx * bpp + c]) }
                }
            }
            if app.retouch.fingerPainting {
                let fg = app.foreground
                for i in 0..<(pickupSize * pickupSize) {
                    pickup[i * 4] = Float(fg.r * 255); pickup[i * 4 + 1] = Float(fg.g * 255); pickup[i * 4 + 2] = Float(fg.b * 255); pickup[i * 4 + 3] = 255
                }
            }
        }

        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let dist = sqrt(dx * dx + dy * dy) / max(0.5, radius)
                if dist > 1 { continue }
                var wgt = dist <= hard ? 1.0 : 1 - (dist - hard) / max(0.001, 1 - hard)
                wgt = wgt * wgt * (3 - 2 * wgt)
                if let sel = selection {
                    let gx = x + origin.x, gy = y + origin.y
                    if gx < 0 || gy < 0 || gx >= sel.width || gy >= sel.height { continue }
                    wgt *= Double(sel.data.assumingMemoryBound(to: UInt8.self)[gy * sel.bytesPerRow + gx]) / 255
                }
                if wgt <= 0.001 { continue }
                let i = y * bpr + x * bpp
                if isGray {
                    var v = Double(data[i]) / 255
                    v = retouchGray(v, wgt * strength, x, y, sp)
                    data[i] = UInt8(clamp(v, 0, 1) * 255)
                    continue
                }
                let a = Double(data[i + 3])
                if a == 0 && kind != .smudge { continue }
                let inv = a > 0 ? 255 / a : 0
                var r = Double(data[i]) * inv / 255, g = Double(data[i + 1]) * inv / 255, b = Double(data[i + 2]) * inv / 255
                var na = a
                let k = wgt * strength
                switch kind {
                case .dodge, .burn:
                    let L = 0.299 * r + 0.587 * g + 0.114 * b
                    let rangeW: Double
                    switch rs.range {
                    case .shadows: rangeW = clamp(1 - L * 1.6, 0, 1)
                    case .midtones: rangeW = clamp(1 - abs(L - 0.5) * 2, 0, 1)
                    case .highlights: rangeW = clamp((L - 0.35) * 1.6, 0, 1)
                    }
                    let amt = k * rs.exposure * rangeW * 0.35
                    if kind == .dodge {
                        r += (1 - r) * amt; g += (1 - g) * amt; b += (1 - b) * amt
                    } else {
                        r -= r * amt; g -= g * amt; b -= b * amt
                    }
                case .sponge:
                    let L = 0.299 * r + 0.587 * g + 0.114 * b
                    let amt = k * 0.25 * (rs.spongeSaturate ? -1 : 1)
                    r += (L - r) * amt; g += (L - g) * amt; b += (L - b) * amt
                case .blur, .sharpen:
                    var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0
                    for oy in -1...1 { for ox in -1...1 {
                        sr += sp(x + ox, y + oy, 0); sg += sp(x + ox, y + oy, 1); sb += sp(x + ox, y + oy, 2); sa += sp(x + ox, y + oy, 3)
                    } }
                    sr /= 9; sg /= 9; sb /= 9; sa /= 9
                    let ainv = sa > 0 ? 1 / sa : 0
                    let ar = sr * ainv, ag = sg * ainv, ab = sb * ainv
                    if kind == .blur {
                        let t = k * 0.5
                        r += (ar - r) * t; g += (ag - g) * t; b += (ab - b) * t
                        if !lockAlpha { na += (sa - na) * t }
                    } else {
                        let t = k * 0.6
                        r += (r - ar) * t; g += (g - ag) * t; b += (b - ab) * t
                    }
                case .smudge:
                    let px = x - Int(cx - radius), py = y - Int(cy - radius)
                    guard px >= 0, py >= 0, px < pickupSize, py < pickupSize else { continue }
                    let pi = (py * pickupSize + px) * 4
                    let t = Float(wgt * rs.strength)
                    for c in 0..<4 {
                        let cur = Float(data[i + c])
                        let nv = cur + (pickup[pi + c] - cur) * t
                        data[i + c] = UInt8(clamp(nv, 0, 255))
                        pickup[pi + c] = pickup[pi + c] + (Float(data[i + c]) - pickup[pi + c]) * (1 - Float(rs.strength))
                    }
                    if lockAlpha {
                        // keep the original alpha: rescale the smudged (premultiplied) colour to it
                        let oa = UInt8(a), sa = data[i + 3]
                        if oa == 0 {
                            for c in 0..<4 { data[i + c] = 0 }
                        } else if sa > 0 {
                            let k = Double(oa) / Double(sa)
                            for c in 0..<3 { data[i + c] = UInt8(clamp(Double(data[i + c]) * k, 0, Double(oa))) }
                            data[i + 3] = oa
                        } else {
                            data[i] = UInt8(clamp(r, 0, 1) * a); data[i + 1] = UInt8(clamp(g, 0, 1) * a); data[i + 2] = UInt8(clamp(b, 0, 1) * a); data[i + 3] = oa
                        }
                        continue
                    }
                    // fix premultiplication
                    let aa = data[i + 3]
                    for c in 0..<3 where data[i + c] > aa { data[i + c] = aa }
                    continue
                default: break
                }
                na = clamp(na, 0, 255)
                let f = na / 255
                data[i] = UInt8(clamp(r, 0, 1) * f * 255)
                data[i + 1] = UInt8(clamp(g, 0, 1) * f * 255)
                data[i + 2] = UInt8(clamp(b, 0, 1) * f * 255)
                data[i + 3] = UInt8(na)
            }
        }
    }

    private func retouchGray(_ v: Double, _ k: Double, _ x: Int, _ y: Int, _ sp: (Int, Int, Int) -> Double) -> Double {
        switch kind {
        case .dodge: return v + (1 - v) * k * 0.2
        case .burn: return v - v * k * 0.2
        case .blur:
            var s = 0.0
            for oy in -1...1 { for ox in -1...1 { s += sp(x + ox, y + oy, 0) } }
            return v + (s / 9 / 255 - v) * k * 0.5
        case .sharpen:
            var s = 0.0
            for oy in -1...1 { for ox in -1...1 { s += sp(x + ox, y + oy, 0) } }
            return v + (v - s / 9 / 255) * k * 0.6
        default: return v
        }
    }

    override func drawOverlay(_ ctx: CGContext) { drawBrushCursor(ctx, size: brush.size, hardness: brush.hardness) }
    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}
