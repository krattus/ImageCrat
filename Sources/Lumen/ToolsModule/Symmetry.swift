import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Symmetry painting

enum SymmetryType: String, CaseIterable, Codable {
    case vertical = "Vertical", horizontal = "Horizontal", dualAxis = "Dual Axis", diagonal = "Diagonal"
    case radial = "Radial", mandala = "Mandala"
}

struct SymmetrySettings: Equatable {
    var enabled = false
    var type: SymmetryType = .vertical
    /// Radial / mandala segment count (2...12).
    var segments = 6
    /// Symmetry centre as a fraction of the canvas (so it follows canvas size changes and other documents).
    var center = CGPoint(x: 0.5, y: 0.5)
    /// Rotation of the axes in degrees.
    var angle: Double = 0

    /// Additional positions for a dab at `p` (the original is not included).
    func mirrors(of p: CGPoint, width: Int, height: Int) -> [CGPoint] {
        guard enabled else { return [] }
        let c = CGPoint(x: center.x * CGFloat(width), y: center.y * CGFloat(height))
        let a = CGFloat(angle * .pi / 180)
        // work in an axis-aligned frame: rotate by -a around the centre, transform, rotate back
        let local = (p - c).rotated(by: -a)
        func back(_ q: CGPoint) -> CGPoint { c + q.rotated(by: a) }
        switch type {
        case .vertical:
            return [back(CGPoint(x: -local.x, y: local.y))]
        case .horizontal:
            return [back(CGPoint(x: local.x, y: -local.y))]
        case .dualAxis:
            return [back(CGPoint(x: -local.x, y: local.y)), back(CGPoint(x: local.x, y: -local.y)), back(CGPoint(x: -local.x, y: -local.y))]
        case .diagonal:
            return [back(CGPoint(x: local.y, y: local.x))]
        case .radial:
            let n = max(2, min(12, segments))
            return (1..<n).map { k in back(local.rotated(by: CGFloat(k) * 2 * .pi / CGFloat(n))) }
        case .mandala:
            let n = max(2, min(12, segments))
            let mirrored = CGPoint(x: -local.x, y: local.y)
            var out: [CGPoint] = (1..<n).map { k in back(local.rotated(by: CGFloat(k) * 2 * .pi / CGFloat(n))) }
            out += (0..<n).map { k in back(mirrored.rotated(by: CGFloat(k) * 2 * .pi / CGFloat(n))) }
            return out
        }
    }

    /// Axis segments (doc space) for display.
    func axes(width: Int, height: Int) -> [(CGPoint, CGPoint)] {
        let W = CGFloat(width), H = CGFloat(height)
        let c = CGPoint(x: center.x * W, y: center.y * H)
        let L = (W + H) * 2
        let a = CGFloat(angle * .pi / 180)
        func line(_ dir: CGFloat) -> (CGPoint, CGPoint) {
            let d = CGPoint(x: cos(dir), y: sin(dir)) * L
            return (c - d, c + d)
        }
        func ray(_ dir: CGFloat) -> (CGPoint, CGPoint) { (c, c + CGPoint(x: cos(dir), y: sin(dir)) * L) }
        switch type {
        case .vertical: return [line(a + .pi / 2)]
        case .horizontal: return [line(a)]
        case .dualAxis: return [line(a), line(a + .pi / 2)]
        case .diagonal: return [line(a + .pi / 4)]
        case .radial, .mandala:
            let n = max(2, min(12, segments))
            return (0..<n).map { k in ray(a - .pi / 2 + CGFloat(k) * 2 * .pi / CGFloat(n)) }
        }
    }
}

enum SymmetryControls {
    /// Tools that paint through the brush engine (brush, pencil, eraser, history/pattern/art brushes, background eraser).
    static func supports(_ k: ToolKind) -> Bool {
        [.brush, .pencil, .eraser, .historyBrush, .patternStamp, .artHistoryBrush, .backgroundEraser].contains(k)
    }

    static func install() {
        BrushDynamicsEngine.symmetryPoints = { p in
            let s = ToolsSettings.shared.symmetry
            guard s.enabled, supports(AppModel.shared.tool), let d = AppActions.doc ?? activeTestDoc else { return [] }
            return s.mirrors(of: p, width: d.state.width, height: d.state.height)
        }
    }

    /// Document used for symmetry when painting headlessly (self tests).
    static weak var activeTestDoc: Document?

    static func drawAxes(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let s = ToolsSettings.shared.symmetry
        guard s.enabled, supports(AppModel.shared.tool) else { return }
        let path = CGMutablePath()
        for (a, b) in s.axes(width: doc.state.width, height: doc.state.height) {
            path.move(to: canvas.docToView(a)); path.addLine(to: canvas.docToView(b))
        }
        ctx.saveGState()
        ctx.clip(to: canvas.docToView(doc.state.canvasCGRect))
        ctx.addPath(path)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.3, blue: 1, alpha: 0.85).cgColor)
        ctx.setLineDash(phase: 0, lengths: [8, 4])
        ctx.strokePath()
        ctx.restoreGState()
        let c = canvas.docToView(CGPoint(x: s.center.x * CGFloat(doc.state.width), y: s.center.y * CGFloat(doc.state.height)))
        OverlayStyle.circleHandle(ctx, at: c, size: 8, filled: true)
    }
}

/// Options-bar "butterfly" menu for brush-type tools.
struct SymmetryMenu: View {
    @Bindable var ts = ToolsSettings.shared

    var body: some View {
        Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
        Menu {
            Button { ts.symmetry.enabled = false; ToolsModule.refreshCanvas() } label: {
                if !ts.symmetry.enabled { Label("Symmetry Off", systemImage: "checkmark") } else { Text("Symmetry Off") }
            }
            Divider()
            ForEach(SymmetryType.allCases, id: \.self) { t in
                Button {
                    ts.symmetry.type = t
                    ts.symmetry.enabled = true
                    if t == .radial || t == .mandala { DialogRegistry.show("symmetryRadial") }
                    ToolsModule.refreshCanvas()
                } label: {
                    let title = t == .radial || t == .mandala ? t.rawValue + "…" : t.rawValue
                    if ts.symmetry.enabled && ts.symmetry.type == t { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            Divider()
            Button("Rotate Axes 45°") { ts.symmetry.angle = (ts.symmetry.angle + 45).truncatingRemainder(dividingBy: 360); ToolsModule.refreshCanvas() }
            Button("Center on Canvas") { ts.symmetry.center = CGPoint(x: 0.5, y: 0.5); ts.symmetry.angle = 0; ToolsModule.refreshCanvas() }
            Button("Center on Selection") {
                if let d = AppActions.doc, let b = d.state.selectionBounds {
                    ts.symmetry.center = CGPoint(x: b.cgRect.midX / CGFloat(d.state.width), y: b.cgRect.midY / CGFloat(d.state.height))
                    ToolsModule.refreshCanvas()
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    .foregroundStyle(ts.symmetry.enabled ? Theme.accent : Theme.text)
                if ts.symmetry.enabled { Text(ts.symmetry.type.rawValue).font(Theme.fontSmall) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Set paint symmetry options")
    }
}

struct SymmetrySegmentsDialog: View {
    @Bindable var ts = ToolsSettings.shared
    @State private var segments: Double = Double(ToolsSettings.shared.symmetry.segments)
    @State private var angle: Double = ToolsSettings.shared.symmetry.angle
    @State private var cx: Double = Double(ToolsSettings.shared.symmetry.center.x * 100)
    @State private var cy: Double = Double(ToolsSettings.shared.symmetry.center.y * 100)

    var body: some View {
        DialogFrame(title: "\(ts.symmetry.type.rawValue) Symmetry", width: 320, onOK: {
            ts.symmetry.segments = Int(segments.rounded())
            ts.symmetry.angle = angle
            ts.symmetry.center = CGPoint(x: cx / 100, y: cy / 100)
            ToolsModule.refreshCanvas()
        }) {
            ValueSlider(label: "Segments", value: $segments, range: 2...12, step: 1)
            ValueSlider(label: "Angle", value: $angle, range: 0...360, unit: "°")
            ValueSlider(label: "Center X", value: $cx, range: 0...100, unit: "%")
            ValueSlider(label: "Center Y", value: $cy, range: 0...100, unit: "%")
        }
    }
}
