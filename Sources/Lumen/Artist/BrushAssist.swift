import AppKit
import CoreGraphics
import ImageCratCore

/// Brush-engine hooks of the Artist module:
///  · input filter (`BrushDynamicsEngine.inputHook`): stroke stabilisers (lazy rope / weighted average, catch-up on
///    release) followed by assisted drawing (rulers and drawing guides);
///  · dab positions (`symmetryPoints`, chained after the symmetry hook): wrap-around copies for seamless tile painting;
///  · dab colour (`dabColorHook`): colour jitter from a swatch group.
enum BrushAssist {
    struct StrokeState {
        var snapper: AssistSnapper?
        var tip: CGPoint
        var window: [CGPoint] = []
        var color: RGBA?
    }

    private static var states: [ObjectIdentifier: StrokeState] = [:]
    private static var installed = false
    /// SplitMix64: well mixed from the first value on (palette picks must not fall into short cycles).
    struct Mixer {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / 9007199254740992.0
        }
    }
    private static var rng = Mixer(seed: 0xA571)
    private static var lastStrokeColor: RGBA?

    /// Rope end and pen position of the running stroke (document space) for the leash overlay.
    static var leash: (tip: CGPoint, pen: CGPoint, length: CGFloat)?

    static func install() {
        guard !installed else { return }
        installed = true
        BrushDynamicsEngine.inputHook = { eng, s, phase in process(eng, s, phase) }
        let previous = BrushDynamicsEngine.symmetryPoints
        BrushDynamicsEngine.symmetryPoints = { p in
            if ArtistContext.padActive { return [] }
            let mirrors = previous?(p) ?? []
            guard ArtistSettings.shared.wrapPainting, let d = ArtistContext.doc else { return mirrors }
            let s = AppModel.shared.activeBrushSettings
            let radius = CGFloat(s.size * (0.5 + max(0, s.scatter)) + 2)
            var out = mirrors
            for q in [p] + mirrors { out += wrapCopies(q, width: d.state.width, height: d.state.height, radius: radius) }
            return out
        }
        BrushDynamicsEngine.dabColorHook = { eng, fg in paletteColor(eng, fg) }
    }

    /// Seeds the palette-jitter generator (tests).
    static func reseed(_ seed: UInt64) { rng = Mixer(seed: seed); lastStrokeColor = nil }

    // MARK: Wrap-around

    /// Copies of a dab at `p` (radius `radius`) that also touch the canvas when the canvas repeats as a tile.
    /// The dab itself is not included.
    static func wrapCopies(_ p: CGPoint, width: Int, height: Int, radius: CGFloat) -> [CGPoint] {
        let W = CGFloat(width), H = CGFloat(height)
        guard W > 0, H > 0 else { return [] }
        let bx = p.x - (p.x / W).rounded(.down) * W, by = p.y - (p.y / H).rounded(.down) * H
        var out: [CGPoint] = []
        for dy in -1...1 {
            for dx in -1...1 {
                let c = CGPoint(x: bx + CGFloat(dx) * W, y: by + CGFloat(dy) * H)
                if abs(c.x - p.x) < 0.01 && abs(c.y - p.y) < 0.01 { continue }
                if c.x + radius <= 0 || c.x - radius >= W || c.y + radius <= 0 || c.y - radius >= H { continue }
                out.append(c)
            }
        }
        return out
    }

    // MARK: Input filter

    static func process(_ eng: BrushDynamicsEngine, _ s: PenSample, _ phase: BrushDynamicsEngine.InputPhase) -> [PenSample]? {
        let prefs = ArtistSettings.shared.prefs
        let key = ObjectIdentifier(eng)
        let zoom = max(0.01, ArtistContext.zoom)
        switch phase {
        case .begin:
            if states.count > 4 { states.removeAll() }
            var st = StrokeState(tip: s.p, window: [s.p])
            if prefs.assist, !ArtistContext.padActive, let d = ArtistContext.doc {
                let data = d.state.artist
                let snap = AssistSnapper(start: s.p, guide: data.guide.visible ? data.guide : DrawingGuide(), rulers: data.rulers,
                                         rulerRange: CGFloat(prefs.rulerSnapRange) / zoom, threshold: 5 / zoom)
                if snap.isActive { st.snapper = snap }
            }
            if prefs.paletteJitter == .perStroke {
                // a new colour each stroke: never the one the previous stroke used (when the palette allows)
                var c = randomPaletteColor()
                var tries = 0
                while c != nil, c == lastStrokeColor, Set(palette.map(\.hex)).count > 1, tries < 8 { c = randomPaletteColor(); tries += 1 }
                st.color = c
                lastStrokeColor = c
            }
            states[key] = st
            leash = prefs.stabilizer == .rope ? (s.p, s.p, CGFloat(prefs.ropeLength) / zoom) : nil
            return nil
        case .move, .end:
            guard var st = states[key] else { return nil }
            // The state outlives `.end`: the engine still paints the last segment (and asks for the stroke colour)
            // after this returns. It is replaced by the next `.begin`.
            defer {
                states[key] = st
                if phase == .end { leash = nil }
            }
            if prefs.stabilizer == .off && st.snapper == nil { return nil }
            var targets: [CGPoint] = []
            switch prefs.stabilizer {
            case .off:
                targets = [s.p]
            case .rope:
                let L = CGFloat(prefs.ropeLength) / zoom
                let v = s.p - st.tip
                if v.length > L {
                    st.tip = s.p - v.normalized * L
                    targets = [st.tip]
                }
                if phase == .end && prefs.catchUp && st.tip != s.p {
                    st.tip = s.p
                    targets.append(s.p)
                }
                leash = (st.tip, s.p, L)
            case .average:
                let n = max(2, prefs.averageWindow)
                st.window.append(s.p)
                if st.window.count > n { st.window.removeFirst(st.window.count - n) }
                func mean(_ a: [CGPoint]) -> CGPoint { a.reduce(.zero, +) / CGFloat(max(1, a.count)) }
                targets = [mean(st.window)]
                if phase == .end && prefs.catchUp {
                    var w = st.window
                    while w.count > 1 { w.removeFirst(); targets.append(mean(w)) }
                }
                st.tip = targets.last ?? st.tip
            }
            var out: [PenSample] = []
            for t in targets {
                var o = s
                o.p = st.snapper?.snap(t) ?? t
                out.append(o)
            }
            return out
        }
    }

    // MARK: Palette jitter

    static var palette: [RGBA] {
        let prefs = ArtistSettings.shared.prefs
        if let g = SwatchGroupStore.shared.group(prefs.paletteGroup), !g.colors.isEmpty { return g.colors }
        return AppModel.shared.swatches
    }

    private static func randomPaletteColor() -> RGBA? {
        let p = palette
        guard !p.isEmpty else { return nil }
        return p[min(p.count - 1, Int(rng.next() * Double(p.count)))]
    }

    private static func paletteColor(_ eng: BrushDynamicsEngine, _ fg: RGBA) -> RGBA? {
        switch ArtistSettings.shared.prefs.paletteJitter {
        case .off: return nil
        case .perStroke: return states[ObjectIdentifier(eng)]?.color
        case .perDab: return randomPaletteColor()
        }
    }

    // MARK: Headless helper

    /// Runs points through the input filter exactly like a stroke would (tests, previews).
    static func filter(_ pts: [CGPoint], engine: BrushDynamicsEngine) -> [CGPoint] {
        guard let first = pts.first else { return [] }
        var out: [CGPoint] = [first]
        _ = process(engine, PenSample(p: first), .begin)
        for (i, p) in pts.dropFirst().enumerated() {
            let phase: BrushDynamicsEngine.InputPhase = i == pts.count - 2 ? .end : .move
            if let r = process(engine, PenSample(p: p), phase) { out += r.map(\.p) } else { out.append(p) }
        }
        return out
    }
}

// MARK: - Canvas overlays

enum ArtistOverlays {
    /// Called by the canvas overlay for every tool.
    static func draw(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let data = doc.state.artist
        if data.guide.kind != .none || !data.rulers.isEmpty {
            GuideRenderer.draw(ctx, data: data, canvas: doc.state.canvasCGRect, toView: { canvas.docToView($0) }, editing: ArtistSettings.shared.editGuides)
        }
        if let l = BrushAssist.leash, NSEvent.pressedMouseButtons & 1 == 1 { drawLeash(ctx, tip: canvas.docToView(l.tip), pen: canvas.docToView(l.pen), length: l.length * canvas.zoom) }
        if AppModel.shared.tool == .eyedropper, ArtistSettings.shared.prefs.eyedropperRing, let m = canvas.lastMouseView {
            let p = canvas.viewToDoc(m)
            let n = max(1, AppModel.shared.eyedropperSample)
            if let c = ToolGeometry.compositeColor(doc, at: p, size: n), c.a > 0 {
                EyedropperRing.draw(ctx, at: m, sampled: c.withAlpha(1), current: AppModel.shared.foreground, sampleSize: n, zoom: canvas.zoom)
            }
        }
    }

    /// The pulled string of the lazy-rope stabiliser: the brush sits at `tip`, the pen drags it on a leash.
    static func drawLeash(_ ctx: CGContext, tip: CGPoint, pen: CGPoint, length: CGFloat) {
        ctx.saveGState()
        let ring = CGPath(ellipseIn: CGRect(x: tip.x - length, y: tip.y - length, width: 2 * length, height: 2 * length), transform: nil)
        ctx.addPath(ring)
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        let line = CGMutablePath()
        line.move(to: tip); line.addLine(to: pen)
        OverlayStyle.contrastStroke(ctx, line, width: 1.5)
        OverlayStyle.circleHandle(ctx, at: tip, size: 7, filled: true)
        OverlayStyle.circleHandle(ctx, at: pen, size: 5)
        ctx.restoreGState()
    }
}

/// Eyedropper preview ring: the averaged colour of the N×N sample area (top half) against the current foreground
/// (bottom half), with the sample area outlined.
enum EyedropperRing {
    static func draw(_ ctx: CGContext, at m: CGPoint, sampled: RGBA, current: RGBA, sampleSize: Int, zoom: CGFloat) {
        let outer: CGFloat = 44, inner: CGFloat = 28
        ctx.saveGState()
        func half(_ top: Bool, _ c: RGBA) {
            let p = CGMutablePath()
            // flipped view: angles run clockwise on screen; the top half spans π…2π
            p.addArc(center: m, radius: outer, startAngle: top ? .pi : 0, endAngle: top ? 2 * .pi : .pi, clockwise: false)
            p.addArc(center: m, radius: inner, startAngle: top ? 2 * .pi : .pi, endAngle: top ? .pi : 0, clockwise: true)
            p.closeSubpath()
            ctx.addPath(p)
            ctx.setFillColor(c.cgColor)
            ctx.fillPath()
        }
        half(true, sampled)
        half(false, current)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.75).cgColor)
        ctx.strokeEllipse(in: CGRect(x: m.x - outer, y: m.y - outer, width: outer * 2, height: outer * 2))
        ctx.strokeEllipse(in: CGRect(x: m.x - inner, y: m.y - inner, width: inner * 2, height: inner * 2))
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: CGRect(x: m.x - outer - 1.5, y: m.y - outer - 1.5, width: outer * 2 + 3, height: outer * 2 + 3))
        ctx.move(to: CGPoint(x: m.x - outer, y: m.y)); ctx.addLine(to: CGPoint(x: m.x - inner, y: m.y))
        ctx.move(to: CGPoint(x: m.x + inner, y: m.y)); ctx.addLine(to: CGPoint(x: m.x + outer, y: m.y))
        ctx.strokePath()
        // sample area
        let side = max(3, CGFloat(sampleSize) * zoom)
        if side < inner * 1.3 {
            let r = CGRect(x: m.x - side / 2, y: m.y - side / 2, width: side, height: side)
            OverlayStyle.contrastStroke(ctx, CGPath(rect: r, transform: nil))
        }
        ctx.restoreGState()
        OverlayStyle.label("\(sampleSize)×\(sampleSize) px  #\(sampled.hex)", at: CGPoint(x: m.x + outer - 8, y: m.y + outer - 8))
    }
}
