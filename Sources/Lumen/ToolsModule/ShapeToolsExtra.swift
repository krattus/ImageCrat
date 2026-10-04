import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Triangle

enum TriangleShape {
    /// Isosceles triangle inscribed in `r` (apex at the top centre) with rounded corners.
    static func path(_ r: CGRect, radius: Double) -> VectorPath {
        let a = CGPoint(x: r.midX, y: r.minY), b = CGPoint(x: r.maxX, y: r.maxY), c = CGPoint(x: r.minX, y: r.maxY)
        guard radius > 0.01 else { return VectorPath(subpaths: [Subpath(points: [PathPoint(a), PathPoint(b), PathPoint(c)], closed: true)]) }
        // clamp the radius to the incircle
        let la = b.distance(to: c), lb = a.distance(to: c), lc = a.distance(to: b)
        let s = (la + lb + lc) / 2
        let area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
        let inr = s > 0 ? area / s : 0
        let rad = min(CGFloat(radius), inr * 0.999)
        let p = CGMutablePath()
        p.move(to: (a + b) / 2)
        p.addArc(tangent1End: b, tangent2End: c, radius: rad)
        p.addArc(tangent1End: c, tangent2End: a, radius: rad)
        p.addArc(tangent1End: a, tangent2End: b, radius: rad)
        p.closeSubpath()
        return VectorPath.from(cgPath: p)
    }
}

/// Triangle tool: like the other shape tools (Shape / Path / Pixels modes), with a corner radius.
final class TriangleTool: Tool {
    private var start: CGPoint?
    private var current: CGPoint?
    private var constrain = false
    private var fromCenter = false

    override var cursor: NSCursor { .crosshair }

    private var rect: CGRect? {
        guard var s = start, var c = current else { return nil }
        if constrain {   // equilateral
            let w = abs(c.x - s.x)
            let h = w * sqrt(3) / 2
            c = CGPoint(x: c.x, y: s.y + (c.y >= s.y ? h : -h))
        }
        if fromCenter { s = s - (c - s) }
        return CGRect(p1: s, p2: c)
    }

    func geometry(_ r: CGRect) -> ShapeGeometry { .path(TriangleShape.path(r, radius: ToolsSettings.shared.triangleRadius)) }

    override func activate() { ToolModes.restore(kind) }

    override func mouseDown(_ e: ToolEvent) { start = canvas.snap(e.doc); current = start }
    override func mouseDragged(_ e: ToolEvent) { current = canvas.snap(e.doc); constrain = e.shift; fromCenter = e.option }

    override func mouseUp(_ e: ToolEvent) {
        defer { start = nil; current = nil }
        guard let d = doc, let r = rect, r.width >= 2, r.height >= 2 else { return }
        TriangleTool.create(d, rect: r, tool: self)
    }

    static func create(_ d: Document, rect r: CGRect, tool: Tool? = nil) {
        let app = AppModel.shared
        let g = ShapeGeometry.path(TriangleShape.path(r, radius: ToolsSettings.shared.triangleRadius))
        let op = app.shapeTool.operation
        switch app.shapeTool.mode {
        case .shape:
            if let op, let id = d.activeLayerID, let existing = d.state.layer(id)?.shape {
                var p = existing.path
                p.subpaths += g.vectorPath.withOperation(op).subpaths
                VectorEditing.setPath(d, .layer(id), p)
                d.commit("Combine Shapes")
            } else {
                _ = VectorEditing.newShapeLayer(d, geometry: g, name: "Triangle")
                d.commit("New Shape Layer")
            }
        case .path:
            if let op, let pid = d.activePathID, let i = d.state.paths.firstIndex(where: { $0.id == pid }) {
                d.state.paths[i].path.subpaths += g.vectorPath.withOperation(op).subpaths
            } else {
                _ = VectorEditing.newWorkPath(d, g.vectorPath)
            }
            d.commit("Work Path")
        case .pixels:
            guard let (dd, id, tgt) = tool?.requirePixelTarget(), let (w, o) = dd.beginPixelEdit(layerID: id, target: tgt) else { return }
            let ctx = w.context
            ctx.saveGState()
            ctx.translateBy(x: CGFloat(-o.x), y: CGFloat(-o.y))
            if let sel = dd.editSelection { w.clip(toMask: sel.makeCGImage(), in: dd.state.canvasCGRect) }
            ctx.addPath(g.vectorPath.cgPath)
            ctx.setFillColor((tgt.isMask ? RGBA(gray: app.foreground.luminance) : app.foreground).cgColor)
            ctx.fillPath()
            ctx.restoreGState()
            w.markDirty()
            dd.commit("Triangle")
        }
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let r = rect else { return }
        var t = canvas.docToViewTransform
        if let p = geometry(r).vectorPath.cgPath.copy(using: &t) { OverlayStyle.accentStroke(ctx, p, width: 1.5) }
        if let m = canvas.lastMouseView { OverlayStyle.label("W: \(Int(r.width))  H: \(Int(r.height))", at: m) }
    }
}

// MARK: - Line arrowheads

enum LineArrows {
    /// Line geometry for the Line tool: a live line, or a path with arrowheads when enabled.
    static func geometry(_ a: CGPoint, _ b: CGPoint, weight: Double) -> ShapeGeometry {
        let ts = ToolsSettings.shared
        let st = AppModel.shared.shapeTool
        guard ts.arrowStart || st.arrowEnd else { return .line(a, b, weight: weight) }
        return .path(path(from: a, to: b, weight: weight, start: ts.arrowStart, end: st.arrowEnd,
                          widthPct: ts.arrowWidth, lengthPct: ts.arrowLength, concavityPct: ts.arrowConcavity))
    }

    /// Line outline with arrowheads sized in % of the line weight (Photoshop: width 500%, length 1000%);
    /// concavity (-50…50%) moves the point where the line meets the arrowhead towards (+) or away from (-) the tip.
    static func path(from a: CGPoint, to b: CGPoint, weight: Double, start: Bool, end: Bool,
                     widthPct: Double = 500, lengthPct: Double = 1000, concavityPct: Double = 0) -> VectorPath {
        let len = a.distance(to: b)
        guard len > 0.01 else { return VectorPath() }
        let d = (b - a).normalized
        let nrm = CGPoint(x: -d.y, y: d.x)
        let hw = CGFloat(weight / 2)
        let aw = max(hw, CGFloat(weight * widthPct / 100) / 2)
        let al = min(CGFloat(weight * lengthPct / 100), len / (start && end ? 2 : 1))
        let conc = CGFloat(clamp(concavityPct, -50, 50) / 100) * al
        var outline: [CGPoint] = []
        // + side from the start to the end
        if start {
            let base = a + d * al, neck = a + d * (al - conc)
            outline += [a, base + nrm * aw, neck + nrm * hw]
        } else {
            outline += [a + nrm * hw]
        }
        if end {
            let base = b - d * al, neck = b - d * (al - conc)
            outline += [neck + nrm * hw, base + nrm * aw, b, base - nrm * aw, neck - nrm * hw]
        } else {
            outline += [b + nrm * hw, b - nrm * hw]
        }
        // - side back to the start
        if start {
            let base = a + d * al, neck = a + d * (al - conc)
            outline += [neck - nrm * hw, base - nrm * aw]
        } else {
            outline += [a - nrm * hw]
        }
        return VectorPath(subpaths: [Subpath(points: outline.map { PathPoint($0) }, closed: true)])
    }
}

/// Line tool options: arrowheads.
struct LineArrowOptions: View {
    @Bindable var app = AppModel.shared
    @Bindable var ts = ToolsSettings.shared
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.right")
                Text(ts.arrowStart || app.shapeTool.arrowEnd ? "Arrows" : "No Arrows").font(Theme.fontSmall)
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.fieldBG))
        }
        .buttonStyle(.plain)
        .help("Arrowheads")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Arrowheads").font(Theme.fontBold)
                HStack {
                    Toggle2(label: "Start", on: $ts.arrowStart)
                    Toggle2(label: "End", on: $app.shapeTool.arrowEnd)
                }
                ValueSlider(label: "Width", value: $ts.arrowWidth, range: 10...1000, unit: "%")
                ValueSlider(label: "Length", value: $ts.arrowLength, range: 10...5000, unit: "%")
                ValueSlider(label: "Concavity", value: $ts.arrowConcavity, range: -50...50, unit: "%")
            }
            .padding(12)
            .frame(width: 280)
        }
    }
}
