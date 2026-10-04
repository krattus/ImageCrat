import AppKit
import ImageCratCore

/// Shared helpers for selection tools.
class SelectionToolBase: Tool {
    var combine: SelectionCombine = .new
    var movingSelection: (start: CGPoint, original: PixelBuffer)?
    private var selectionMoved = false

    override var cursor: NSCursor { .crosshair }

    func combineMode(_ e: ToolEvent) -> SelectionCombine {
        if e.shift && e.option { return .intersect }
        if e.shift { return .add }
        if e.option { return .subtract }
        return app.selection.combine
    }

    func insideSelection(_ p: CGPoint) -> Bool {
        guard let s = doc?.state.selection else { return false }
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        guard x >= 0, y >= 0, x < s.width, y < s.height else { return false }
        return s.alpha(x, y) >= 128
    }

    func beginMoveSelection(_ e: ToolEvent) -> Bool {
        guard combine == .new, !e.command, let s = doc?.state.selection, insideSelection(e.doc) else { return false }
        movingSelection = (e.doc, s)
        selectionMoved = false
        return true
    }

    func updateMoveSelection(_ e: ToolEvent) {
        guard let (start, orig) = movingSelection, let d = doc else { return }
        let dx = Int((e.doc.x - start.x).rounded()), dy = Int((e.doc.y - start.y).rounded())
        if dx != 0 || dy != 0 { selectionMoved = true }
        let m = PixelBuffer(width: orig.width, height: orig.height, format: .gray)
        m.copyPixels(from: orig, at: IPoint(x: dx, y: dy))
        m.markDirty()
        d.state.selection = m
        d.setNeedsOverlay()
    }

    func endMoveSelection() {
        guard let (_, orig) = movingSelection else { return }
        movingSelection = nil
        if selectionMoved {
            doc?.commit("Move Selection")
        } else {
            // a plain click inside the selection deselects (no empty "Move Selection" step)
            doc?.state.selection = orig
            doc?.setSelection(nil, commitName: "Deselect")
        }
    }

    /// Applies a new shape mask with current combine mode and feather, and commits.
    func apply(_ mask: PixelBuffer, name: String) {
        guard let d = doc else { return }
        var m = mask
        if app.selection.feather > 0 { m = SelectionOps.feather(m, radius: app.selection.feather, direction: app.featherDirection) }
        let result = SelectionOps.combine(d.state.selection, m, mode: combine)
        // nothing selected before and nothing now (e.g. a marquee outside the canvas): no history step
        if d.state.selection == nil && result.opaqueBounds() == nil { return }
        d.setSelection(result, commitName: name)
    }
}

// MARK: - Marquee

final class MarqueeTool: SelectionToolBase {
    private var start: CGPoint?
    private var current: CGPoint?
    private var fromCenter = false
    private var square = false

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        combine = combineMode(e)
        if beginMoveSelection(e) { return }
        if kind == .marqueeRow || kind == .marqueeColumn {
            let r = kind == .marqueeRow ? CGRect(x: 0, y: floor(e.doc.y), width: CGFloat(d.state.width), height: 1)
                                        : CGRect(x: floor(e.doc.x), y: 0, width: 1, height: CGFloat(d.state.height))
            apply(SelectionOps.rectMask(r, width: d.state.width, height: d.state.height), name: kind == .marqueeRow ? "Single Row Marquee" : "Single Column Marquee")
            return
        }
        start = canvas.snap(e.doc)
        current = start
    }

    override func mouseDragged(_ e: ToolEvent) {
        if movingSelection != nil { updateMoveSelection(e); return }
        guard start != nil else { return }
        current = canvas.snap(e.doc)
        fromCenter = e.option && combine != .subtract && combine != .intersect
        square = e.shift && combine != .add && combine != .intersect
        if let r = rect() {
            let label = "W: \(Int(r.width))  H: \(Int(r.height))"
            status(label)
        }
    }

    private func rect() -> CGRect? {
        guard var s = start, var c = current else { return nil }
        if app.selection.fixedRatio || square {
            let ratio = square ? 1 : clamp(max(0.001, app.selection.ratioW) / max(0.001, app.selection.ratioH), 0.001, 1000)   // W = 0 made the height infinite
            let w = abs(c.x - s.x), h = abs(c.y - s.y)
            var nw = w, nh = h
            if w / max(0.001, h) > ratio { nh = w / ratio } else { nw = h * ratio }
            c = CGPoint(x: s.x + (c.x >= s.x ? nw : -nw), y: s.y + (c.y >= s.y ? nh : -nh))
        }
        if fromCenter {
            let d = c - s
            s = s - d
        }
        return CGRect(p1: s, p2: c).integral
    }

    override func mouseUp(_ e: ToolEvent) {
        if movingSelection != nil { endMoveSelection(); return }
        defer { start = nil; current = nil }
        guard let d = doc, let r = rect() else { return }
        if r.width < 1 || r.height < 1 {
            if combine == .new && d.state.selection != nil {
                d.setSelection(nil, commitName: "Deselect")
            }
            return
        }
        let m: PixelBuffer
        if kind == .marqueeEllipse {
            m = SelectionOps.mask(fromPath: CGPath(ellipseIn: r, transform: nil), width: d.state.width, height: d.state.height, antialias: app.selection.antialias)
        } else {
            m = SelectionOps.rectMask(r, width: d.state.width, height: d.state.height)
        }
        apply(m, name: kind == .marqueeEllipse ? "Elliptical Marquee" : "Rectangular Marquee")
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let r = rect(), r.width > 0 || r.height > 0 else { return }
        let vr = canvas.docToView(r)
        let p = kind == .marqueeEllipse ? CGPath(ellipseIn: vr, transform: nil) : CGPath(rect: vr, transform: nil)
        (canvas.overlay).drawAnts(ctx, p, phase: canvas.antsPhase)
        if let m = canvas.lastMouseView { OverlayStyle.label("W: \(Int(r.width)) px\nH: \(Int(r.height)) px", at: m) }
    }
}

// MARK: - Lasso

final class LassoTool: SelectionToolBase {
    private var points: [CGPoint] = []

    override func mouseDown(_ e: ToolEvent) {
        combine = combineMode(e)
        if beginMoveSelection(e) { return }
        points = [e.doc]
    }

    override func mouseDragged(_ e: ToolEvent) {
        if movingSelection != nil { updateMoveSelection(e); return }
        guard !points.isEmpty else { return }
        if let l = points.last, l.distance(to: e.doc) * canvas.zoom < 1.5 { return }
        points.append(e.doc)
    }

    override func mouseUp(_ e: ToolEvent) {
        if movingSelection != nil { endMoveSelection(); return }
        defer { points = [] }
        guard let d = doc else { return }
        if points.count < 3 {
            if combine == .new && d.state.selection != nil { d.setSelection(nil, commitName: "Deselect") }
            return
        }
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        apply(SelectionOps.mask(fromPath: p, width: d.state.width, height: d.state.height, antialias: app.selection.antialias), name: "Lasso")
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard points.count > 1 else { return }
        let p = CGMutablePath()
        p.addLines(between: points.map { canvas.docToView($0) })
        canvas.overlay.drawAnts(ctx, p, phase: canvas.antsPhase)
    }
}

final class PolygonLassoTool: SelectionToolBase {
    private var points: [CGPoint] = []
    private var hover: CGPoint?
    /// Canvas size the outline was started on (it is dropped when another command changes the canvas).
    private var startCanvas = CGSize.zero

    override var isBusy: Bool { validate(); return !points.isEmpty }
    /// Edit ▸ Undo takes back the last point.
    override func undoPending() -> Bool {
        if !points.isEmpty { points.removeLast() }
        canvas.overlay.needsDisplay = true
        return true
    }
    override func deactivate() { super.deactivate(); points = []; hover = nil }

    private func validate() {
        guard !points.isEmpty, let d = doc, startCanvas != CGSize(width: d.state.width, height: d.state.height) else { return }
        points = []; hover = nil
    }

    /// Shift: the segment from the last point snaps to 45° steps.
    private func constrained(_ p: CGPoint, _ shift: Bool) -> CGPoint {
        guard shift, let l = points.last else { return p }
        let d = p - l
        let a = (atan2(d.y, d.x) / (.pi / 4)).rounded() * (.pi / 4)
        let len = d.length
        return l + CGPoint(x: cos(a) * len, y: sin(a) * len)
    }

    override func mouseDown(_ e: ToolEvent) {
        validate()
        if points.isEmpty {
            combine = combineMode(e)
            if beginMoveSelection(e) { return }
            if let d = doc { startCanvas = CGSize(width: d.state.width, height: d.state.height) }
        }
        let p = constrained(e.doc, e.shift)       // the clicked point is constrained like its preview
        if points.count >= 3, let f = points.first, (f.distance(to: p) * canvas.zoom < 8 || e.clickCount >= 2) {
            finish()
            return
        }
        if e.clickCount >= 2 && points.count >= 3 { finish(); return }
        points.append(p)
    }

    override func mouseDragged(_ e: ToolEvent) {
        if movingSelection != nil { updateMoveSelection(e) }
        hover = e.doc
    }

    override func mouseUp(_ e: ToolEvent) {
        if movingSelection != nil { endMoveSelection() }
    }

    override func mouseMoved(_ e: ToolEvent) {
        hover = constrained(e.doc, e.shift)
    }

    override func commit() { if points.count >= 3 { finish() } }
    override func cancel() { points = []; hover = nil }

    override func keyDown(_ e: NSEvent) -> Bool {
        if e.keyCode == 51, !points.isEmpty { points.removeLast(); return true }
        return false
    }

    private func finish() {
        guard let d = doc, points.count >= 3 else { points = []; return }
        let p = CGMutablePath()
        p.addLines(between: points)
        p.closeSubpath()
        apply(SelectionOps.mask(fromPath: p, width: d.state.width, height: d.state.height, antialias: app.selection.antialias), name: "Polygonal Lasso")
        points = []
    }

    override func drawOverlay(_ ctx: CGContext) {
        validate()
        guard !points.isEmpty else { return }
        var pts = points.map { canvas.docToView($0) }
        if let h = hover { pts.append(canvas.docToView(h)) }
        let p = CGMutablePath()
        p.addLines(between: pts)
        OverlayStyle.contrastStroke(ctx, p)
        if let f = pts.first { OverlayStyle.circleHandle(ctx, at: f, size: 8) }
    }
}

// MARK: - Magic wand

final class MagicWandTool: SelectionToolBase {
    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        combine = combineMode(e)
        guard let src = AppActions.sampleSource(allLayers: app.selection.sampleAllLayers) else { return }
        let seed = IPoint(x: Int(floor(e.doc.x)), y: Int(floor(e.doc.y)))
        guard seed.x >= 0, seed.y >= 0, seed.x < d.state.width, seed.y < d.state.height else { return }
        let m = SelectionOps.floodMask(src: src, seed: seed, tolerance: app.selection.tolerance, contiguous: app.selection.contiguous, antialias: app.selection.antialias)
        apply(m, name: "Magic Wand")
    }
}

// MARK: - Quick selection

final class QuickSelectTool: SelectionToolBase {
    private var source: PixelBuffer?
    private var accum: PixelBuffer?
    private var placer = DabPlacer(spacing: 4, smoothing: 0)

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        combine = e.option ? .subtract : (d.state.selection == nil ? .new : .add)
        source = AppActions.sampleSource(allLayers: true)
        accum = PixelBuffer(width: d.state.width, height: d.state.height, format: .gray)
        placer = DabPlacer(spacing: max(2, app.quickSelectSize / 3), smoothing: 0)
        for (p, _) in placer.begin(e.doc, pressure: 1) { grow(p) }
        preview()
    }

    override func mouseDragged(_ e: ToolEvent) {
        for (p, _) in placer.move(e.doc, pressure: 1) { grow(p) }
        preview()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let a = accum else { return }
        d.revertUncommitted()
        let smooth = SelectionOps.feather(a, radius: 1.2)
        let result = SelectionOps.combine(d.state.selection, smooth, mode: combine)
        d.setSelection(result, commitName: "Quick Selection")
        accum = nil
        source = nil
    }

    private func preview() {
        guard let d = doc, let a = accum else { return }
        let base = d.committedState.selection
        d.state.selection = SelectionOps.combine(base, a, mode: combine)
        d.setNeedsOverlay()
    }

    private func grow(_ p: CGPoint) {
        guard let src = source, let a = accum else { return }
        let r = Int(app.quickSelectSize * 2.5)
        let window = IRect(x: Int(p.x) - r, y: Int(p.y) - r, width: 2 * r, height: 2 * r).intersection(src.bounds)
        if window.isEmpty { return }
        let sub = src.cropped(to: window)
        let seed = IPoint(x: Int(p.x) - window.x, y: Int(p.y) - window.y)
        let m = SelectionOps.floodMask(src: sub, seed: seed, tolerance: 38, contiguous: true, antialias: false)
        // also include the brush footprint itself
        let brushR = app.quickSelectSize / 2
        m.context.setFillColor(gray: 1, alpha: 1)
        m.context.fillEllipse(in: CGRect(x: Double(seed.x) - brushR, y: Double(seed.y) - brushR, width: brushR * 2, height: brushR * 2))
        // union into accum
        let ad = a.data.assumingMemoryBound(to: UInt8.self)
        let md = m.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<window.height {
            for x in 0..<window.width {
                let v = md[y * m.bytesPerRow + x]
                let i = (y + window.y) * a.bytesPerRow + x + window.x
                if v > ad[i] { ad[i] = v }
            }
        }
        a.markDirty()
    }

    override func drawOverlay(_ ctx: CGContext) { drawBrushCursor(ctx, size: app.quickSelectSize) }

    override func keyDown(_ e: NSEvent) -> Bool {
        guard let ch = e.charactersIgnoringModifiers else { return false }
        if ch == "]" { app.quickSelectSize = min(500, app.quickSelectSize * 1.2); return true }
        if ch == "[" { app.quickSelectSize = max(2, app.quickSelectSize / 1.2); return true }
        return false
    }
}
