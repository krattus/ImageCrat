import AppKit
import ImageCratCore

class CropTool: Tool {
    private var rect: CGRect?
    /// Canvas size the box was made for. When another command changes the canvas underneath (Image Size, Canvas Size,
    /// Rotate, undo …) the box no longer means anything and is reset instead of cropping back to the old size.
    private var rectCanvas = CGSize.zero
    private var drag: (handle: TransformHandle?, start: CGPoint, startRect: CGRect)?
    private var creating: CGPoint?

    override var cursor: NSCursor { .crosshair }
    /// Busy only while the box differs from the canvas (an untouched box must not swallow Edit ▸ Undo).
    override var isBusy: Bool {
        validate()
        guard let r = rect, let d = doc else { return false }
        return CropTool.pixelRect(r) != d.state.canvasCGRect
    }

    private func resetRect() {
        rect = doc?.state.canvasCGRect
        rectCanvas = doc.map { CGSize(width: $0.state.width, height: $0.state.height) } ?? .zero
    }

    private func validate() {
        guard rect != nil, let d = doc, rectCanvas != CGSize(width: d.state.width, height: d.state.height) else { return }
        resetRect()
        drag = nil; creating = nil
    }

    /// The box on whole pixels (nearest edges).
    private static func pixelRect(_ r: CGRect) -> CGRect {
        CGRect(p1: CGPoint(x: r.minX.rounded(), y: r.minY.rounded()), p2: CGPoint(x: r.maxX.rounded(), y: r.maxY.rounded()))
    }

    override func activate() {
        guard doc != nil else { return }
        resetRect()
        canvas.overlay.needsDisplay = true
    }

    override func deactivate() { rect = nil; canvas.overlay.needsDisplay = true }
    override func documentWillChange(_ old: Document) { rect = nil }

    override func commit() {
        validate()
        guard let r = rect, let d = doc else { return }
        let ir = IRect(enclosing: CropTool.pixelRect(r))
        resetRect()                          // the box is consumed (crop() commits the current tool: no re-entry)
        if ir != d.state.canvasRect && ir.width > 0 && ir.height > 0 {
            let genExpand = GenAIToolHooks.cropExpansion(crop: ir, canvas: d.state.canvasRect, doc: d)
            AppActions.crop(to: ir, deletePixels: app.crop.deleteCropped)
            genExpand?()
        }
        resetRect()
        canvas.overlay.needsDisplay = true
    }

    override func cancel() {
        resetRect()
        canvas.overlay.needsDisplay = true
    }

    private func handleHit(_ v: CGPoint) -> TransformHandle? {
        guard let r = rect else { return nil }
        let q = Quad(rect: r).mapped { canvas.docToView($0) }.points
        for i in 0..<4 where q[i].distance(to: v) < 9 { return .corner(i) }
        for i in 0..<4 where ((q[i] + q[(i + 1) % 4]) / 2).distance(to: v) < 9 { return .edge(i) }
        if r.contains(canvas.viewToDoc(v)) { return .move }      // doc space: exact in a rotated view too
        return nil
    }

    override func mouseDown(_ e: ToolEvent) {
        validate()
        if rect == nil { activate() }
        guard let r = rect else { return }
        if e.clickCount == 2, r.contains(e.doc) { commit(); return }
        if let h = handleHit(e.view) {
            drag = (h, e.doc, r)
        } else {
            creating = e.doc
            drag = (nil, e.doc, r)
        }
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let dr = drag else { return }
        let p = canvas.snap(e.doc)
        // (bounded: an extreme typed ratio made the box — and the Int(…) in the status text — overflow)
        let ratio: CGFloat? = app.crop.ratioW > 0 && app.crop.ratioH > 0 ? CGFloat(clamp(app.crop.ratioW / app.crop.ratioH, 0.001, 1000)) : (e.shift ? dr.startRect.width / max(1, dr.startRect.height) : nil)
        if let s = creating {
            var r = CGRect(p1: s, p2: p)
            if let k = ratio {
                if r.width / max(1, r.height) > k { r.size.height = r.width / k } else { r.size.width = r.height * k }
                if p.x < s.x { r.origin.x = s.x - r.width }
                if p.y < s.y { r.origin.y = s.y - r.height }
            }
            rect = r
            return
        }
        guard let h = dr.handle else { return }
        var r = dr.startRect
        let d = p - dr.start
        switch h {
        case .move:
            r = r.offsetBy(dx: d.x, dy: d.y)
        case .corner(let i):
            var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
            if i == 0 || i == 3 { x0 += d.x } else { x1 += d.x }
            if i == 0 || i == 1 { y0 += d.y } else { y1 += d.y }
            r = CGRect(p1: CGPoint(x: x0, y: y0), p2: CGPoint(x: x1, y: y1))
            if let k = ratio {
                let h2 = r.width / k
                if i == 0 || i == 1 { r.origin.y = r.maxY - h2 }
                r.size.height = h2
            }
        case .edge(let i):
            var x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY
            switch i {
            case 0: y0 += d.y
            case 1: x1 += d.x
            case 2: y1 += d.y
            default: x0 += d.x
            }
            r = CGRect(p1: CGPoint(x: x0, y: y0), p2: CGPoint(x: x1, y: y1))
            if let k = ratio {
                if i == 1 || i == 3 { r.size.height = r.width / k } else { r.size.width = r.height * k }
            }
        default: break
        }
        rect = CropTool.pixelRect(r)
        status("W: \(Int(r.width)) px  H: \(Int(r.height)) px")
    }

    override func mouseUp(_ e: ToolEvent) {
        drag = nil
        creating = nil
        if let r = rect, r.width < 2 || r.height < 2 { resetRect() }
    }

    override func drawOverlay(_ ctx: CGContext) {
        validate()
        guard let r = rect else { return }
        // the box as a quad in view space (a rectangle unless the view is rotated)
        let q = Quad(rect: r).mapped { canvas.docToView($0) }
        let pts = q.points
        ctx.saveGState()
        ctx.addRect(canvas.bounds)
        ctx.addPath(q.path)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        if app.crop.showThirds {
            let p = CGMutablePath()
            for i in 1...2 {
                let t = CGFloat(i) / 3
                p.move(to: q.tl.lerp(q.tr, t)); p.addLine(to: q.bl.lerp(q.br, t))
                p.move(to: q.tl.lerp(q.bl, t)); p.addLine(to: q.tr.lerp(q.br, t))
            }
            ctx.saveGState()
            ctx.addPath(p)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.5).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(q.path)
        ctx.strokePath()
        // L-shaped corner handles along the box edges
        ctx.setLineWidth(3)
        let L: CGFloat = 14
        for i in 0..<4 {
            let c = pts[i]
            let a = (pts[(i + 1) % 4] - c).normalized, b = (pts[(i + 3) % 4] - c).normalized
            ctx.move(to: c + a * L); ctx.addLine(to: c); ctx.addLine(to: c + b * L)
        }
        ctx.strokePath()
        for i in 0..<4 {
            let m = (pts[i] + pts[(i + 1) % 4]) / 2
            let dir = (pts[(i + 1) % 4] - pts[i]).normalized
            ctx.move(to: m - dir * 8)
            ctx.addLine(to: m + dir * 8)
        }
        ctx.strokePath()
        ctx.setLineWidth(1)
    }
}
