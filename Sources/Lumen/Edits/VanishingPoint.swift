import SwiftUI
import AppKit
import ImageCratCore

// MARK: - Vanishing Point (Filter ▸ Vanishing Point…)
//
// Perspective planes are quads (doc coordinates, tl/tr/br/bl) mapped from the unit square by a homography. Edits use
// "metric" plane coordinates (u·aspect·scale, v·scale) so that brush sizes, offsets and marquees behave like pixels
// measured at the plane's reference size, and shrink with distance automatically.

/// Bilinear sample of a premultiplied RGBA buffer at doc point (x, y) (pixel centres at +0.5). Outside → transparent.
@inline(__always) func vpSample(_ b: PixelBuffer, _ x: CGFloat, _ y: CGFloat) -> SIMD4<Float> {
    let fx = Float(x) - 0.5, fy = Float(y) - 0.5
    let x0 = Int(floor(fx)), y0 = Int(floor(fy))
    let tx = fx - Float(x0), ty = fy - Float(y0)
    let p = b.data.assumingMemoryBound(to: UInt8.self)
    @inline(__always) func px(_ x: Int, _ y: Int) -> SIMD4<Float> {
        let xx = min(max(x, 0), b.width - 1), yy = min(max(y, 0), b.height - 1)
        if x < -1 || y < -1 || x > b.width || y > b.height { return .zero }
        let q = p + yy * b.bytesPerRow + xx * 4
        return SIMD4(Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3]))
    }
    let a = px(x0, y0), c = px(x0 + 1, y0), d = px(x0, y0 + 1), e = px(x0 + 1, y0 + 1)
    return (a * (1 - tx) + c * tx) * (1 - ty) + (d * (1 - tx) + e * tx) * ty
}

struct VPPlane: Equatable {
    var q: Quad

    var H: Homography? { Homography.squareToQuad(q) }
    var scale: CGFloat { max(1, (q.tl.distance(to: q.bl) + q.tr.distance(to: q.br)) / 2) }
    var aspect: CGFloat { max(0.01, (q.tl.distance(to: q.tr) + q.bl.distance(to: q.br)) / 2 / scale) }

    /// Convex, non-degenerate quad (grids draw blue); otherwise red like Photoshop.
    var isValid: Bool {
        let p = q.points
        var sign: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cr = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cr) < 1e-3 { return false }
            if sign == 0 { sign = cr > 0 ? 1 : -1 } else if (cr > 0 ? 1 : -1) != sign { return false }
        }
        return H != nil
    }

    func toMetric(_ p: CGPoint) -> CGPoint? {
        guard let hi = H?.inverted else { return nil }
        let uv = hi.apply(p)
        return CGPoint(x: uv.x * aspect * scale, y: uv.y * scale)
    }

    func fromMetric(_ m: CGPoint) -> CGPoint {
        guard let h = H else { return m }
        return h.apply(CGPoint(x: m.x / (aspect * scale), y: m.y / scale))
    }

    func contains(_ p: CGPoint) -> Bool { q.path.contains(p) }

    /// Homogeneous vanishing points of the plane's u and v directions.
    var vanishing: (SIMD3<Double>, SIMD3<Double>)? {
        guard let h = H else { return nil }
        let m = h.m
        return (SIMD3(m[0], m[3], m[6]), SIMD3(m[1], m[4], m[7]))
    }
}

enum VPGeom {
    @inline(__always) static func h(_ p: CGPoint) -> SIMD3<Double> { SIMD3(Double(p.x), Double(p.y), 1) }
    @inline(__always) static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    static func point(_ v: SIMD3<Double>) -> CGPoint? {
        guard abs(v.z) > 1e-12 else { return nil }
        return CGPoint(x: v.x / v.z, y: v.y / v.z)
    }
    /// Line through a point and a (possibly infinite) vanishing point.
    static func line(_ p: CGPoint, _ v: SIMD3<Double>) -> SIMD3<Double> { cross(h(p), v) }
    static func meet(_ l1: SIMD3<Double>, _ l2: SIMD3<Double>) -> CGPoint? { point(cross(l1, l2)) }

    /// Orthogonal projection of `p` onto the line through `a` towards vanishing point `v`.
    static func project(_ p: CGPoint, onto a: CGPoint, towards v: SIMD3<Double>) -> CGPoint {
        var dir: CGPoint
        if let vp = point(v), vp.distance(to: a) > 1e-6 { dir = (vp - a).normalized } else { dir = CGPoint(x: v.x, y: v.y).normalized }
        if dir == .zero { return p }
        return a + dir * (p - a).dot(dir)
    }

    /// Vanishing point of the direction perpendicular (in 3-D) to a plane, assuming square pixels and the principal
    /// point at the image centre; the focal length follows from the plane's two orthogonal vanishing points.
    static func perpendicularVanishing(_ plane: VPPlane, imageSize: CGSize) -> SIMD3<Double>? {
        guard let (v1, v2) = plane.vanishing else { return nil }
        let cx = Double(imageSize.width) / 2, cy = Double(imageSize.height) / 2
        func centered(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(v.x - cx * v.z, v.y - cy * v.z, v.z) }
        let a = centered(v1), b = centered(v2)
        var f2 = -(a.x * b.x + a.y * b.y) / (a.z * b.z)
        let dflt = pow(Double(max(imageSize.width, imageSize.height)) * 1.2, 2)
        if !f2.isFinite || f2 <= 0 || f2 > dflt * 400 || f2 < dflt / 400 { f2 = dflt }
        let f = f2.squareRoot()
        let d1 = SIMD3(a.x / f, a.y / f, a.z), d2 = SIMD3(b.x / f, b.y / f, b.z)
        let n = cross(d1, d2)
        let v3c = SIMD3(n.x * f, n.y * f, n.z)
        return SIMD3(v3c.x + cx * v3c.z, v3c.y + cy * v3c.z, v3c.z)
    }
}

enum VPTool: String, CaseIterable, Identifiable {
    case editPlane = "Edit Plane", createPlane = "Create Plane", marquee = "Marquee", stamp = "Stamp", brush = "Brush", transform = "Transform"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .editPlane: return "cursorarrow"
        case .createPlane: return "square.grid.3x3.topleft.filled"
        case .marquee: return "rectangle.dashed"
        case .stamp: return "seal"
        case .brush: return "paintbrush.pointed"
        case .transform: return "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

final class VPModel: ObservableObject {
    /// Working pixels (canvas size, the active layer).
    let original: PixelBuffer
    @Published var image: PixelBuffer
    @Published var planes: [VPPlane] = []
    @Published var active: Int? = nil
    @Published var tool: VPTool = .createPlane
    @Published var pending: [CGPoint] = []
    @Published var gridSize: Double = 50
    @Published var brushSize: Double = 40
    @Published var hardness: Double = 50
    @Published var opacity: Double = 100
    @Published var color: RGBA = AppModel.shared.foreground
    @Published var feather: Double = 1
    @Published var tick = 0
    // stamp
    @Published var stampSource: (plane: Int, metric: CGPoint)? = nil
    var stampOffset: CGPoint? = nil       // dest metric − source metric (aligned)
    var aligned = true
    // marquee
    @Published var marquee: (plane: Int, rect: CGRect)? = nil
    // paste
    @Published var paste: (img: PixelBuffer, plane: Int, center: CGPoint, width: CGFloat)? = nil

    private var strokeBase: PixelBuffer?
    private var dragStartMetric: CGPoint?
    private var marqueeAtDragStart: CGRect?
    private var lastDab: CGPoint?

    init(image: PixelBuffer) {
        original = image.copy()
        self.image = image
    }

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    func planeIndex(at p: CGPoint) -> Int? {
        if let a = active, planes.indices.contains(a), planes[a].contains(p) { return a }
        return planes.lastIndex { $0.contains(p) }
    }

    // MARK: Planes

    @discardableResult
    func addPoint(_ p: CGPoint) -> Int? {
        pending.append(p)
        if pending.count == 4 {
            let q = Quad(tl: pending[0], tr: pending[1], br: pending[2], bl: pending[3])
            pending = []
            planes.append(VPPlane(q: q))
            active = planes.count - 1
            tool = .editPlane
            return active
        }
        return nil
    }

    /// Edge index: 0 top (tl→tr), 1 right (tr→br), 2 bottom (br→bl), 3 left (bl→tl).
    static func edge(_ q: Quad, _ e: Int) -> (CGPoint, CGPoint) {
        let p = q.points
        return (p[e], p[(e + 1) % 4])
    }

    /// Photoshop's ⌘-drag of an edge node: tears off a plane perpendicular (in 3-D) to plane `i`, sharing edge `e`.
    @discardableResult
    func tearOff(plane i: Int, edge e: Int, to target: CGPoint) -> Int? {
        guard planes.indices.contains(i), let q = tearOffQuad(plane: i, edge: e, to: target) else { return nil }
        planes.append(VPPlane(q: q))
        active = planes.count - 1
        return active
    }

    func tearOffQuad(plane i: Int, edge e: Int, to target: CGPoint) -> Quad? {
        let pl = planes[i]
        guard let (v1, v2) = pl.vanishing, let v3 = VPGeom.perpendicularVanishing(pl, imageSize: size) else { return nil }
        let (a, b) = VPModel.edge(pl.q, e)
        let ve = e % 2 == 0 ? v1 : v2
        let mid = (a + b) / 2
        let m2 = VPGeom.project(target, onto: mid, towards: v3)
        let across = VPGeom.line(m2, ve)
        guard let a2 = VPGeom.meet(VPGeom.line(a, v3), across), let b2 = VPGeom.meet(VPGeom.line(b, v3), across) else { return nil }
        // new plane: shared edge a-b as its "bottom", the torn edge a2-b2 as its "top"
        return Quad(tl: a2, tr: b2, br: b, bl: a)
    }

    /// Plain edge-node drag: moves the edge along the plane (extends / shrinks it) keeping its perspective.
    func extend(plane i: Int, edge e: Int, to target: CGPoint) {
        guard planes.indices.contains(i), let (v1, v2) = planes[i].vanishing else { return }
        var p = planes[i].q.points
        let (ia, ib) = (e, (e + 1) % 4)
        let (id, ic) = ((e + 3) % 4, (e + 2) % 4)       // corners of the opposite edge adjacent to a and b
        let ve = e % 2 == 0 ? v1 : v2, vo = e % 2 == 0 ? v2 : v1
        let mid = (p[ia] + p[ib]) / 2
        let m2 = VPGeom.project(target, onto: mid, towards: vo)
        let across = VPGeom.line(m2, ve)
        guard let na = VPGeom.meet(VPGeom.line(p[id], vo), across), let nb = VPGeom.meet(VPGeom.line(p[ic], vo), across) else { return }
        p[ia] = na; p[ib] = nb
        let nq = Quad(tl: p[0], tr: p[1], br: p[2], bl: p[3])
        if VPPlane(q: nq).isValid { planes[i].q = nq }
    }

    func moveCorner(plane i: Int, corner c: Int, to p: CGPoint) {
        guard planes.indices.contains(i) else { return }
        var pts = planes[i].q.points
        pts[c] = p
        planes[i].q = Quad(tl: pts[0], tr: pts[1], br: pts[2], bl: pts[3])
    }

    func deletePlane(_ i: Int) {
        guard planes.indices.contains(i) else { return }
        planes.remove(at: i)
        active = planes.isEmpty ? nil : planes.count - 1
        marquee = nil; stampSource = nil; paste = nil
    }

    // MARK: Painting in perspective

    /// Doc bounding box of a metric circle on a plane.
    func footprint(_ pl: VPPlane, center m: CGPoint, radius r: CGFloat) -> IRect {
        var pts: [CGPoint] = []
        for k in 0..<16 { let a = CGFloat(k) / 16 * 2 * .pi; pts.append(pl.fromMetric(m + CGPoint(x: cos(a) * r, y: sin(a) * r))) }
        let b = CGRect.bounding(pts).insetBy(dx: -2, dy: -2)
        return IRect(enclosing: b).intersection(IRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    @inline(__always) func falloff(_ t: CGFloat) -> Float {
        let h = CGFloat(hardness / 100)
        if t >= 1 { return 0 }
        if t <= h { return 1 }
        let x = (t - h) / max(0.001, 1 - h)
        return Float(1 - x * x * (3 - 2 * x))
    }

    func beginStroke() { strokeBase = image.copy(); lastDab = nil }
    func endStroke() { strokeBase = nil; lastDab = nil; tick += 1 }

    func defineStampSource(_ p: CGPoint) {
        guard let i = planeIndex(at: p), let m = planes[i].toMetric(p) else { NSSound.beep(); return }
        stampSource = (i, m)
        stampOffset = nil
    }

    /// Dabs along the path from the previous dab to `p` (spacing ¼ of the brush in metric units).
    func paint(at p: CGPoint, stamp: Bool) {
        guard let i = planeIndex(at: p), let m = planes[i].toMetric(p) else { return }
        if stamp {
            guard let src = stampSource else { return }
            if stampOffset == nil || (!aligned && lastDab == nil) { stampOffset = m - src.metric }
        }
        if let last = lastDab {
            let d = last.distance(to: m), step = max(1, CGFloat(brushSize) * 0.2)
            if d < step { return }
            var t = step
            while t <= d { dab(plane: i, metric: last.lerp(m, t / d), stamp: stamp); t += step }
            lastDab = last.lerp(m, min(1, (t - step) / d))
        } else {
            dab(plane: i, metric: m, stamp: stamp)
            lastDab = m
        }
    }

    func dab(plane i: Int, metric m: CGPoint, stamp: Bool) {
        let pl = planes[i]
        let r = CGFloat(brushSize / 2)
        let box = footprint(pl, center: m, radius: r)
        guard !box.isEmpty, let base = strokeBase ?? Optional(image) else { return }
        let src = stamp ? stampSource : nil
        let srcPlane = src.map { planes[$0.plane] }
        let off = stampOffset ?? .zero
        let col = SIMD4<Float>(Float(color.r * 255), Float(color.g * 255), Float(color.b * 255), 255)
        let op = Float(opacity / 100)
        let p = image.data.assumingMemoryBound(to: UInt8.self)
        guard let hi = pl.H?.inverted else { return }
        let sx = 1 / (pl.aspect * pl.scale), sy = 1 / pl.scale
        _ = sx; _ = sy
        for y in box.minY..<box.maxY {
            for x in box.minX..<box.maxX {
                let d = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let uv = hi.apply(d)
                let mm = CGPoint(x: uv.x * pl.aspect * pl.scale, y: uv.y * pl.scale)
                let t = mm.distance(to: m) / r
                if t >= 1 || uv.x < 0 || uv.y < 0 || uv.x > 1 || uv.y > 1 { continue }
                let w = falloff(t) * op
                if w <= 0 { continue }
                var s: SIMD4<Float>
                if let sp = srcPlane {
                    let sd = sp.fromMetric(mm - off)
                    s = vpSample(base, sd.x, sd.y)
                } else {
                    s = col
                }
                let q = p + y * image.bytesPerRow + x * 4
                let c = SIMD4<Float>(Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3]))
                let o = c + (s - c) * w
                q[0] = UInt8(max(0, min(255, o.x.rounded()))); q[1] = UInt8(max(0, min(255, o.y.rounded())))
                q[2] = UInt8(max(0, min(255, o.z.rounded()))); q[3] = UInt8(max(0, min(255, o.w.rounded())))
            }
        }
        image.markDirty(box)
    }

    // MARK: Marquee (select, then drag to copy the pixels in perspective)

    func marqueeBegin(_ p: CGPoint) -> Bool {
        guard let i = planeIndex(at: p), let m = planes[i].toMetric(p) else { return false }
        dragStartMetric = m
        if let mq = marquee, mq.plane == i, mq.rect.contains(m) {
            marqueeAtDragStart = mq.rect
            strokeBase = image.copy()
            return true           // moving a copy of the selection
        }
        marquee = (i, CGRect(origin: m, size: .zero))
        marqueeAtDragStart = nil
        return false
    }

    func marqueeDrag(_ p: CGPoint) {
        guard let mq = marquee, let s = dragStartMetric, let m = planes[mq.plane].toMetric(p) else { return }
        if let r0 = marqueeAtDragStart {
            moveSelection(from: r0, by: m - s)
        } else {
            marquee = (mq.plane, CGRect(p1: s, p2: m))
        }
    }

    func marqueeEnd() {
        marqueeAtDragStart = nil; dragStartMetric = nil; strokeBase = nil; tick += 1
        if let mq = marquee, mq.rect.width < 2 || mq.rect.height < 2 { marquee = nil }
    }

    /// Copies the pixels of metric rect `r0` (from the image at drag start) to `r0 + delta`, in perspective.
    func moveSelection(from r0: CGRect, by delta: CGPoint) {
        guard let mq = marquee, let base = strokeBase else { return }
        let pl = planes[mq.plane]
        // restore the previous destination
        if mq.rect != r0 { restore(from: base, region: quadBounds(pl, mq.rect)) }
        let dst = r0.offsetBy(dx: delta.x, dy: delta.y)
        marquee = (mq.plane, dst)
        let box = quadBounds(pl, dst)
        guard !box.isEmpty, let hi = pl.H?.inverted else { return }
        let fe = CGFloat(max(0.01, feather))
        let p = image.data.assumingMemoryBound(to: UInt8.self)
        for y in box.minY..<box.maxY {
            for x in box.minX..<box.maxX {
                let uv = hi.apply(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5))
                let mm = CGPoint(x: uv.x * pl.aspect * pl.scale, y: uv.y * pl.scale)
                guard dst.contains(mm), uv.x >= 0, uv.y >= 0, uv.x <= 1, uv.y <= 1 else { continue }
                let edge = min(mm.x - dst.minX, dst.maxX - mm.x, mm.y - dst.minY, dst.maxY - mm.y)
                let w = Float(min(1, edge / fe))
                let sd = pl.fromMetric(mm - delta)
                let s = vpSample(base, sd.x, sd.y)
                let q = p + y * image.bytesPerRow + x * 4
                let c = SIMD4<Float>(Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3]))
                let o = c + (s - c) * w
                q[0] = UInt8(max(0, min(255, o.x.rounded()))); q[1] = UInt8(max(0, min(255, o.y.rounded())))
                q[2] = UInt8(max(0, min(255, o.z.rounded()))); q[3] = UInt8(max(0, min(255, o.w.rounded())))
            }
        }
        image.markDirty()
    }

    func quadBounds(_ pl: VPPlane, _ r: CGRect) -> IRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(pl.fromMetric)
        return IRect(enclosing: CGRect.bounding(pts).insetBy(dx: -2, dy: -2)).intersection(IRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    func restore(from base: PixelBuffer, region r: IRect) {
        guard !r.isEmpty else { return }
        image.copyPixels(from: base, rect: r)
    }

    // MARK: Paste onto a plane

    func pasteImage(_ img: PixelBuffer) {
        guard let i = active ?? (planes.isEmpty ? nil : 0), planes.indices.contains(i) else { NSSound.beep(); return }
        let pl = planes[i]
        let wM = pl.aspect * pl.scale * 0.6
        paste = (img, i, CGPoint(x: pl.aspect * pl.scale / 2, y: pl.scale / 2), wM)
        tool = .transform
    }

    /// Doc quad of the pasted image.
    func pasteQuad() -> Quad? {
        guard let pa = paste, planes.indices.contains(pa.plane) else { return nil }
        let pl = planes[pa.plane]
        let h = pa.width * CGFloat(pa.img.height) / CGFloat(max(1, pa.img.width))
        let r = CGRect(x: pa.center.x - pa.width / 2, y: pa.center.y - h / 2, width: pa.width, height: h)
        return Quad(tl: pl.fromMetric(CGPoint(x: r.minX, y: r.minY)), tr: pl.fromMetric(CGPoint(x: r.maxX, y: r.minY)),
                    br: pl.fromMetric(CGPoint(x: r.maxX, y: r.maxY)), bl: pl.fromMetric(CGPoint(x: r.minX, y: r.maxY)))
    }

    /// Renders the pasted image (clipped to its plane) into `target`.
    func renderPaste(into target: PixelBuffer) {
        guard let pa = paste, let q = pasteQuad(), let h = Homography(from: Quad(rect: CGRect(x: 0, y: 0, width: pa.img.width, height: pa.img.height)), to: q),
              let hi = h.inverted else { return }
        let pl = planes[pa.plane]
        let box = IRect(enclosing: q.bounds.insetBy(dx: -2, dy: -2)).intersection(IRect(x: 0, y: 0, width: target.width, height: target.height))
        guard !box.isEmpty, let phi = pl.H?.inverted else { return }
        let p = target.data.assumingMemoryBound(to: UInt8.self)
        let op = Float(opacity / 100)
        for y in box.minY..<box.maxY {
            for x in box.minX..<box.maxX {
                let d = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let uv = phi.apply(d)
                if uv.x < 0 || uv.y < 0 || uv.x > 1 || uv.y > 1 { continue }
                let sp = hi.apply(d)
                if sp.x < 0 || sp.y < 0 || sp.x > CGFloat(pa.img.width) || sp.y > CGFloat(pa.img.height) { continue }
                let s = vpSample(pa.img, sp.x, sp.y) * op
                let q = p + y * target.bytesPerRow + x * 4
                let c = SIMD4<Float>(Float(q[0]), Float(q[1]), Float(q[2]), Float(q[3]))
                let o = s + c * (1 - s.w / 255)       // source-over (premultiplied)
                q[0] = UInt8(max(0, min(255, o.x.rounded()))); q[1] = UInt8(max(0, min(255, o.y.rounded())))
                q[2] = UInt8(max(0, min(255, o.z.rounded()))); q[3] = UInt8(max(0, min(255, o.w.rounded())))
            }
        }
        target.markDirty()
    }

    func commitPaste() {
        guard paste != nil else { return }
        renderPaste(into: image)
        paste = nil
        tick += 1
    }

    /// Image shown in the preview (working pixels + floating paste).
    func previewImage() -> CGImage {
        if paste != nil {
            let t = image.copy()
            renderPaste(into: t)
            return t.makeCGImage()
        }
        return image.makeCGImage()
    }

    // MARK: Overlay drawing (CoreGraphics, doc → view transform `t`)

    func drawOverlay(_ cg: CGContext, _ t: CGAffineTransform, showGrid: Bool = true) {
        cg.saveGState()
        for (k, pl) in planes.enumerated() {
            let color = pl.isValid ? CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1) : CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
            cg.setStrokeColor(color)
            // grid
            if showGrid, pl.isValid, gridSize > 2 {
                cg.setLineWidth(k == active ? 1 : 0.6)
                cg.setAlpha(0.8)
                let W = pl.aspect * pl.scale, Hh = pl.scale
                let step = CGFloat(gridSize)
                var u: CGFloat = 0
                while u <= W + 0.01 {
                    cg.move(to: pl.fromMetric(CGPoint(x: u, y: 0)).applying(t)); cg.addLine(to: pl.fromMetric(CGPoint(x: u, y: Hh)).applying(t)); u += step
                }
                var v: CGFloat = 0
                while v <= Hh + 0.01 {
                    cg.move(to: pl.fromMetric(CGPoint(x: 0, y: v)).applying(t)); cg.addLine(to: pl.fromMetric(CGPoint(x: W, y: v)).applying(t)); v += step
                }
                cg.strokePath()
            }
            cg.setAlpha(1)
            cg.setLineWidth(k == active ? 2 : 1.2)
            cg.addPath(pl.q.path.copy(using: [t]) ?? pl.q.path)
            cg.strokePath()
            if tool == .editPlane && k == (active ?? -1) {
                for c in pl.q.points { handle(cg, c.applying(t)) }
                for e in 0..<4 { let (a, b) = VPModel.edge(pl.q, e); handle(cg, ((a + b) / 2).applying(t), small: true) }
            }
        }
        // pending creation points
        if !pending.isEmpty {
            cg.setStrokeColor(CGColor(red: 0.2, green: 0.55, blue: 1, alpha: 1))
            cg.setLineWidth(1.5)
            for (i, p) in pending.enumerated() {
                handle(cg, p.applying(t))
                if i > 0 { cg.move(to: pending[i - 1].applying(t)); cg.addLine(to: p.applying(t)); cg.strokePath() }
            }
        }
        // marquee
        if let mq = marquee, planes.indices.contains(mq.plane) {
            let pl = planes[mq.plane], r = mq.rect
            let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map { pl.fromMetric($0).applying(t) }
            let path = CGMutablePath(); path.addLines(between: pts); path.closeSubpath()
            cg.setLineWidth(1); cg.setStrokeColor(.black); cg.addPath(path); cg.strokePath()
            cg.setStrokeColor(.white); cg.setLineDash(phase: 0, lengths: [4, 4]); cg.addPath(path); cg.strokePath(); cg.setLineDash(phase: 0, lengths: [])
        }
        if let q = pasteQuad() {
            cg.setLineWidth(1); cg.setStrokeColor(CGColor(red: 1, green: 0.8, blue: 0.1, alpha: 1))
            cg.addPath(q.path.copy(using: [t]) ?? q.path); cg.strokePath()
        }
        if let s = stampSource, planes.indices.contains(s.plane) {
            let c = planes[s.plane].fromMetric(s.metric).applying(t)
            cg.setStrokeColor(.white); cg.setLineWidth(1.5)
            cg.move(to: CGPoint(x: c.x - 7, y: c.y)); cg.addLine(to: CGPoint(x: c.x + 7, y: c.y))
            cg.move(to: CGPoint(x: c.x, y: c.y - 7)); cg.addLine(to: CGPoint(x: c.x, y: c.y + 7)); cg.strokePath()
        }
        cg.restoreGState()
    }

    private func handle(_ cg: CGContext, _ p: CGPoint, small: Bool = false) {
        let s: CGFloat = small ? 5 : 7
        let r = CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s)
        cg.setFillColor(.white); cg.fill(r)
        cg.setStrokeColor(.black); cg.setLineWidth(1); cg.stroke(r)
    }

    /// Projected brush outline for the cursor.
    func brushOutline(at p: CGPoint) -> [CGPoint]? {
        guard let i = planeIndex(at: p), let m = planes[i].toMetric(p) else { return nil }
        let r = CGFloat(brushSize / 2)
        return (0...32).map { k in let a = CGFloat(k) / 32 * 2 * .pi; return planes[i].fromMetric(m + CGPoint(x: cos(a) * r, y: sin(a) * r)) }
    }

    // MARK: Hit testing for Edit Plane

    enum Hit { case corner(Int, Int), edge(Int, Int), inside(Int) }

    func hit(_ p: CGPoint, tolerance tol: CGFloat) -> Hit? {
        let order = (active.map { [$0] } ?? []) + planes.indices.filter { $0 != active }
        for i in order {
            let q = planes[i].q
            for (c, pt) in q.points.enumerated() where pt.distance(to: p) <= tol { return .corner(i, c) }
            for e in 0..<4 { let (a, b) = VPModel.edge(q, e); if ((a + b) / 2).distance(to: p) <= tol { return .edge(i, e) } }
        }
        if let i = planeIndex(at: p) { return .inside(i) }
        return nil
    }
}

// MARK: - Dialog

final class VPModelBox: ObservableObject {
    let model: VPModel?
    let layerID: UUID?
    init() {
        guard let d = AppActions.doc, let l = d.activeLayer, l.isRaster,
              let img = AppActions.sampleSource(allLayers: false) else { model = nil; layerID = nil; return }
        model = VPModel(image: img)
        layerID = l.id
    }
}

struct VanishingPointDialog: View {
    @StateObject private var box = VPModelBox()
    var body: some View {
        if let m = box.model, let id = box.layerID { VanishingPointWorkspace(m: m, layerID: id) } else {
            DialogFrame(title: "Vanishing Point", onOK: {}) { Text("Select a pixel layer first.") }
        }
    }
}

struct VanishingPointWorkspace: View {
    @ObservedObject var m: VPModel
    let layerID: UUID
    @State private var hover: CGPoint?
    @State private var dragHit: VPModel.Hit?
    @State private var dragStart: CGPoint?
    @State private var tornPlane: Int?
    @State private var pasteStart: CGPoint?
    @State private var showGrid = true
    let frame = CGSize(width: 820, height: 540)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vanishing Point").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    ForEach(VPTool.allCases) { t in IconButton(symbol: t.symbol, help: t.rawValue, active: m.tool == t, size: 30) { setTool(t) } }
                }
                preview
                side.frame(width: 220)
            }
            HStack {
                Text(help).font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                Spacer()
                Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { apply() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    var help: String {
        switch m.tool {
        case .createPlane: return "Click four corners to define a perspective plane."
        case .editPlane: return "Drag corner nodes to adjust · drag edge nodes to extend · ⌘-drag an edge node to tear off a perpendicular plane."
        case .marquee: return "Drag to select inside a plane, then drag the selection to copy it in perspective."
        case .stamp: return "⌥-click to set the source, then paint — the clone follows the plane's perspective."
        case .brush: return "Paint with the colour in perspective."
        case .transform: return "Drag the pasted image to move it across the plane; use the Size slider to scale."
        }
    }

    func setTool(_ t: VPTool) {
        if t != .transform { m.commitPaste() }
        m.tool = t
        m.tick += 1
    }

    func fit() -> (CGFloat, CGPoint) {
        let W = CGFloat(m.image.width), H = CGFloat(m.image.height)
        let s = min(frame.width / W, frame.height / H)
        return (s, CGPoint(x: (frame.width - W * s) / 2, y: (frame.height - H * s) / 2))
    }

    var preview: some View {
        let (s, o) = fit()
        let t = CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: o.x, ty: o.y)
        let _ = m.tick
        return Canvas { ctx, _ in
            let r = CGRect(x: o.x, y: o.y, width: CGFloat(m.image.width) * s, height: CGFloat(m.image.height) * s)
            ctx.draw(Image(decorative: m.previewImage(), scale: 1), in: r)
            ctx.withCGContext { cg in
                m.drawOverlay(cg, t, showGrid: showGrid)
                if let h = hover, [.stamp, .brush].contains(m.tool), let pts = m.brushOutline(at: h) {
                    cg.setStrokeColor(.white); cg.setLineWidth(1)
                    cg.addLines(between: pts.map { $0.applying(t) }); cg.strokePath()
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onContinuousHover { ph in
            if case .active(let p) = ph { hover = CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s) } else { hover = nil }
            if [.stamp, .brush].contains(m.tool) { m.tick += 1 }
        }
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let p = CGPoint(x: (v.location.x - o.x) / s, y: (v.location.y - o.y) / s)
            if dragStart == nil { dragStart = p; began(p, tolerance: 8 / s) } else { dragged(p) }
            hover = p
            m.tick += 1
        }.onEnded { v in
            let p = CGPoint(x: (v.location.x - o.x) / s, y: (v.location.y - o.y) / s)
            ended(p)
            dragStart = nil; dragHit = nil; tornPlane = nil; pasteStart = nil
            m.tick += 1
        })
    }

    func began(_ p: CGPoint, tolerance: CGFloat) {
        let mods = NSEvent.modifierFlags
        switch m.tool {
        case .createPlane:
            break
        case .editPlane:
            dragHit = m.hit(p, tolerance: tolerance)
            if case .inside(let i) = dragHit { m.active = i }
            if case .corner(let i, _) = dragHit { m.active = i }
            if case .edge(let i, _) = dragHit { m.active = i }
        case .marquee:
            _ = m.marqueeBegin(p)
        case .stamp:
            if mods.contains(.option) { m.defineStampSource(p); return }
            m.beginStroke(); m.paint(at: p, stamp: true)
        case .brush:
            m.beginStroke(); m.paint(at: p, stamp: false)
        case .transform:
            pasteStart = m.paste?.center
        }
    }

    func dragged(_ p: CGPoint) {
        let mods = NSEvent.modifierFlags
        switch m.tool {
        case .createPlane: break
        case .editPlane:
            switch dragHit {
            case .corner(let i, let c): m.moveCorner(plane: i, corner: c, to: p)
            case .edge(let i, let e):
                if mods.contains(.command) || tornPlane != nil {
                    if let tp = tornPlane, let q = m.tearOffQuad(plane: i, edge: e, to: p) { m.planes[tp].q = q }
                    else if tornPlane == nil { tornPlane = m.tearOff(plane: i, edge: e, to: p) }
                } else {
                    m.extend(plane: i, edge: e, to: p)
                }
            case .inside(let i):
                if let st = dragStart {
                    let d = p - st
                    m.planes[i].q = m.planes[i].q.mapped { $0 + d }
                    dragStart = p
                }
            case nil: break
            }
        case .marquee: m.marqueeDrag(p)
        case .stamp: if !mods.contains(.option) { m.paint(at: p, stamp: true) }
        case .brush: m.paint(at: p, stamp: false)
        case .transform:
            guard let pa = m.paste, let c0 = pasteStart, let st = dragStart,
                  let a = m.planes[pa.plane].toMetric(st), let b = m.planes[pa.plane].toMetric(p) else { return }
            m.paste?.center = c0 + (b - a)
        }
    }

    func ended(_ p: CGPoint) {
        switch m.tool {
        case .createPlane:
            if let st = dragStart, st.distance(to: p) < 4 { m.addPoint(p) }
        case .marquee: m.marqueeEnd()
        case .stamp, .brush: m.endStroke()
        default: break
        }
    }

    var side: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption(m.tool.rawValue)
            ValueSlider(label: "Grid Size", value: $m.gridSize, range: 5...400, unit: " px", labelWidth: 64)
            Toggle2(label: "Show Grid", on: $showGrid)
            if [.stamp, .brush].contains(m.tool) {
                ValueSlider(label: "Diameter", value: $m.brushSize, range: 2...500, unit: " px", labelWidth: 64)
                ValueSlider(label: "Hardness", value: $m.hardness, range: 0...100, unit: "%", labelWidth: 64)
                ValueSlider(label: "Opacity", value: $m.opacity, range: 1...100, unit: "%", labelWidth: 64)
            }
            if m.tool == .stamp { Toggle2(label: "Aligned", on: Binding(get: { m.aligned }, set: { m.aligned = $0 })) }
            if m.tool == .brush { HStack { Text("Color").foregroundStyle(Theme.textDim); ColorWell(color: $m.color) } }
            if m.tool == .marquee {
                ValueSlider(label: "Feather", value: $m.feather, range: 0...50, unit: " px", labelWidth: 64)
                Button("Deselect") { m.marquee = nil; m.tick += 1 }.buttonStyle(PanelButtonStyle())
            }
            Divider()
            Button("Paste Image from Clipboard") {
                if let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    m.pasteImage(PixelBuffer(cgImage: cg)); m.tick += 1
                } else { NSSound.beep() }
            }.buttonStyle(PanelButtonStyle())
            if let pa = m.paste {
                ValueSlider(label: "Size", value: Binding(get: { Double(pa.width) }, set: { m.paste?.width = CGFloat($0); m.tick += 1 }),
                            range: 10...Double(max(20, m.planes[pa.plane].aspect * m.planes[pa.plane].scale * 3)), unit: " px", labelWidth: 64)
                Button("Apply Paste") { m.commitPaste() }.buttonStyle(PanelButtonStyle())
            }
            if let a = m.active {
                Button("Delete Plane") { m.deletePlane(a); m.tick += 1 }.buttonStyle(PanelButtonStyle())
            }
            Spacer()
        }
    }

    func apply() {
        m.commitPaste()
        AppModel.shared.dialog = nil
        guard let d = AppActions.doc, let (w, o) = d.beginPixelEdit(layerID: layerID, target: .content) else { return }
        let W = d.state.width, H = d.state.height
        w.context.saveGState()
        w.context.setBlendMode(.copy)
        w.drawImage(m.image.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: W, height: H), interpolation: .none)
        w.context.restoreGState()
        w.markDirty()
        d.commit("Vanishing Point")
        d.setNeedsRender()
    }
}

enum VanishingPointModule {
    static func register() {
        MenuRegistry.add("Filter", "Vanishing Point…", key: "v", modifiers: [.command, .option],
                         enabled: { FilterLauncher.canRun(smartFilter: false, layerPixels: true) }) {
            if FilterLauncher.prepare(smartFilter: false, layerPixels: true) { DialogRegistry.show("edits.vanishingPoint") }
        }
        DialogRegistry.register("edits.vanishingPoint") { AnyView(VanishingPointDialog()) }
    }
}
