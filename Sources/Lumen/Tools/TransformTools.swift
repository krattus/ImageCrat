import AppKit
import CoreImage
import ImageCratCore

extension CIImage {
    /// Applies a doc-space homography to a CI-space image.
    func applyingHomography(_ h: Homography, space: CanvasSpace) -> CIImage {
        if h.isAffine {
            return transformed(by: space.ciTransform(h.affine), highQualityDownsample: true)
        }
        let ext = extent
        if ext.isInfinite || ext.isEmpty { return self }
        let docR = space.docRect(ext)
        let q = h.mapRect(docR).mapped { space.ciPoint($0) }
        return applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(cgPoint: q.tl), "inputTopRight": CIVector(cgPoint: q.tr),
            "inputBottomRight": CIVector(cgPoint: q.br), "inputBottomLeft": CIVector(cgPoint: q.bl),
        ])
    }
}

enum TransformHandle: Equatable {
    case corner(Int)      // 0 tl, 1 tr, 2 br, 3 bl
    case edge(Int)        // 0 top, 1 right, 2 bottom, 3 left
    case rotate
    case move
    case reference
}

/// An interactive free-transform session over one or more layers (or a floating selection).
final class TransformSession {
    let doc: Document
    let layerIDs: [UUID]
    let sourceQuad: Quad
    var quad: Quad
    var reference: CGPoint
    private var floating: (id: UUID, buffer: PixelBuffer, origin: IPoint)?
    /// The layer buffer the floating pixels were cut out of (uncommitted working copy).
    private var floatingBase: PixelBuffer?
    private var selectionAtStart: PixelBuffer?
    let space: CanvasSpace
    var isFloating: Bool { floating != nil }

    // drag state
    private var dragHandle: TransformHandle?
    private var dragStartQuad: Quad?
    private var dragStartPoint: CGPoint = .zero
    private var dragStartRef: CGPoint = .zero

    /// Transforms only the selection outline (Select ▸ Transform Selection).
    private(set) var selectionOnly = false

    init?(selectionOf doc: Document) {
        guard let sel = doc.state.selection, let b = sel.opaqueBounds() else { return nil }
        self.doc = doc
        self.space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        layerIDs = []
        selectionAtStart = sel
        selectionOnly = true
        sourceQuad = Quad(rect: b.cgRect)
        quad = sourceQuad
        reference = sourceQuad.center
        doc.showSelectionEdges = false
        doc.setNeedsOverlay()
    }

    /// The layers a transform of `layerIDs` moves (a group moves its children; position-locked layers stay).
    private static func movableLayers(_ doc: Document, _ layerIDs: [UUID]) -> [Layer] {
        doc.withoutDescendants(layerIDs).compactMap { doc.state.layer($0) }.filter { !$0.locks.positionLocked }
    }

    /// A single raster layer with a selection transforms the selected pixels (floating selection).
    private static func floats(_ doc: Document, _ layers: [Layer], useSelection: Bool) -> Bool {
        useSelection && layers.count == 1 && layers[0].isRaster && doc.state.selection?.opaqueBounds() != nil && doc.editTarget == .content
    }

    /// Whether a session for these layers would start (without starting one): the initializer's own tests, so the
    /// commands that start one can be disabled exactly when they would only say "Nothing to transform".
    static func canStart(doc: Document, layerIDs: [UUID], useSelection: Bool = true) -> Bool {
        let layers = movableLayers(doc, layerIDs)
        guard !layers.isEmpty else { return false }
        return floats(doc, layers, useSelection: useSelection) || contentQuad(layers, in: doc.state) != nil
    }

    init?(doc: Document, layerIDs: [UUID], useSelection: Bool = true) {
        self.doc = doc
        self.space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        let layers = TransformSession.movableLayers(doc, layerIDs)
        guard !layers.isEmpty else { return nil }
        self.layerIDs = layers.map(\.id)
        selectionAtStart = doc.state.selection

        // Floating pixel selection on a single raster layer
        if TransformSession.floats(doc, layers, useSelection: useSelection), let l = layers.first, let sel = doc.state.selection, let selB = sel.opaqueBounds() {
            guard let (working, origin) = doc.beginPixelEdit(layerID: l.id, target: .content, coverCanvas: false) else { return nil }
            let fl = PixelBuffer(width: working.width, height: working.height)
            let selImg = sel.makeCGImage()
            let canvasInBuf = CGRect(x: -origin.x, y: -origin.y, width: doc.state.width, height: doc.state.height)
            fl.context.saveGState()
            fl.clip(toMask: selImg, in: canvasInBuf)
            fl.drawImage(working.makeCGImage(), in: CGRect(x: 0, y: 0, width: working.width, height: working.height))
            fl.context.restoreGState()
            fl.markDirty()
            working.context.saveGState()
            working.clip(toMask: selImg, in: canvasInBuf)
            working.context.setBlendMode(.destinationOut)
            working.context.setFillColor(RGBA.black.cgColor)
            working.context.fill(CGRect(x: 0, y: 0, width: working.width, height: working.height))
            working.context.restoreGState()
            working.markDirty()
            floating = (l.id, fl, origin)
            floatingBase = working
            let b = fl.opaqueBounds().map { $0.offsetBy(dx: origin.x, dy: origin.y).cgRect } ?? selB.cgRect
            sourceQuad = Quad(rect: b)
        } else {
            guard let q = TransformSession.contentQuad(layers, in: doc.state) else { return nil }
            sourceQuad = q
        }
        quad = sourceQuad
        reference = sourceQuad.center
        updatePreview()
    }

    /// The box a transform of these layers starts from.
    private static func contentQuad(_ layers: [Layer], in state: DocumentState) -> Quad? {
        var u: CGRect? = nil
        for l in layers {
            if let b = Compositor.shared.contentBounds(l, state: state) { u = u.map { $0.union(b) } ?? b }
        }
        guard let bounds = u, bounds.width > 0, bounds.height > 0 else { return nil }
        if layers.count == 1, let so = layers[0].smart, so.warp == nil { return so.quad }
        if layers.count == 1, let t = layers[0].text { return TextRenderer.docQuad(t) }
        return Quad(rect: bounds)
    }

    /// True while the session still describes the document: its layers exist and the box it started from still sits
    /// on their content. Another command (or a history jump) that moved, replaced or deleted them invalidates it.
    var matchesDocument: Bool {
        if selectionOnly { return doc.state.selection === selectionAtStart }
        if let f = floating { return doc.state.layer(f.id)?.raster?.buffer === floatingBase }
        let layers = layerIDs.compactMap { doc.state.layer($0) }
        guard layers.count == layerIDs.count, let q = TransformSession.contentQuad(layers, in: doc.state) else { return false }
        return zip(q.points, sourceQuad.points).allSatisfy { $0.distance(to: $1) < 0.01 }
    }

    var homography: Homography? { Homography(from: sourceQuad, to: quad) }

    func updatePreview() {
        guard let h = homography else { return }
        if selectionOnly { doc.setNeedsOverlay(); return }
        let sp = space
        if let f = floating {
            let placed = sp.place(f.buffer, at: f.origin)
            let warped = placed.applyingHomography(h, space: sp)
            doc.contentOverrides[f.id] = { img in warped.composited(over: img) }
            doc.showSelectionEdges = false
        } else {
            for id in layerIDs {
                doc.contentOverrides[id] = { img in img.applyingHomography(h, space: sp) }
            }
        }
        doc.setNeedsRender()
    }

    /// `force`: record the step even if nothing was moved (a floating selection must be put back into its layer
    /// before another command's step is recorded — reverting would throw that command's changes away).
    func commit(force: Bool = false) {
        defer { cleanup() }
        guard let h = homography else { return }
        if selectionOnly {
            if quad != sourceQuad, let sel = selectionAtStart {
                doc.state.selection = SelectionOps.transform(sel, by: h)
                doc.commit("Transform Selection")
            }
            return
        }
        if quad == sourceQuad && !(force && floating != nil) {
            if floating != nil { doc.revertUncommitted() }
            return
        }
        if let f = floating {
            let placed = space.place(f.buffer, at: f.origin)
            let warped = placed.applyingHomography(h, space: space)
            guard let layer = doc.state.layer(f.id), let r = layer.raster else { return }
            let base = space.place(r.buffer, at: r.origin)
            let combined = warped.composited(over: base)
            var docR = IRect(enclosing: space.docRect(combined.extent))
            docR = docR.intersection(IRect(x: -space.width, y: -space.height, width: space.width * 3, height: space.height * 3).union(r.frame))
            let buf = RenderEngine.renderBuffer(combined, docRect: docR, space: space)
            doc.updateLayer(f.id) { $0.raster = RasterContent(buffer: buf, origin: docR.origin) }
            if let sel = selectionAtStart, doc.state.selection === sel {      // unless another command changed it meanwhile
                doc.state.selection = SelectionOps.transform(sel, by: h)
            }
        } else {
            for id in layerIDs {
                guard let l = doc.state.layer(id) else { continue }
                let nl = LayerTransformer.apply(h, to: l, space: space)
                doc.updateLayer(id) { $0 = nl }
            }
        }
        doc.contentOverrides.removeAll()
        doc.commit("Free Transform")
    }

    func cancel() {
        cleanup()
        doc.revertUncommitted()
    }

    private func cleanup() {
        for id in layerIDs { doc.contentOverrides.removeValue(forKey: id) }
        if let f = floating { doc.contentOverrides.removeValue(forKey: f.id) }
        doc.showSelectionEdges = true
        doc.setNeedsRender()
    }

    // MARK: Interaction

    func handles(in canvas: CanvasView) -> [(TransformHandle, CGPoint)] {
        let q = quad.mapped { canvas.docToView($0) }
        let pts = q.points
        var out: [(TransformHandle, CGPoint)] = []
        for i in 0..<4 { out.append((.corner(i), pts[i])) }
        for i in 0..<4 { out.append((.edge(i), (pts[i] + pts[(i + 1) % 4]) / 2)) }
        return out
    }

    func hitTest(_ v: CGPoint, canvas: CanvasView) -> TransformHandle? {
        if canvas.docToView(reference).distance(to: v) < 7 { return .reference }
        for (h, p) in handles(in: canvas) where p.distance(to: v) < 7 { return h }
        let q = quad.mapped { canvas.docToView($0) }
        if q.path.contains(v) { return .move }
        // near corners outside → rotate
        for p in q.points where p.distance(to: v) < 28 { return .rotate }
        return .rotate
    }

    func beginDrag(_ h: TransformHandle, at p: CGPoint) {
        dragHandle = h
        dragStartQuad = quad
        dragStartPoint = p
        dragStartRef = reference
    }

    func drag(to p: CGPoint, e: ToolEvent, canvas: CanvasView) {
        guard let h = dragHandle, let q0 = dragStartQuad else { return }
        let delta = p - dragStartPoint
        switch h {
        case .move:
            var d = delta
            if e.shift { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
            quad = q0.mapped { $0 + d }
            reference = dragStartRef + d
        case .reference:
            reference = dragStartRef + delta
        case .rotate:
            let c = reference
            var a = (p - c).angle - (dragStartPoint - c).angle
            if e.shift { a = (a / (.pi / 12)).rounded() * (.pi / 12) }
            quad = q0.mapped { $0.rotated(by: a, around: c) }
        case .corner(let i):
            if e.command && e.option && e.shift {
                // perspective: move corner and mirror the horizontal neighbour
                var pts = q0.points
                let neighbour = i == 0 ? 1 : i == 1 ? 0 : i == 2 ? 3 : 2
                let edgeDir = (pts[neighbour] - pts[i]).normalized
                let along = edgeDir * delta.dot(edgeDir)
                pts[i] = pts[i] + along
                pts[neighbour] = pts[neighbour] - along
                var nq = q0; nq.points = pts; quad = nq
            } else if e.command {
                var pts = q0.points
                pts[i] = pts[i] + delta
                var nq = q0; nq.points = pts; quad = nq
            } else {
                let proportional = !e.shift
                scale(q0, fixed: e.option ? reference : q0.points[(i + 2) % 4], moving: q0.points[i], to: q0.points[i] + delta, axisU: true, axisV: true, proportional: proportional)
            }
        case .edge(let i):
            let a = q0.points[i], b = q0.points[(i + 1) % 4]
            let mid = (a + b) / 2
            if e.command {
                // skew along edge direction
                let dir = (b - a).normalized
                let along = dir * delta.dot(dir)
                var pts = q0.points
                pts[i] = pts[i] + along
                pts[(i + 1) % 4] = pts[(i + 1) % 4] + along
                var nq = q0; nq.points = pts; quad = nq
            } else {
                let opp = (q0.points[(i + 2) % 4] + q0.points[(i + 3) % 4]) / 2
                let horizontal = i == 1 || i == 3
                scale(q0, fixed: e.option ? reference : opp, moving: mid, to: mid + delta, axisU: horizontal, axisV: !horizontal, proportional: e.shift)
            }
        }
        updatePreview()
    }

    /// Scales the quad in its own (U,V) frame so that `moving` lands at `target`, keeping `fixed` in place.
    private func scale(_ q0: Quad, fixed: CGPoint, moving: CGPoint, to target: CGPoint, axisU: Bool, axisV: Bool, proportional: Bool) {
        let U = q0.tr - q0.tl, V = q0.bl - q0.tl
        let det = U.x * V.y - U.y * V.x
        guard abs(det) > 1e-6 else { return }
        func coords(_ p: CGPoint) -> (CGFloat, CGFloat) {
            ((p.x * V.y - p.y * V.x) / det, (U.x * p.y - U.y * p.x) / det)
        }
        let (ma, mb) = coords(moving - fixed)
        let (ta, tb) = coords(target - fixed)
        var sx: CGFloat = axisU && abs(ma) > 1e-6 ? ta / ma : 1
        var sy: CGFloat = axisV && abs(mb) > 1e-6 ? tb / mb : 1
        if proportional {
            if axisU && axisV {
                let s = abs(sx - 1) > abs(sy - 1) ? sx : sy
                sx = s; sy = s
            } else if axisU { sy = abs(sx) } else { sx = abs(sy) }
        }
        quad = q0.mapped { p in
            let (a, b) = coords(p - fixed)
            return fixed + U * (a * sx) + V * (b * sy)
        }
    }

    func endDrag() { dragHandle = nil; dragStartQuad = nil }

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        if selectionOnly, let sel = selectionAtStart, let h = homography {
            // live preview of the transformed marching ants
            let outline = SelectionOps.outline(sel)
            let mapped = CGMutablePath()
            outline.applyWithBlock { el in
                let e = el.pointee
                let p = canvas.docToView(h.apply(e.points[0]))
                if e.type == .moveToPoint { mapped.move(to: p) } else if e.type == .addLineToPoint { mapped.addLine(to: p) }
            }
            canvas.overlay.drawAnts(ctx, mapped, phase: canvas.antsPhase)
        }
        let q = quad.mapped { canvas.docToView($0) }
        OverlayStyle.accentStroke(ctx, q.path)
        for (h, p) in handles(in: canvas) {
            if case .corner = h { OverlayStyle.handle(ctx, at: p) } else { OverlayStyle.handle(ctx, at: p, size: 6) }
        }
        let r = canvas.docToView(reference)
        ctx.setStrokeColor(OverlayStyle.accent.cgColor)
        ctx.strokeEllipse(in: CGRect(x: r.x - 4, y: r.y - 4, width: 8, height: 8))
        ctx.move(to: CGPoint(x: r.x - 6, y: r.y)); ctx.addLine(to: CGPoint(x: r.x + 6, y: r.y))
        ctx.move(to: CGPoint(x: r.x, y: r.y - 6)); ctx.addLine(to: CGPoint(x: r.x, y: r.y + 6))
        ctx.strokePath()
    }

    var info: String {
        let b = quad.bounds
        let w = quad.tl.distance(to: quad.tr), h = quad.tl.distance(to: quad.bl)
        let sw = sourceQuad.tl.distance(to: sourceQuad.tr), sh = sourceQuad.tl.distance(to: sourceQuad.bl)
        let ang = (quad.tr - quad.tl).angle * 180 / .pi
        let o = ArtboardCoords.rulerOrigin(doc)   // (measured from the active artboard's corner, like the rulers)
        return String(format: "X: %.0f  Y: %.0f  W: %.1f%%  H: %.1f%%  ∠ %.1f°", b.midX - o.x, b.midY - o.y, w / max(1, sw) * 100, h / max(1, sh) * 100, ang)
    }
}

// MARK: - Move tool

final class MoveTool: Tool {
    private(set) var session: TransformSession? { didSet { AppModel.shared.sessionTick += 1 } }
    /// Mesh/scale sessions (Warp, Puppet Warp, Perspective Warp, Content-Aware Scale).
    var interactive: InteractiveSession? { didSet { canvas.overlay.needsDisplay = true; AppModel.shared.sessionTick += 1 } }
    private var sessionDragging = false
    private var moveStart: CGPoint?
    private var movedLayers: [UUID] = []
    private var baseState: DocumentState?
    private var lastDelta: CGPoint = .zero
    private var floatMove = false
    private var snapLines: [CGRect] = []
    private var didDuplicate = false
    /// Auto-select: the layer a click would pick right now (hover highlight), and the ⇧-drag layer marquee.
    private(set) var hoverTarget: UUID?
    private var marqueeStart: CGPoint?
    private(set) var marqueeRect: CGRect?

    override var cursor: NSCursor {
        if session != nil { return .arrow }
        return .arrow
    }

    override var isBusy: Bool { session != nil || interactive != nil }
    /// Blur Gallery pins belong to their own dialog, which decides between OK and Cancel.
    override var pendingPolicy: PendingPolicy { interactive is BlurGallerySession ? .keep : .commit }
    override func abandonPending() { if !(interactive is BlurGallerySession) { abandonSession() } }

    /// Layers Edit ▸ Free Transform acts on: the selected ones (or the active one) plus linked layers.
    static func transformLayerIDs(_ d: Document) -> [UUID] {
        d.withLinked(d.orderedSelection.isEmpty ? (d.activeLayerID.map { [$0] } ?? []) : d.orderedSelection)
    }

    func startTransform(selectionOnly: Bool = false) {
        guard let d = doc else { return }
        if session != nil { return }
        guard let s = selectionOnly ? TransformSession(selectionOf: d) : TransformSession(doc: d, layerIDs: MoveTool.transformLayerIDs(d)) else {
            status("Nothing to transform.")
            Beep.play()
            return
        }
        session = s
        canvas.overlay.needsDisplay = true
        status(s.info)
    }

    override func commit() { commitSession(force: false) }

    private func commitSession(force: Bool) {
        PendingEdits.inToolCommit = true
        defer { PendingEdits.inToolCommit = false }
        if let i = interactive { i.commit(); interactive = nil; return }
        session?.commit(force: force)
        session = nil
        canvas.overlay.needsDisplay = true
    }

    /// Another command is recording a history step while a session is pending (see `PendingEdits`).
    /// - A floating pixel selection has cut pixels out of its layer; that hole must not be recorded without them, so
    ///   the move is applied first.
    /// - A session that still sits on its layers stays open when the command left the layer stack alone (a guide was
    ///   added, the selection changed, an asynchronous result arrived …).
    /// - Otherwise (layers added, removed, reordered, replaced or moved) the session is stale and is dropped.
    func reconcileWithDocument() {
        guard let d = doc else { return }
        let sameLayers = d.state.allLayers.map(\.id) == d.committedState.allLayers.map(\.id)
        if let i = interactive {
            if i is BlurGallerySession { return }
            if i.matchesDocument && sameLayers { return }
        } else if let s = session {
            if s.matchesDocument {
                if s.isFloating { commitSession(force: true); return }
                if sameLayers { return }
            }
        } else { return }
        abandonSession()
    }

    /// Forgets the sessions without committing or reverting (see `abandonSession`).
    func clearSessions() {
        session = nil
        interactive = nil
    }

    override func cancel() {
        if let i = interactive { i.cancel(); interactive = nil; return }
        session?.cancel()
        session = nil
        canvas.overlay.needsDisplay = true
    }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if let i = interactive { i.mouseDown(e, canvas: canvas); return }
        if let s = session {
            let h = s.hitTest(e.view, canvas: canvas)
            if e.option, !s.selectionOnly, !s.isFloating, h == .move || h == nil {
                // ⌥-drag during a pending transform: apply it, then duplicate-and-move like a normal ⌥-drag
                commit()
            } else {
                if let h {
                    s.beginDrag(h, at: e.doc)
                    sessionDragging = true
                }
                return
            }
        }
        if SpacingHandles.shared.mouseDown(e, canvas: canvas) { return }   // Layout module: on-canvas spacing handles
        // Implicit transform via bounding box handles
        if app.moveShowTransform, let box = currentBoundsQuad(), let h = boxHandleHit(box, e.view) {
            startTransform()
            if let s = session {
                s.beginDrag(h, at: e.doc)
                sessionDragging = true
            }
            return
        }
        // Auto-select (⌘ inverts the setting for this click)
        setHover(nil)
        if autoSelects(e.modifiers) {
            if let id = LayerHitTester.shared.target(at: e.doc, in: d, mode: app.moveAutoSelectMode) {
                if e.shift {
                    if !d.selectedLayerIDs.contains(id) { d.selectLayer(id, extend: true) }      // ⇧ adds to the selection
                } else {
                    d.selectLayer(id)                                                         // (like Photoshop: a plain click selects just that layer;
                }                                                                             //  ⌘-drag moves a multi-selection without auto-select)
                LayerGroups.reveal(d, id)                                                     // auto-reveal in the Layers panel
            } else if e.shift {
                marqueeStart = e.doc                                                          // ⇧-drag on empty canvas: select layers by marquee
                marqueeRect = nil
                return
            }
        }
        let candidates = d.orderedSelection.isEmpty ? (d.activeLayerID.map { [$0] } ?? []) : d.orderedSelection
        // hidden layers are not moved (like locked ones)
        let ids = candidates.filter { d.state.layer($0).map { !$0.locks.positionLocked && $0.isVisible } ?? false }
        guard !ids.isEmpty else {
            let hidden = candidates.contains { d.state.layer($0)?.isVisible == false }
            status(hidden ? "Could not use the move tool because the layer is hidden." : "Could not use the move tool because the layer is locked.")
            return
        }
        // Moving selected pixels
        if d.state.selection != nil, ids.count == 1, d.state.layer(ids[0])?.isRaster == true, !e.command {
            if e.option { // duplicate selection contents first: handled as float without clearing
                AppActions.layerViaCopy()
            }
            if let s = TransformSession(doc: d, layerIDs: [d.activeLayerID ?? ids[0]]) {
                session = s
                s.beginDrag(.move, at: e.doc)
                sessionDragging = true
                floatMove = true
                return
            }
        }
        didDuplicate = false
        if e.option {
            // duplicate layers then move the copies
            AppActions.duplicateLayers(commit: false)
            didDuplicate = true
        }
        movedLayers = d.withoutDescendants(didDuplicate ? d.orderedSelection : d.withLinked(ids)).filter { d.state.layer($0).map { !$0.locks.positionLocked } ?? false }
        baseState = d.state
        moveStart = e.doc
        lastDelta = .zero
    }

    override func mouseDragged(_ e: ToolEvent) {
        if let i = interactive { i.mouseDragged(e, canvas: canvas); return }
        if let m = marqueeStart {
            marqueeRect = CGRect(x: min(m.x, e.doc.x), y: min(m.y, e.doc.y), width: abs(e.doc.x - m.x), height: abs(e.doc.y - m.y))
            canvas.overlay.needsDisplay = true
            return
        }
        if let s = session, sessionDragging {
            s.drag(to: e.doc, e: e, canvas: canvas)
            status(s.info)
            return
        }
        if SpacingHandles.shared.mouseDragged(e, canvas: canvas) { return }
        guard let d = doc, let start = moveStart, let base = baseState else { return }
        var delta = e.doc - start
        if e.shift { if abs(delta.x) > abs(delta.y) { delta.y = 0 } else { delta.x = 0 } }
        delta = CGPoint(x: delta.x.rounded(), y: delta.y.rounded())
        // Snap moved bounds to guides / canvas
        snapLines = []
        if d.snapEnabled, let b = unionBounds(base) {
            let moved = b.offsetBy(dx: delta.x, dy: delta.y)
            let t = 6 / canvas.zoom
            var xs: [CGFloat] = [0, CGFloat(d.state.width) / 2, CGFloat(d.state.width)]
            var ys: [CGFloat] = [0, CGFloat(d.state.height) / 2, CGFloat(d.state.height)]
            if d.showGuides { for g in d.state.guides { if g.isVertical { xs.append(g.position) } else { ys.append(g.position) } } }
            var bestX: CGFloat? = nil, bestY: CGFloat? = nil
            for x in xs { for v in [moved.minX, moved.midX, moved.maxX] where abs(v - x) < t && (bestX == nil || abs(x - v) < abs(bestX!)) { bestX = x - v } }
            for y in ys { for v in [moved.minY, moved.midY, moved.maxY] where abs(v - y) < t && (bestY == nil || abs(y - v) < abs(bestY!)) { bestY = y - v } }
            if let bx = bestX { delta.x += bx.rounded() }
            if let by = bestY { delta.y += by.rounded() }
        }
        if let b = unionBounds(base) {   // Smart Guides: snap to other layers, show alignment lines and distances
            delta = SmartGuides.shared.adjust(delta, moving: b, doc: d, movedIDs: movedLayers, zoom: canvas.zoom, snap: d.snapEnabled && !e.control)
        }
        guard delta != lastDelta else { return }
        lastDelta = delta
        var st = base
        for id in movedLayers {
            st.updateLayer(id) { $0.translate(dx: Double(delta.x), dy: Double(delta.y)) }
        }
        d.state = st
        status("Δ X: \(Int(delta.x))  Δ Y: \(Int(delta.y))")
    }

    override func mouseUp(_ e: ToolEvent) {
        if let i = interactive { i.mouseUp(e, canvas: canvas); return }
        if marqueeStart != nil {
            if let r = marqueeRect, r.width >= 1 || r.height >= 1, let d = doc {
                for id in LayerHitTester.shared.layers(in: r, of: d, mode: app.moveAutoSelectMode).reversed() where !d.selectedLayerIDs.contains(id) {
                    d.selectLayer(id, extend: true)
                }
            }
            marqueeStart = nil
            marqueeRect = nil
            canvas.overlay.needsDisplay = true
            return
        }
        if let s = session, sessionDragging {
            s.endDrag()
            sessionDragging = false
            if floatMove {
                floatMove = false
                commit()
            }
            return
        }
        if SpacingHandles.shared.mouseUp(e, canvas: canvas) { return }
        if moveStart != nil, let d = doc {
            if didDuplicate { ArtboardOps.movedCopies = Set(movedLayers) }   // ⌥-drag copies are nested by where they land
            if lastDelta != .zero { d.commit(didDuplicate ? "Duplicate & Move" : "Move") }
            else if didDuplicate { d.commit("Duplicate Layer") }
        }
        moveStart = nil
        baseState = nil
        movedLayers = []
        snapLines = []
        SmartGuides.shared.clear()
    }

    /// Whether a click with these modifiers auto-selects: the setting, inverted while ⌘ is held (like Photoshop).
    func autoSelects(_ m: NSEvent.ModifierFlags) -> Bool { app.moveAutoSelect != m.contains(.command) }

    /// The layer a click at `p` would pick with these modifiers (nil: auto-select is off, or nothing is there).
    func hoverCandidate(at p: CGPoint, modifiers m: NSEvent.ModifierFlags) -> UUID? {
        guard let d = doc, session == nil, interactive == nil, moveStart == nil, autoSelects(m) else { return nil }
        return LayerHitTester.shared.target(at: p, in: d, mode: app.moveAutoSelectMode)
    }

    private func setHover(_ id: UUID?) {
        guard id != hoverTarget else { return }
        hoverTarget = id
        canvas.overlay.needsDisplay = true
    }

    override func flagsChanged(_ m: NSEvent.ModifierFlags) {
        if let v = canvas.lastMouseView { setHover(hoverCandidate(at: canvas.viewToDoc(v), modifiers: m)) }
    }

    override func deactivate() {
        setHover(nil)
        super.deactivate()
    }

    override func mouseMoved(_ e: ToolEvent) {
        setHover(hoverCandidate(at: e.doc, modifiers: e.modifiers))
        guard let s = session else { return }
        let h = s.hitTest(e.view, canvas: canvas)
        switch h {
        case .rotate: NSCursor.crosshair.set()
        case .move: NSCursor.openHand.set()
        case .corner, .edge: NSCursor.pointingHand.set()
        default: NSCursor.arrow.set()
        }
    }

    private func unionBounds(_ st: DocumentState) -> CGRect? {
        var u: CGRect? = nil
        for id in movedLayers {
            if let l = st.layer(id), let b = Compositor.shared.contentBounds(l, state: st) { u = u.map { $0.union(b) } ?? b }
        }
        return u
    }

    private func currentBoundsQuad() -> Quad? {
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id), !l.isAdjustment else { return nil }
        if let so = l.smart, so.warp == nil { return so.quad }   // a mesh-warped object is boxed by what it draws
        if let t = l.text { return TextRenderer.docQuad(t) }
        guard let b = Compositor.shared.contentBounds(l, state: d.state) else { return nil }
        return Quad(rect: b)
    }

    private func boxHandleHit(_ q: Quad, _ v: CGPoint) -> TransformHandle? {
        let pts = q.mapped { canvas.docToView($0) }.points
        for i in 0..<4 where pts[i].distance(to: v) < 7 { return .corner(i) }
        for i in 0..<4 where ((pts[i] + pts[(i + 1) % 4]) / 2).distance(to: v) < 7 { return .edge(i) }
        return nil
    }

    override func drawOverlay(_ ctx: CGContext) {
        if let i = interactive { i.draw(ctx, canvas: canvas); return }
        if let s = session {
            s.draw(ctx, canvas: canvas)
            return
        }
        if let r = marqueeRect {
            ctx.saveGState()
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            OverlayStyle.accentStroke(ctx, canvas.docToViewPath(r))
            ctx.restoreGState()
        }
        // hover highlight: a thin outline of the layer a click would pick (not of the selected ones)
        if let id = hoverTarget, let d = doc, moveStart == nil, !d.selectedLayerIDs.contains(id), let path = LayerHitTester.shared.outline(id, in: d) {
            var t = canvas.docToViewTransform
            if let vp = path.copy(using: &t) { OverlayStyle.accentStroke(ctx, vp) }
        }
        if app.moveShowTransform, moveStart == nil, let q = currentBoundsQuad() {
            let vq = q.mapped { canvas.docToView($0) }
            OverlayStyle.accentStroke(ctx, vq.path)
            for (i, p) in vq.points.enumerated() {
                OverlayStyle.handle(ctx, at: p)
                OverlayStyle.handle(ctx, at: (p + vq.points[(i + 1) % 4]) / 2, size: 6)
            }
        }
    }

    override func keyDown(_ e: NSEvent) -> Bool {
        if let i = interactive {
            if e.keyCode == 36 || e.keyCode == 76 { commit(); return true }
            if e.keyCode == 53 { cancel(); return true }
            return i.keyDown(e)
        }
        if session != nil {
            if e.keyCode == 36 || e.keyCode == 76 { commit(); return true }
            if e.keyCode == 53 { cancel(); return true }
        }
        return false
    }

    override func contextMenu(_ e: ToolEvent) -> NSMenu? {
        guard let d = doc else { return nil }
        let m = NSMenu()
        // Photoshop: right-click with the Move tool lists the layers under the cursor (topmost first) to select one
        let under = LayerHitTester.shared.layers(at: e.doc, in: d)
        for id in under {
            guard let l = d.state.layer(id) else { continue }
            let item = m.addItem(withTitle: l.name, action: #selector(AutoSelectMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = AutoSelectMenuTarget.shared
            item.representedObject = id
            if d.activeLayerID == id { item.state = .on }
        }
        if !under.isEmpty { m.addItem(.separator()) }
        m.addItem(withTitle: "Free Transform", action: #selector(MenuTarget.freeTransform), keyEquivalent: "").target = MenuTarget.shared
        m.addItem(withTitle: "Flip Horizontal", action: #selector(MenuTarget.flipH), keyEquivalent: "").target = MenuTarget.shared
        m.addItem(withTitle: "Flip Vertical", action: #selector(MenuTarget.flipV), keyEquivalent: "").target = MenuTarget.shared
        m.addItem(withTitle: "Rotate 90° Clockwise", action: #selector(MenuTarget.rotateCW), keyEquivalent: "").target = MenuTarget.shared
        m.addItem(withTitle: "Rotate 90° Counter Clockwise", action: #selector(MenuTarget.rotateCCW), keyEquivalent: "").target = MenuTarget.shared
        if !AppActions.canFreeTransform { m.autoenablesItems = false; m.items.forEach { $0.isEnabled = $0.target === AutoSelectMenuTarget.shared } }
        return m
    }
}

/// Target for AppKit context menus.
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    @objc func freeTransform() { AppActions.freeTransform() }
    @objc func flipH() { AppActions.flipLayers(horizontal: true) }
    @objc func flipV() { AppActions.flipLayers(horizontal: false) }
    @objc func rotateCW() { AppActions.rotateLayers(degrees: 90) }
    @objc func rotateCCW() { AppActions.rotateLayers(degrees: -90) }
}
