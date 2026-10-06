import Vision
import SwiftUI
import AppKit
import CoreImage
import ImageCratCore

enum LiquifyMode: String, CaseIterable, Identifiable {
    case forward = "Forward Warp", twirlCW = "Twirl Clockwise", twirlCCW = "Twirl Counter-Clockwise", pucker = "Pucker", bloat = "Bloat", reconstruct = "Reconstruct", smooth = "Smooth"
    case freeze = "Freeze Mask", thaw = "Thaw Mask"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .forward: return "hand.point.up.left"
        case .twirlCW: return "arrow.clockwise"
        case .twirlCCW: return "arrow.counterclockwise"
        case .pucker: return "arrow.down.right.and.arrow.up.left"
        case .bloat: return "arrow.up.left.and.arrow.down.right"
        case .reconstruct: return "arrow.uturn.backward"
        case .smooth: return "water.waves"
        case .freeze: return "snowflake"
        case .thaw: return "drop"
        }
    }
}

/// Displacement field (doc-space offsets: result(p) = source(p + d(p))) on a coarse grid.
final class DisplacementField {
    let width: Int, height: Int       // doc size
    let step: Int
    let gw: Int, gh: Int
    var d: [SIMD2<Float>]
    /// Face-Aware Liquify displacement (recomputed from the sliders), added to the brush field.
    var face: [SIMD2<Float>]
    /// Freeze mask per grid cell (1 = protected from brush edits).
    var frozen: [Float]

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        step = max(2, Int(ceil(Double(max(width, height)) / 900)))
        gw = width / step + 2
        gh = height / step + 2
        d = Array(repeating: .zero, count: gw * gh)
        face = d
        frozen = Array(repeating: 0, count: gw * gh)
    }

    var isIdentity: Bool { !d.contains { $0 != .zero } && !face.contains { $0 != .zero } }

    func reset() { d = Array(repeating: .zero, count: gw * gh) }

    func setAllFrozen(_ v: Float) { frozen = Array(repeating: v, count: gw * gh) }
    func invertFrozen() { frozen = frozen.map { 1 - $0 } }

    /// Bilinear sample (grid coordinates in doc pixels).
    func sample(_ x: Float, _ y: Float) -> SIMD2<Float> {
        let fx = clamp(x / Float(step), 0, Float(gw - 1)), fy = clamp(y / Float(step), 0, Float(gh - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(gw - 1, x0 + 1), y1 = min(gh - 1, y0 + 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let a = d[y0 * gw + x0], b = d[y0 * gw + x1], c = d[y1 * gw + x0], e = d[y1 * gw + x1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + e * tx) * ty
    }

    func apply(mode: LiquifyMode, center: CGPoint, delta: CGPoint, radius: Double, pressure: Double) {
        let r = Float(radius)
        let cx = Float(center.x), cy = Float(center.y)
        let gx0 = max(0, Int((cx - r) / Float(step))), gx1 = min(gw - 1, Int((cx + r) / Float(step)) + 1)
        let gy0 = max(0, Int((cy - r) / Float(step))), gy1 = min(gh - 1, Int((cy + r) / Float(step)) + 1)
        if gx1 < gx0 || gy1 < gy0 { return }
        let p = Float(pressure)
        if mode == .freeze || mode == .thaw {
            for gy in gy0...gy1 { for gx in gx0...gx1 {
                let dx = Float(gx * step) - cx, dy = Float(gy * step) - cy
                let dist = sqrt(dx * dx + dy * dy)
                if dist >= r { continue }
                var w = 1 - dist / r
                w = min(1, w * 2) * p * 2
                let i = gy * gw + gx
                frozen[i] = mode == .freeze ? min(1, frozen[i] + w) : max(0, frozen[i] - w)
            } }
            return
        }
        let old = d
        for gy in gy0...gy1 {
            for gx in gx0...gx1 {
                let px = Float(gx * step), py = Float(gy * step)
                let dx = px - cx, dy = py - cy
                let dist = sqrt(dx * dx + dy * dy)
                if dist >= r { continue }
                var w = 1 - dist / r
                w = w * w * (3 - 2 * w) * p
                let i = gy * gw + gx
                switch mode {
                case .forward:
                    // new(p) = old(p - δ·w) - δ·w
                    let sx = px - Float(delta.x) * w, sy = py - Float(delta.y) * w
                    let prev = sampleOld(old, sx, sy)
                    d[i] = prev + SIMD2(sx - px, sy - py)
                case .twirlCW, .twirlCCW:
                    let a = (mode == .twirlCW ? -0.06 : 0.06) * w
                    let rx = dx * cos(a) - dy * sin(a), ry = dx * sin(a) + dy * cos(a)
                    let sx = cx + rx, sy = cy + ry
                    d[i] = sampleOld(old, sx, sy) + SIMD2(sx - px, sy - py)
                case .pucker, .bloat:
                    let k: Float = (mode == .pucker ? 0.05 : -0.05) * w
                    let sx = px + dx * k, sy = py + dy * k
                    d[i] = sampleOld(old, sx, sy) + SIMD2(sx - px, sy - py)
                case .reconstruct:
                    d[i] = old[i] * (1 - 0.15 * w)
                case .smooth:
                    var acc = SIMD2<Float>.zero
                    var n: Float = 0
                    for oy in -1...1 { for ox in -1...1 {
                        let xx = clamp(gx + ox, 0, gw - 1), yy = clamp(gy + oy, 0, gh - 1)
                        acc += old[yy * gw + xx]; n += 1
                    } }
                    d[i] = old[i] + (acc / n - old[i]) * 0.5 * w
                case .freeze, .thaw:
                    break
                }
                if frozen[i] > 0 { d[i] = old[i] + (d[i] - old[i]) * (1 - frozen[i]) }
            }
        }
    }

    private func sampleOld(_ old: [SIMD2<Float>], _ x: Float, _ y: Float) -> SIMD2<Float> {
        let fx = clamp(x / Float(step), 0, Float(gw - 1)), fy = clamp(y / Float(step), 0, Float(gh - 1))
        let x0 = Int(fx), y0 = Int(fy)
        let x1 = min(gw - 1, x0 + 1), y1 = min(gh - 1, y0 + 1)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let a = old[y0 * gw + x0], b = old[y0 * gw + x1], c = old[y1 * gw + x0], e = old[y1 * gw + x1]
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + e * tx) * ty
    }

    /// CI-space displacement image (r = dx, g = dy in doc space): the field over the canvas it was painted on, zero
    /// outside it, so pixels of the layer beyond the canvas are never moved (Photoshop keeps them as they were).
    func ciImage(space: CanvasSpace) -> CIImage {
        DisplacementField.displacementImage(gw: gw, gh: gh, step: step, width: width, height: height, placement: .identity, space: space) { i in
            self.d[i] + self.face[i]
        }
    }

    /// The displacement image of a grid (cell (gx, gy) at doc (gx·step, gy·step) of a `width` × `height` canvas), its
    /// vectors and positions carried into the current doc space by the affine `placement` (doc → doc, y down), in the CI
    /// space of `space`. Zero outside the (placed) painting canvas.
    static func displacementImage(gw: Int, gh: Int, step: Int, width: Int, height: Int, placement t: CGAffineTransform, space: CanvasSpace,
                                  value: (Int) -> SIMD2<Float>) -> CIImage {
        let zero = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
        guard gw > 0, gh > 0, step > 0 else { return zero }
        var floats = [Float](repeating: 0, count: gw * gh * 4)
        let la = Float(t.a), lb = Float(t.b), lc = Float(t.c), ld = Float(t.d)
        // Bitmap row 0 is the top of the CI image.
        for gy in 0..<gh {
            for gx in 0..<gw {
                let i = gy * gw + gx
                let v = value(i)
                let o = i * 4
                floats[o] = la * v.x + lc * v.y; floats[o + 1] = lb * v.x + ld * v.y; floats[o + 3] = 1
            }
        }
        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        let img = CIImage(bitmapData: data, bytesPerRow: gw * 16, size: CGSize(width: gw, height: gh), format: .RGBAf, colorSpace: nil)
        // Grid cell (gx, gy) sits at doc (gx*step, gy*step) → CI of the painting canvas (x, H - y): cell centres
        // (gx, gy) → (gx*s, H - gy*s).
        let s = CGFloat(step), refH = CGFloat(height)
        let toRef = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: -0.5 * s, ty: refH - (CGFloat(gh) - 0.5) * s)
        var disp = img.transformed(by: toRef).clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        // painting-canvas CI → its doc space → placement → current doc space → current CI
        let m = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: refH)
            .concatenating(t)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(space.height)))
        if !m.isIdentity { disp = disp.transformed(by: m) }
        return disp.composited(over: zero)
    }

    /// Where a displacement image built with `placement` can be non-zero, in the CI space of `space`.
    static func reach(width: Int, height: Int, placement t: CGAffineTransform, space: CanvasSpace) -> CGRect {
        let docRect = CGRect(x: 0, y: 0, width: width, height: height).applying(t)
        return space.ciRect(docRect).integral
    }

    static let kernel = CIKernel(source: """
    kernel vec4 liquify(sampler src, sampler disp) {
        vec2 dc = destCoord();
        vec4 d = sample(disp, samplerTransform(disp, dc));
        return sample(src, samplerTransform(src, dc + vec2(d.r, -d.g)));
    }
    """)

    /// The warped layer. Like Photoshop, the whole canvas is the working area: the result covers the source *and* the
    /// canvas, so pixels pushed into empty, transparent parts of the canvas are kept (the layer grows) instead of being
    /// clipped to the layer's old bounds; pixels outside the canvas stay as they are.
    func warp(_ src: CIImage, space: CanvasSpace) -> CIImage {
        guard !isIdentity else { return src }
        return DisplacementField.warp(src, disp: ciImage(space: space), reach: DisplacementField.reach(width: width, height: height, placement: .identity, space: space), step: step)
    }

    /// `src` warped by a displacement image whose non-zero part lies within `reach` (CI). The result's extent is the
    /// source's plus `reach`; outside the source the warp samples transparency.
    static func warp(_ src: CIImage, disp: CIImage, reach: CGRect, step: Int) -> CIImage {
        guard let k = kernel, !src.extent.isInfinite else { return src }
        let ext = (src.extent.isEmpty ? reach : src.extent.union(reach)).integral
        guard !ext.isEmpty else { return src }
        let padded = src.composited(over: CIImage.clearImage.cropped(to: ext)).clampedToExtent()
        let pad = CGFloat(step) * 2
        return k.apply(extent: ext, roiCallback: { i, r in i == 0 ? ext.insetBy(dx: -2, dy: -2) : r.insetBy(dx: -pad, dy: -pad) },
                       arguments: [padded, disp])?.cropped(to: ext) ?? src
    }

    /// The field as a smart-filter mesh, painted with the smart object at `reference`.
    func mesh(reference: Quad) -> LiquifyMesh {
        var dx = [Float](repeating: 0, count: gw * gh), dy = dx
        for i in 0..<(gw * gh) { let v = d[i] + face[i]; dx[i] = v.x; dy[i] = v.y }
        return LiquifyMesh(width: width, height: height, step: step, gw: gw, gh: gh, dx: dx, dy: dy, reference: reference)
    }

    /// A field for a `width` × `height` canvas holding what `mesh` does there now (carried by `placement`): re-editing a
    /// Liquify smart filter after the object was moved or scaled starts from the effect as it shows.
    convenience init(width: Int, height: Int, mesh: LiquifyMesh, placement: CGAffineTransform) {
        self.init(width: width, height: height)
        for gy in 0..<gh { for gx in 0..<gw {
            let (x, y) = mesh.displacement(at: CGPoint(x: gx * step, y: gy * step), placement: placement)
            d[gy * gw + gx] = SIMD2(Float(x), Float(y))
        } }
    }
}

/// Liquify as a smart filter (Photoshop's way on a smart object): the stored mesh is applied to the smart object's
/// placed content in document space, so the result is not limited to the object's original or untransformed bounds —
/// it can reach anywhere on the canvas — and it follows the object when it is moved or scaled later.
enum LiquifySmartFilter {
    private struct Entry { let mesh: LiquifyMesh; let placement: CGAffineTransform; let height: Int; let image: CIImage }
    private static var cache: [UUID: Entry] = [:]
    private static let lock = NSLock()

    static func apply(_ f: FilterInstance, _ img: CIImage, space: CanvasSpace, quad: Quad?) -> CIImage {
        guard let mesh = f.liquify, mesh.isValid, !mesh.isIdentity, !img.extent.isInfinite else { return img }
        let t = quad.map { mesh.placement(to: $0) } ?? .identity
        let disp = displacement(f.id, mesh, t, space)
        // the working area is the canvas: the result may grow beyond the object up to (and only up to) the canvas
        let reach = DisplacementField.reach(width: mesh.width, height: mesh.height, placement: t, space: space)
            .intersection(space.ciCanvas.union(img.extent))
        guard !reach.isNull, !reach.isEmpty else { return img }   // the mesh's area is nowhere near: nothing moves
        return DisplacementField.warp(img, disp: disp, reach: reach, step: mesh.step)
    }

    private static func displacement(_ id: UUID, _ mesh: LiquifyMesh, _ t: CGAffineTransform, _ space: CanvasSpace) -> CIImage {
        lock.lock()
        if let e = cache[id], e.mesh == mesh, e.placement == t, e.height == space.height { lock.unlock(); return e.image }
        lock.unlock()
        let img = DisplacementField.displacementImage(gw: mesh.gw, gh: mesh.gh, step: mesh.step, width: mesh.width, height: mesh.height,
                                                      placement: t, space: space) { i in SIMD2(mesh.dx[i], mesh.dy[i]) }
        lock.lock()
        if cache.count > 32 { cache.removeAll() }
        cache[id] = Entry(mesh: mesh, placement: t, height: space.height, image: img)
        lock.unlock()
        return img
    }
}

// MARK: - Preview view

final class LiquifyPreviewView: NSView {
    var source: CIImage = .empty()
    /// The document's selection (canvas-size gray) and the layer's transparency lock: OK applies the warp only there,
    /// so the preview shows it the same way.
    var selection: CIImage?
    var lockAlpha = false
    var space = CanvasSpace(width: 1, height: 1)
    var field: DisplacementField?
    var mode: LiquifyMode = .forward
    var brushSize: Double = 100
    var pressure: Double = 0.5
    /// Photoshop's "Stylus Pressure": the pen's pressure scales the brush pressure (a mouse counts as full).
    var useStylus = true
    /// Pen pressure of the current sample (Preferences ▸ Tablet curve applied).
    private(set) var penPressure: Double = 1
    var showMask = true
    var onChange: (() -> Void)?
    private var last: CGPoint?
    private var mouse: CGPoint?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var fitScale: CGFloat { min(bounds.width / CGFloat(space.width), bounds.height / CGFloat(space.height)) }
    var fitOrigin: CGPoint {
        let s = fitScale
        return CGPoint(x: (bounds.width - CGFloat(space.width) * s) / 2, y: (bounds.height - CGFloat(space.height) * s) / 2)
    }
    func toDoc(_ v: CGPoint) -> CGPoint { (v - fitOrigin) / fitScale }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(white: 0.16, alpha: 1).setFill()
        bounds.fill()
        let s = fitScale, o = fitOrigin
        let docRect = CGRect(x: o.x, y: o.y, width: CGFloat(space.width) * s, height: CGFloat(space.height) * s)
        // checker
        let cs: CGFloat = 8
        ctx.saveGState()
        ctx.clip(to: docRect)
        NSColor.white.setFill(); docRect.fill()
        NSColor(white: 0.82, alpha: 1).setFill()
        var y = docRect.minY; var row = 0
        while y < docRect.maxY {
            var x = docRect.minX + (row % 2 == 0 ? 0 : cs)
            while x < docRect.maxX { CGRect(x: x, y: y, width: cs, height: cs).fill(); x += cs * 2 }
            y += cs; row += 1
        }
        ctx.restoreGState()
        var warped = field?.warp(source, space: space) ?? source
        if selection != nil || lockAlpha {
            warped = AppActions.restrict(warped, original: source, selection: selection, lockAlpha: lockAlpha, canvas: space.ciCanvas)
        }
        let scale = s * (window?.backingScaleFactor ?? 2)
        let scaled = warped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let r = CGRect(x: 0, y: 0, width: CGFloat(space.width) * scale, height: CGFloat(space.height) * scale).integral
        if let cg = RenderEngine.context.createCGImage(scaled, from: r, format: .RGBA8, colorSpace: sRGBSpace) {
            ctx.saveGState()
            ctx.translateBy(x: docRect.minX, y: docRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(cg, in: CGRect(origin: .zero, size: docRect.size))
            ctx.restoreGState()
        }
        if showMask, let f = field, f.frozen.contains(where: { $0 > 0 }) {
            var px = [UInt8](repeating: 0, count: f.gw * f.gh * 4)
            for i in 0..<(f.gw * f.gh) where f.frozen[i] > 0 {
                let a = UInt8(min(1, f.frozen[i]) * 110)
                px[i * 4] = a; px[i * 4 + 3] = a   // premultiplied red
            }
            if let prov = CGDataProvider(data: Data(px) as CFData),
               let img = CGImage(width: f.gw, height: f.gh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: f.gw * 4, space: sRGBSpace,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                let cell = CGFloat(f.step) * s
                ctx.saveGState()
                ctx.clip(to: docRect)
                ctx.translateBy(x: docRect.minX - cell / 2, y: docRect.minY - cell / 2 + CGFloat(f.gh) * cell)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: CGFloat(f.gw) * cell, height: CGFloat(f.gh) * cell))
                ctx.restoreGState()
            }
        }
        if let m = mouse {
            let d = brushSize * s
            let rr = CGRect(x: m.x - d / 2, y: m.y - d / 2, width: d, height: d)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: rr)
            ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(0.5); ctx.strokeEllipse(in: rr.insetBy(dx: -1.5, dy: -1.5))
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self, userInfo: nil)
        addTrackingArea(t); tracking = t
    }

    override func mouseMoved(with event: NSEvent) { mouse = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { mouse = nil; needsDisplay = true }

    private func readPen(_ e: NSEvent, _ phase: TabletInput.Phase) {
        let r = TabletInput.shared.reading(e, phase: phase)
        penPressure = useStylus && r.isTablet ? r.pressure : 1
    }

    override func mouseDown(with event: NSEvent) {
        TabletInput.shared.beginStroke(painting: true)
        readPen(event, .down)
        let v = convert(event.locationInWindow, from: nil)
        last = toDoc(v)
        mouse = v
        stamp(at: last!, delta: .zero)
    }

    override func mouseDragged(with event: NSEvent) {
        readPen(event, .drag)
        let v = convert(event.locationInWindow, from: nil)
        mouse = v
        let p = toDoc(v)
        guard let l = last else { return }
        let dist = p.distance(to: l)
        let stepLen = max(1, brushSize * 0.08)
        let n = max(1, Int(dist / stepLen))
        for i in 1...n {
            let a = l.lerp(p, CGFloat(i - 1) / CGFloat(n)), b = l.lerp(p, CGFloat(i) / CGFloat(n))
            stamp(at: b, delta: b - a)
        }
        last = p
    }

    override func mouseUp(with event: NSEvent) { last = nil; TabletInput.shared.endStroke(); onChange?() }
    override func tabletPoint(with event: NSEvent) { if last != nil { mouseDragged(with: event) } }

    private func stamp(at p: CGPoint, delta: CGPoint) {
        guard let f = field else { return }
        if mode == .forward && delta == .zero { needsDisplay = true; return }
        f.apply(mode: mode, center: p, delta: delta, radius: brushSize / 2, pressure: pressure * penPressure)
        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        brushSize = clamp(brushSize * pow(1.02, Double(event.scrollingDeltaY)), 5, 2000)
        needsDisplay = true
    }
}

struct LiquifyPreview: NSViewRepresentable {
    let source: CIImage
    let space: CanvasSpace
    let field: DisplacementField
    var selection: CIImage? = nil
    var lockAlpha = false
    var mode: LiquifyMode
    var brushSize: Double
    var pressure: Double
    var useStylus = true
    var showMask = true
    var tick = 0

    func makeNSView(context: Context) -> LiquifyPreviewView {
        let v = LiquifyPreviewView()
        v.source = source; v.space = space; v.field = field
        v.selection = selection; v.lockAlpha = lockAlpha
        return v
    }
    func updateNSView(_ v: LiquifyPreviewView, context: Context) {
        v.mode = mode; v.brushSize = brushSize; v.pressure = pressure; v.useStylus = useStylus; v.showMask = showMask
        v.needsDisplay = true
    }
}

// MARK: - Dialog

extension LiquifyDialog {
    func faceSlider(_ label: String, _ kp: WritableKeyPath<FaceAwareSettings, Double>) -> some View {
        ValueSlider(label: label, value: Binding(get: { faceSettings[keyPath: kp] }, set: { faceSettings[keyPath: kp] = $0 }), range: -100...100, labelWidth: 84)
    }
}

struct LiquifyDialog: View {
    @State private var mode: LiquifyMode = .forward
    @State private var size: Double = 150
    @State private var pressure: Double = 0.5
    @State private var stylusPressure = true
    @State private var field: DisplacementField
    @State private var resetToken = 0
    @State private var showMask = true
    @State private var faceSettings = FaceAwareSettings()
    @State private var faceIndex = 0
    @State private var tick = 0
    let faces: [FaceLandmarks]
    let source: CIImage
    let space: CanvasSpace
    /// What OK keeps the warp to (see `AppActions.restrict`).
    let selection: CIImage?
    let lockAlpha: Bool
    /// A smart object: OK adds (or, with `editingFilter`, updates) a Liquify smart filter instead of changing pixels.
    let smartLayer: UUID?
    let editingFilter: UUID?

    init(smartLayer: UUID? = nil, editingFilter: UUID? = nil) {
        let d = AppActions.doc
        let sp = CanvasSpace(width: d?.state.width ?? 1, height: d?.state.height ?? 1)
        space = sp
        let src = LiquifyDialog.workingSource(d, smartLayer: smartLayer, editingFilter: editingFilter)
        self.smartLayer = src.smartLayer
        self.editingFilter = src.smartLayer == nil ? nil : editingFilter
        source = src.image
        selection = src.selection
        lockAlpha = src.lockAlpha
        faces = FaceLandmarks.detect(src.image, space: sp)
        _field = State(initialValue: src.field ?? DisplacementField(width: sp.width, height: sp.height))
    }

    /// What the dialog warps, exactly what OK will warp (so the preview is the result): the active layer's pixels — all
    /// of them, including any outside the canvas, on a transparent canvas-size area the warp may push them into — or,
    /// for a smart object, its placed content after the smart filters below this one.
    static func workingSource(_ d: Document?, smartLayer: UUID? = nil, editingFilter: UUID? = nil)
        -> (image: CIImage, selection: CIImage?, lockAlpha: Bool, smartLayer: UUID?, field: DisplacementField?) {
        let sp = CanvasSpace(width: d?.state.width ?? 1, height: d?.state.height ?? 1)
        let clear = CIImage.clearImage.cropped(to: sp.ciCanvas)
        guard let d else { return (clear, nil, false, nil, nil) }
        func materialized(_ c: CIImage) -> CIImage {
            let rect = (c.extent.isInfinite || c.extent.isEmpty ? sp.ciCanvas : c.extent.union(sp.ciCanvas)).integral
            let img = c.composited(over: CIImage.clearImage.cropped(to: rect)).cropped(to: rect)
            // materialize once for speed
            if let cg = RenderEngine.cgImage(img, rect: rect) { return CIImage(cgImage: cg).translated(rect.minX, rect.minY) }
            return img
        }
        let sid = smartLayer ?? (!d.quickMask && d.activeLayer?.isSmartObject == true ? d.activeLayerID : nil)
        if let sid, let l = d.state.layer(sid), let so = l.smart {
            let index = editingFilter.flatMap { e in so.filters.firstIndex { $0.id == e } } ?? so.filters.count
            let img = materialized(Compositor.shared.smartImage(sid, so, space: sp, filtersBelow: index))
            var sel = d.state.selection?.ciImage
            var field: DisplacementField? = nil
            if so.filters.indices.contains(index), editingFilter != nil {
                let f = so.filters[index]
                sel = f.mask.map { m in
                    sp.place(m.buffer, at: m.origin).composited(over: CIImage.color(RGBA(gray: Double(m.outsideValue) / 255), sp.ciCanvas))
                }
                if let mesh = f.liquify, mesh.isValid {
                    field = DisplacementField(width: sp.width, height: sp.height, mesh: mesh, placement: mesh.placement(to: so.quad))
                }
            }
            return (img, sel, false, sid, field)
        }
        var img = clear
        if let l = d.activeLayer, let c = Compositor.shared.contentImage(l, space: sp) { img = materialized(c) }
        return (img, d.state.selection?.ciImage, d.activeLayer?.locks.transparency == true, nil, nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(tr(smartLayer != nil ? "Liquify (Smart Filter)" : "Liquify")).font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    ForEach(LiquifyMode.allCases) { m in
                        IconButton(symbol: m.symbol, help: m.rawValue, active: mode == m, size: 30) { mode = m }
                    }
                }
                LiquifyPreview(source: source, space: space, field: field, selection: selection, lockAlpha: lockAlpha,
                               mode: mode, brushSize: size, pressure: pressure, useStylus: stylusPressure, showMask: showMask, tick: tick)
                    .id(resetToken)
                    .frame(width: 820, height: 540)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 10) {
                    Caption("Brush Tool Options")
                    Text(tr(mode.rawValue)).font(Theme.fontBold)
                    ValueSlider(label: "Size", value: $size, range: 5...2000, unit: " px", labelWidth: 54)
                    ValueSlider(label: "Pressure", value: Binding(get: { pressure * 100 }, set: { pressure = $0 / 100 }), range: 1...100, unit: "%", labelWidth: 54)
                    Toggle2(label: "Stylus Pressure", on: $stylusPressure)
                    Divider()
                    Caption("Mask Options")
                    HStack(spacing: 4) {
                        Button("None") { field.setAllFrozen(0); tick += 1 }.buttonStyle(PanelButtonStyle())
                        Button("Mask All") { field.setAllFrozen(1); tick += 1 }.buttonStyle(PanelButtonStyle())
                        Button("Invert") { field.invertFrozen(); tick += 1 }.buttonStyle(PanelButtonStyle())
                    }
                    Toggle2(label: "Show Mask", on: $showMask)
                    Divider()
                    Caption("Face-Aware Liquify")
                    if faces.isEmpty {
                        Text("No faces detected.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                if faces.count > 1 {
                                    Picker("Face", selection: $faceIndex) { ForEach(faces.indices, id: \.self) { Text("Face #\($0 + 1)").tag($0) } }
                                }
                                Text("Eyes").font(Theme.fontBold)
                                faceSlider("Eye Size", \.eyeSize); faceSlider("Eye Height", \.eyeHeight); faceSlider("Eye Width", \.eyeWidth)
                                faceSlider("Eye Tilt", \.eyeTilt); faceSlider("Eye Distance", \.eyeDistance)
                                Text("Nose").font(Theme.fontBold)
                                faceSlider("Nose Height", \.noseHeight); faceSlider("Nose Width", \.noseWidth)
                                Text("Mouth").font(Theme.fontBold)
                                faceSlider("Smile", \.smile); faceSlider("Upper Lip", \.upperLip); faceSlider("Lower Lip", \.lowerLip)
                                faceSlider("Mouth Width", \.mouthWidth); faceSlider("Mouth Height", \.mouthHeight)
                                Text("Face Shape").font(Theme.fontBold)
                                faceSlider("Forehead", \.forehead); faceSlider("Chin Height", \.chinHeight)
                                faceSlider("Jawline", \.jawline); faceSlider("Face Width", \.faceWidth)
                                Button("Reset Face") { faceSettings = FaceAwareSettings() }.buttonStyle(PanelButtonStyle())
                            }
                        }
                        .frame(maxHeight: 260)
                    }
                    Divider()
                    Button("Restore All") { field.reset(); faceSettings = FaceAwareSettings(); resetToken += 1 }.buttonStyle(PanelButtonStyle())
                    Text("Drag on the preview to warp. Scroll to change the brush size. Freeze Mask protects areas.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                    Spacer()
                }
                .frame(width: 230)
                .onChange(of: faceSettings) { _, v in
                    let pick = faces.indices.contains(faceIndex) ? [faces[faceIndex]] : faces
                    field.applyFaces(pick, v)
                    tick += 1
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") {
                    let f = field, sl = smartLayer, ef = editingFilter
                    AppModel.shared.dialog = nil
                    AppActions.applyLiquify(f, smartLayer: sl, editingFilter: ef)
                }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }
}

// MARK: - Face-Aware Liquify

/// Facial landmarks (doc coordinates, y-down) detected with Vision.
struct FaceLandmarks {
    var bounds: CGRect
    var leftEye: [CGPoint]      // eye with the smaller x in the image
    var rightEye: [CGPoint]
    var nose: [CGPoint]
    var outerLips: [CGPoint]
    var contour: [CGPoint]

    static func centroid(_ p: [CGPoint]) -> CGPoint {
        guard !p.isEmpty else { return .zero }
        return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
    }
    static func extent(_ p: [CGPoint]) -> CGRect {
        guard let f = p.first else { return .zero }
        return p.reduce(CGRect(origin: f, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    static func detect(_ img: CIImage, space: CanvasSpace) -> [FaceLandmarks] {
        let flat = img.composited(over: CIImage.color(.white, space.ciCanvas)).cropped(to: space.ciCanvas)
        guard let cg = RenderEngine.cgImage(flat, rect: space.ciCanvas) else { return [] }
        let req = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
        let W = CGFloat(space.width), H = CGFloat(space.height)
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (r?.pointsInImage(imageSize: CGSize(width: W, height: H)) ?? []).map { CGPoint(x: $0.x, y: H - $0.y) }
        }
        return (req.results ?? []).compactMap { f in
            guard let lm = f.landmarks else { return nil }
            let bb = f.boundingBox
            var a = pts(lm.leftEye), b = pts(lm.rightEye)
            if centroid(a).x > centroid(b).x { swap(&a, &b) }
            return FaceLandmarks(bounds: CGRect(x: bb.minX * W, y: (1 - bb.maxY) * H, width: bb.width * W, height: bb.height * H),
                                 leftEye: a, rightEye: b, nose: pts(lm.nose), outerLips: pts(lm.outerLips), contour: pts(lm.faceContour))
        }
    }
}

struct FaceAwareSettings: Equatable {
    var eyeSize: Double = 0, eyeHeight: Double = 0, eyeWidth: Double = 0, eyeTilt: Double = 0, eyeDistance: Double = 0
    var noseHeight: Double = 0, noseWidth: Double = 0
    var smile: Double = 0, upperLip: Double = 0, lowerLip: Double = 0, mouthWidth: Double = 0, mouthHeight: Double = 0
    var forehead: Double = 0, chinHeight: Double = 0, jawline: Double = 0, faceWidth: Double = 0
}

extension DisplacementField {
    /// Recomputes the face displacement layer from the sliders (all values −100…100).
    func applyFaces(_ faces: [FaceLandmarks], _ s: FaceAwareSettings) {
        face = Array(repeating: .zero, count: gw * gh)
        for f in faces {
            let fw = f.bounds.width
            // helper: add displacement disp(p) for cells within radius r of c (smooth falloff)
            func region(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ disp: (CGFloat, CGFloat) -> CGPoint) {
                guard rx > 1, ry > 1 else { return }
                let gx0 = max(0, Int((c.x - rx) / CGFloat(step))), gx1 = min(gw - 1, Int((c.x + rx) / CGFloat(step)) + 1)
                let gy0 = max(0, Int((c.y - ry) / CGFloat(step))), gy1 = min(gh - 1, Int((c.y + ry) / CGFloat(step)) + 1)
                guard gx0 <= gx1, gy0 <= gy1 else { return }
                for gy in gy0...gy1 { for gx in gx0...gx1 {
                    let dx = CGFloat(gx * step) - c.x, dy = CGFloat(gy * step) - c.y
                    let t = sqrt((dx / rx) * (dx / rx) + (dy / ry) * (dy / ry))
                    if t >= 1 { continue }
                    var w = 1 - t
                    w = w * w * (3 - 2 * w)
                    let v = disp(dx, dy)
                    face[gy * gw + gx] += SIMD2(Float(v.x * w), Float(v.y * w))
                } }
            }
            let k = { (v: Double) in CGFloat(v / 100) }
            // Eyes
            for (i, eye) in [f.leftEye, f.rightEye].enumerated() where !eye.isEmpty {
                let c = FaceLandmarks.centroid(eye), e = FaceLandmarks.extent(eye)
                let r = max(e.width, fw * 0.12) * 1.4
                let side: CGFloat = i == 0 ? -1 : 1
                if s.eyeSize != 0 { region(c, r, r) { dx, dy in CGPoint(x: -dx * k(s.eyeSize) * 0.35, y: -dy * k(s.eyeSize) * 0.35) } }
                if s.eyeWidth != 0 { region(c, r, r) { dx, _ in CGPoint(x: -dx * k(s.eyeWidth) * 0.35, y: 0) } }
                if s.eyeHeight != 0 { region(c, r, r) { _, _ in CGPoint(x: 0, y: k(s.eyeHeight) * r * 0.25) } }
                if s.eyeDistance != 0 { region(c, r, r) { _, _ in CGPoint(x: -side * k(s.eyeDistance) * r * 0.3, y: 0) } }
                if s.eyeTilt != 0 {
                    let a = side * k(s.eyeTilt) * 0.3
                    region(c, r, r) { dx, dy in CGPoint(x: dx * cos(a) - dy * sin(a) - dx, y: dx * sin(a) + dy * cos(a) - dy) }
                }
            }
            // Nose
            if !f.nose.isEmpty {
                let c = FaceLandmarks.centroid(f.nose), e = FaceLandmarks.extent(f.nose)
                let r = max(e.width, fw * 0.15) * 1.3
                if s.noseWidth != 0 { region(c, r, r) { dx, _ in CGPoint(x: -dx * k(s.noseWidth) * 0.35, y: 0) } }
                if s.noseHeight != 0 { region(c, r, r * 1.2) { _, _ in CGPoint(x: 0, y: k(s.noseHeight) * r * 0.2) } }
            }
            // Mouth
            if !f.outerLips.isEmpty {
                let c = FaceLandmarks.centroid(f.outerLips), e = FaceLandmarks.extent(f.outerLips)
                let rx = max(e.width, fw * 0.25) * 0.8, ry = max(e.height, fw * 0.1) * 1.4
                if s.mouthWidth != 0 { region(c, rx * 1.3, ry) { dx, _ in CGPoint(x: -dx * k(s.mouthWidth) * 0.3, y: 0) } }
                if s.mouthHeight != 0 { region(c, rx, ry) { _, dy in CGPoint(x: 0, y: -dy * k(s.mouthHeight) * 0.35) } }
                if s.upperLip != 0 { region(CGPoint(x: c.x, y: c.y - e.height * 0.25), rx, ry * 0.6) { _, dy in CGPoint(x: 0, y: -dy * k(s.upperLip) * 0.4) } }
                if s.lowerLip != 0 { region(CGPoint(x: c.x, y: c.y + e.height * 0.25), rx, ry * 0.6) { _, dy in CGPoint(x: 0, y: -dy * k(s.lowerLip) * 0.4) } }
                if s.smile != 0 {
                    for corner in [CGPoint(x: e.minX, y: c.y), CGPoint(x: e.maxX, y: c.y)] {
                        let side: CGFloat = corner.x < c.x ? -1 : 1
                        region(corner, rx * 1.0, ry * 1.1) { _, _ in CGPoint(x: -side * k(s.smile) * rx * 0.08, y: k(s.smile) * ry * 0.3) }
                    }
                }
            }
            // Face shape
            let fc = CGPoint(x: f.bounds.midX, y: f.bounds.midY)
            if s.faceWidth != 0 { region(fc, f.bounds.width * 0.75, f.bounds.height * 0.7) { dx, _ in CGPoint(x: -dx * k(s.faceWidth) * 0.12, y: 0) } }
            if s.jawline != 0 {
                region(CGPoint(x: fc.x, y: f.bounds.maxY - f.bounds.height * 0.15), f.bounds.width * 0.75, f.bounds.height * 0.35) { dx, _ in CGPoint(x: -dx * k(s.jawline) * 0.15, y: 0) }
            }
            if s.chinHeight != 0 {
                region(CGPoint(x: fc.x, y: f.bounds.maxY), f.bounds.width * 0.35, f.bounds.height * 0.3) { _, _ in CGPoint(x: 0, y: -k(s.chinHeight) * f.bounds.height * 0.06) }
            }
            if s.forehead != 0 {
                region(CGPoint(x: fc.x, y: f.bounds.minY), f.bounds.width * 0.6, f.bounds.height * 0.35) { _, _ in CGPoint(x: 0, y: k(s.forehead) * f.bounds.height * 0.06) }
            }
        }
    }
}
