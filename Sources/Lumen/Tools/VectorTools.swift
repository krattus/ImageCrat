import AppKit
import ImageCratCore

/// What a vector tool is editing.
enum PathTarget: Equatable {
    case layer(UUID)
    case workPath(UUID)
    /// The path of type on a path ("<layer> Type Path"): editing it re-flows the text, which owns the path from then on.
    case typePath(UUID)

    /// The layer whose locks apply (shape layer or type layer).
    var layerID: UUID? {
        switch self {
        case .layer(let id), .typePath(let id): return id
        case .workPath: return nil
        }
    }
}

enum VectorEditing {
    static func currentTarget(_ d: Document) -> PathTarget? {
        if let pid = pickedWorkPath(d) { return .workPath(pid) }       // picked on the canvas over the active shape layer
        if let id = d.activeLayerID, let l = d.state.layer(id), l.isShape { return .layer(id) }
        if let pid = d.activePathID, d.state.paths.contains(where: { $0.id == pid }) { return .workPath(pid) }
        // the active type layer's own path (shown as "<layer> Type Path" while no other path is selected)
        if let id = d.activeLayerID, let p = d.state.layer(id)?.text?.pathText, !p.path.isEmpty { return .typePath(id) }
        return nil
    }

    static func path(_ d: Document, _ t: PathTarget) -> VectorPath? {
        switch t {
        case .layer(let id): return d.state.layer(id)?.shape?.path
        case .workPath(let pid): return d.state.paths.first { $0.id == pid }?.path
        case .typePath(let id):
            guard let t = d.state.layer(id)?.text, let p = t.pathText else { return nil }
            return t.transform.isIdentity ? p.path : p.path.applying(t.transform)   // (doc coordinates)
        }
    }

    /// Replaces the path (baking the shape's live geometry into an editable path).
    static func setPath(_ d: Document, _ t: PathTarget, _ p: VectorPath) {
        switch t {
        case .layer(let id):
            d.updateLayer(id) { l in
                guard var s = l.shape else { return }
                s.geometry = .path(p)
                s.transform = .identity
                s.perspective = nil
                l.shape = s
            }
        case .workPath(let pid):
            if let i = d.state.paths.firstIndex(where: { $0.id == pid }) { d.state.paths[i].path = p }
        case .typePath(let id):
            // one subpath of 2+ anchors (deleting below that is refused); the text re-flows and owns its path now
            guard let sub = p.subpaths.first(where: { $0.points.count >= 2 }), let t = d.state.layer(id)?.text, var pt = t.pathText else { return }
            var local = VectorPath(subpaths: [sub])
            if !t.transform.isIdentity { local = local.applying(t.transform.inverted()) }
            // (a drag that hasn't moved anything yet is not an edit: the link stays)
            if pt.path.subpaths.count == 1, TypePathLink.close(pt.path.subpaths[0], local.subpaths[0], eps: 1e-6) { return }
            TypePathLink.retarget(&pt, to: local)
            pt.source = nil
            if pt != t.pathText { d.updateLayer(id) { $0.text?.pathText = pt } }
        }
    }

    static func newShapeLayer(_ d: Document, geometry: ShapeGeometry, name: String) -> UUID {
        let app = AppModel.shared
        var fill = app.shapeTool.fill
        if case .color = fill { fill = .color(app.foreground) }
        var stroke = StrokeStyle(paint: app.shapeTool.stroke, width: app.shapeTool.strokeWidth, alignment: app.shapeTool.strokeAlignment)
        if let o = app.shapeTool.strokeOptions {   // Stroke Options (caps, corners, dashes) set in the options bar
            stroke.cap = o.cap; stroke.join = o.join; stroke.miterLimit = o.miterLimit
            stroke.dash = o.dash; stroke.dashPhase = o.dashPhase; stroke.dashAlignment = o.dashAlignment; stroke.dashUnit = o.dashUnit
        }
        if app.shapeTool.stroke.isNone { stroke.paint = .none }
        let content = ShapeContent(geometry: geometry, fill: fill, stroke: stroke)
        let layer = Layer(name: d.nextLayerName(name), content: .shape(content))
        d.addLayer(layer)
        return layer.id
    }

    /// A new path drawn in Path mode (or made by a command). Like Photoshop: the active path (Work Path or a saved one)
    /// takes it as new components; with no active path the unsaved Work Path is replaced (saved paths are kept).
    /// `addToActive: false` (Make Work Path from a selection or from type) always replaces the Work Path.
    static func newWorkPath(_ d: Document, _ p: VectorPath, addToActive: Bool = true) -> UUID {
        if addToActive, let pid = d.activePathID, let i = d.state.paths.firstIndex(where: { $0.id == pid }) {
            d.state.paths[i].path.subpaths += p.subpaths
            return pid
        }
        if let i = d.state.paths.firstIndex(where: { $0.name == PathOps.workPathName }) {
            TypePathLink.unlink(d, pathID: d.state.paths[i].id)   // a new path, not an edit: type made on the old one keeps it
            d.state.paths[i].path = p
            d.activePathID = d.state.paths[i].id
            return d.state.paths[i].id
        }
        let np = NamedPath(name: PathOps.workPathName, path: p)
        d.state.paths.append(np)
        d.activePathID = np.id
        return np.id
    }

    static func drawPath(_ ctx: CGContext, _ p: VectorPath, canvas: CanvasView, anchors: Bool, selected: Set<Int> = [], flatIndexBase: Int = 0) {
        var t = canvas.docToViewTransform
        if let vp = p.cgPath.copy(using: &t) { OverlayStyle.accentStroke(ctx, vp, width: 1.2) }
        guard anchors else { return }
        var idx = 0
        for s in p.subpaths {
            for pt in s.points {
                let a = canvas.docToView(pt.anchor)
                if selected.contains(idx) {
                    for c in [pt.inControl, pt.outControl] where c != pt.anchor {
                        let cv = canvas.docToView(c)
                        ctx.setStrokeColor(OverlayStyle.accent.cgColor)
                        ctx.setLineWidth(1)
                        ctx.move(to: a); ctx.addLine(to: cv); ctx.strokePath()
                        OverlayStyle.circleHandle(ctx, at: cv, size: 6, filled: true)
                    }
                }
                OverlayStyle.handle(ctx, at: a, size: 6, filled: selected.contains(idx))
                idx += 1
            }
        }
    }
}

// MARK: - Pen

final class PenTool: Tool {
    private var target: PathTarget?
    private var subIndex: Int?
    private var dragging = false
    private var hover: CGPoint?
    private var freeform: [CGPoint] = []

    override var cursor: NSCursor { .crosshair }

    override func activate() { ToolModes.restore(kind) }
    override func deactivate() { finish() }
    override func commit() { finish() }
    override func cancel() { finish() }

    private func finish() {
        target = nil
        subIndex = nil
        canvas.overlay.needsDisplay = true
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        let p = e.doc
        if kind == .freeformPen {
            freeform = [p]
            return
        }
        if e.command, target != nil { finish(); return }
        // Continue current open subpath
        if let t = target, let si = subIndex, var path = VectorEditing.path(d, t), si < path.subpaths.count {
            var sub = path.subpaths[si]
            if sub.points.count >= 2, let f = sub.points.first, canvas.docToView(f.anchor).distance(to: e.view) < 8 {
                sub.closed = true
                path.subpaths[si] = sub
                VectorEditing.setPath(d, t, path)
                d.commit("Close Path")
                finish()
                return
            }
            sub.points.append(PathPoint(p))
            path.subpaths[si] = sub
            VectorEditing.setPath(d, t, path)
            dragging = true
            return
        }
        // Start a new path
        let first = VectorPath(subpaths: [Subpath(points: [PathPoint(p)])])
        if app.penMode == .shape {
            if let existing = VectorEditing.currentTarget(d), case .layer = existing, e.shift, var path = VectorEditing.path(d, existing) {
                path.subpaths.append(Subpath(points: [PathPoint(p)]))
                VectorEditing.setPath(d, existing, path)
                target = existing
                subIndex = path.subpaths.count - 1
            } else {
                let id = VectorEditing.newShapeLayer(d, geometry: .path(first), name: "Shape")
                target = .layer(id)
                subIndex = 0
            }
        } else {
            let pid: UUID
            if let existing = VectorEditing.currentTarget(d), case .workPath(let id) = existing {
                pid = id
                var path = VectorEditing.path(d, existing)!
                path.subpaths.append(first.subpaths[0])
                VectorEditing.setPath(d, existing, path)
                subIndex = path.subpaths.count - 1
            } else {
                pid = VectorEditing.newWorkPath(d, first)
                subIndex = (VectorEditing.path(d, .workPath(pid))?.subpaths.count ?? 1) - 1
            }
            target = .workPath(pid)
        }
        dragging = true
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let d = doc else { return }
        if kind == .freeformPen {
            if let l = freeform.last, l.distance(to: e.doc) * canvas.zoom > 2 { freeform.append(e.doc) }
            return
        }
        guard dragging, let t = target, let si = subIndex, var path = VectorEditing.path(d, t), si < path.subpaths.count,
              var last = path.subpaths[si].points.last else { return }
        let out = e.doc
        last.outControl = out
        last.inControl = last.anchor - (out - last.anchor)
        last.isSmooth = true
        path.subpaths[si].points[path.subpaths[si].points.count - 1] = last
        VectorEditing.setPath(d, t, path)
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc else { return }
        if kind == .freeformPen {
            defer { freeform = [] }
            guard freeform.count > 2 else { return }
            let pts = PenTool.simplify(freeform, epsilon: 2 / canvas.zoom)
            var sub = Subpath(points: PenTool.smoothBezier(pts))
            if let f = freeform.first, let l = freeform.last, f.distance(to: l) * canvas.zoom < 10 { sub.closed = true }
            let vp = VectorPath(subpaths: [sub])
            if app.penMode == .shape {
                _ = VectorEditing.newShapeLayer(d, geometry: .path(vp), name: "Shape")
            } else {
                _ = VectorEditing.newWorkPath(d, vp)
            }
            d.commit("Freeform Pen")
            return
        }
        if dragging {
            dragging = false
            d.commit("Add Anchor Point")
        }
    }

    override func mouseMoved(_ e: ToolEvent) { hover = e.doc }

    override func keyDown(_ e: NSEvent) -> Bool {
        guard [36, 53, 76].contains(e.keyCode) else { return false }
        // Return / Esc end the path being drawn; pressed again they deselect (hide) the active path, like Photoshop
        if target != nil { finish() } else if let d = doc { PathOps.deselectPath(d) }
        return true
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let d = doc else { return }
        if kind == .freeformPen, freeform.count > 1 {
            let p = CGMutablePath()
            p.addLines(between: freeform.map { canvas.docToView($0) })
            OverlayStyle.accentStroke(ctx, p, width: 1.5)
            return
        }
        if let t = target ?? VectorEditing.currentTarget(d), let path = VectorEditing.path(d, t) {
            VectorEditing.drawPath(ctx, path, canvas: canvas, anchors: true, selected: target != nil ? lastIndexSet(path) : [])
            // rubber band
            if target != nil, let si = subIndex, si < path.subpaths.count, let last = path.subpaths[si].points.last, let h = hover, !dragging {
                let p = CGMutablePath()
                p.move(to: canvas.docToView(last.anchor))
                if last.outControl != last.anchor {
                    p.addQuadCurve(to: canvas.docToView(h), control: canvas.docToView(last.outControl))
                } else {
                    p.addLine(to: canvas.docToView(h))
                }
                OverlayStyle.contrastStroke(ctx, p, dashed: true)
            }
        }
    }

    private func lastIndexSet(_ p: VectorPath) -> Set<Int> {
        guard let si = subIndex else { return [] }
        var idx = 0
        for (i, s) in p.subpaths.enumerated() {
            if i == si { return [idx + s.points.count - 1] }
            idx += s.points.count
        }
        return []
    }

    // MARK: Freeform helpers

    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var maxD: CGFloat = 0, idx = 0
        let a = pts.first!, b = pts.last!
        for i in 1..<(pts.count - 1) {
            let d = distanceToSegment(pts[i], a, b)
            if d > maxD { maxD = d; idx = i }
        }
        if maxD > epsilon {
            let l = simplify(Array(pts[0...idx]), epsilon: epsilon)
            let r = simplify(Array(pts[idx...]), epsilon: epsilon)
            return l.dropLast() + r
        }
        return [a, b]
    }

    static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let ab = b - a
        let t = clamp(((p - a).dot(ab)) / max(1e-9, ab.dot(ab)), 0, 1)
        return p.distance(to: a + ab * t)
    }

    /// Catmull-Rom → Bezier.
    static func smoothBezier(_ pts: [CGPoint]) -> [PathPoint] {
        guard pts.count > 2 else { return pts.map { PathPoint($0) } }
        var out: [PathPoint] = []
        for i in 0..<pts.count {
            let p0 = pts[max(0, i - 1)], p1 = pts[i], p2 = pts[min(pts.count - 1, i + 1)]
            let tangent = (p2 - p0) / 6
            out.append(PathPoint(anchor: p1, inControl: p1 - tangent, outControl: p1 + tangent, isSmooth: true))
        }
        out[0].inControl = out[0].anchor
        out[out.count - 1].outControl = out[out.count - 1].anchor
        return out
    }
}

// MARK: - Path selection / Direct selection

final class PathSelectTool: Tool {
    /// Component (subpath index) picked with the Path Selection tool; nil = whole path.
    static var selectedComponent: Int?
    private var selected: Set<Int> = []
    private var drag: (kind: DragKind, start: CGPoint, original: VectorPath, target: PathTarget)?
    private var baseState: DocumentState?
    private var positionLocked = false

    enum DragKind { case anchor(Int), inHandle(Int), outHandle(Int), whole }

    override var cursor: NSCursor { .arrow }

    override func activate() { selected = [] }
    /// A type-on-a-path drag interrupted by Esc or a tool switch puts the type back.
    override func cancel() { PathTextDrag.cancel() }
    override func deactivate() { PathTextDrag.cancel(); super.deactivate() }

    private func flatPoints(_ p: VectorPath) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for (si, s) in p.subpaths.enumerated() { for pi in s.points.indices { out.append((si, pi)) } }
        return out
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        // Type on a path: drag along the path moves the text, across it flips the text (Direct Selection: except on an
        // anchor / handle of the target path, which edits the path)
        if !(kind == .directSelect && targetPointHit(d, e)), PathTextDrag.begin(d, e, canvas: canvas, viaPathTool: true) { return }
        // Pick a shape layer under the cursor if clicking outside the current target
        var target = VectorEditing.currentTarget(d)
        if let pid = VectorEditing.workPathHit(d, e.doc, tolerance: 5 / canvas.zoom, interior: true) {
            // the active work path's outline wins over shape layers: it is what the user sees under the cursor
            if target != .workPath(pid) { selected = [] }
            VectorEditing.pickWorkPath(d, pid)
            target = .workPath(pid)
        } else if kind == .pathSelect || target == nil {
            if let id = AppActions.layerAt(e.doc, shapesOnly: true) {
                VectorEditing.pickWorkPath(d, nil)
                d.selectLayer(id)
                target = .layer(id)
                selected = []
            }
        }
        guard let t = target, let path = VectorEditing.path(d, t) else { return }
        positionLocked = false
        if let id = t.layerID, let l = d.state.layer(id) {
            if !canModify(l) { return }                       // fully locked: nothing can be edited
            positionLocked = l.locks.positionLocked            // position lock: anchors yes, moving the layer no
        }
        baseState = d.state
        if kind == .pathSelect {
            PathSelectTool.selectedComponent = nil
            if path.subpaths.count > 1 {
                let tol = 5 / canvas.zoom
                for (i, sp) in path.subpaths.enumerated().reversed() {
                    var c = sp; c.closed = true
                    let cp = c.cgPath
                    if cp.contains(e.doc) || cp.copy(strokingWithWidth: tol * 2, lineCap: .round, lineJoin: .round, miterLimit: 4).contains(e.doc) {
                        PathSelectTool.selectedComponent = i
                        break
                    }
                }
            }
            app.sessionTick += 1
        }
        if kind == .directSelect {
            let flat = flatPoints(path)
            // handles of selected anchors first
            for (i, (si, pi)) in flat.enumerated() where selected.contains(i) {
                let pt = path.subpaths[si].points[pi]
                if pt.inControl != pt.anchor, canvas.docToView(pt.inControl).distance(to: e.view) < 6 {
                    drag = (.inHandle(i), e.doc, path, t); return
                }
                if pt.outControl != pt.anchor, canvas.docToView(pt.outControl).distance(to: e.view) < 6 {
                    drag = (.outHandle(i), e.doc, path, t); return
                }
            }
            for (i, (si, pi)) in flat.enumerated() {
                let pt = path.subpaths[si].points[pi]
                if canvas.docToView(pt.anchor).distance(to: e.view) < 6 {
                    if e.option {
                        // toggle smooth / corner
                        var np = path
                        var q = np.subpaths[si].points[pi]
                        if q.hasHandles { q.inControl = q.anchor; q.outControl = q.anchor; q.isSmooth = false }
                        else {
                            let prev = np.subpaths[si].points[max(0, pi - 1)].anchor
                            let next = np.subpaths[si].points[min(np.subpaths[si].points.count - 1, pi + 1)].anchor
                            let tan = (next - prev) / 4
                            q.inControl = q.anchor - tan; q.outControl = q.anchor + tan; q.isSmooth = true
                        }
                        np.subpaths[si].points[pi] = q
                        VectorEditing.setPath(d, t, np)
                        d.commit("Convert Point")
                        return
                    }
                    if e.shift { if selected.contains(i) { selected.remove(i) } else { selected.insert(i) } } else if !selected.contains(i) { selected = [i] }
                    drag = (.anchor(i), e.doc, path, t)
                    return
                }
            }
            if !path.cgPath.boundingBoxOfPath.insetBy(dx: -4 / canvas.zoom, dy: -4 / canvas.zoom).contains(e.doc) { selected = [] }
        }
        drag = (.whole, e.doc, path, t)
    }

    /// Direct Selection: `e` is on an anchor (or a selected anchor's handle) of the path it edits.
    private func targetPointHit(_ d: Document, _ e: ToolEvent) -> Bool {
        guard let t = VectorEditing.currentTarget(d), let path = VectorEditing.path(d, t) else { return false }
        for (i, (si, pi)) in flatPoints(path).enumerated() {
            let pt = path.subpaths[si].points[pi]
            if canvas.docToView(pt.anchor).distance(to: e.view) < 6 { return true }
            if selected.contains(i), [pt.inControl, pt.outControl].contains(where: { $0 != pt.anchor && canvas.docToView($0).distance(to: e.view) < 6 }) { return true }
        }
        return false
    }

    override func mouseDragged(_ e: ToolEvent) {
        if PathTextDrag.drag(e, canvas: canvas) { return }
        guard let d = doc, let dr = drag else { return }
        let delta = e.doc - dr.start
        let flat = flatPoints(dr.original)
        var np = dr.original
        switch dr.kind {
        case .whole:
            if kind == .pathSelect, let ci = PathSelectTool.selectedComponent, ci < np.subpaths.count {
                np.subpaths[ci] = Subpath(points: np.subpaths[ci].points.map { $0.mapped { $0 + delta } }, closed: np.subpaths[ci].closed, operation: np.subpaths[ci].operation)
                break
            }
            if case .typePath = dr.target, positionLocked { return }
            if case .layer(let id) = dr.target, let base = baseState {
                if positionLocked { return }
                var st = base
                st.updateLayer(id) { $0.translate(dx: Double(delta.x), dy: Double(delta.y)) }
                d.state = st
                return
            }
            np = dr.original.mapped { $0 + delta }
        case .anchor:
            for i in selected where i < flat.count {
                let (si, pi) = flat[i]
                np.subpaths[si].points[pi] = np.subpaths[si].points[pi].mapped { $0 + delta }
            }
        case .inHandle(let i), .outHandle(let i):
            let (si, pi) = flat[i]
            var q = np.subpaths[si].points[pi]
            let isIn: Bool = { if case .inHandle = dr.kind { return true }; return false }()
            if isIn {
                q.inControl = q.inControl + delta
                if q.isSmooth && !e.option {
                    let len = q.outControl.distance(to: q.anchor)
                    q.outControl = q.anchor + (q.anchor - q.inControl).normalized * len
                } else if e.option { q.isSmooth = false }
            } else {
                q.outControl = q.outControl + delta
                if q.isSmooth && !e.option {
                    let len = q.inControl.distance(to: q.anchor)
                    q.inControl = q.anchor + (q.anchor - q.outControl).normalized * len
                } else if e.option { q.isSmooth = false }
            }
            np.subpaths[si].points[pi] = q
        }
        VectorEditing.setPath(d, dr.target, np)
    }

    override func mouseUp(_ e: ToolEvent) {
        if PathTextDrag.end(e, canvas: canvas) { return }
        guard let d = doc, let dr = drag else { return }
        if e.doc.distance(to: dr.start) > 0.01 { d.commit(kind == .directSelect ? "Edit Path" : "Move Path") }
        drag = nil
        baseState = nil
    }

    override func keyDown(_ e: NSEvent) -> Bool {
        if [36, 53, 76].contains(e.keyCode), drag == nil, PathTextDrag.active == nil, let d = doc {
            // Return / Esc: deselect the anchors, then the path itself (its outline is hidden)
            if !selected.isEmpty { selected = [] } else { PathOps.deselectPath(d) }
            return true
        }
        guard e.keyCode == 51 || e.keyCode == 117, let d = doc, let t = VectorEditing.currentTarget(d), var p = VectorEditing.path(d, t), !selected.isEmpty else { return false }
        if let id = t.layerID, let l = d.state.layer(id), !canModify(l) { return true }
        let flat = flatPoints(p)
        for i in selected.sorted(by: >) where i < flat.count {
            let (si, pi) = flat[i]
            p.subpaths[si].points.remove(at: pi)
        }
        p.subpaths.removeAll { $0.points.isEmpty }
        selected = []
        VectorEditing.setPath(d, t, p)
        d.commit("Delete Anchor Point")
        return true
    }

    override func drawOverlay(_ ctx: CGContext) {
        PathTextDrag.drawMarker(ctx, canvas: canvas)
        guard let d = doc, let t = VectorEditing.currentTarget(d), let p = VectorEditing.path(d, t) else { return }
        VectorEditing.drawPath(ctx, p, canvas: canvas, anchors: kind == .directSelect, selected: selected)
        if kind == .pathSelect {
            var b = p.bounds
            if let ci = PathSelectTool.selectedComponent, ci < p.subpaths.count { b = p.subpaths[ci].cgPath.boundingBoxOfPath }
            OverlayStyle.contrastStroke(ctx, CGPath(rect: canvas.docToView(b), transform: nil), dashed: true)
        }
    }
}

// MARK: - Shape tools

final class ShapeTool: Tool {
    private var start: CGPoint?
    private var current: CGPoint?
    private var fromCenter = false
    private var constrain = false

    override var cursor: NSCursor { .crosshair }

    override func activate() { ToolModes.restore(kind) }

    /// End point of the Line tool (⇧ snaps to 45°).
    private func lineEnd(_ s: CGPoint, _ c: CGPoint) -> CGPoint {
        guard constrain else { return c }
        let dd = c - s
        let a = (atan2(dd.y, dd.x) / (.pi / 4)).rounded() * (.pi / 4)
        return s + CGPoint(x: cos(a) * dd.length, y: sin(a) * dd.length)
    }

    /// The outline added in Path mode: the Line tool draws a 2-anchor open path along the drag, like Photoshop
    /// (weight and arrowheads belong to Shape and Pixels mode); the other tools add their geometry's outline.
    private func pathModePath() -> VectorPath? {
        if kind == .line, let s = start, let c = current {
            return VectorPath(subpaths: [Subpath(points: [PathPoint(s), PathPoint(lineEnd(s, c))])])
        }
        return geometry()?.vectorPath
    }

    private func geometry() -> ShapeGeometry? {
        guard var s = start, var c = current else { return nil }
        let st = app.shapeTool
        if kind == .line {
            return LineArrows.geometry(s, lineEnd(s, c), weight: st.lineWeight)
        }
        if constrain {
            let w = abs(c.x - s.x), h = abs(c.y - s.y), m = max(w, h)
            c = CGPoint(x: s.x + (c.x >= s.x ? m : -m), y: s.y + (c.y >= s.y ? m : -m))
        }
        if fromCenter { s = s - (c - s) }
        let r = CGRect(p1: s, p2: c)
        switch kind {
        case .rectangle: return .rectangle(r, cornerRadius: 0)
        case .roundedRect: return .rectangle(r, cornerRadius: st.cornerRadius)
        case .ellipse: return .ellipse(r)
        case .polygon: return .polygon(r, sides: st.sides, starRatio: 1)
        case .customShape: return .polygon(r, sides: st.sides < 3 ? 5 : st.sides, starRatio: st.starRatio)
        case .libraryShape: return .library(st.libraryID, r)
        default: return nil
        }
    }

    override func mouseDown(_ e: ToolEvent) {
        start = canvas.snap(e.doc)
        current = start
    }

    /// Path mode: Return / Esc deselect (hide) the active path, like the path tools.
    override func keyDown(_ e: NSEvent) -> Bool {
        guard [36, 53, 76].contains(e.keyCode), start == nil, app.shapeTool.mode == .path, let d = doc, d.activePathID != nil else { return false }
        PathOps.deselectPath(d)
        return true
    }

    override func mouseDragged(_ e: ToolEvent) {
        current = canvas.snap(e.doc)
        constrain = e.shift
        fromCenter = e.option
    }

    override func mouseUp(_ e: ToolEvent) {
        defer { start = nil; current = nil }
        guard let d = doc, let s = start, let c = current, let g = geometry() else { return }
        if s.distance(to: c) < 2 { return }
        let op = app.shapeTool.operation
        switch app.shapeTool.mode {
        case .shape:
            if let op, let id = d.activeLayerID, let existing = d.state.layer(id)?.shape {
                var p = existing.path
                p.subpaths += g.vectorPath.withOperation(op).subpaths
                VectorEditing.setPath(d, .layer(id), p)
                d.commit("Combine Shapes")
            } else {
                _ = VectorEditing.newShapeLayer(d, geometry: g, name: kind == .line ? "Line" : g.kindName)
                d.commit("New Shape Layer")
            }
        case .path:
            let vp = pathModePath() ?? g.vectorPath
            if let op, let pid = d.activePathID, let i = d.state.paths.firstIndex(where: { $0.id == pid }) {
                d.state.paths[i].path.subpaths += vp.withOperation(op).subpaths
            } else {
                _ = VectorEditing.newWorkPath(d, vp)
            }
            d.commit("Work Path")
        case .pixels:
            guard let (dd, id, tgt) = requirePixelTarget(), let (w, o) = dd.beginPixelEdit(layerID: id, target: tgt) else { return }
            let ctx = w.context
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(-o.x), y: CGFloat(-o.y))
            if let sel = dd.editSelection { w.clip(toMask: sel.makeCGImage(), in: dd.state.canvasCGRect) }
            let rp = g.vectorPath.resolved
            ctx.addPath(rp.path)
            ctx.setFillColor((tgt.isMask ? RGBA(gray: app.foreground.luminance) : app.foreground).cgColor)
            if rp.evenOdd { ctx.fillPath(using: .evenOdd) } else { ctx.fillPath() }
            ctx.restoreGState()
            w.markDirty()
            dd.commit(kind.displayName.replacingOccurrences(of: " Tool", with: ""))
        }
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let g = geometry() else { return }
        var t = canvas.docToViewTransform
        let preview = app.shapeTool.mode == .path ? (pathModePath() ?? g.vectorPath) : g.vectorPath
        if let p = preview.cgPath.copy(using: &t) { OverlayStyle.accentStroke(ctx, p, width: 1.5) }
        if let s = start, let c = current, let m = canvas.lastMouseView {
            OverlayStyle.label("W: \(Int(abs(c.x - s.x)))  H: \(Int(abs(c.y - s.y)))", at: m)
        }
    }
}


extension VectorEditing {
    /// Sets the Boolean operation of the selected component (or of every component but the first).
    static func setComponentOperation(_ op: PathOperation) {
        guard let d = AppActions.doc, let t = currentTarget(d), var p = path(d, t), !p.subpaths.isEmpty else { return }
        if let ci = PathSelectTool.selectedComponent, ci < p.subpaths.count {
            p.subpaths[ci].operation = op
        } else {
            for i in p.subpaths.indices.dropFirst() { p.subpaths[i].operation = op }
        }
        setPath(d, t, p)
        d.commit("Path Operation")
    }

    /// Merge Shape Components: bakes the Boolean result into plain combined outlines.
    static func mergeComponents() {
        guard let d = AppActions.doc, let t = currentTarget(d), let p = path(d, t), PathBoolean.needsResolve(p) else { NSSound.beep(); return }
        setPath(d, t, PathBoolean.merged(p))
        PathSelectTool.selectedComponent = nil
        d.commit("Merge Shape Components")
    }

    static var currentComponentOperation: PathOperation? {
        guard let d = AppActions.doc, let t = currentTarget(d), let p = path(d, t) else { return nil }
        if let ci = PathSelectTool.selectedComponent, ci < p.subpaths.count { return p.subpaths[ci].operation }
        return p.subpaths.count > 1 ? p.subpaths[1].operation : nil
    }
}
