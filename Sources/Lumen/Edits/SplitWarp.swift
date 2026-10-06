import SwiftUI
import AppKit
import ImageCratCore

// MARK: - Warp with split grids (Split Crosswise / Vertically / Horizontally, custom grid sizes) and Cylinder warp

enum SplitWarpMode: String, CaseIterable, Identifiable {
    case crosswise = "Split Crosswise", vertically = "Split Vertically", horizontally = "Split Horizontally"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .crosswise: return "plus.square"
        case .vertically: return "square.split.2x1"
        case .horizontally: return "square.split.1x2"
        }
    }
}

enum SplitWarpStyle: Equatable, Hashable {
    case custom
    case preset(WarpStyle)
    case cylinder

    var name: String {
        switch self {
        case .custom: return "Custom"
        case .preset(let s): return s.displayName
        case .cylinder: return "Cylinder"
        }
    }

    /// Cylinder wrap of a normalized point (0…1, y down). `bend` −1…1 sets the curvature (wrap angle up to 180°).
    static func cylinder(_ u: Double, _ v: Double, bend: Double) -> (Double, Double) {
        let theta = max(0.001, abs(bend)) * .pi
        let phi = (u - 0.5) * theta
        let x = 0.5 + sin(phi) / (2 * sin(theta / 2))
        // top and bottom edges become elliptical arcs: the centre moves most, the sides stay
        let arc = (cos(phi) - cos(theta / 2)) / max(1e-6, 1 - cos(theta / 2))
        let y = v + (bend >= 0 ? 1 : -1) * 0.16 * abs(bend) * arc
        return (x, y)
    }
}

final class SplitWarpSession: InteractiveSession {
    let doc: Document
    let layerID: UUID
    let bounds: CGRect
    let space: CanvasSpace
    /// Normalized positions (0…1) of the grid's columns and rows (split lines included).
    private(set) var xs: [Double]
    private(set) var ys: [Double]
    /// Control points, row-major (ys.count rows × xs.count columns), doc coordinates.
    var control: [CGPoint]
    var style: SplitWarpStyle = .custom { didSet { styleChanged(from: oldValue) } }
    var bend: Double = 0.5 { didSet { updatePreview() } }
    var hDistort: Double = 0 { didSet { updatePreview() } }
    var vDistort: Double = 0 { didSet { updatePreview() } }
    /// Armed split tool: the next click inside the mesh inserts split lines there.
    var splitMode: SplitWarpMode?
    var showGrid = true
    private var dragIndex: Int?
    private var dragStart: CGPoint = .zero
    private var startControl: [CGPoint] = []
    private var dragBend = false
    private var bendStart = 0.0

    var title: String { "Warp" }
    var matchesDocument: Bool { SessionValidity.layer(layerID, in: doc, stillHas: bounds) }

    init?(doc: Document, layerID: UUID) {
        guard let l = doc.state.layer(layerID), WarpApply.canWarp(l), let b = Compositor.shared.contentBounds(l, state: doc.state), b.width > 1, b.height > 1 else { return nil }
        self.doc = doc; self.layerID = layerID; self.bounds = b
        self.space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        xs = []; ys = []; control = []
        setGrid(cols: 3, rows: 3)
    }

    // MARK: Grid

    var cols: Int { xs.count - 1 }
    var rows: Int { ys.count - 1 }

    /// Regular grid of `cols` × `rows` cells (resets the warp, like Photoshop's grid menu).
    func setGrid(cols c: Int, rows r: Int) {
        xs = (0...max(1, c)).map { Double($0) / Double(max(1, c)) }
        ys = (0...max(1, r)).map { Double($0) / Double(max(1, r)) }
        control = restPositions()
        if style != .custom { style = .custom }
        updatePreview()
    }

    func rest(_ u: Double, _ v: Double) -> CGPoint {
        CGPoint(x: bounds.minX + CGFloat(u) * bounds.width, y: bounds.minY + CGFloat(v) * bounds.height)
    }

    private func restPositions() -> [CGPoint] {
        var p: [CGPoint] = []
        for v in ys { for u in xs { p.append(rest(u, v)) } }
        return p
    }

    /// Fractional grid index of a normalized coordinate among `knots`.
    private static func index(_ t: Double, _ knots: [Double]) -> Double {
        if t <= knots[0] { return 0 }
        for i in 0..<(knots.count - 1) where t <= knots[i + 1] {
            return Double(i) + (t - knots[i]) / max(1e-9, knots[i + 1] - knots[i])
        }
        return Double(knots.count - 1)
    }

    /// Smooth warp of a normalized point: rest position + interpolated control displacement (so splits at rest are exact).
    func evaluate(_ u: Double, _ v: Double) -> CGPoint {
        if style != .custom { return styled(u, v) }
        let disp = MeshGrid(cols: xs.count, rows: ys.count, positions: zip(control, restPositions()).map { $0 - $1 })
        let fu = SplitWarpSession.index(u, xs) / Double(xs.count - 1)
        let fv = SplitWarpSession.index(v, ys) / Double(ys.count - 1)
        return rest(u, v) + disp.evaluate(u: fu, v: fv)
    }

    private func styled(_ u: Double, _ v: Double) -> CGPoint {
        var (x, y): (Double, Double)
        switch style {
        case .preset(let s): (x, y) = s.map(u, v, bend: bend, h: hDistort, vd: vDistort)
        case .cylinder:
            (x, y) = SplitWarpStyle.cylinder(u, v, bend: bend)
            if hDistort != 0 { y = 0.5 + (y - 0.5) * (1 + hDistort * (x - 0.5) * 1.2) }
            if vDistort != 0 { x = 0.5 + (x - 0.5) * (1 + vDistort * (y - 0.5) * 1.2) }
        case .custom: (x, y) = (u, v)
        }
        return rest(x, y)
    }

    private func styleChanged(from old: SplitWarpStyle) {
        if style == .custom && old != .custom {
            // bake the preset into the control grid so it can be edited point by point
            let saved = style
            style = old
            var pts: [CGPoint] = []
            for v in ys { for u in xs { pts.append(evaluate(u, v)) } }
            style = saved
            control = pts
        }
        updatePreview()
    }

    /// Inserts split lines through the doc point `p` (keeps the current shape).
    func split(at p: CGPoint, mode: SplitWarpMode) {
        if style != .custom { style = .custom }
        guard let (u, v) = normalizedAt(p) else { return }
        func insert(_ t: Double, into knots: [Double]) -> (Int, [Double])? {
            guard t > 0.01, t < 0.99, !knots.contains(where: { abs($0 - t) < 0.01 }) else { return nil }
            var k = knots
            let i = k.firstIndex { $0 > t } ?? k.count
            k.insert(t, at: i)
            return (i, k)
        }
        var nx = xs, ny = ys
        if mode != .horizontally, let (_, k) = insert(u, into: xs) { nx = k }
        if mode != .vertically, let (_, k) = insert(v, into: ys) { ny = k }
        guard nx != xs || ny != ys else { return }
        var pts: [CGPoint] = []
        for vv in ny { for uu in nx { pts.append(evaluate(uu, vv)) } }
        xs = nx; ys = ny; control = pts
        updatePreview()
    }

    /// Normalized source coordinates of a doc point on the warped mesh (inverse by search on a dense grid + refinement).
    func normalizedAt(_ p: CGPoint) -> (Double, Double)? {
        let n = 48
        var best = (0.0, 0.0), bd = CGFloat.infinity
        for j in 0...n { for i in 0...n {
            let u = Double(i) / Double(n), v = Double(j) / Double(n)
            let d = evaluate(u, v).distance(to: p)
            if d < bd { bd = d; best = (u, v) }
        } }
        var (u, v) = best
        var step = 1.0 / Double(n)
        for _ in 0..<24 {
            var improved = false
            for (du, dv) in [(step, 0.0), (-step, 0), (0, step), (0, -step)] {
                let uu = clamp(u + du, 0, 1), vv = clamp(v + dv, 0, 1)
                let d = evaluate(uu, vv).distance(to: p)
                if d < bd { bd = d; u = uu; v = vv; improved = true }
            }
            if !improved { step /= 2 }
        }
        return bd < max(bounds.width, bounds.height) * 0.05 + 4 ? (u, v) : nil
    }

    var destMesh: MeshGrid {
        let n = 48
        var pts: [CGPoint] = []
        for j in 0..<n { for i in 0..<n { pts.append(evaluate(Double(i) / Double(n - 1), Double(j) / Double(n - 1))) } }
        return MeshGrid(cols: n, rows: n, positions: pts)
    }

    var warpData: MeshWarpData { MeshWarpData(from: MeshGrid.regular(bounds, cols: 48, rows: 48), to: destMesh) }

    func updatePreview() {
        let w = warpData, sp = space
        doc.contentOverrides[layerID] = { img in MeshWarp.warp(img, from: w.from, to: w.to, space: sp) }
        doc.setNeedsRender()
        AppActions.canvas?.overlay.needsDisplay = true
    }

    /// Cylinder curvature handle (top middle of the warped mesh).
    var bendHandle: CGPoint { evaluate(0.5, 0) + CGPoint(x: 0, y: -18) }

    // MARK: Events

    func mouseDown(_ e: ToolEvent, canvas: CanvasView) {
        dragStart = e.doc
        dragBend = false
        if style == .cylinder, canvas.docToView(bendHandle).distance(to: e.view) < 9 {
            dragBend = true; bendStart = bend
            return
        }
        if let m = splitMode {
            split(at: e.doc, mode: m)
            splitMode = nil
            AppModel.shared.sessionTick += 1
            return
        }
        if e.option, style == .custom, let (u, v) = normalizedAt(e.doc) {
            // ⌥-click with a split tool armed does nothing; plain ⌥-click on a split line removes it
            removeSplit(near: u, v, tolerance: 6 / Double(max(bounds.width, bounds.height)) / Double(canvas.zoom))
            return
        }
        if style == .custom {
            dragIndex = control.firstIndex { canvas.docToView($0).distance(to: e.view) < 8 }
        } else {
            dragIndex = nil
        }
        if dragIndex == nil, destMesh.bounds.contains(e.doc) {
            if style != .custom { style = .custom }
            dragIndex = -1
        }
        startControl = control
    }

    func mouseDragged(_ e: ToolEvent, canvas: CanvasView) {
        if dragBend {
            bend = clamp(bendStart + Double(e.doc.y - dragStart.y) / Double(max(1, bounds.height) * 0.16), -1, 1)
            AppModel.shared.sessionTick += 1
            return
        }
        guard let i = dragIndex else { return }
        let d = e.doc - dragStart
        var c = startControl
        if i >= 0 {
            c[i] = startControl[i] + d
        } else {
            let radius = max(bounds.width, bounds.height) * 0.5
            for k in c.indices {
                let w = max(0, 1 - startControl[k].distance(to: dragStart) / radius)
                c[k] = startControl[k] + d * (w * w)
            }
        }
        control = c
        updatePreview()
    }

    func mouseUp(_ e: ToolEvent, canvas: CanvasView) { dragIndex = nil; dragBend = false }

    /// Removes the split line (row or column) closest to (u, v) if within tolerance (never the outer border).
    func removeSplit(near u: Double, _ v: Double, tolerance: Double) {
        let ci = xs.indices.dropFirst().dropLast().min { abs(xs[$0] - u) < abs(xs[$1] - u) }
        let ri = ys.indices.dropFirst().dropLast().min { abs(ys[$0] - v) < abs(ys[$1] - v) }
        let dc = ci.map { abs(xs[$0] - u) } ?? .infinity, dr = ri.map { abs(ys[$0] - v) } ?? .infinity
        guard min(dc, dr) <= max(tolerance, 0.01) else { return }
        var pts: [[CGPoint]] = (0..<ys.count).map { r in Array(control[(r * xs.count)..<((r + 1) * xs.count)]) }
        if dc <= dr, let c = ci {
            xs.remove(at: c); for r in pts.indices { pts[r].remove(at: c) }
        } else if let r = ri {
            ys.remove(at: r); pts.remove(at: r)
        }
        control = pts.flatMap { $0 }
        updatePreview()
    }

    func keyDown(_ e: NSEvent) -> Bool { false }

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        ctx.saveGState()
        ctx.setStrokeColor(OverlayStyle.accent.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1)
        let samples = 40
        if showGrid {
            for v in ys {
                for k in 0...samples { let p = canvas.docToView(evaluate(Double(k) / Double(samples), v)); if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } }
            }
            for u in xs {
                for k in 0...samples { let p = canvas.docToView(evaluate(u, Double(k) / Double(samples))); if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } }
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
        if style == .custom {
            for v in ys { for u in xs { OverlayStyle.circleHandle(ctx, at: canvas.docToView(evaluate(u, v)), size: 8) } }
        }
        if style == .cylinder {
            let top = canvas.docToView(evaluate(0.5, 0)), h = canvas.docToView(bendHandle)
            ctx.setStrokeColor(OverlayStyle.accent.cgColor); ctx.move(to: top); ctx.addLine(to: h); ctx.strokePath()
            OverlayStyle.handle(ctx, at: h, size: 9, filled: true)
        }
        if splitMode != nil, let m = canvas.lastMouseView, let (u, v) = normalizedAt(canvas.viewToDoc(m)) {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemYellow.cgColor); ctx.setLineDash(phase: 0, lengths: [4, 3])
            if splitMode != .horizontally { for k in 0...samples { let p = canvas.docToView(evaluate(u, Double(k) / Double(samples))); if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } } }
            if splitMode != .vertically { for k in 0...samples { let p = canvas.docToView(evaluate(Double(k) / Double(samples), v)); if k == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) } } }
            ctx.strokePath()
            ctx.restoreGState()
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

/// Options-bar controls for `SplitWarpSession`.
struct SplitWarpOptions: View {
    let w: SplitWarpSession
    let bump: () -> Void
    @State private var customCols = 6.0
    @State private var customRows = 6.0

    var body: some View {
        ForEach(SplitWarpMode.allCases) { m in
            IconButton(symbol: m.symbol, help: m.rawValue + " — then click on the mesh", active: w.splitMode == m) {
                w.splitMode = w.splitMode == m ? nil : m; bump()
            }
        }
        Menu("Grid: \(w.cols) × \(w.rows)") {
            Button("Default") { w.setGrid(cols: 3, rows: 3); bump() }
            Button("3 × 3") { w.setGrid(cols: 3, rows: 3); bump() }
            Button("4 × 4") { w.setGrid(cols: 4, rows: 4); bump() }
            Button("5 × 5") { w.setGrid(cols: 5, rows: 5); bump() }
        }.frame(width: 110)
        NumberField(label: "", value: $customCols, width: 30)
        Text("×").foregroundStyle(Theme.textFaint)
        NumberField(label: "", value: $customRows, width: 30)
        Button("Custom") { w.setGrid(cols: Int(clamp(customCols, 1, 50)), rows: Int(clamp(customRows, 1, 50))); bump() }.buttonStyle(PanelButtonStyle())
        Picker("Warp", selection: Binding(get: { w.style }, set: { w.style = $0; bump() })) {
            Text("Custom").tag(SplitWarpStyle.custom)
            Text("Cylinder").tag(SplitWarpStyle.cylinder)
            Divider()
            ForEach(WarpStyle.allCases.filter { $0 != .none }) { Text(tr($0.displayName)).tag(SplitWarpStyle.preset($0)) }
        }.frame(width: 150)
        if w.style != .custom {
            CompactSlider(label: "Bend", value: Binding(get: { w.bend * 100 }, set: { w.bend = $0 / 100; bump() }), range: -100...100, unit: "%")
            CompactSlider(label: "H", value: Binding(get: { w.hDistort * 100 }, set: { w.hDistort = $0 / 100; bump() }), range: -100...100, unit: "%")
            CompactSlider(label: "V", value: Binding(get: { w.vDistort * 100 }, set: { w.vDistort = $0 / 100; bump() }), range: -100...100, unit: "%")
        } else {
            Text(tr(w.splitMode == nil ? "Drag points · ⌥-click a split line to remove it" : "Click on the mesh to split")).foregroundStyle(Theme.textFaint)
        }
    }
}
