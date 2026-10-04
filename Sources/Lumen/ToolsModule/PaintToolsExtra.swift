import AppKit
import CoreImage
import ImageCratCore

// MARK: - Pattern Stamp / Art History Brush

/// Pattern Stamp paints the current pattern through the brush; Art History Brush paints stylized strokes whose
/// colors come from the History Brush source state. Both run through the brush dynamics engine (so spacing,
/// dynamics and symmetry apply) with a custom stamp.
final class StampBrushTool: Tool {
    private var stroke: PaintStroke?
    private var engine: BrushDynamicsEngine?
    private var patternSource: PixelBuffer?
    private var historySource: (PixelBuffer, IPoint)?
    private var rng = SeededRandom(seed: 1)

    override var cursor: NSCursor { .crosshair }

    private var settings: BrushSettings {
        kind == .patternStamp ? ToolsSettings.shared.patternStampBrush : ToolsSettings.shared.artHistoryBrush
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let (d, id, target) = requirePixelTarget() else { return }
        guard let st = begin(d, layerID: id, target: target, at: e.doc) else { return }
        engine?.begin(PenSample(e))
        st.flush()
    }

    /// Sets up the stroke (shared with the self test).
    @discardableResult
    func begin(_ d: Document, layerID id: UUID, target: EditTarget, at p: CGPoint) -> PaintStroke? {
        let s = settings
        guard let st = PaintStroke(doc: d, layerID: id, target: target, opacity: s.opacity, blend: s.blendMode.cgBlendMode) else { return nil }
        st.setPreviewBlend(s.blendMode)
        if kind == .patternStamp {
            guard let pat = ToolsSettings.shared.currentPattern else { status("No pattern."); d.revertUncommitted(); return nil }
            let phase = ToolsSettings.shared.patternAligned ? CGPoint(x: -st.origin.x, y: -st.origin.y) : st.toBuffer(p)
            patternSource = StampBrushTool.tiled(pat.image, width: st.working.width, height: st.working.height, phase: phase)
        } else {
            historySource = StampBrushTool.historyBuffer(d, id)
            guard historySource != nil else { status("The history state has no pixels for this layer."); d.revertUncommitted(); return nil }
            rng = SeededRandom(seed: UInt64(abs(Int(p.x * 31 + p.y * 17)) + 3))
        }
        stroke = st
        let eng = BrushDynamicsEngine(settings: s, target: st.strokeBuf, origin: st.origin, paint: .dynamic(fg: app.foreground, bg: app.background),
                                      grayOutput: target.isMask)
        eng.customStamp = { [weak self] dab in self?.stamp(dab) }
        engine = eng
        st.dynamics = eng
        return st
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let st = stroke, let eng = engine else { return }
        eng.move(PenSample(e))
        st.flush()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let st = stroke, let eng = engine else { return }
        eng.move(PenSample(e), final: true)
        finish(st)
    }

    func finish(_ st: PaintStroke) {
        st.finish(name: kind.displayName.replacingOccurrences(of: " Tool", with: ""))
        stroke = nil; engine = nil; patternSource = nil; historySource = nil
    }

    /// Feeds a list of samples through the engine (self test).
    func paint(_ pts: [CGPoint]) {
        guard let st = stroke, let eng = engine, let f = pts.first else { return }
        eng.begin(PenSample(p: f))
        for (i, p) in pts.dropFirst().enumerated() { eng.move(PenSample(p: p), final: i == pts.count - 2); if i % 4 == 0 { st.flush() } }
        finish(st)
    }

    private func stamp(_ dab: BrushDynamicsEngine.DabInstance) {
        guard let st = stroke else { return }
        let s = settings
        if kind == .patternStamp {
            guard let src = patternSource,
                  let m = BrushTips.mask(diameter: dab.diameter, hardness: s.hardness, roundness: dab.roundness, angle: dab.angle.rounded(), tipID: s.tipID) else { return }
            if ToolsSettings.shared.patternImpressionist {
                // impressionist: paint dabs of the pattern's local average colour
                let c = st.toBuffer(dab.center)
                let px = src.pixel(Int(c.x), Int(c.y))
                let col = RGBA(r: Double(px.0) / 255, g: Double(px.1) / 255, b: Double(px.2) / 255, a: 1)
                if let img = BrushTips.colored(m, color: col) { st.dab(img, at: dab.center, alpha: dab.alpha) }
            } else {
                st.maskedDab(mask: m, at: dab.center, source: src, sourceOrigin: st.origin, offset: .zero, alpha: dab.alpha)
            }
        } else {
            artStrokes(at: dab.center, diameter: dab.diameter, alpha: dab.alpha)
        }
    }

    // MARK: Pattern

    /// A buffer filled with the pattern tiled so that pattern (0,0) lands at `phase` (buffer coordinates).
    static func tiled(_ pat: PixelBuffer, width: Int, height: Int, phase: CGPoint) -> PixelBuffer {
        let out = PixelBuffer(width: width, height: height)
        let pw = pat.width, ph = pat.height
        let img = pat.makeCGImage()
        let ox = Int(floor(phase.x)) % pw, oy = Int(floor(phase.y)) % ph
        var y = oy > 0 ? oy - ph : oy
        while y < height {
            var x = ox > 0 ? ox - pw : ox
            while x < width {
                out.drawImage(img, in: CGRect(x: x, y: y, width: pw, height: ph), interpolation: .none)
                x += pw
            }
            y += ph
        }
        out.markDirty()
        return out
    }

    // MARK: Art history

    static func historyBuffer(_ d: Document, _ id: UUID) -> (PixelBuffer, IPoint)? {
        let idx = AppModel.shared.historyBrushSource ?? 0
        let h = d.history.indices.contains(idx) ? d.history[idx] : d.history[0]
        if let l = h.state.layer(id), let r = l.raster { return (r.buffer, r.origin) }
        return nil
    }

    private func sourceColor(_ p: CGPoint) -> RGBA? {
        guard let (b, o) = historySource else { return nil }
        let x = Int(floor(p.x)) - o.x, y = Int(floor(p.y)) - o.y
        guard x >= 0, y >= 0, x < b.width, y < b.height else { return nil }
        let px = b.pixel(x, y)
        guard px.3 > 8 else { return nil }
        return RGBA(r: Double(px.0) / 255, g: Double(px.1) / 255, b: Double(px.2) / 255, a: 1)
    }

    private func sourceLum(_ p: CGPoint) -> Double {
        guard let c = sourceColor(p) else { return 0 }
        return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
    }

    /// Stylized strokes around `c`: each starts at a random point within the Area, takes the source colour there
    /// and follows the image's edges (perpendicular to the luminance gradient); curl styles bend continuously.
    private func artStrokes(at c: CGPoint, diameter: Double, alpha: Double) {
        guard let st = stroke else { return }
        let ts = ToolsSettings.shared
        let style = ts.artStyle
        let area = max(diameter, ts.artArea)
        let count = max(1, Int((area / max(2, diameter) * 0.6).rounded()))
        let base = max(1.5, diameter)
        let (lenMul, loose, curl): (Double, Double, Double) = {
            switch style {
            case .tightShort: return (2, 0.05, 0)
            case .tightMedium: return (4, 0.05, 0)
            case .tightLong: return (8, 0.05, 0)
            case .looseMedium: return (4, 0.5, 0)
            case .looseLong: return (8, 0.5, 0)
            case .dab: return (0, 0, 0)
            case .tightCurl: return (4, 0.05, 0.35)
            case .tightCurlLong: return (8, 0.05, 0.35)
            case .looseCurl: return (4, 0.5, 0.35)
            case .looseCurlLong: return (8, 0.5, 0.35)
            }
        }()
        let ctx = st.strokeBuf.context
        for _ in 0..<count {
            let a = rng.next() * 2 * .pi, r = sqrt(rng.next()) * area / 2
            var p = CGPoint(x: c.x + CGFloat(cos(a) * r), y: c.y + CGFloat(sin(a) * r))
            guard let col = sourceColor(p) else { continue }
            if ts.artTolerance > 0, let dst = currentColor(p) {
                // Tolerance: only paint where the current image differs enough from the source
                let diff = abs(dst.r - col.r) + abs(dst.g - col.g) + abs(dst.b - col.b)
                if diff * 100 / 3 < ts.artTolerance { continue }
            }
            let w = base * (0.7 + rng.next() * 0.6)
            ctx.setFillColor(col.withAlpha(min(1, alpha)).cgColor)
            ctx.setStrokeColor(col.withAlpha(min(1, alpha)).cgColor)
            if lenMul == 0 {
                let q = st.toBuffer(p)
                ctx.fillEllipse(in: CGRect(x: q.x - w / 2, y: q.y - w / 2, width: w, height: w))
                st.addDirty(IRect(enclosing: CGRect(x: q.x - w, y: q.y - w, width: 2 * w, height: 2 * w)))
                continue
            }
            // direction along edges
            let g = CGPoint(x: sourceLum(p + CGPoint(x: 1, y: 0)) - sourceLum(p - CGPoint(x: 1, y: 0)),
                            y: sourceLum(p + CGPoint(x: 0, y: 1)) - sourceLum(p - CGPoint(x: 0, y: 1)))
            var dir: Double = g.length > 0.01 ? atan2(Double(g.x), -Double(g.y)) : rng.next() * 2 * .pi
            let length = base * lenMul * (0.6 + rng.next() * 0.8)
            let steps = max(2, Int(length / max(1, w * 0.5)))
            let stepLen = length / Double(steps)
            let path = CGMutablePath()
            var q = st.toBuffer(p)
            path.move(to: q)
            var bounds = CGRect(origin: q, size: .zero)
            for _ in 0..<steps {
                dir += curl + (rng.next() * 2 - 1) * loose
                p = p + CGPoint(x: cos(dir) * stepLen, y: sin(dir) * stepLen)
                q = st.toBuffer(p)
                path.addLine(to: q)
                bounds = bounds.union(CGRect(origin: q, size: .zero))
            }
            ctx.saveGState()
            ctx.setLineWidth(w)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()
            st.addDirty(IRect(enclosing: bounds.insetBy(dx: -w - 1, dy: -w - 1)))
        }
    }

    private func currentColor(_ p: CGPoint) -> RGBA? {
        guard let st = stroke else { return nil }
        let q = st.toBuffer(p)
        let px = st.base.pixel(Int(q.x), Int(q.y))
        return RGBA(r: Double(px.0) / 255, g: Double(px.1) / 255, b: Double(px.2) / 255, a: 1)
    }

    override func drawOverlay(_ ctx: CGContext) {
        drawBrushCursor(ctx, size: kind == .artHistoryBrush ? max(settings.size, ToolsSettings.shared.artArea) : settings.size, hardness: settings.hardness)
    }

    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}

// MARK: - Background Eraser

/// Samples the colour under the brush hotspot and erases similar colours inside the brush (tolerance), with
/// Continuous / Once / Background Swatch sampling, Contiguous / Discontiguous / Find Edges limits and
/// Protect Foreground Color.
final class BackgroundEraserTool: Tool {
    private var working: PixelBuffer?
    private var original: PixelBuffer?
    private var origin = IPoint.zero
    private var placer = DabPlacer(spacing: 2, smoothing: 0)
    private var sample: (Double, Double, Double)?
    private var selection: PixelBuffer?
    private weak var d: Document?

    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let (doc, id, target) = requirePixelTarget(), target == .content else {
            if doc?.editTarget == .mask { status("The Background Eraser works on layer pixels, not masks.") }
            return
        }
        begin(doc, layerID: id)
        dabs(placer.begin(e.doc, pressure: e.pressure))
    }

    func begin(_ doc: Document, layerID id: UUID) {
        guard let (w, o) = doc.beginPixelEdit(layerID: id, target: .content) else { return }
        d = doc
        working = w
        original = w.copy()
        origin = o
        selection = doc.state.selection
        sample = nil
        let s = ToolsSettings.shared.bgEraserBrush
        placer = DabPlacer(spacing: max(1, s.size * max(0.05, s.spacing)), smoothing: s.smoothing)
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard working != nil else { return }
        dabs(placer.move(e.doc, pressure: e.pressure))
    }

    override func mouseUp(_ e: ToolEvent) {
        guard working != nil else { return }
        dabs(placer.move(e.doc, pressure: e.pressure, final: true))
        end()
    }

    func end() {
        d?.commit("Background Eraser")
        working = nil; original = nil; d = nil
    }

    /// Processes placed dabs (and their symmetry mirrors).
    func dabs(_ list: [(CGPoint, Double)]) {
        guard let w = working, let doc = d else { return }
        let sym = ToolsSettings.shared.symmetry
        for (p, pr) in list {
            erase(at: p, pressure: pr)
            if sym.enabled && SymmetryControls.supports(app.tool) {
                for m in sym.mirrors(of: p, width: doc.state.width, height: doc.state.height) { erase(at: m, pressure: pr, mirrored: true) }
            }
        }
        w.markDirty()
        doc.setNeedsRender()
    }

    private func erase(at p: CGPoint, pressure: Double, mirrored: Bool = false) {
        guard let w = working, let orig = original else { return }
        let ts = ToolsSettings.shared
        let s = ts.bgEraserBrush
        var size = s.size
        if s.pressureSize { size *= max(0.05, pressure) }
        let radius = size / 2
        let cx = Double(p.x) - Double(origin.x), cy = Double(p.y) - Double(origin.y)
        let x0 = max(0, Int(floor(cx - radius))), x1 = min(w.width - 1, Int(ceil(cx + radius)))
        let y0 = max(0, Int(floor(cy - radius))), y1 = min(w.height - 1, Int(ceil(cy + radius)))
        guard x1 >= x0, y1 >= y0 else { return }
        let data = w.data.assumingMemoryBound(to: UInt8.self)
        let bpr = w.bytesPerRow
        func color(_ x: Int, _ y: Int) -> (Double, Double, Double, Double) {
            let i = y * bpr + x * 4
            let a = Double(data[i + 3])
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(data[i]) * 255 / a, Double(data[i + 1]) * 255 / a, Double(data[i + 2]) * 255 / a, a)
        }
        // sampling
        let hx = clamp(Int(cx), 0, w.width - 1), hy = clamp(Int(cy), 0, w.height - 1)
        switch ts.bgSampling {
        case .continuous:
            if !mirrored || sample == nil {
                let op = orig.pixel(hx, hy)
                if op.3 > 0 { sample = (Double(op.0), Double(op.1), Double(op.2)) }
            }
        case .once:
            if sample == nil { let op = orig.pixel(hx, hy); if op.3 > 0 { sample = (Double(op.0), Double(op.1), Double(op.2)) } }
        case .backgroundSwatch:
            let b = app.background
            sample = (b.r * 255, b.g * 255, b.b * 255)
        }
        var target = sample
        if ts.bgSampling == .continuous {   // each dab (incl. mirrors) samples under its own hotspot
            let op = orig.pixel(hx, hy)
            target = op.3 > 0 ? (Double(op.0), Double(op.1), Double(op.2)) : nil
        }
        guard let tc = target else { return }
        let tol = ts.bgTolerance / 100 * 255 * 1.2 + 0.5
        let fg = app.foreground
        let fgc = (fg.r * 255, fg.g * 255, fg.b * 255)
        func dist(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
            max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
        }
        let rw = x1 - x0 + 1, rh = y1 - y0 + 1
        // candidate mask (within tolerance)
        var match = [Bool](repeating: false, count: rw * rh)
        for y in y0...y1 {
            for x in x0...x1 {
                let c = color(x, y)
                guard c.3 > 0 else { continue }
                let rgb = (c.0, c.1, c.2)
                if dist(rgb, tc) > tol { continue }
                if ts.bgProtectForeground && dist(rgb, fgc) <= 12 { continue }
                match[(y - y0) * rw + (x - x0)] = true
            }
        }
        var allowed = match
        if ts.bgLimits != .discontiguous {
            // flood fill from the hotspot through matching pixels
            allowed = [Bool](repeating: false, count: rw * rh)
            let sx = hx - x0, sy = hy - y0
            var seeds: [(Int, Int)] = []
            if sx >= 0, sy >= 0, sx < rw, sy < rh, match[sy * rw + sx] { seeds.append((sx, sy)) }
            else {
                // hotspot pixel itself not matching (e.g. already erased): seed from matching pixels near the centre
                for yy in max(0, sy - 2)...min(rh - 1, sy + 2) { for xx in max(0, sx - 2)...min(rw - 1, sx + 2) where match[yy * rw + xx] { seeds.append((xx, yy)) } }
            }
            var stack = seeds
            for (x, y) in seeds { allowed[y * rw + x] = true }
            while let (x, y) = stack.popLast() {
                for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)] where nx >= 0 && ny >= 0 && nx < rw && ny < rh {
                    let i = ny * rw + nx
                    if match[i] && !allowed[i] { allowed[i] = true; stack.append((nx, ny)) }
                }
            }
        }
        let hard = s.hardness
        for y in y0...y1 {
            for x in x0...x1 where allowed[(y - y0) * rw + (x - x0)] {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                let dd = sqrt(dx * dx + dy * dy) / max(0.5, radius)
                if dd > 1 { continue }
                var wgt = dd <= hard ? 1.0 : 1 - (dd - hard) / max(0.001, 1 - hard)
                if let sel = selection {
                    let gx = x + origin.x, gy = y + origin.y
                    if gx < 0 || gy < 0 || gx >= sel.width || gy >= sel.height { continue }
                    wgt *= Double(sel.data.assumingMemoryBound(to: UInt8.self)[gy * sel.bytesPerRow + gx]) / 255
                }
                if ts.bgLimits == .findEdges {
                    // keep sharp edges: pixels close to the tolerance limit are only partly erased
                    let c = color(x, y)
                    let k = 1 - dist((c.0, c.1, c.2), tc) / max(1, tol)
                    wgt *= clamp(k * 2, 0, 1)
                }
                wgt *= s.opacity
                guard wgt > 0.001 else { continue }
                let i = y * bpr + x * 4
                let f = 1 - wgt
                for k in 0..<4 { data[i + k] = UInt8(clamp(Double(data[i + k]) * f, 0, 255)) }
            }
        }
    }

    override func drawOverlay(_ ctx: CGContext) {
        let s = ToolsSettings.shared.bgEraserBrush
        drawBrushCursor(ctx, size: s.size, hardness: s.hardness)
        if let m = canvas.lastMouseView {   // hotspot cross
            let p = CGMutablePath()
            p.move(to: CGPoint(x: m.x - 3, y: m.y)); p.addLine(to: CGPoint(x: m.x + 3, y: m.y))
            p.move(to: CGPoint(x: m.x, y: m.y - 3)); p.addLine(to: CGPoint(x: m.x, y: m.y + 3))
            OverlayStyle.contrastStroke(ctx, p)
        }
    }

    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}
