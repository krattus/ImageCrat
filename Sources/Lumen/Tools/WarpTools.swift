import AppKit
import CoreImage
import ImageCratCore

// MARK: - Interactive sessions hosted by the Move tool

protocol InteractiveSession: AnyObject {
    var title: String { get }
    func mouseDown(_ e: ToolEvent, canvas: CanvasView)
    func mouseDragged(_ e: ToolEvent, canvas: CanvasView)
    func mouseUp(_ e: ToolEvent, canvas: CanvasView)
    func draw(_ ctx: CGContext, canvas: CanvasView)
    func commit()
    func cancel()
    func keyDown(_ e: NSEvent) -> Bool
    /// False once another command changed the layer so that the session's mesh no longer sits on it.
    var matchesDocument: Bool { get }
}

extension InteractiveSession {
    func keyDown(_ e: NSEvent) -> Bool { false }
    var matchesDocument: Bool { true }
}

enum SessionValidity {
    /// The layer still exists, can still be warped and its content bounds are the ones the session started from.
    static func layer(_ id: UUID, in doc: Document, stillHas bounds: CGRect) -> Bool {
        guard let l = doc.state.layer(id), WarpApply.canWarp(l), let b = Compositor.shared.contentBounds(l, state: doc.state) else { return false }
        return abs(b.minX - bounds.minX) < 0.5 && abs(b.minY - bounds.minY) < 0.5 && abs(b.maxX - bounds.maxX) < 0.5 && abs(b.maxY - bounds.maxY) < 0.5
    }
}

enum WarpApply {
    /// Applies a warp (from → to) to a layer. Raster: resampled; smart object: stored non-destructively; shape: path mapped.
    static func apply(_ warp: MeshWarpData, to layerID: UUID, doc d: Document, name: String) {
        guard let l = d.state.layer(layerID) else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        switch l.content {
        case .raster(let r):
            let img = MeshWarp.warp(space.place(r.buffer, at: r.origin), from: warp.from, to: warp.to, space: space)
            var rect = IRect(enclosing: space.docRect(img.extent))
            rect = rect.intersection(IRect(x: -space.width, y: -space.height, width: space.width * 3, height: space.height * 3))
            guard !rect.isEmpty else { return }
            let buf = RenderEngine.renderBuffer(img, docRect: rect, space: space)
            d.updateLayer(layerID) { $0.raster = RasterContent(buffer: buf, origin: rect.origin) }
        case .smartObject(var so):
            if let existing = so.warp {
                so.warp = MeshWarpData(from: existing.from, to: MeshGrid(cols: existing.to.cols, rows: existing.to.rows, positions: existing.to.positions.map(warp.map)))
            } else {
                so.warp = warp
            }
            d.updateLayer(layerID) { $0.smart = so }
        case .shape(var s):
            // The path takes the shape's transform and perspective with it; its segments are subdivided so that
            // straight edges and long curves can bend (mapping only the anchor points leaves a rectangle unwarped).
            s.geometry = .path(mapPath(s.path, warp.map)); s.transform = .identity; s.perspective = nil
            d.updateLayer(layerID) { $0.shape = s }
        default:
            return
        }
        // Masks linked to the layer follow the warp (like Free Transform).
        if var m = l.mask, m.isLinked {
            let img = MeshWarp.warp(space.place(m.buffer, at: m.origin), from: warp.from, to: warp.to, space: space)
            let target = IRect(enclosing: warp.to.bounds).intersection(IRect(x: -space.width, y: -space.height, width: space.width * 3, height: space.height * 3))
                .union(IRect(x: 0, y: 0, width: space.width, height: space.height))
            let bg = CIImage.color(RGBA(gray: Double(m.outsideValue) / 255), space.ciRect(target))
            m.buffer = RenderEngine.renderBuffer(img.composited(over: bg), docRect: target, space: space, format: .gray)
            m.origin = target.origin
            d.updateLayer(layerID) { $0.mask = m }
        }
        if let vm = l.vectorMask { d.updateLayer(layerID) { $0.vectorMask = mapPath(vm, warp.map) } }
        d.contentOverrides.removeValue(forKey: layerID)
        d.commit(name)
    }

    /// Maps a vector path through `f`, component by component (Boolean operations are kept). Lines are split into
    /// short pieces and curves into shorter curves first, so the result follows a non-linear mapping.
    static func mapPath(_ path: VectorPath, _ f: (CGPoint) -> CGPoint) -> VectorPath {
        var subs: [Subpath] = []
        for sp in path.subpaths where !sp.points.isEmpty {
            let out = CGMutablePath()
            var cur = CGPoint.zero, start = CGPoint.zero
            func line(to b: CGPoint) {
                let n = max(1, Int(ceil(cur.distance(to: b) / 6)))
                for i in 1...n { out.addLine(to: f(cur.lerp(b, CGFloat(i) / CGFloat(n)))) }
                cur = b
            }
            func curve(_ c1: CGPoint, _ c2: CGPoint, _ e: CGPoint) {
                let length = cur.distance(to: c1) + c1.distance(to: c2) + c2.distance(to: e)
                let n = max(1, min(64, Int(ceil(length / 20))))
                var p0 = cur, p1 = c1, p2 = c2
                let p3 = e
                for i in 0..<n {
                    // split the remaining curve at t (de Casteljau); the left part is one output piece
                    let t = 1 / CGFloat(n - i)
                    let a = p0.lerp(p1, t), b = p1.lerp(p2, t), c = p2.lerp(p3, t)
                    let ab = a.lerp(b, t), bc = b.lerp(c, t)
                    let mid = ab.lerp(bc, t)
                    out.addCurve(to: f(mid), control1: f(a), control2: f(ab))
                    p0 = mid; p1 = bc; p2 = c
                }
                cur = e
            }
            sp.cgPath.applyWithBlock { el in
                let e = el.pointee
                switch e.type {
                case .moveToPoint: cur = e.points[0]; start = cur; out.move(to: f(cur))
                case .addLineToPoint: line(to: e.points[0])
                case .addQuadCurveToPoint:
                    let q = e.points[0], end = e.points[1]
                    curve(cur.lerp(q, 2.0 / 3), end.lerp(q, 2.0 / 3), end)
                case .addCurveToPoint: curve(e.points[0], e.points[1], e.points[2])
                case .closeSubpath:
                    if cur.distance(to: start) > 0.01 { line(to: start) }
                    out.closeSubpath(); cur = start
                @unknown default: break
                }
            }
            for var m in VectorPath.from(cgPath: out).subpaths { m.operation = sp.operation; subs.append(m) }
        }
        return VectorPath(subpaths: subs)
    }

    static func canWarp(_ l: Layer) -> Bool { l.isRaster || l.isSmartObject || l.isShape }
}

// MARK: - Warp (grid + presets)

final class WarpSession: InteractiveSession {
    let doc: Document
    let layerID: UUID
    let bounds: CGRect
    var gridSize: Int { didSet { resetGrid() } }
    var control: MeshGrid
    var style: WarpStyle = .none { didSet { applyStyle() } }
    var bend: Double = 0.5 { didSet { applyStyle() } }
    var hDistort: Double = 0 { didSet { applyStyle() } }
    var vDistort: Double = 0 { didSet { applyStyle() } }
    private var dragIndex: Int?
    private var dragStart: CGPoint = .zero
    private var startControl: MeshGrid?
    let space: CanvasSpace

    var title: String { "Warp" }
    var matchesDocument: Bool { SessionValidity.layer(layerID, in: doc, stillHas: bounds) }

    init?(doc: Document, layerID: UUID) {
        guard let l = doc.state.layer(layerID), WarpApply.canWarp(l), let b = Compositor.shared.contentBounds(l, state: doc.state), b.width > 1, b.height > 1 else { return nil }
        self.doc = doc; self.layerID = layerID; self.bounds = b
        self.space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        gridSize = 4
        control = MeshGrid.regular(b, cols: 4, rows: 4)
        updatePreview()
    }

    private func resetGrid() {
        control = MeshGrid.regular(bounds, cols: gridSize, rows: gridSize)
        style = .none
        updatePreview()
    }

    private func applyStyle() {
        guard style != .none else { updatePreview(); return }
        let dense = style.mesh(bounds, bend: bend, h: hDistort, v: vDistort, cols: gridSize, rows: gridSize)
        control = dense
        updatePreview()
    }

    var destMesh: MeshGrid {
        if style != .none { return style.mesh(bounds, bend: bend, h: hDistort, v: vDistort) }
        return control.densified(cols: 40, rows: 40)
    }

    var warpData: MeshWarpData { MeshWarpData(from: MeshGrid.regular(bounds, cols: 40, rows: 40), to: destMesh) }

    func updatePreview() {
        let w = warpData, sp = space
        doc.contentOverrides[layerID] = { img in MeshWarp.warp(img, from: w.from, to: w.to, space: sp) }
        doc.setNeedsRender()
    }

    func mouseDown(_ e: ToolEvent, canvas: CanvasView) {
        dragIndex = control.positions.firstIndex { canvas.docToView($0).distance(to: e.view) < 8 }
        if dragIndex == nil, Quad(rect: bounds).path.contains(e.doc) || control.bounds.contains(e.doc) {
            dragIndex = -1   // drag the whole mesh region (moves nearest point with falloff)
        }
        if dragIndex != nil, style != .none { style = .none }
        dragStart = e.doc
        startControl = control
    }

    func mouseDragged(_ e: ToolEvent, canvas: CanvasView) {
        guard let i = dragIndex, let sc = startControl else { return }
        let d = e.doc - dragStart
        var c = sc
        if i >= 0 {
            c.positions[i] = sc.positions[i] + d
        } else {
            // drag inside: pull nearby control points with a smooth falloff (like Photoshop's warp)
            let radius = max(bounds.width, bounds.height) * 0.5
            for k in c.positions.indices {
                let w = max(0, 1 - sc.positions[k].distance(to: dragStart) / radius)
                c.positions[k] = sc.positions[k] + d * (w * w)
            }
        }
        control = c
        updatePreview()
    }

    func mouseUp(_ e: ToolEvent, canvas: CanvasView) { dragIndex = nil }

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        // grid lines through the dense mesh
        let dense = destMesh
        let step = max(1, dense.cols / max(2, (gridSize - 1) * 3))
        ctx.saveGState()
        ctx.setStrokeColor(OverlayStyle.accent.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        for r in stride(from: 0, to: dense.rows, by: step) {
            for c in 0..<dense.cols { let p = canvas.docToView(dense.point(c, r)); if c == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } }
        }
        for c in stride(from: 0, to: dense.cols, by: step) {
            for r in 0..<dense.rows { let p = canvas.docToView(dense.point(c, r)); if r == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } }
        }
        ctx.strokePath()
        ctx.restoreGState()
        if style == .none {
            for p in control.positions { OverlayStyle.circleHandle(ctx, at: canvas.docToView(p), size: 8) }
        }
    }

    func commit() {
        WarpApply.apply(warpData, to: layerID, doc: doc, name: "Warp")
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.setNeedsRender()
    }

    func cancel() {
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.setNeedsRender()
    }
}

// MARK: - Puppet Warp

final class PuppetWarpSession: InteractiveSession {
    let doc: Document
    let layerID: UUID
    let bounds: CGRect
    var pins: [(src: CGPoint, dst: CGPoint)] = []
    var density: Int = 36 { didSet { updatePreview() } }
    var rigidity: Double = 1 { didSet { updatePreview() } }
    var showMesh = true
    private var dragPin: Int?
    let space: CanvasSpace

    var title: String { "Puppet Warp" }
    var matchesDocument: Bool { SessionValidity.layer(layerID, in: doc, stillHas: bounds.insetBy(dx: 2, dy: 2)) }

    init?(doc: Document, layerID: UUID) {
        guard let l = doc.state.layer(layerID), WarpApply.canWarp(l), let b = Compositor.shared.contentBounds(l, state: doc.state), b.width > 1, b.height > 1 else { return nil }
        self.doc = doc; self.layerID = layerID; self.bounds = b.insetBy(dx: -2, dy: -2)
        self.space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        updatePreview()
    }

    var sourceMesh: MeshGrid { MeshGrid.regular(bounds, cols: density, rows: density) }

    var warpData: MeshWarpData {
        let src = sourceMesh
        let dst = MLSDeformer.deform(src, src: pins.map(\.src), dst: pins.map(\.dst), alpha: rigidity)
        return MeshWarpData(from: src, to: dst)
    }

    func updatePreview() {
        let w = warpData, sp = space
        doc.contentOverrides[layerID] = { img in MeshWarp.warp(img, from: w.from, to: w.to, space: sp) }
        doc.setNeedsRender()
    }

    func mouseDown(_ e: ToolEvent, canvas: CanvasView) {
        if let i = pins.firstIndex(where: { canvas.docToView($0.dst).distance(to: e.view) < 8 }) {
            if e.option { pins.remove(at: i); updatePreview(); return }
            dragPin = i
            return
        }
        // new pin: its source is the undeformed location under the cursor (inverse through current mesh ≈ nearest)
        let src = inverseMap(e.doc)
        pins.append((src, e.doc))
        dragPin = pins.count - 1
        updatePreview()
    }

    /// Approximate inverse of the current deformation (nearest mesh vertex search + local offset).
    private func inverseMap(_ p: CGPoint) -> CGPoint {
        guard !pins.isEmpty else { return p }
        let w = warpData
        var best = 0
        var bestD = CGFloat.infinity
        for (i, q) in w.to.positions.enumerated() { let d = q.distance(to: p); if d < bestD { bestD = d; best = i } }
        return w.from.positions[best] + (p - w.to.positions[best])
    }

    func mouseDragged(_ e: ToolEvent, canvas: CanvasView) {
        guard let i = dragPin, i < pins.count else { return }
        pins[i].dst = e.doc
        updatePreview()
    }

    func mouseUp(_ e: ToolEvent, canvas: CanvasView) { dragPin = nil }

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        if showMesh {
            let m = warpData.to
            let step = max(1, m.cols / 18)
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(white: 0.1, alpha: 0.45).cgColor)
            ctx.setLineWidth(0.5)
            for r in stride(from: 0, to: m.rows, by: step) {
                for c in 0..<m.cols { let p = canvas.docToView(m.point(c, r)); if c == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } }
            }
            for c in stride(from: 0, to: m.cols, by: step) {
                for r in 0..<m.rows { let p = canvas.docToView(m.point(c, r)); if r == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } }
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        for (i, p) in pins.enumerated() {
            let v = canvas.docToView(p.dst)
            ctx.setFillColor((i == dragPin ? NSColor.systemYellow : NSColor.systemYellow.withAlphaComponent(0.85)).cgColor)
            ctx.fillEllipse(in: CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10))
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.strokeEllipse(in: CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10))
        }
    }

    func keyDown(_ e: NSEvent) -> Bool {
        if (e.keyCode == 51 || e.keyCode == 117), !pins.isEmpty { pins.removeLast(); updatePreview(); return true }
        return false
    }

    func commit() {
        if !pins.isEmpty { WarpApply.apply(warpData, to: layerID, doc: doc, name: "Puppet Warp") }
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.setNeedsRender()
    }

    func cancel() {
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.setNeedsRender()
    }
}

// MARK: - Perspective Warp

/// Piecewise-projective warp over a small grid of planes (1–2 × 1–2).
final class PerspectiveWarpSession: InteractiveSession {
    enum Mode: String, CaseIterable { case layout = "Layout", warp = "Warp" }
    let doc: Document
    let layerID: UUID
    var mode: Mode = .layout { didSet { if mode == .warp { warped = layout }; updatePreview() } }
    var planesX = 1, planesY = 1
    /// Control points ((planesX+1) × (planesY+1)) in layout and warped positions.
    var layout: [CGPoint]
    var warped: [CGPoint]
    private var drag: Int?
    private var dragStart: CGPoint = .zero
    private var startPts: [CGPoint] = []
    let space: CanvasSpace
    private let startBounds: CGRect

    var title: String { "Perspective Warp" }
    var matchesDocument: Bool { SessionValidity.layer(layerID, in: doc, stillHas: startBounds) }

    init?(doc: Document, layerID: UUID) {
        guard let l = doc.state.layer(layerID), WarpApply.canWarp(l), let b = Compositor.shared.contentBounds(l, state: doc.state), b.width > 1, b.height > 1 else { return nil }
        self.doc = doc; self.layerID = layerID
        startBounds = b
        self.space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        layout = Quad(rect: b).points
        layout = [layout[0], layout[1], layout[3], layout[2]]   // row-major: tl, tr, bl, br
        warped = layout
    }

    func index(_ c: Int, _ r: Int) -> Int { r * (planesX + 1) + c }

    /// Splits the planes (layout mode only).
    func split(horizontal: Bool) {
        guard mode == .layout else { return }
        if horizontal, planesX == 1 {
            var n: [CGPoint] = []
            for r in 0...planesY { let a = layout[index(0, r)], b = layout[index(1, r)]; n += [a, a.lerp(b, 0.5), b] }
            planesX = 2; layout = n
        } else if !horizontal, planesY == 1 {
            var n: [CGPoint] = []
            let cols = planesX + 1
            let top = Array(layout[0..<cols]), bot = Array(layout[cols..<(2 * cols)])
            n += top
            n += zip(top, bot).map { $0.lerp($1, 0.5) }
            n += bot
            planesY = 2; layout = n
        }
        warped = layout
        updatePreview()
    }

    var warpData: MeshWarpData {
        // dense grid per plane mapped by its homography, merged into one regular source grid
        let per = 16
        let cols = planesX * per + 1, rows = planesY * per + 1
        var from: [CGPoint] = [], to: [CGPoint] = []
        let lb = CGRect.bounding(layout)
        for r in 0..<rows {
            for c in 0..<cols {
                let pc = min(planesX - 1, c / per), pr = min(planesY - 1, r / per)
                let u = CGFloat(c - pc * per) / CGFloat(per), v = CGFloat(r - pr * per) / CGFloat(per)
                let lq = Quad(tl: layout[index(pc, pr)], tr: layout[index(pc + 1, pr)], br: layout[index(pc + 1, pr + 1)], bl: layout[index(pc, pr + 1)])
                let wq = Quad(tl: warped[index(pc, pr)], tr: warped[index(pc + 1, pr)], br: warped[index(pc + 1, pr + 1)], bl: warped[index(pc, pr + 1)])
                // source point in the layout plane (bilinear), destination via plane homography
                let sp = lq.tl.lerp(lq.tr, u).lerp(lq.bl.lerp(lq.br, u), v)
                let dp = Homography(from: lq, to: wq)?.apply(sp) ?? sp
                from.append(sp); to.append(dp)
            }
        }
        _ = lb
        return MeshWarpData(from: MeshGrid(cols: cols, rows: rows, positions: from), to: MeshGrid(cols: cols, rows: rows, positions: to))
    }

    func updatePreview() {
        guard mode == .warp else { doc.contentOverrides.removeValue(forKey: layerID); doc.setNeedsRender(); return }
        let w = warpData, sp = space
        doc.contentOverrides[layerID] = { img in MeshWarp.warp(img, from: w.from, to: w.to, space: sp) }
        doc.setNeedsRender()
    }

    func mouseDown(_ e: ToolEvent, canvas: CanvasView) {
        let pts = mode == .layout ? layout : warped
        drag = pts.firstIndex { canvas.docToView($0).distance(to: e.view) < 9 }
        dragStart = e.doc
        startPts = pts
    }

    func mouseDragged(_ e: ToolEvent, canvas: CanvasView) {
        guard let i = drag else { return }
        var p = startPts
        var d = e.doc - dragStart
        if e.shift, mode == .warp { if abs(d.x) > abs(d.y) { d.y = 0 } else { d.x = 0 } }
        p[i] = startPts[i] + d
        if mode == .layout { layout = p; warped = p } else { warped = p }
        updatePreview()
    }

    func mouseUp(_ e: ToolEvent, canvas: CanvasView) { drag = nil }

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        let pts = mode == .layout ? layout : warped
        ctx.saveGState()
        ctx.setStrokeColor(OverlayStyle.accent.cgColor)
        ctx.setLineWidth(1.5)
        for r in 0...planesY {
            for c in 0...planesX {
                let p = canvas.docToView(pts[index(c, r)])
                if c == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
        }
        for c in 0...planesX {
            for r in 0...planesY {
                let p = canvas.docToView(pts[index(c, r)])
                if r == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
        }
        ctx.strokePath()
        if mode == .layout {
            // grid hint inside planes
            ctx.setStrokeColor(OverlayStyle.accent.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(0.5)
            for pr in 0..<planesY { for pc in 0..<planesX {
                let q = Quad(tl: pts[index(pc, pr)], tr: pts[index(pc + 1, pr)], br: pts[index(pc + 1, pr + 1)], bl: pts[index(pc, pr + 1)])
                for k in 1..<4 {
                    let t = CGFloat(k) / 4
                    ctx.move(to: canvas.docToView(q.tl.lerp(q.tr, t))); ctx.addLine(to: canvas.docToView(q.bl.lerp(q.br, t)))
                    ctx.move(to: canvas.docToView(q.tl.lerp(q.bl, t))); ctx.addLine(to: canvas.docToView(q.tr.lerp(q.br, t)))
                }
            } }
            ctx.strokePath()
        }
        ctx.restoreGState()
        for p in pts { OverlayStyle.handle(ctx, at: canvas.docToView(p), size: 8) }
    }

    func commit() {
        if mode == .warp, warped != layout { WarpApply.apply(warpData, to: layerID, doc: doc, name: "Perspective Warp") }
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.setNeedsRender()
    }

    func cancel() {
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.setNeedsRender()
    }
}

// MARK: - Content-Aware Scale

final class ContentAwareScaleSession: InteractiveSession {
    let doc: Document
    let layerID: UUID
    let source: CGRect
    var target: CGRect
    var amount: Double = 100
    var protectChannel: UUID? = nil
    private var dragHandle: Int?     // 0…7 edges/corners, 8 = move
    private var dragStart: CGPoint = .zero
    private var startRect: CGRect = .zero
    let space: CanvasSpace

    var title: String { "Content-Aware Scale" }
    var matchesDocument: Bool { SessionValidity.layer(layerID, in: doc, stillHas: source) }

    init?(doc: Document, layerID: UUID) {
        guard let l = doc.state.layer(layerID), l.isRaster, let b = Compositor.shared.contentBounds(l, state: doc.state), b.width > 2, b.height > 2 else { return nil }
        self.doc = doc; self.layerID = layerID
        source = b.integral; target = source
        space = CanvasSpace(width: doc.state.width, height: doc.state.height)
    }

    func updatePreview() {
        let s = source, t = target, sp = space
        let h = Homography(from: Quad(rect: s), to: Quad(rect: t)) ?? .identity
        doc.contentOverrides[layerID] = { img in img.applyingHomography(h, space: sp) }
        doc.setNeedsRender()
    }

    private func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    func mouseDown(_ e: ToolEvent, canvas: CanvasView) {
        dragHandle = handlePoints(target).firstIndex { canvas.docToView($0).distance(to: e.view) < 8 } ?? (target.contains(e.doc) ? 8 : nil)
        dragStart = e.doc; startRect = target
    }

    func mouseDragged(_ e: ToolEvent, canvas: CanvasView) {
        guard let h = dragHandle else { return }
        let d = e.doc - dragStart
        var x0 = startRect.minX, y0 = startRect.minY, x1 = startRect.maxX, y1 = startRect.maxY
        switch h {
        case 8: x0 += d.x; x1 += d.x; y0 += d.y; y1 += d.y
        default:
            if [0, 6, 7].contains(h) { x0 += d.x }
            if [2, 3, 4].contains(h) { x1 += d.x }
            if [0, 1, 2].contains(h) { y0 += d.y }
            if [4, 5, 6].contains(h) { y1 += d.y }
        }
        target = CGRect(p1: CGPoint(x: x0, y: y0), p2: CGPoint(x: x1, y: y1)).integral
        updatePreview()
    }

    func mouseUp(_ e: ToolEvent, canvas: CanvasView) { dragHandle = nil }

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        OverlayStyle.accentStroke(ctx, canvas.docToViewPath(target))
        for p in handlePoints(target) { OverlayStyle.handle(ctx, at: canvas.docToView(p)) }
    }

    func commit() {
        defer { doc.contentOverrides.removeValue(forKey: layerID); doc.setNeedsRender() }
        guard target != source, target.width >= 2, target.height >= 2, let l = doc.state.layer(layerID), let r = l.raster else { return }
        let local = IRect(enclosing: source.offsetBy(dx: CGFloat(-r.origin.x), dy: CGFloat(-r.origin.y))).intersection(r.buffer.bounds)
        let crop = r.buffer.cropped(to: local)
        var protect: PixelBuffer? = nil
        if let ch = protectChannel, let a = doc.state.alphaChannels.first(where: { $0.id == ch }) {
            protect = a.buffer.cropped(to: IRect(enclosing: source))
        }
        AppModel.shared.setStatus("Content-aware scaling…")
        guard target.width.isFinite, target.height.isFinite else { return }
        let scaled = ContentAwareScale.scale(crop, newWidth: min(maxCanvasDimension, Int(target.width)), newHeight: min(maxCanvasDimension, Int(target.height)), protect: protect, amount: amount / 100)
        // replace the content region
        guard let (w, o) = doc.beginPixelEdit(layerID: layerID, target: .content) else { return }
        let ctx = w.context
        ctx.saveGState()
        ctx.setBlendMode(.clear)
        ctx.fill(source.offsetBy(dx: CGFloat(-o.x), dy: CGFloat(-o.y)))
        ctx.restoreGState()
        w.drawImage(scaled.makeCGImage(), in: target.offsetBy(dx: CGFloat(-o.x), dy: CGFloat(-o.y)), blend: .normal)
        w.markDirty()
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.commit("Content-Aware Scale")
        AppModel.shared.setStatus("")
    }

    func cancel() {
        // drop the live preview (it used to stay on the layer after Esc)
        doc.contentOverrides.removeValue(forKey: layerID)
        doc.setNeedsRender()
    }
}
