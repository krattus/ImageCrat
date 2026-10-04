import AppKit
import ImageCratCore

/// Artboard tool: drag on empty canvas to create an artboard, drag an artboard's name (or body) to move it,
/// drag its handles to resize it, and click the "+" buttons next to the active artboard to add one of the same size
/// beside it (⌥-click duplicates it with its contents). Double-click a name to rename the artboard; ⇧-click adds
/// artboards to the selection (Align / Spacing in the options bar). Model operations live in `ArtboardOps`.
final class ArtboardTool: Tool {
    private enum Drag {
        case create(CGPoint)
        case move(UUID, CGPoint, DocumentState)
        case resize(UUID, TransformHandle, CGRect, CGPoint)
    }
    private var drag: Drag?
    private var current: CGPoint?
    private var changed = false

    static let gap: CGFloat = 100

    override var cursor: NSCursor { .arrow }

    /// The selected artboard: the active layer or its closest artboard ancestor.
    static func activeArtboard(_ d: Document) -> Layer? {
        var id = d.activeLayerID
        while let i = id, let l = d.state.layer(i) {
            if l.isArtboard { return l }
            id = d.state.parentID(of: i)
        }
        return nil
    }

    /// (no name to grab while View ▸ Show ▸ Artboard Names is off)
    private func labelRect(_ l: Layer) -> CGRect? { ArtboardCanvas.namesShown ? ArtboardCanvas.labelRect(l, canvas: canvas)?.insetBy(dx: -2, dy: -2) : nil }

    enum Side: CaseIterable { case top, right, bottom, left }

    private func plusButtons(_ r: CGRect) -> [(Side, CGPoint)] {
        let q = canvas.docToView(r)
        return [(.top, CGPoint(x: q.midX, y: q.minY - 30)), (.right, CGPoint(x: q.maxX + 24, y: q.midY)),
                (.bottom, CGPoint(x: q.midX, y: q.maxY + 24)), (.left, CGPoint(x: q.minX - 24, y: q.midY))]
    }

    private func handles(_ r: CGRect) -> [(TransformHandle, CGPoint)] {
        let q = Quad(rect: r).mapped { canvas.docToView($0) }.points
        var out: [(TransformHandle, CGPoint)] = []
        for i in 0..<4 { out.append((.corner(i), q[i])) }
        for i in 0..<4 { out.append((.edge(i), (q[i] + q[(i + 1) % 4]) / 2)) }
        return out
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        changed = false
        if e.clickCount >= 2, let l = ArtboardCanvas.labelHit(e.view, canvas: canvas) {
            d.selectLayer(l.id)
            ArtboardCanvas.beginRename(l.id, canvas: canvas)
            return
        }
        if let a = ArtboardTool.activeArtboard(d), let ab = a.artboard {
            if let (side, _) = plusButtons(ab.rect).first(where: { $0.1.distance(to: e.view) < 11 }) {
                if e.option { ArtboardOps.duplicate(d, [a.id], side: side) } else { ArtboardTool.addAdjacent(d, to: a.id, side: side) }
                return
            }
            if let (h, _) = handles(ab.rect).first(where: { $0.1.distance(to: e.view) < 7 }) {
                guard canModify(a, position: true) else { return }
                drag = .resize(a.id, h, ab.rect, e.doc)
                return
            }
        }
        let boards = AppActions.artboards(d).reversed()
        if let l = boards.first(where: { $0.isVisible && labelRect($0)?.contains(e.view) == true }) ?? boards.first(where: { $0.isVisible && $0.artboard!.rect.contains(e.doc) }) {
            if e.shift {   // ⇧-click: add to / remove from the artboard selection
                d.selectLayer(l.id, extend: true)
                app.sessionTick += 1
                return
            }
            d.selectLayer(l.id)
            app.sessionTick += 1
            guard canModify(l, position: true) else { return }
            drag = .move(l.id, e.doc, d.state)
            return
        }
        drag = .create(canvas.snap(e.doc))
        current = canvas.snap(e.doc)
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc, let dr = drag else { return }
        switch dr {
        case .create:
            current = canvas.snap(e.doc)
        case .move(let id, let start, let base):
            let delta = (e.doc - start).rounded
            var st = base
            st.updateLayer(id) { $0.translate(dx: Double(delta.x), dy: Double(delta.y)) }
            d.state = st
            changed = delta != .zero
            status("Δ X: \(Int(delta.x))  Δ Y: \(Int(delta.y))")
        case .resize(let id, let h, let r0, let start):
            let dp = (canvas.snap(e.doc) - start).rounded
            var x0 = r0.minX, y0 = r0.minY, x1 = r0.maxX, y1 = r0.maxY
            switch h {
            case .corner(let i):
                if i == 0 || i == 3 { x0 += dp.x } else { x1 += dp.x }
                if i == 0 || i == 1 { y0 += dp.y } else { y1 += dp.y }
            case .edge(let i):
                switch i { case 0: y0 += dp.y; case 1: x1 += dp.x; case 2: y1 += dp.y; default: x0 += dp.x }
            default: break
            }
            let r = CGRect(p1: CGPoint(x: x0, y: y0), p2: CGPoint(x: x1, y: y1)).integral
            guard r.width >= 1, r.height >= 1 else { return }
            d.revertUncommitted()
            ArtboardTool.setRect(d, id, r)
            changed = true
            status("W: \(Int(r.width)) px  H: \(Int(r.height)) px")
        }
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let dr = drag else { return }
        defer { drag = nil; current = nil }
        switch dr {
        case .create(let s):
            guard let c = current, abs(c.x - s.x) >= 4, abs(c.y - s.y) >= 4 else { return }
            ArtboardTool.create(d, rect: CGRect(p1: s, p2: c).integral)
        case .move(let id, _, _):
            guard changed, d.state.layer(id)?.artboard != nil else { return }
            ArtboardOps.commitSized(d, "Move Artboard")   // grows / shrinks the canvas around the artboards
            Compositor.shared.clearCaches()
        case .resize(let id, _, _, _):
            guard changed, d.state.layer(id)?.artboard != nil else { return }
            ArtboardOps.commitSized(d, "Resize Artboard")
            Compositor.shared.clearCaches()
        }
    }

    // MARK: Model operations

    static func setRect(_ d: Document, _ id: UUID, _ r: CGRect) {
        d.updateLayer(id) { l in
            guard case .group(var g) = l.content, var ab = g.artboard else { return }
            ab.rect = r
            g.artboard = ab
            l.content = .group(g)
        }
    }

    /// New artboard from a drag (the first one in a normal document takes the layers it covers, see `ArtboardOps.create`).
    @discardableResult
    static func create(_ d: Document, rect: CGRect, name: String? = nil) -> UUID {
        ArtboardOps.create(d, rect: rect, name: name)
    }

    /// "+" button: adds an empty artboard of the same size (and background) beside `id`, past artboards already there.
    @discardableResult
    static func addAdjacent(_ d: Document, to id: UUID, side: Side) -> UUID? {
        guard let src = d.state.layer(id), let ab = src.artboard else { return nil }
        let nr = ArtboardOps.freeRect(d.state, size: ab.rect.size, beside: ab.rect, side: side)
        return ArtboardOps.create(d, rect: nr, background: ab.background, preset: ab.presetName)
    }

    // MARK: Overlay

    override func drawOverlay(_ ctx: CGContext) {
        guard let d = doc else { return }
        if case .create(let s) = drag, let c = current {
            OverlayStyle.contrastStroke(ctx, CGPath(rect: canvas.docToView(CGRect(p1: s, p2: c)), transform: nil), dashed: true)
            if let m = canvas.lastMouseView { OverlayStyle.label("W: \(Int(abs(c.x - s.x)))  H: \(Int(abs(c.y - s.y)))", at: m) }
            return
        }
        guard let a = ArtboardTool.activeArtboard(d), let ab = a.artboard else { return }
        let q = canvas.docToView(ab.rect)
        OverlayStyle.accentStroke(ctx, CGPath(rect: q, transform: nil), width: 2)
        for (h, p) in handles(ab.rect) {
            if case .corner = h { OverlayStyle.handle(ctx, at: p) } else { OverlayStyle.handle(ctx, at: p, size: 6) }
        }
        guard drag == nil else { return }
        for (_, p) in plusButtons(ab.rect) {
            let r = CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)
            ctx.setFillColor(NSColor(white: 0.2, alpha: 0.85).cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(OverlayStyle.accent.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: r)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: p.x - 4.5, y: p.y)); ctx.addLine(to: CGPoint(x: p.x + 4.5, y: p.y))
            ctx.move(to: CGPoint(x: p.x, y: p.y - 4.5)); ctx.addLine(to: CGPoint(x: p.x, y: p.y + 4.5))
            ctx.strokePath()
        }
    }
}
