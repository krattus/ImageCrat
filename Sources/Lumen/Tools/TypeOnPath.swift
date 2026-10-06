import AppKit
import SwiftUI
import ImageCratCore

// Type on a path, Photoshop style: the Type tool shows the type-on-a-path cursor over any visible path or shape outline
// and starts the text where it is clicked; the Path Selection / Direct Selection tools (or ⌘ with the Type tool) drag
// the text along its path, and across the path to flip it to the other side.

enum TypeOnPath {
    /// Paths the Type tool can put text on: the active path (Paths panel), the active shape layer and every visible
    /// shape layer, one subpath each (doc coordinates). A Line shape offers its centre line (an open path), not the
    /// outline of its weight.
    static func candidates(_ d: Document) -> [Subpath] {
        var out: [Subpath] = []
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }) { out += np.path.subpaths }
        if let s = d.activeLayer?.shape { out += subpaths(of: s) }
        for (l, _) in d.state.layers.flattenedForDisplay(includeCollapsed: true) where l.isVisible && l.id != d.activeLayerID {
            if let s = l.shape { out += subpaths(of: s) }
        }
        return out.filter { $0.points.count >= 2 }
    }

    static func subpaths(of s: ShapeContent) -> [Subpath] {
        if case .line(let a, let b, _) = s.geometry {
            var vp = VectorPath(subpaths: [Subpath(points: [PathPoint(a), PathPoint(b)])]).applying(s.transform)
            if let h = s.perspective { vp = vp.mapped(h.apply) }
            return vp.subpaths
        }
        return s.path.subpaths
    }

    /// The nearest candidate subpath within `tolerance` (doc units) of `p` and the arc length of the nearest point.
    static func hit(_ d: Document, _ p: CGPoint, tolerance: CGFloat) -> (VectorPath, CGFloat)? {
        var best: (VectorPath, CGFloat, CGFloat)?
        for sp in candidates(d) {
            let single = VectorPath(subpaths: [sp])
            let (s, dist) = PathSampler(single).nearest(p)
            if dist <= tolerance, dist < (best?.2 ?? .infinity) { best = (single, s, dist) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Type ▸ Type on Path: starts type on the active path (or the active shape's outline) at its start.
    static func startFromMenu() {
        guard let d = AppActions.doc, let canvas = AppActions.canvas, canvas.document === d else { return }
        var sub: Subpath? = nil
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }) { sub = np.path.subpaths.first { $0.points.count >= 2 } }
        if sub == nil, let s = d.activeLayer?.shape { sub = subpaths(of: s).first { $0.points.count >= 2 } }
        guard let sp = sub else {
            AppModel.shared.setStatus(helpText)
            Beep.play()
            return
        }
        if canvas.currentTool.kind != .text { AppModel.shared.tool = .text }
        (canvas.tool(for: .text) as? TextTool)?.beginTypeOnPath(VectorPath(subpaths: [sp]), at: 0)
    }

    static let helpText = "Type on a path: draw a path (Pen, or a shape tool in Path mode) or a shape, then click its outline with the Type tool. ⌘-drag the type (or use the Path Selection tool) to move it along the path; drag across the path to flip it."
}

// MARK: - Moving / flipping type along its path

/// One drag of type on a path along (move) or across (flip) its path. Started by the Path Selection / Direct Selection
/// tools, or by ⌘ with the Type tool; one history step ("Move Type on Path" / "Flip Type") unless the layer is open in
/// the type editor (then the edit session's step includes it).
final class PathTextDrag {
    nonisolated(unsafe) static var active: PathTextDrag?

    weak var doc: Document?
    let layerID: UUID
    let original: TextOnPath
    let toLocal: CGAffineTransform
    let scale: CGFloat
    let sampler: PathSampler
    let startS: CGFloat
    let anchor0: CGFloat
    let editing: Bool
    var current: TextOnPath
    var moved = false

    init?(_ d: Document, _ id: UUID, at p: CGPoint) {
        guard let t = d.state.layer(id)?.text, let pt = t.pathText, !pt.path.isEmpty else { return nil }
        doc = d
        layerID = id
        original = pt
        current = pt
        toLocal = t.transform.inverted()
        scale = max(1e-3, sqrt(abs(t.transform.a * t.transform.d - t.transform.b * t.transform.c)))
        sampler = PathSampler(pt.path)
        guard sampler.total > 0 else { return nil }
        startS = sampler.nearest(p.applying(toLocal)).s
        let off = CGFloat(pt.startOffset)
        anchor0 = pt.flipped ? sampler.total - off : off
        editing = TextTool.editing?.isEditing(id) ?? false
    }

    /// Type-on-a-path layer under `p` (doc): near its path or on its glyphs; the active layer first, then from the top.
    /// `glyphsOnly`: only a click on the glyphs counts, except for the active layer (Path Selection tool: a click on
    /// the outline of another layer's path belongs to that path / shape).
    static func hit(_ d: Document, _ p: CGPoint, canvas: CanvasView, glyphsOnly: Bool = false) -> UUID? {
        var ids: [UUID] = []
        if let a = d.activeLayerID { ids.append(a) }
        for (l, _) in d.state.layers.flattenedForDisplay(includeCollapsed: true) where l.isVisible && l.id != d.activeLayerID { ids.append(l.id) }
        for id in ids {
            guard let t = d.state.layer(id)?.text, let pt = t.pathText, !pt.path.isEmpty else { continue }
            let local = p.applying(t.transform.inverted())
            let k = max(1e-3, sqrt(abs(t.transform.a * t.transform.d - t.transform.b * t.transform.c)))
            let tol = 6 / max(0.01, canvas.zoom) / k
            if !glyphsOnly || id == d.activeLayerID, PathSampler(pt.path).nearest(local).distance <= tol { return id }
            if TextRenderer.layout(t).lines.contains(where: { $0.bounds.insetBy(dx: -2, dy: -2).contains(local) }) { return id }
        }
        return nil
    }

    /// Mouse down: starts a drag when it hits type on a path (Type tool: only with ⌘). Returns true when it did.
    static func begin(_ d: Document, _ e: ToolEvent, canvas: CanvasView, viaPathTool: Bool) -> Bool {
        guard viaPathTool || e.command else { return false }
        guard let id = hit(d, e.doc, canvas: canvas, glyphsOnly: viaPathTool), let l = d.state.layer(id) else { return false }
        if l.locks.all || l.locks.position {
            AppModel.shared.setStatus("The layer is locked.")
            Beep.play()
            return true
        }
        if let tt = TextTool.editing, tt.editingID != nil, !tt.isEditing(id) { tt.endEditing(commit: true) }
        guard d.state.layer(id) != nil, let drag = PathTextDrag(d, id, at: e.doc) else { return false }
        if !drag.editing, d.activeLayerID != id { d.selectLayer(id) }
        if drag.editing { TextTool.editing?.refocusEditor() }
        active = drag
        canvas.overlay.needsDisplay = true
        return true
    }

    static func drag(_ e: ToolEvent, canvas: CanvasView) -> Bool {
        guard let a = active else { return false }
        a.update(e.doc, canvas: canvas)
        return true
    }

    static func end(_ e: ToolEvent, canvas: CanvasView) -> Bool {
        guard let a = active else { return false }
        active = nil
        if a.editing { TextTool.editing?.refocusEditor() }    // typing continues after a ⌘-drag
        if a.moved, !a.editing, let d = a.doc, d.state.layer(a.layerID) != nil {
            d.commit(a.current.flipped != a.original.flipped ? "Flip Type" : "Move Type on Path")
            d.setNeedsRender()
        }
        canvas.overlay.needsDisplay = true
        return true
    }

    /// Esc / tool switch mid-drag: the text goes back where it was.
    static func cancel() {
        guard let a = active else { return }
        active = nil
        if a.moved { a.apply(a.original) }
    }

    /// The new placement for the cursor at `p` (doc): along the path by the distance dragged, flipped when the cursor
    /// is on the far side of the path (more than 3 screen pixels away from it).
    func placement(for p: CGPoint, zoom: CGFloat) -> TextOnPath {
        let local = p.applying(toLocal)
        let total = sampler.total
        let (s, dist) = sampler.nearest(local)
        var flipped = current.flipped
        if dist * scale * zoom > 3, let (q, ang) = sampler.sample(s) {
            let v = local - q
            // glyphs stand on the side where cross(tangent, v) < 0 (y-down); the other side flips the text
            flipped = cos(ang) * v.y - sin(ang) * v.x > 0
        }
        var delta = s - startS
        var anchor: CGFloat
        if sampler.closed {
            if delta > total / 2 { delta -= total } else if delta < -total / 2 { delta += total }
            anchor = (anchor0 + delta).truncatingRemainder(dividingBy: total)
            if anchor < 0 { anchor += total }
        } else {
            anchor = min(max(0, anchor0 + delta), total)
        }
        var r = current
        r.flipped = flipped
        r.startOffset = Double(flipped ? total - anchor : anchor)
        return r
    }

    func update(_ p: CGPoint, canvas: CanvasView) {
        let n = placement(for: p, zoom: canvas.zoom)
        guard n != current else { return }
        current = n
        moved = n != original
        apply(n)
        canvas.overlay.needsDisplay = true
    }

    func apply(_ p: TextOnPath) {
        guard let d = doc else { return }
        if editing, let tt = TextTool.editing, tt.isEditing(layerID) {
            tt.updateEditingPathText(p)
        } else {
            d.updateLayer(layerID) { $0.text?.pathText = p }
        }
        d.setNeedsRender()
    }

    /// Path Selection / Direct Selection: the path and start point of the active type on a path.
    static func drawMarker(_ ctx: CGContext, canvas: CanvasView) {
        guard let d = canvas.document, let id = active?.layerID ?? d.activeLayerID, !(TextTool.editing?.isEditing(id) ?? false),
              let t = d.state.layer(id)?.text, let p = t.pathText, !p.path.isEmpty else { return }
        let vp = p.path.applying(t.transform)
        let path = TextRenderer.mapPath(vp.cgPath, maxSegment: 1_000_000) { canvas.docToView($0) }
        OverlayStyle.contrastStroke(ctx, path)
        if let (pt, _) = PathSampler(p.path, flipped: p.flipped).sample(CGFloat(p.startOffset)) {   // (arc length in layer space)
            OverlayStyle.circleHandle(ctx, at: canvas.docToView(pt.applying(t.transform)), size: 8, filled: true)
        }
    }
}

// MARK: - Cursors

/// Photoshop's type cursors: I-beam with a path through it (type on a path), I-beam in a dotted ellipse (area type),
/// I-beam with an arrow (⌘ over type on a path: drag to move / flip it).
enum TypePathCursors {
    static func cursor(onPath: Bool, area: Bool, move: Bool) -> NSCursor {
        if move { return moveAlong }
        if onPath { return typeOnPath }
        if area { return areaType }
        return .iBeam
    }

    static let typeOnPath = make { ctx in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 3, y: 18)); p.addQuadCurve(to: CGPoint(x: 21, y: 16), control: CGPoint(x: 12, y: 24))
        stroke(ctx, p, dashed: true)
    }
    static let areaType = make { ctx in
        stroke(ctx, CGPath(ellipseIn: CGRect(x: 3, y: 2, width: 18, height: 20), transform: nil), dashed: true)
    }
    static let moveAlong = make { ctx in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 15, y: 19)); p.addLine(to: CGPoint(x: 22, y: 19))
        p.move(to: CGPoint(x: 19, y: 16)); p.addLine(to: CGPoint(x: 22, y: 19)); p.addLine(to: CGPoint(x: 19, y: 22))
        stroke(ctx, p, dashed: false)
    }

    private static func stroke(_ ctx: CGContext, _ p: CGPath, dashed: Bool) {
        ctx.saveGState()
        ctx.addPath(p); ctx.setLineWidth(3); ctx.setStrokeColor(NSColor.white.cgColor); ctx.strokePath()
        ctx.addPath(p); ctx.setLineWidth(1.2); ctx.setStrokeColor(NSColor.black.cgColor)
        if dashed { ctx.setLineDash(phase: 0, lengths: [2.5, 1.5]) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// 24 × 24 cursor (y-down drawing): an I-beam in the middle plus `extra`.
    private static func make(_ extra: @escaping (CGContext) -> Void) -> NSCursor {
        let img = NSImage(size: NSSize(width: 24, height: 24), flipped: true) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            extra(ctx)
            let beam = CGMutablePath()
            beam.move(to: CGPoint(x: 9, y: 3)); beam.addLine(to: CGPoint(x: 15, y: 3))
            beam.move(to: CGPoint(x: 12, y: 3)); beam.addLine(to: CGPoint(x: 12, y: 19))
            beam.move(to: CGPoint(x: 9, y: 19)); beam.addLine(to: CGPoint(x: 15, y: 19))
            ctx.addPath(beam); ctx.setLineWidth(3); ctx.setStrokeColor(NSColor.white.cgColor); ctx.strokePath()
            ctx.addPath(beam); ctx.setLineWidth(1.2); ctx.setStrokeColor(NSColor.black.cgColor); ctx.strokePath()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 12, y: 12))
    }
}

// MARK: - Options bar hint

/// Type tool options: how to type on a path / in a shape, shown when the document has paths or shapes.
struct TypePathHint: View {
    @Bindable var app = AppModel.shared
    var body: some View {
        if let d = app.activeDocument, !app.textEditingActive, !d.state.paths.isEmpty || d.state.allLayers.contains(where: { $0.isShape }) {
            Text("Click a path to type on it · inside a closed path for area type · ⌘-drag to move or flip")
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .help(tr(TypeOnPath.helpText))
        }
    }
}
