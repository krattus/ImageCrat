import AppKit
import SwiftUI
import ImageCratCore

/// Transparent view above the canvas that draws the emitter handles (never takes mouse events itself).
final class ParticleHandlesView: NSView {
    weak var controller: ParticleOverlayController?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        controller?.draw(ctx)
    }
}

/// Invisible view placed behind the editor dialog: reports the dialog's frame so canvas clicks can be told apart.
struct ParticleCardProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        ParticleOverlayController.cardView = v
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { ParticleOverlayController.cardView = v }
}

/// On-canvas handles of the particle editor: emitter position, size / rotation, direction arrow, attractors,
/// vortex centre, floor line and the freehand emission path ("Particle Brush").
///
/// The editor dialog lives in the app's dialog overlay, which swallows clicks on the canvas, so a local event
/// monitor routes canvas clicks (outside the dialog card) to the handles and forwards scroll / pinch to the canvas.
final class ParticleOverlayController {
    static weak var cardView: NSView?

    weak var editor: ParticleEditor?
    weak var canvas: CanvasView?
    private let view = ParticleHandlesView(frame: .zero)
    private var monitor: Any?

    enum Drag: Equatable { case none, pos, width, height, direction, attractor(Int), vortex, floor, path }
    private var drag: Drag = .none
    private var dragStartLen: CGFloat = 1
    private var dragStartSpeeds: (Double, Double) = (0, 0)
    private var stroke: [CGPoint] = []

    init(editor: ParticleEditor, canvas: CanvasView) {
        self.editor = editor
        self.canvas = canvas
        view.controller = self
        view.frame = canvas.bounds
        view.autoresizingMask = [.width, .height]
        canvas.addSubview(view)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel, .magnify]) { [weak self] e in
            guard let self else { return e }
            return self.route(e)
        }
    }

    func remove() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        view.removeFromSuperview()
    }

    func refresh() { view.needsDisplay = true }

    // MARK: Geometry

    private var st: ParticleEditorState? { editor?.state }
    private var W: CGFloat { CGFloat(editor?.doc.state.width ?? 1) }
    private var H: CGFloat { CGFloat(editor?.doc.state.height ?? 1) }
    private var unit: CGFloat { min(W, H) / 1000 }

    private func top() -> ParticleSystemSettings? {
        guard let st, st.effect.systems.indices.contains(st.selected) else { return nil }
        return st.effect.systems[st.selected]
    }

    private func setTop(_ f: (inout ParticleSystemSettings) -> Void) {
        guard let st, st.effect.systems.indices.contains(st.selected) else { return }
        f(&st.effect.systems[st.selected])
    }

    private func center(_ s: ParticleSystemSettings) -> CGPoint {
        s.shape.usesMap && s.shape != .text ? CGPoint(x: W / 2, y: H / 2) : CGPoint(x: s.pos.x * W, y: s.pos.y * H)
    }

    private func axes(_ s: ParticleSystemSettings) -> (CGPoint, CGPoint) {
        let a = CGFloat(-s.emitterRotation * .pi / 180)
        return (CGPoint(x: cos(a), y: sin(a)), CGPoint(x: -sin(a), y: cos(a)))
    }

    private func hasWidth(_ s: ParticleSystemSettings) -> Bool {
        switch s.shape {
        case .line, .circle, .ring, .rectangle, .frame, .grid, .spiral, .text: return true
        default: return false
        }
    }
    private func hasHeight(_ s: ParticleSystemSettings) -> Bool { hasWidth(s) && s.shape != .line }

    private func arrowLength(_ s: ParticleSystemSettings) -> CGFloat {
        let zoom = max(0.01, canvas?.zoom ?? 1)
        let avg = CGFloat((s.speedMin + s.speedMax) / 2)
        return min(max(avg * unit * 0.35, 70 / zoom), 0.45 * min(W, H))
    }

    private func arrowTip(_ s: ParticleSystemSettings, from c: CGPoint) -> CGPoint {
        let d = CGFloat(s.direction * .pi / 180)
        let l = arrowLength(s)
        return CGPoint(x: c.x + cos(d) * l, y: c.y - sin(d) * l)
    }

    // MARK: Events

    private func inCard(_ e: NSEvent) -> Bool {
        guard let v = ParticleOverlayController.cardView, v.window === e.window else { return false }
        return v.convert(v.bounds, to: nil).insetBy(dx: -14, dy: -30).contains(e.locationInWindow)
    }

    private func route(_ e: NSEvent) -> NSEvent? {
        guard let canvas, let win = canvas.window, e.window === win, let editor, !editor.isClosed else { return e }
        guard ParticleOverlayController.cardView != nil else { return e }
        // a popover (presets, colour picker) or panel is key: let its own click handling run
        if let key = NSApp.keyWindow, key !== win, drag == .none { return e }
        let p = canvas.convert(e.locationInWindow, from: nil)
        if drag != .none {
            if e.type == .leftMouseDragged { dragged(p, e); return nil }
            if e.type == .leftMouseUp { finish(); return nil }
        }
        guard canvas.bounds.contains(p), !inCard(e) else { return e }
        switch e.type {
        case .leftMouseDown: down(p, e); return nil
        case .leftMouseDragged, .leftMouseUp: return nil
        case .scrollWheel: canvas.scrollWheel(with: e); return nil
        case .magnify: canvas.magnify(with: e); return nil
        default: return e
        }
    }

    private func down(_ v: CGPoint, _ e: NSEvent) {
        guard let canvas, let st, let s = top() else { return }
        if st.drawPath {
            drag = .path
            stroke = [canvas.viewToDoc(v)]
            return
        }
        func near(_ docPoint: CGPoint) -> Bool { canvas.docToView(docPoint).distance(to: v) < 10 }
        let c = center(s)
        let (ax, ay) = axes(s)
        let ex = s.size.width * W / 2, ey = s.size.height * H / 2
        let arrowSys = st.system
        if near(arrowTip(arrowSys, from: c)) {
            drag = .direction
            dragStartLen = max(1, arrowLength(arrowSys))
            dragStartSpeeds = (arrowSys.speedMin, arrowSys.speedMax)
        } else if !(s.shape.usesMap && s.shape != .text), near(c) { drag = .pos }
        else if hasWidth(s), near(c + ax * ex) { drag = .width }
        else if hasHeight(s), near(c + ay * ey) { drag = .height }
        else if let i = s.attractors.firstIndex(where: { near(CGPoint(x: $0.pos.x * W, y: $0.pos.y * H)) }) { drag = .attractor(i) }
        else if s.vortex != 0 || s.vortexPull != 0, near(CGPoint(x: s.vortexCenter.x * W, y: s.vortexCenter.y * H)) { drag = .vortex }
        else if s.floorEnabled, abs(canvas.docToView(CGPoint(x: 0, y: s.floorY * Double(H))).y - v.y) < 7 { drag = .floor }
        else { drag = .none }
        view.needsDisplay = true
    }

    private func dragged(_ v: CGPoint, _ e: NSEvent) {
        guard let canvas, let st, let s = top() else { return }
        let d = canvas.viewToDoc(v)
        let c = center(s)
        switch drag {
        case .none: break
        case .path:
            if let last = stroke.last, canvas.docToView(last).distance(to: v) > 3 { stroke.append(d) }
        case .pos:
            setTop { $0.pos = CGPoint(x: d.x / W, y: d.y / H) }
        case .width:
            let r = d - c
            let len = max(1, r.length)
            let ang = atan2(r.y, r.x)
            setTop { t in
                t.size.width = len * 2 / self.W
                var deg = Double(-ang * 180 / .pi)
                if e.modifierFlags.contains(.shift) { deg = (deg / 15).rounded() * 15 }
                t.emitterRotation = deg
            }
        case .height:
            let (_, ay) = axes(s)
            let proj = abs((d - c).dot(ay))
            setTop { $0.size.height = max(0.002, proj * 2 / self.H) }
        case .direction:
            let r = d - c
            guard r.length > 1 else { break }
            var deg = Double(atan2(-r.y, r.x) * 180 / .pi)
            if e.modifierFlags.contains(.shift) { deg = (deg / 15).rounded() * 15 }
            var sys = st.system
            sys.direction = deg
            if !e.modifierFlags.contains(.option) {
                let k = Double(r.length / dragStartLen)
                if dragStartSpeeds.1 > 0 { sys.speedMin = dragStartSpeeds.0 * k; sys.speedMax = dragStartSpeeds.1 * k }
            }
            st.system = sys
        case .attractor(let i):
            setTop { if $0.attractors.indices.contains(i) { $0.attractors[i].pos = CGPoint(x: d.x / self.W, y: d.y / self.H) } }
        case .vortex:
            setTop { $0.vortexCenter = CGPoint(x: d.x / self.W, y: d.y / self.H) }
        case .floor:
            setTop { $0.floorY = Double(min(max(d.y / self.H, 0), 1.2)) }
        }
        view.needsDisplay = true
    }

    private func finish() {
        if drag == .path, stroke.count >= 2 {
            // keep at most ~240 points
            let step = max(1, stroke.count / 240)
            var pts: [CGPoint] = []
            for (i, p) in stroke.enumerated() where i % step == 0 || i == stroke.count - 1 { pts.append(CGPoint(x: p.x / W, y: p.y / H)) }
            setTop { $0.shape = .path; $0.pathPoints = pts; $0.pathClosed = false }
        }
        stroke = []
        drag = .none
        view.needsDisplay = true
    }

    /// Drives a press-drag-release on the canvas (view coordinates) exactly like the mouse would (tests, scripting).
    func simulateDrag(from a: CGPoint, to b: CGPoint, steps: Int = 8) {
        guard let e = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        down(a, e)
        for k in 1...max(1, steps) {
            let t = CGFloat(k) / CGFloat(max(1, steps))
            dragged(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), e)
        }
        finish()
    }

    /// View-space positions of the main handles of the selected system (tests).
    func handlePoints() -> (pos: CGPoint, width: CGPoint, height: CGPoint, arrow: CGPoint)? {
        guard let canvas, let st, let s = top() else { return nil }
        let c = center(s)
        let (ax, ay) = axes(s)
        return (canvas.docToView(c), canvas.docToView(c + ax * (s.size.width * W / 2)), canvas.docToView(c + ay * (s.size.height * H / 2)),
                canvas.docToView(arrowTip(st.system, from: c)))
    }

    // MARK: Drawing

    func draw(_ ctx: CGContext) {
        guard let canvas, let st, let s = top() else { return }
        let c = center(s)
        let (ax, ay) = axes(s)
        let ex = s.size.width * W / 2, ey = s.size.height * H / 2
        func v(_ p: CGPoint) -> CGPoint { canvas.docToView(p) }

        // emitter outline
        let outline = CGMutablePath()
        switch s.shape {
        case .line:
            outline.move(to: v(c - ax * ex)); outline.addLine(to: v(c + ax * ex))
        case .circle, .ring, .spiral:
            for k in 0...64 {
                let a = CGFloat(k) / 64 * 2 * .pi
                let p = v(c + ax * (cos(a) * ex) + ay * (sin(a) * ey))
                if k == 0 { outline.move(to: p) } else { outline.addLine(to: p) }
            }
        case .rectangle, .frame, .grid, .text:
            let pts = [c - ax * ex - ay * ey, c + ax * ex - ay * ey, c + ax * ex + ay * ey, c - ax * ex + ay * ey]
            outline.move(to: v(pts[0])); for p in pts.dropFirst() { outline.addLine(to: v(p)) }; outline.closeSubpath()
        case .path:
            let pts = s.pathPoints.map { v(CGPoint(x: $0.x * W, y: $0.y * H)) }
            if let f = pts.first { outline.move(to: f); for p in pts.dropFirst() { outline.addLine(to: p) } }
        default: break
        }
        if !outline.isEmpty { OverlayStyle.contrastStroke(ctx, outline, dashed: true) }

        // stroke being drawn
        if stroke.count > 1 {
            let p = CGMutablePath()
            p.move(to: v(stroke[0])); for q in stroke.dropFirst() { p.addLine(to: v(q)) }
            OverlayStyle.accentStroke(ctx, p, width: 2)
        }

        // floor
        if s.floorEnabled {
            let p = CGMutablePath()
            p.move(to: v(CGPoint(x: 0, y: s.floorY * Double(H)))); p.addLine(to: v(CGPoint(x: W, y: s.floorY * Double(H))))
            OverlayStyle.contrastStroke(ctx, p, dashed: true)
            OverlayStyle.handle(ctx, at: v(CGPoint(x: W / 2, y: s.floorY * Double(H))), size: 7, filled: drag == .floor)
        }

        // direction arrow + spread cone
        let arrowSys = st.system
        let tip = arrowTip(arrowSys, from: c)
        let hasVelocity = arrowSys.speedMax > 0 || arrowSys.speedMin > 0
        if hasVelocity {
            let vc = v(c), vt = v(tip)
            let arrow = CGMutablePath()
            arrow.move(to: vc); arrow.addLine(to: vt)
            let dir = (vt - vc).normalized
            let left = dir.rotated(by: 2.6), right = dir.rotated(by: -2.6)
            arrow.move(to: vt); arrow.addLine(to: vt + left * 9)
            arrow.move(to: vt); arrow.addLine(to: vt + right * 9)
            OverlayStyle.contrastStroke(ctx, arrow, width: 1.5)
            if arrowSys.spread > 0.5 && arrowSys.spread < 359 {
                let cone = CGMutablePath()
                let l = vc.distance(to: vt) * 0.8
                for sgn in [-1.0, 1.0] {
                    let a = CGFloat(sgn * arrowSys.spread / 2 * .pi / 180)
                    cone.move(to: vc); cone.addLine(to: vc + dir.rotated(by: a) * l)
                }
                OverlayStyle.contrastStroke(ctx, cone, dashed: true)
            }
            OverlayStyle.circleHandle(ctx, at: vt, size: 8, filled: drag == .direction)
        }

        // size handles
        if hasWidth(s) { OverlayStyle.handle(ctx, at: v(c + ax * ex), size: 7, filled: drag == .width) }
        if hasHeight(s) { OverlayStyle.handle(ctx, at: v(c + ay * ey), size: 7, filled: drag == .height) }

        // attractors / vortex
        for (i, a) in s.attractors.enumerated() {
            let p = v(CGPoint(x: a.pos.x * W, y: a.pos.y * H))
            let r = CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)
            ctx.setFillColor((a.strength >= 0 ? NSColor.systemGreen : NSColor.systemRed).withAlphaComponent(drag == .attractor(i) ? 1 : 0.85).cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: r)
        }
        if s.vortex != 0 || s.vortexPull != 0 {
            let p = v(CGPoint(x: s.vortexCenter.x * W, y: s.vortexCenter.y * H))
            let swirl = CGMutablePath()
            swirl.addArc(center: p, radius: 9, startAngle: 0.3, endAngle: 4.6, clockwise: false)
            OverlayStyle.contrastStroke(ctx, swirl, width: 1.5)
            OverlayStyle.circleHandle(ctx, at: p, size: 6, filled: drag == .vortex)
        }

        // position handle (on top)
        if !(s.shape.usesMap && s.shape != .text) {
            let p = v(c)
            ctx.setFillColor((drag == .pos ? OverlayStyle.accent : NSColor.white).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.7).cgColor); ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12))
        }
    }
}
