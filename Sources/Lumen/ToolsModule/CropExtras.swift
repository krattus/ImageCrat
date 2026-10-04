import AppKit
import SwiftUI
import Vision
import ImageCratCore

// MARK: - Perspective Crop

/// Drag a box (or click four corners) and move each corner onto the edges of a plane; Return rectifies the
/// plane into a new, rectangular canvas.
final class PerspectiveCropTool: Tool {
    private(set) var quad: Quad? { didSet { quadCanvas = doc.map { CGSize(width: $0.state.width, height: $0.state.height) } ?? .zero } }
    /// Canvas size the quad was drawn for; another command changing the canvas underneath drops the quad.
    private var quadCanvas = CGSize.zero
    private var dragCorner: Int?
    private var dragMove: (CGPoint, Quad)?
    private var creating: CGPoint?
    private var current: CGPoint?

    override var cursor: NSCursor { .crosshair }
    override var isBusy: Bool { validate(); return quad != nil }

    private func validate() {
        guard quad != nil, let d = doc, quadCanvas != CGSize(width: d.state.width, height: d.state.height) else { return }
        quad = nil; dragCorner = nil; dragMove = nil
        app.sessionTick += 1
    }

    override func deactivate() { quad = nil }
    override func documentWillChange(_ old: Document) { quad = nil }
    override func cancel() { quad = nil; canvas.overlay.needsDisplay = true; app.sessionTick += 1 }

    override func commit() {
        validate()
        guard let d = doc, let q = quad else { return }
        quad = nil
        PerspectiveCropTool.apply(d, quad: q)
        app.sessionTick += 1
    }

    override func mouseDown(_ e: ToolEvent) {
        validate()
        if let q = quad {
            if e.clickCount == 2, q.path.contains(e.doc) { commit(); return }
            let pts = q.mapped { canvas.docToView($0) }.points
            if let i = pts.firstIndex(where: { $0.distance(to: e.view) < 9 }) { dragCorner = i; return }
            if q.path.contains(e.doc) { dragMove = (e.doc, q); return }
        }
        creating = e.doc
        current = e.doc
    }

    override func mouseDragged(_ e: ToolEvent) {
        if let i = dragCorner, var q = quad {
            var pts = q.points
            pts[i] = e.doc
            q.points = pts
            quad = q
            return
        }
        if let (s, q0) = dragMove { quad = q0.mapped { $0 + (e.doc - s) }; return }
        if creating != nil { current = e.doc }
    }

    override func mouseUp(_ e: ToolEvent) {
        defer { dragCorner = nil; dragMove = nil; creating = nil; current = nil }
        if let s = creating, let c = current, s.distance(to: c) * canvas.zoom > 4 {
            quad = Quad(rect: CGRect(p1: s, p2: c))
            app.sessionTick += 1
        }
    }

    override func keyDown(_ e: NSEvent) -> Bool {
        if quad != nil && (e.keyCode == 36 || e.keyCode == 76) { commit(); return true }
        if quad != nil && e.keyCode == 53 { cancel(); return true }
        return false
    }

    /// Output size: average lengths of opposite edges.
    static func outputSize(_ q: Quad) -> (Int, Int) {
        let w = (q.tl.distance(to: q.tr) + q.bl.distance(to: q.br)) / 2
        let h = (q.tl.distance(to: q.bl) + q.tr.distance(to: q.br)) / 2
        guard w.isFinite, h.isFinite else { return (1, 1) }
        return (min(maxCanvasDimension, max(1, Int(w.rounded()))), min(maxCanvasDimension, max(1, Int(h.rounded()))))
    }

    /// Rectifies the document so `q` becomes the whole (new) canvas.
    static func apply(_ d: Document, quad q: Quad) {
        let (w, h) = outputSize(q)
        guard let hom = Homography(from: q, to: Quad(rect: CGRect(x: 0, y: 0, width: w, height: h))) else { NSSound.beep(); return }
        let before = d.historyIndex
        AppActions.transformDocument(d, h: hom, newWidth: w, newHeight: h, name: "Perspective Crop", nearest: false, guideMap: nil)
        if ToolsSettings.shared.cropDeletePixels { AppActions.crop(to: IRect(x: 0, y: 0, width: w, height: h), deletePixels: true) }
        d.coalesceLastSteps(d.historyIndex - before, name: "Perspective Crop")      // one undo step
    }

    override func drawOverlay(_ ctx: CGContext) {
        if let s = creating, let c = current {
            OverlayStyle.contrastStroke(ctx, CGPath(rect: canvas.docToView(CGRect(p1: s, p2: c)), transform: nil), dashed: true)
            return
        }
        validate()
        guard let q = quad else { return }
        let vq = q.mapped { canvas.docToView($0) }
        ctx.saveGState()
        ctx.addRect(canvas.bounds)
        ctx.addPath(vq.path)
        ctx.setFillColor(NSColor(white: 0, alpha: 0.5).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
        if ToolsSettings.shared.perspectiveShowGrid {
            let grid = CGMutablePath()
            let n = 4
            for i in 1..<n {
                let t = CGFloat(i) / CGFloat(n)
                grid.move(to: vq.tl.lerp(vq.bl, t)); grid.addLine(to: vq.tr.lerp(vq.br, t))
                grid.move(to: vq.tl.lerp(vq.tr, t)); grid.addLine(to: vq.bl.lerp(vq.br, t))
            }
            ctx.saveGState()
            ctx.addPath(grid)
            ctx.setStrokeColor(NSColor(white: 1, alpha: 0.55).cgColor)
            ctx.setLineWidth(0.75)
            ctx.strokePath()
            ctx.restoreGState()
        }
        OverlayStyle.contrastStroke(ctx, vq.path)
        for p in vq.points { OverlayStyle.handle(ctx, at: p, size: 8) }
        let (w, h) = PerspectiveCropTool.outputSize(q)
        OverlayStyle.label("\(w) × \(h) px", at: vq.br)
    }
}

// MARK: - Crop tool straighten mode

/// The Crop tool with a Straighten mode: draw a line along something that should be level; the image is rotated
/// to level it and cropped to the largest rectangle that has no empty corners.
final class StraightenCropTool: CropTool {
    private var line: (CGPoint, CGPoint)?

    override func mouseDown(_ e: ToolEvent) {
        if ToolsSettings.shared.cropStraighten || e.command {
            line = (e.doc, e.doc)
            return
        }
        super.mouseDown(e)
    }

    override func mouseDragged(_ e: ToolEvent) {
        if let l = line {
            line = (l.0, e.doc)
            let a = StraightenCropTool.correction(for: l.0, e.doc)
            status(String(format: "Angle: %.2f°", -a * 180 / .pi))
            return
        }
        super.mouseDragged(e)
    }

    override func mouseUp(_ e: ToolEvent) {
        if let l = line {
            line = nil
            guard let d = doc, l.0.distance(to: e.doc) * canvas.zoom > 6 else { return }
            let a = StraightenCropTool.correction(for: l.0, e.doc)
            StraightenCropTool.straighten(d, radians: a)
            ToolsSettings.shared.cropStraighten = false
            activate()
            return
        }
        super.mouseUp(e)
    }

    override func drawOverlay(_ ctx: CGContext) {
        super.drawOverlay(ctx)
        if let l = line {
            let p = CGMutablePath()
            p.move(to: canvas.docToView(l.0)); p.addLine(to: canvas.docToView(l.1))
            OverlayStyle.contrastStroke(ctx, p, width: 1.5)
            let a = StraightenCropTool.correction(for: l.0, l.1)
            OverlayStyle.label(String(format: "%.1f°", -a * 180 / .pi), at: canvas.docToView(l.1))
        }
    }

    /// Rotation (radians, doc space y-down, positive = clockwise) that makes the line horizontal or vertical,
    /// whichever is closer.
    static func correction(for a: CGPoint, _ b: CGPoint) -> CGFloat {
        let d = b - a
        var ang = atan2(d.y, d.x)          // y-down: positive = clockwise from +x
        // fold into (-45°, 45°] around the nearest axis
        while ang > .pi / 4 { ang -= .pi / 2 }
        while ang <= -.pi / 4 { ang += .pi / 2 }
        return -ang
    }

    /// Largest axis-aligned rectangle inside a w×h rectangle rotated by `angle`.
    static func inscribedSize(_ w: CGFloat, _ h: CGFloat, angle: CGFloat) -> CGSize {
        guard w > 0, h > 0 else { return .zero }
        let longer = w >= h
        let sideLong = longer ? w : h, sideShort = longer ? h : w
        let sa = abs(sin(angle)), ca = abs(cos(angle))
        if sa < 1e-9 { return CGSize(width: w, height: h) }
        if sideShort <= 2 * sa * ca * sideLong || abs(sa - ca) < 1e-10 {
            let x = 0.5 * sideShort
            return longer ? CGSize(width: x / sa, height: x / ca) : CGSize(width: x / ca, height: x / sa)
        }
        let cos2a = ca * ca - sa * sa
        return CGSize(width: (w * ca - h * sa) / cos2a, height: (h * ca - w * sa) / cos2a)
    }

    /// Rotates the whole document by `radians` around its centre, then crops to the inscribed rectangle.
    static func straighten(_ d: Document, radians a: CGFloat, crop: Bool = true) {
        guard abs(a) > 1e-5 else { AppModel.shared.setStatus("Already straight."); return }
        AppActions.canvas?.commitCurrentTool()      // a pending crop box is applied before the size is read
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        let c = CGPoint(x: W / 2, y: H / 2)
        let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a).translatedBy(x: -c.x, y: -c.y)
        let before = d.historyIndex
        AppActions.transformDocument(d, h: Homography(affine: t), newWidth: d.state.width, newHeight: d.state.height,
                                     name: "Straighten", nearest: false, guideMap: nil)
        guard crop else { return }
        let s = inscribedSize(W, H, angle: a)
        let r = CGRect(x: c.x - s.width / 2, y: c.y - s.height / 2, width: s.width, height: s.height)
        let ir = IRect(x: Int(ceil(r.minX)), y: Int(ceil(r.minY)), width: Int(floor(r.width)), height: Int(floor(r.height)))
        if !ir.isEmpty { AppActions.crop(to: ir, deletePixels: AppModel.shared.crop.deleteCropped) }
        d.coalesceLastSteps(d.historyIndex - before, name: "Straighten")      // rotate + crop = one undo step
    }

    /// Auto Straighten: detects the horizon with Vision and levels the image.
    static func autoStraighten(_ d: Document) {
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        guard let cg = RenderEngine.cgImage(Compositor.shared.composite(d), rect: sp.ciCanvas),
              let angle = detectHorizon(cg) else {
            AppModel.shared.setStatus("Auto Straighten: no horizon detected.")
            NSSound.beep()
            return
        }
        // Vision's angle is the (y-up, counter-clockwise) rotation that levels the horizon: a horizon rising to the
        // right gives a negative angle. In y-down doc space (positive = clockwise) the correction is -angle.
        straighten(d, radians: CGFloat(-angle))
        AppModel.shared.setStatus(String(format: "Auto Straighten: rotated %.2f°", angle * 180 / .pi))
    }

    /// Horizon angle (radians, counter-clockwise in image space) or nil.
    static func detectHorizon(_ cg: CGImage) -> Double? {
        let req = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        guard let obs = req.results?.first else { return nil }
        return Double(obs.angle)
    }
}

extension ToolsSettings {
    /// Perspective crop follows the Crop tool's "Delete Cropped Pixels" option.
    var cropDeletePixels: Bool { AppModel.shared.crop.deleteCropped }
}

/// Crop options-bar additions: Straighten mode and Auto Straighten.
struct CropStraightenControls: View {
    @Bindable var ts = ToolsSettings.shared
    var body: some View {
        Rectangle().fill(Theme.divider).frame(width: 1, height: 20)
        IconButton(symbol: "level", help: "Straighten: draw a line to level the photo (or ⌘-drag)", active: ts.cropStraighten) { ts.cropStraighten.toggle() }
        Button("Auto Straighten") { if let d = AppActions.doc { StraightenCropTool.autoStraighten(d) } }
            .buttonStyle(PanelButtonStyle())
            .help("Detect the horizon and level the image")
    }
}
