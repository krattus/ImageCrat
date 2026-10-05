import AppKit
import ImageCratCore

// MARK: - Curvature math

enum CurvatureMath {
    /// Smooth bezier anchors passing through `pts` (Catmull-Rom tangents); `corners` get no handles.
    static func anchors(_ pts: [CGPoint], corners: Set<Int> = [], closed: Bool = false) -> [PathPoint] {
        let n = pts.count
        guard n > 0 else { return [] }
        if n == 1 { return [PathPoint(pts[0])] }
        var out: [PathPoint] = []
        for i in 0..<n {
            let p = pts[i]
            if corners.contains(i) { out.append(PathPoint(p)); continue }
            let prev: CGPoint?, next: CGPoint?
            if closed {
                prev = pts[(i - 1 + n) % n]; next = pts[(i + 1) % n]
            } else {
                prev = i > 0 ? pts[i - 1] : nil
                next = i < n - 1 ? pts[i + 1] : nil
            }
            guard let a = prev, let b = next else { out.append(PathPoint(p)); continue }   // open endpoints
            // tangent along (next - prev), handle lengths proportional to the adjacent segment lengths
            let dir = (b - a).normalized
            let lin = p.distance(to: a) / 3, lout = p.distance(to: b) / 3
            out.append(PathPoint(anchor: p, inControl: p - dir * lin, outControl: p + dir * lout, isSmooth: true))
        }
        return out
    }

    /// Point on a cubic segment.
    static func bezier(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return p0 * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + p3 * (t * t * t)
    }

    /// Nearest point on the path: (subpath, segment index (from point i to i+1), t, distance).
    static func nearestSegment(_ path: VectorPath, to p: CGPoint) -> (Int, Int, CGFloat, CGFloat)? {
        var best: (Int, Int, CGFloat, CGFloat)?
        for (si, s) in path.subpaths.enumerated() {
            let n = s.points.count
            guard n > 1 else { continue }
            let segs = s.closed ? n : n - 1
            for i in 0..<segs {
                let a = s.points[i], b = s.points[(i + 1) % n]
                var bt: CGFloat = 0, bd = CGFloat.infinity
                for k in 0...64 {
                    let t = CGFloat(k) / 64
                    let q = bezier(a.anchor, a.outControl, b.inControl, b.anchor, t)
                    let d = q.distance(to: p)
                    if d < bd { bd = d; bt = t }
                }
                // refine
                var lo = max(0, bt - 1 / 64), hi = min(1, bt + 1 / 64)
                for _ in 0..<20 {
                    let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
                    let d1 = bezier(a.anchor, a.outControl, b.inControl, b.anchor, m1).distance(to: p)
                    let d2 = bezier(a.anchor, a.outControl, b.inControl, b.anchor, m2).distance(to: p)
                    if d1 < d2 { hi = m2 } else { lo = m1 }
                }
                bt = (lo + hi) / 2
                bd = bezier(a.anchor, a.outControl, b.inControl, b.anchor, bt).distance(to: p)
                if best == nil || bd < best!.3 { best = (si, i, bt, bd) }
            }
        }
        return best
    }

    /// Splits segment i→i+1 of a subpath at t (de Casteljau), inserting a new smooth anchor.
    static func split(_ s: Subpath, segment i: Int, t: CGFloat) -> Subpath {
        var sub = s
        let n = s.points.count
        let j = (i + 1) % n
        let a = s.points[i], b = s.points[j]
        let p0 = a.anchor, p1 = a.outControl, p2 = b.inControl, p3 = b.anchor
        let straight = p1 == p0 && p2 == p3
        let q0 = p0.lerp(p1, t), q1 = p1.lerp(p2, t), q2 = p2.lerp(p3, t)
        let r0 = q0.lerp(q1, t), r1 = q1.lerp(q2, t)
        let m = r0.lerp(r1, t)
        var na = a, nb = b
        var mid: PathPoint
        if straight {
            mid = PathPoint(p0.lerp(p3, t))
        } else {
            na.outControl = q0
            nb.inControl = q2
            mid = PathPoint(anchor: m, inControl: r0, outControl: r1, isSmooth: true)
        }
        sub.points[i] = na
        sub.points[j] = nb
        sub.points.insert(mid, at: i + 1)
        return sub
    }
}

// MARK: - Curvature Pen

/// Curvature Pen: click to add points; the curve passes smoothly through them. Double-click (or Option-click)
/// an anchor to toggle corner/smooth, drag an anchor to move it, click the first point to close, Return/Esc ends.
final class CurvaturePenTool: Tool {
    private(set) var points: [CGPoint] = []
    private(set) var corners: Set<Int> = []
    private var closed = false
    private var target: PathTarget?
    private var subIndex = 0
    private var dragging: Int?
    private var dragMoved = false
    private var hover: CGPoint?
    /// The document the path is being drawn in.
    private weak var pathDoc: Document?

    override var cursor: NSCursor { .crosshair }
    override var isBusy: Bool { target != nil }
    /// Every point is a history step: Edit ▸ Undo takes back the last one (the tool re-reads the path, see `sync`).
    override func undoPending() -> Bool { false }

    override func activate() { ToolModes.restore(kind) }
    override func deactivate() { finish() }
    override func commit() { finish() }
    override func cancel() { finish() }

    private func finish() {
        // an anchor drag interrupted by Return / Esc / a tool switch must not stay uncommitted
        if dragging != nil, dragMoved, let d = pathDoc { d.commit("Edit Path") }
        dragMoved = false
        target = nil; points = []; corners = []; closed = false; dragging = nil
        canvas.overlay.needsDisplay = true
    }

    /// Re-reads the path from the document when it changed underneath the tool (undo / redo / History panel): points
    /// that were undone must not come back with the next click, and a path whose layer is gone is over.
    private func sync() {
        guard let t = target, dragging == nil else { return }
        guard let d = doc, d === pathDoc, let path = VectorEditing.path(d, t), subIndex < path.subpaths.count else { finish(); return }
        let sub = path.subpaths[subIndex]
        let anchors = sub.points.map(\.anchor)
        if anchors.count == points.count, zip(anchors, points).allSatisfy({ $0.distance(to: $1) < 0.001 }) { return }
        points = anchors
        corners = Set(sub.points.indices.filter { $0 > 0 && $0 < anchors.count - 1 && !sub.points[$0].hasHandles })
        if sub.closed || points.isEmpty { finish() }
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        sync()
        if target != nil {
            if let i = points.firstIndex(where: { canvas.docToView($0).distance(to: e.view) < 7 }) {
                if e.clickCount == 2 || e.option {
                    if corners.contains(i) { corners.remove(i) } else { corners.insert(i) }
                    apply(d, commit: "Convert Point")
                    return
                }
                if i == 0 && points.count >= 3 && !closed {
                    closed = true
                    apply(d, commit: "Close Path")
                    finish()
                    return
                }
                dragging = i
                return
            }
            add(e.doc, d: d, corner: e.clickCount == 2)
            dragging = points.count - 1
            return
        }
        start(d, at: e.doc)
        dragging = 0
    }

    /// Starts a new path (shape layer or work path per the pen mode).
    func start(_ d: Document, at p: CGPoint) {
        pathDoc = d
        points = [p]
        corners = []
        closed = false
        let first = VectorPath(subpaths: [Subpath(points: [PathPoint(p)])])
        if app.penMode == .shape {
            let id = VectorEditing.newShapeLayer(d, geometry: .path(first), name: "Shape")
            target = .layer(id)
            subIndex = 0
        } else {
            let pid = VectorEditing.newWorkPath(d, first)
            target = .workPath(pid)
            subIndex = (VectorEditing.path(d, .workPath(pid))?.subpaths.count ?? 1) - 1
        }
        apply(d, commit: "Curvature Pen")
    }

    func add(_ p: CGPoint, d: Document, corner: Bool = false) {
        points.append(p)
        if corner { corners.insert(points.count - 1) }
        apply(d, commit: "Add Anchor Point")
    }

    private func apply(_ d: Document, commit name: String?) {
        guard let t = target, var path = VectorEditing.path(d, t) else { return }
        let sub = Subpath(points: CurvatureMath.anchors(points, corners: corners, closed: closed), closed: closed)
        if subIndex < path.subpaths.count { path.subpaths[subIndex] = sub } else { path.subpaths.append(sub); subIndex = path.subpaths.count - 1 }
        VectorEditing.setPath(d, t, path)
        if let n = name { d.commit(n) }
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc, let i = dragging, i < points.count else { return }
        points[i] = e.doc
        dragMoved = true
        apply(d, commit: nil)
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, dragging != nil else { return }
        dragging = nil
        if dragMoved { d.commit("Edit Path") }
        dragMoved = false
    }

    override func mouseMoved(_ e: ToolEvent) { hover = e.doc }

    override func keyDown(_ e: NSEvent) -> Bool {
        if e.keyCode == 36 || e.keyCode == 53 || e.keyCode == 76 {
            // ends the path being drawn; pressed again it deselects (hides) the active path, like Photoshop
            if target != nil { finish() } else if let d = doc { PathOps.deselectPath(d) }
            return true
        }
        sync()
        if (e.keyCode == 51 || e.keyCode == 117), let d = doc, target != nil, points.count > 1 {
            points.removeLast()
            corners.remove(points.count)
            apply(d, commit: "Delete Anchor Point")
            return true
        }
        return false
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let d = doc else { return }
        sync()
        if let t = target ?? VectorEditing.currentTarget(d), let path = VectorEditing.path(d, t) {
            VectorEditing.drawPath(ctx, path, canvas: canvas, anchors: target == nil)
        }
        guard target != nil else { return }
        // rubber band: preview of the curve with the hover point added
        if let h = hover, dragging == nil, !closed, points.count >= 1 {
            let preview = CurvatureMath.anchors(points + [h], corners: corners)
            let sub = Subpath(points: preview)
            var t = canvas.docToViewTransform
            if let vp = sub.cgPath.copy(using: &t) { OverlayStyle.contrastStroke(ctx, vp, dashed: true) }
        }
        for (i, p) in points.enumerated() {
            let v = canvas.docToView(p)
            if corners.contains(i) { OverlayStyle.handle(ctx, at: v, size: 7, filled: i == points.count - 1) }
            else { OverlayStyle.circleHandle(ctx, at: v, size: 8, filled: i == points.count - 1) }
        }
    }
}

// MARK: - Add / Delete Anchor Point, Convert Point

/// Add Anchor Point (click a segment), Delete Anchor Point (click an anchor) and Convert Point (click an anchor to
/// make it a corner, drag from it to pull out smooth handles, drag a handle to move it independently).
final class AnchorEditTool: Tool {
    private var drag: (target: PathTarget, si: Int, pi: Int, handle: Int, original: VectorPath)?   // handle: 0 anchor-drag, 1 in, 2 out
    private var moved = false

    override var cursor: NSCursor { .crosshair }

    private func target(_ d: Document, _ e: ToolEvent) -> PathTarget? {
        // the active work path under the cursor wins over the active shape layer (both outlines are shown)
        if let pid = VectorEditing.workPathHit(d, e.doc, tolerance: 8 / canvas.zoom) { VectorEditing.pickWorkPath(d, pid); return .workPath(pid) }
        if let t = VectorEditing.currentTarget(d) { return t }
        if let id = AppActions.layerAt(e.doc, shapesOnly: true) { d.selectLayer(id); return .layer(id) }
        return nil
    }

    private func anchorHit(_ p: VectorPath, _ v: CGPoint) -> (Int, Int)? {
        for (si, s) in p.subpaths.enumerated() {
            for (pi, pt) in s.points.enumerated() where canvas.docToView(pt.anchor).distance(to: v) < 7 { return (si, pi) }
        }
        return nil
    }

    private func handleHit(_ p: VectorPath, _ v: CGPoint) -> (Int, Int, Int)? {
        for (si, s) in p.subpaths.enumerated() {
            for (pi, pt) in s.points.enumerated() {
                if pt.inControl != pt.anchor, canvas.docToView(pt.inControl).distance(to: v) < 6 { return (si, pi, 1) }
                if pt.outControl != pt.anchor, canvas.docToView(pt.outControl).distance(to: v) < 6 { return (si, pi, 2) }
            }
        }
        return nil
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc, let t = target(d, e), var path = VectorEditing.path(d, t) else { return }
        if let id = t.layerID, let l = d.state.layer(id), !canModify(l) { return }
        moved = false
        switch kind {
        case .addAnchor:
            if let (si, pi) = anchorHit(path, e.view) {   // clicking an existing anchor: drag it
                drag = (t, si, pi, 0, path)
                return
            }
            guard let (si, seg, tt, dist) = CurvatureMath.nearestSegment(path, to: e.doc), dist * canvas.zoom < 8 else {
                status("Click on a path segment to add an anchor point."); return
            }
            path.subpaths[si] = CurvatureMath.split(path.subpaths[si], segment: seg, t: tt)
            VectorEditing.setPath(d, t, path)
            d.commit("Add Anchor Point")
            drag = (t, si, seg + 1, 0, path)
        case .deleteAnchor:
            guard let (si, pi) = anchorHit(path, e.view) else { status("Click an anchor point to delete it."); return }
            let before = path
            path = AnchorEditTool.deleting(path, si, pi)
            VectorEditing.setPath(d, t, path)
            // (a type path keeps at least two anchors: nothing deleted, no step)
            guard VectorEditing.path(d, t) != before else { Beep.play(); status("A type path needs at least two anchor points."); return }
            d.commit("Delete Anchor Point")
        default:   // convert point
            if let (si, pi, h) = handleHit(path, e.view) {
                path.subpaths[si].points[pi].isSmooth = false
                drag = (t, si, pi, h, path)
                return
            }
            guard let (si, pi) = anchorHit(path, e.view) else { return }
            var q = path.subpaths[si].points[pi]
            if q.hasHandles {
                q.inControl = q.anchor; q.outControl = q.anchor; q.isSmooth = false
                path.subpaths[si].points[pi] = q
                VectorEditing.setPath(d, t, path)
                d.commit("Convert Point")
            } else {
                drag = (t, si, pi, 3, path)   // drag out new smooth handles
            }
        }
    }

    static func deleting(_ path: VectorPath, _ si: Int, _ pi: Int) -> VectorPath {
        var p = path
        p.subpaths[si].points.remove(at: pi)
        if p.subpaths[si].points.count < 2 && p.subpaths[si].closed { p.subpaths[si].closed = false }
        p.subpaths.removeAll { $0.points.isEmpty }
        return p
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc, let dr = drag else { return }
        var path = dr.original
        guard dr.si < path.subpaths.count, dr.pi < path.subpaths[dr.si].points.count else { return }
        var q = path.subpaths[dr.si].points[dr.pi]
        switch dr.handle {
        case 0:
            let delta = e.doc - q.anchor
            q = q.mapped { $0 + delta }
        case 1: q.inControl = e.doc; q.isSmooth = false
        case 2: q.outControl = e.doc; q.isSmooth = false
        default:
            q.outControl = e.doc
            q.inControl = q.anchor - (e.doc - q.anchor)
            q.isSmooth = true
        }
        path.subpaths[dr.si].points[dr.pi] = q
        VectorEditing.setPath(d, dr.target, path)
        moved = true
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, drag != nil else { return }
        drag = nil
        if moved { d.commit(kind == .convertPoint ? "Convert Point" : "Edit Path") }
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let d = doc, let t = VectorEditing.currentTarget(d), let p = VectorEditing.path(d, t) else { return }
        var all = Set<Int>()
        var n = 0
        for s in p.subpaths { for _ in s.points { all.insert(n); n += 1 } }
        VectorEditing.drawPath(ctx, p, canvas: canvas, anchors: true, selected: kind == .convertPoint ? all : [])
        if kind == .addAnchor, let m = canvas.lastMouseView, let (si, seg, tt, dist) = CurvatureMath.nearestSegment(p, to: canvas.viewToDoc(m)), dist * canvas.zoom < 8 {
            let s = p.subpaths[si]
            let a = s.points[seg], b = s.points[(seg + 1) % s.points.count]
            let q = CurvatureMath.bezier(a.anchor, a.outControl, b.inControl, b.anchor, tt)
            OverlayStyle.handle(ctx, at: canvas.docToView(q), size: 6, filled: true)
        }
    }
}
