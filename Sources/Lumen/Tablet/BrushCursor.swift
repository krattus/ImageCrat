import AppKit
import ImageCratCore

/// Painting cursor (Preferences ▸ Cursors): the outline of the actual brush tip — its shape, angle and roundness —
/// at the brush size, scaled by the zoom and turned with Rotate View / Flip Canvas. Normal Brush Tip outlines where
/// the tip is 50% opaque, Full Size the whole tip; Precise and Standard show a crosshair only. Caps Lock switches to
/// the precise crosshair, like Photoshop.
enum BrushCursor {
    /// Tip outlines in tip pixels (centred on 0,0, y down), keyed by tip / angle / roundness / hardness / flips.
    private static var cache: [String: (path: CGPath, ref: Double)] = [:]
    private static var cacheOrder: [String] = []
    /// Outlines are traced from a tip rendered this large and scaled (cheap at any brush size).
    static let referenceDiameter = 96.0

    /// Whether the cursor is the precise crosshair (preference or Caps Lock).
    static var isPrecise: Bool {
        AppModel.shared.prefs.brushCursor == .precise || TabletInput.shared.capsLock()
    }

    static func draw(_ ctx: CGContext, canvas: CanvasView, size: Double, hardness: Double, settings: BrushSettings?) {
        guard let m = canvas.lastMouseView, !BrushHUD.shared.isActive else { return }
        let prefs = AppModel.shared.prefs
        var style = prefs.brushCursor
        if TabletInput.shared.capsLock() { style = .precise }
        let showOutline = style == .normal || style == .fullSize
        let d = CGFloat(size) * canvas.zoom
        if showOutline && d >= 3 {
            var s = settings ?? BrushSettings()
            if settings == nil { s.hardness = hardness }
            let path = outline(s, size: size, hardness: hardness, full: style == .fullSize, canvas: canvas, at: m)
            ctx.saveGState()
            ctx.setLineWidth(2.25)
            ctx.setStrokeColor(NSColor(white: 0, alpha: 0.6).cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.setLineWidth(1)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.92).cgColor)
            ctx.addPath(path); ctx.strokePath()
            ctx.restoreGState()
        }
        if !showOutline || d < 10 || prefs.showCrosshairInBrushTip {
            let k: CGFloat = showOutline && d >= 10 ? 3 : 6
            crosshair(ctx, at: m, arm: k)
        }
    }

    static func crosshair(_ ctx: CGContext, at m: CGPoint, arm k: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.setLineWidth(2.5)
        ctx.move(to: CGPoint(x: m.x - k, y: m.y)); ctx.addLine(to: CGPoint(x: m.x + k, y: m.y))
        ctx.move(to: CGPoint(x: m.x, y: m.y - k)); ctx.addLine(to: CGPoint(x: m.x, y: m.y + k))
        ctx.strokePath()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.95).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: m.x - k, y: m.y)); ctx.addLine(to: CGPoint(x: m.x + k, y: m.y))
        ctx.move(to: CGPoint(x: m.x, y: m.y - k)); ctx.addLine(to: CGPoint(x: m.x, y: m.y + k))
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The tip outline in view coordinates around `c`: brush size × zoom, with the view's rotation and flip.
    static func outline(_ s: BrushSettings, size: Double, hardness: Double, full: Bool, canvas: CanvasView, at c: CGPoint) -> CGPath {
        let local = tipPath(s, hardness: hardness, full: full)
        let k = CGFloat(size / local.ref)
        let t = canvas.docToViewTransform
        // doc → view linear part (zoom, rotation, flip), scaled from reference tip pixels to the brush size
        let lin = CGAffineTransform(a: t.a * k, b: t.b * k, c: t.c * k, d: t.d * k, tx: c.x, ty: c.y)
        var tr = lin
        return local.path.copy(using: &tr) ?? local.path
    }

    /// Outline of the tip at the reference size (tip pixel coordinates, centred, y down) and that reference size.
    static func tipPath(_ s: BrushSettings, hardness: Double, full: Bool) -> (path: CGPath, ref: Double) {
        let ref = referenceDiameter
        let roundness = max(0.02, min(1, s.roundness))
        let flipX = s.dynamics.flipX, flipY = s.dynamics.flipY
        if s.tipID == "round" {
            // analytic ellipse: radius of the 50% contour for Normal (soft tips look smaller), whole tip for Full Size
            let scale = full ? 1 : 0.5 + 0.5 * max(0, min(1, hardness))
            let rx = CGFloat(ref / 2 * scale), ry = rx * CGFloat(roundness)
            var t = CGAffineTransform(rotationAngle: CGFloat(-s.angle * .pi / 180))   // angle is counter-clockwise on screen
            return (CGPath(ellipseIn: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: &t), ref)
        }
        let key = "\(s.tipID)|\(Int(s.angle.rounded()))|\(Int(roundness * 100))|\(full ? 100 : Int(hardness * 20))|\(flipX)|\(flipY)"
        if let c = cache[key] { return c }
        // trace the real tip: stamp it like the brush engine does, then outline the covered pixels
        let side = Int(ref * 1.5) + 4
        let buf = PixelBuffer(width: side, height: side, format: .gray)
        let o = Double(side) / 2
        let dab = DabRaster.Dab(cx: o, cy: o, diameter: ref, roundness: roundness, angle: s.angle, flipX: flipX, flipY: flipY,
                                hardness: full ? 1 : hardness)
        DabRaster.stamp(dab, tip: TipSource.get(s.tipID), into: buf, alpha: 1)
        // binarize (any coverage for Full Size, half for Normal), then close the gaps between bristles / speckles so the
        // outline shows the tip's envelope instead of every grain
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        let thr: UInt8 = full ? 12 : 100
        for i in 0..<(buf.bytesPerRow * side) { p[i] = p[i] > thr ? 255 : 0 }
        buf.markDirty()
        let gap = ref / 14
        let closed = SelectionOps.contract(SelectionOps.expand(buf, by: gap), by: gap)
        var t = CGAffineTransform(translationX: CGFloat(-o), y: CGFloat(-o))
        let raw = SelectionOps.outline(closed)
        let path = raw.isEmpty ? CGPath(ellipseIn: CGRect(x: -ref / 2, y: -ref / 2, width: ref, height: ref), transform: nil) : (raw.copy(using: &t) ?? raw)
        cache[key] = (path, ref)
        cacheOrder.append(key)
        if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
        return (path, ref)
    }
}
