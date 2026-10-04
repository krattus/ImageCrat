import AppKit
import CoreGraphics
import ImageCratCore

// Drawing guides (perspective / isometric / grid / radial) and assist rulers (straight edge, ellipse, French curve):
// geometry, stroke snapping, overlay drawing and on-canvas editing.

// MARK: - Ruler geometry

extension AssistRuler {
    /// Polyline of the ruler in document space (the straight edge is returned as its two end points).
    func polyline(segments: Int = 96) -> [CGPoint] {
        guard isValid else { return [] }
        switch kind {
        case .straight: return points
        case .ellipse:
            let (c, u, v) = ellipseAxes
            return (0...segments).map { i in
                let t = CGFloat(i) / CGFloat(segments) * 2 * .pi
                return c + u * cos(t) + v * sin(t)
            }
        case .curve:
            return (0...segments).map { i in bezier(CGFloat(i) / CGFloat(segments)) }
        }
    }

    /// Centre and the two semi-axis vectors of an ellipse ruler (the second axis is perpendicular to the first).
    var ellipseAxes: (CGPoint, CGPoint, CGPoint) {
        let c = points[0]
        var u = points[1] - c
        if u.length < 0.5 { u = CGPoint(x: 1, y: 0) }
        let n = CGPoint(x: -u.y, y: u.x).normalized
        var b = abs((points[2] - c).dot(n))
        if b < 0.5 { b = max(0.5, (points[2] - c).length) }
        return (c, u, n * b)
    }

    func bezier(_ t: CGFloat) -> CGPoint {
        let m = 1 - t
        let a = points[0] * (m * m * m), b = points[1] * (3 * m * m * t), c = points[2] * (3 * m * t * t), d = points[3] * (t * t * t)
        return a + b + c + d
    }

    /// Shortest distance from `p` to the ruler's outline (the straight edge counts as an infinite line).
    func distance(to p: CGPoint) -> CGFloat {
        guard isValid else { return .infinity }
        switch kind {
        case .straight:
            let d = (points[1] - points[0]).normalized
            if d == .zero { return p.distance(to: points[0]) }
            let v = p - points[0]
            return abs(v.x * d.y - v.y * d.x)
        default:
            return AssistGeometry.nearest(on: polyline(), to: p).distance
        }
    }
}

enum AssistGeometry {
    /// Nearest point on a polyline with the unit normal of the segment and the signed offset of `p` along it.
    static func nearest(on poly: [CGPoint], to p: CGPoint) -> (point: CGPoint, normal: CGPoint, distance: CGFloat, signed: CGFloat) {
        var best = (point: poly.first ?? p, normal: CGPoint(x: 0, y: -1), distance: CGFloat.infinity, signed: CGFloat(0))
        guard poly.count > 1 else { return best }
        for i in 0..<(poly.count - 1) {
            let a = poly[i], b = poly[i + 1]
            let ab = b - a
            let l2 = ab.dot(ab)
            if l2 < 1e-9 { continue }
            let t = clamp((p - a).dot(ab) / l2, 0, 1)
            let q = a + ab * t
            let d = p.distance(to: q)
            if d < best.distance {
                let n = CGPoint(x: -ab.y, y: ab.x).normalized
                best = (q, n, d, (p - q).dot(n))
            }
        }
        return best
    }

    static func unit(_ degrees: Double) -> CGPoint {
        let a = CGFloat(degrees * .pi / 180)
        return CGPoint(x: cos(a), y: sin(a))
    }

    /// The directions (unit vectors, document space, y down) a stroke starting at `s` may follow for a guide.
    static func directions(_ g: DrawingGuide, at s: CGPoint) -> [CGPoint] {
        func toward(_ vp: CGPoint) -> CGPoint? { let d = vp - s; return d.length > 0.5 ? d.normalized : nil }
        switch g.kind {
        case .none: return []
        case .perspective1:
            let h = unit(g.horizonAngle)
            return g.vps.prefix(1).compactMap(toward) + [h, CGPoint(x: -h.y, y: h.x)]
        case .perspective2:
            guard g.vps.count >= 2 else { return [] }
            var h = (g.vps[1] - g.vps[0]).normalized
            if h == .zero { h = CGPoint(x: 1, y: 0) }
            return g.vps.prefix(2).compactMap(toward) + [CGPoint(x: -h.y, y: h.x)]
        case .perspective3:
            return g.vps.prefix(3).compactMap(toward)
        case .isometric:
            return [CGPoint(x: 0, y: 1), unit(-g.isoAngle), unit(180 + g.isoAngle)]
        case .grid:
            return [unit(g.gridAngle), unit(g.gridAngle + 90)]
        case .radial:
            return toward(g.center).map { [$0] } ?? []
        }
    }
}

// MARK: - Stroke snapping

/// What an assisted stroke is locked to.
enum AssistLock: Equatable {
    case line(origin: CGPoint, dir: CGPoint)
    case circle(center: CGPoint, radius: CGFloat)
    /// Ellipse through the stroke start: centre, semi-axis vectors and the scale relative to the ruler.
    case ellipse(center: CGPoint, u: CGPoint, v: CGPoint, k: CGFloat)
    /// Offset copy of a curve (polyline + signed normal offset).
    case curve(poly: [CGPoint], offset: CGFloat)

    func project(_ p: CGPoint) -> CGPoint {
        switch self {
        case .line(let o, let d):
            return o + d * (p - o).dot(d)
        case .circle(let c, let r):
            let v = p - c
            return v.length < 1e-6 ? CGPoint(x: c.x + r, y: c.y) : c + v.normalized * r
        case .ellipse(let c, let u, let v, let k):
            let lu = max(1e-6, u.length), lv = max(1e-6, v.length)
            let x = (p - c).dot(u) / (lu * lu), y = (p - c).dot(v) / (lv * lv)
            let l = (x * x + y * y).squareRoot()
            if l < 1e-6 { return c + u * k }
            return c + u * (x / l * k) + v * (y / l * k)
        case .curve(let poly, let off):
            let n = AssistGeometry.nearest(on: poly, to: p)
            return n.point + n.normal * off
        }
    }
}

/// Per-stroke snapping state: rulers win when the stroke starts next to one, otherwise the guide direction closest to
/// the first few pixels of movement is chosen and the whole stroke follows it.
struct AssistSnapper {
    let start: CGPoint
    let guide: DrawingGuide
    /// Travel (document px) before the guide direction is decided.
    let threshold: CGFloat
    private(set) var lock: AssistLock?
    private(set) var rulerID: UUID?

    init(start: CGPoint, guide: DrawingGuide, rulers: [AssistRuler], rulerRange: CGFloat, threshold: CGFloat) {
        self.start = start
        self.guide = guide
        self.threshold = max(1.5, threshold)
        // nearest ruler within range
        var best: (AssistRuler, CGFloat)?
        for r in rulers where r.isValid {
            let d = r.distance(to: start)
            if d <= rulerRange && d < (best?.1 ?? .infinity) { best = (r, d) }
        }
        if let (r, _) = best {
            rulerID = r.id
            switch r.kind {
            case .straight:
                let d = (r.points[1] - r.points[0]).normalized
                lock = .line(origin: start, dir: d == .zero ? CGPoint(x: 1, y: 0) : d)
            case .ellipse:
                let (c, u, v) = r.ellipseAxes
                let lu = u.length, lv = v.length
                let x = (start - c).dot(u) / (lu * lu), y = (start - c).dot(v) / (lv * lv)
                lock = .ellipse(center: c, u: u, v: v, k: max(0.02, (x * x + y * y).squareRoot()))
            case .curve:
                let poly = r.polyline(segments: 160)
                lock = .curve(poly: poly, offset: AssistGeometry.nearest(on: poly, to: start).signed)
            }
        }
    }

    var isActive: Bool { lock != nil || guide.kind != .none }

    mutating func snap(_ p: CGPoint) -> CGPoint {
        if let l = lock { return l.project(p) }
        guard guide.kind != .none else { return p }
        let move = p - start
        if move.length < threshold { return start }     // hold the pen in place until the direction is known
        let m = move.normalized
        var cands: [AssistLock] = AssistGeometry.directions(guide, at: start).map { .line(origin: start, dir: $0) }
        var scores: [CGFloat] = AssistGeometry.directions(guide, at: start).map { abs($0.dot(m)) }
        if guide.kind == .radial {
            let r = start.distance(to: guide.center)
            if r > 0.5 {
                let radial = (start - guide.center).normalized
                cands.append(.circle(center: guide.center, radius: r))
                scores.append(abs(CGPoint(x: -radial.y, y: radial.x).dot(m)))
            }
        }
        guard let i = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return p }
        lock = cands[i]
        return cands[i].project(p)
    }
}

// MARK: - Document actions

enum DrawingGuides {
    static func setKind(_ k: DrawingGuideKind) {
        guard let d = AppActions.doc else { return }
        if k == .none {
            d.state.artist.guide.kind = .none
        } else {
            var g = DrawingGuide.standard(k, width: d.state.width, height: d.state.height)
            let old = d.state.artist.guide
            g.color = old.color; g.opacity = old.opacity
            if old.kind != .none { g.spacing = old.spacing; g.isoAngle = old.isoAngle }
            d.state.artist.guide = g
        }
        d.commit(k == .none ? "Remove Drawing Guide" : "Drawing Guide: \(k.title)")
        AppModel.shared.setStatus(k == .none ? "Drawing guide removed" : "\(k.title): drag the handles to adjust · strokes snap while Assisted Drawing is on")
        ArtistModule.refreshCanvas()
    }

    static func toggleVisible() {
        guard let d = AppActions.doc else { return }
        d.state.artist.guide.visible.toggle()
        d.commit("Drawing Guide Visibility")
        ArtistModule.refreshCanvas()
    }

    static func addRuler(_ k: AssistRulerKind) {
        guard let d = AppActions.doc else { return }
        d.state.artist.rulers.append(AssistRuler.standard(k, width: d.state.width, height: d.state.height))
        d.commit("Add \(k.title)")
        ArtistSettings.shared.editGuides = true
        AppModel.shared.setStatus("\(k.title) added: drag its handles; strokes started near it follow it")
        ArtistModule.refreshCanvas()
    }

    static func removeRuler(_ id: UUID) {
        guard let d = AppActions.doc else { return }
        d.state.artist.rulers.removeAll { $0.id == id }
        d.commit("Remove Ruler")
        ArtistModule.refreshCanvas()
    }

    static func removeRulers() {
        guard let d = AppActions.doc, !d.state.artist.rulers.isEmpty else { return }
        d.state.artist.rulers = []
        d.commit("Remove Rulers")
        ArtistModule.refreshCanvas()
    }
}

// MARK: - Rendering

enum GuideRenderer {
    /// Draws the guide and rulers. `toView` maps document points into the context; `canvas` is the document rect.
    static func draw(_ ctx: CGContext, data: ArtistDocData, canvas: CGRect, toView: (CGPoint) -> CGPoint, editing: Bool, labels: Bool = true) {
        let g = data.guide
        let quad = canvas.corners.map(toView)
        ctx.saveGState()
        if g.kind != .none && g.visible {
            ctx.saveGState()
            let clip = CGMutablePath()
            clip.addLines(between: quad); clip.closeSubpath()
            ctx.addPath(clip); ctx.clip()
            drawGuide(ctx, g, canvas: canvas, toView: toView)
            ctx.restoreGState()
        }
        for r in data.rulers where r.isValid { drawRuler(ctx, r, toView: toView, editing: editing) }
        if editing && g.kind != .none && g.visible {
            for (h, p) in GuideEditor.handles(data) {
                if case .ruler = h { continue }
                if case .rulerMove = h { continue }
                let v = toView(p)
                OverlayStyle.circleHandle(ctx, at: v, size: 11, filled: true)
                if labels, let t = GuideEditor.label(h) { OverlayStyle.label(t, at: CGPoint(x: v.x - 6, y: v.y - 6)) }
            }
        }
        ctx.restoreGState()
    }

    private static func stroke(_ ctx: CGContext, _ path: CGPath, _ color: RGBA, _ alpha: Double, width: CGFloat = 1, dash: [CGFloat] = []) {
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(color.withAlpha(clamp(alpha, 0, 1)).cgColor)
        ctx.setLineDash(phase: 0, lengths: dash)
        ctx.strokePath()
    }

    /// Family of parallel lines with direction `dir` spaced `spacing` apart (perpendicular), through `origin`, covering `rect`.
    static func parallels(dir: CGPoint, spacing: CGFloat, origin: CGPoint, covering rect: CGRect, limit: Int = 400) -> [(CGPoint, CGPoint)] {
        let n = CGPoint(x: -dir.y, y: dir.x)
        let ds = rect.corners.map { ($0 - origin).dot(n) }
        let ts = rect.corners.map { ($0 - origin).dot(dir) }
        guard let lo = ds.min(), let hi = ds.max(), let t0 = ts.min(), let t1 = ts.max(), spacing > 0.5 else { return [] }
        var k0 = Int((lo / spacing).rounded(.down)), k1 = Int((hi / spacing).rounded(.up))
        if k1 - k0 > limit { let mid = (k0 + k1) / 2; k0 = mid - limit / 2; k1 = mid + limit / 2 }
        return (k0...k1).map { k in
            let o = origin + n * (CGFloat(k) * spacing)
            return (o + dir * t0, o + dir * t1)
        }
    }

    /// Ray directions (degrees) for a vanishing point: all around when it lies on the canvas, otherwise a fan that
    /// covers the canvas as seen from the point (so distant vanishing points still give a useful grid).
    static func rayAngles(from vp: CGPoint, canvas: CGRect, count: Int = 18) -> [Double] {
        if canvas.insetBy(dx: -1, dy: -1).contains(vp) { return (0..<36).map { Double($0) * 10 } }
        let mid = Double(atan2(canvas.midY - vp.y, canvas.midX - vp.x)) * 180 / .pi
        var lo = 0.0, hi = 0.0
        for c in canvas.corners {
            var d = Double(atan2(c.y - vp.y, c.x - vp.x)) * 180 / .pi - mid
            while d > 180 { d -= 360 }
            while d < -180 { d += 360 }
            lo = min(lo, d); hi = max(hi, d)
        }
        let step = (hi - lo) / Double(count)
        return (0...count).map { mid + lo + Double($0) * step }
    }

    private static func drawGuide(_ ctx: CGContext, _ g: DrawingGuide, canvas: CGRect, toView: (CGPoint) -> CGPoint) {
        let reach = (canvas.width + canvas.height) * 4
        func line(_ p: CGMutablePath, _ a: CGPoint, _ b: CGPoint) { p.move(to: toView(a)); p.addLine(to: toView(b)) }
        let fine = CGMutablePath(), strong = CGMutablePath()
        switch g.kind {
        case .none: break
        case .perspective1, .perspective2, .perspective3:
            for vp in g.vps {
                for deg in rayAngles(from: vp, canvas: canvas) { line(fine, vp, vp + AssistGeometry.unit(deg) * reach) }
            }
            // horizon
            if g.kind == .perspective1, let vp = g.vps.first {
                let h = AssistGeometry.unit(g.horizonAngle)
                line(strong, vp - h * reach, vp + h * reach)
            } else if g.vps.count >= 2 {
                let h = (g.vps[1] - g.vps[0]).normalized
                line(strong, g.vps[0] - h * reach, g.vps[1] + h * reach)
            }
        case .isometric:
            let s = CGFloat(g.spacing)
            let c = CGPoint(x: canvas.midX, y: canvas.midY)
            let cosA = max(0.05, cos(CGFloat(g.isoAngle * .pi / 180)))
            for (a, b) in parallels(dir: CGPoint(x: 0, y: 1), spacing: s * cosA, origin: c, covering: canvas) { line(fine, a, b) }
            for deg in [-g.isoAngle, 180 + g.isoAngle] {
                for (a, b) in parallels(dir: AssistGeometry.unit(deg), spacing: s * cosA, origin: c, covering: canvas) { line(fine, a, b) }
            }
        case .grid:
            let s = CGFloat(g.spacing)
            let c = CGPoint(x: canvas.midX, y: canvas.midY)
            for deg in [g.gridAngle, g.gridAngle + 90] {
                for (i, (a, b)) in parallels(dir: AssistGeometry.unit(deg), spacing: s, origin: c, covering: canvas).enumerated() {
                    line(i % 4 == 0 ? strong : fine, a, b)
                }
            }
        case .radial:
            let n = max(2, g.spokes)
            for k in 0..<n { line(fine, g.center, g.center + AssistGeometry.unit(Double(k) * 360 / Double(n)) * reach) }
            let far = canvas.corners.map { $0.distance(to: g.center) }.max() ?? 0
            let s = max(4, CGFloat(g.spacing))
            var r = s
            var count = 0
            while r <= far && count < 300 {
                let pts = (0...72).map { i in toView(g.center + AssistGeometry.unit(Double(i) * 5) * r) }
                (count % 4 == 3 ? strong : fine).addLines(between: pts)
                r += s; count += 1
            }
        }
        stroke(ctx, fine, g.color, g.opacity * 0.75, width: 0.75)
        stroke(ctx, strong, g.color, min(1, g.opacity * 1.5), width: 1.25)
    }

    private static func drawRuler(_ ctx: CGContext, _ r: AssistRuler, toView: (CGPoint) -> CGPoint, editing: Bool) {
        let col = RGBA(r: 1, g: 0.55, b: 0.1)
        let path = CGMutablePath()
        switch r.kind {
        case .straight:
            let d = (r.points[1] - r.points[0])
            let ext = d.normalized * 4000
            path.move(to: toView(r.points[0] - ext)); path.addLine(to: toView(r.points[1] + ext))
            stroke(ctx, path, col, 0.35, width: 1, dash: [6, 4])
            let body = CGMutablePath()
            body.move(to: toView(r.points[0])); body.addLine(to: toView(r.points[1]))
            stroke(ctx, body, col, 0.95, width: 2)
        case .ellipse, .curve:
            path.addLines(between: r.polyline().map(toView))
            stroke(ctx, path, col, 0.95, width: 2)
            if editing {
                let aux = CGMutablePath()
                if r.kind == .curve {
                    aux.move(to: toView(r.points[0])); aux.addLine(to: toView(r.points[1]))
                    aux.move(to: toView(r.points[3])); aux.addLine(to: toView(r.points[2]))
                } else {
                    let (c, u, v) = r.ellipseAxes
                    aux.move(to: toView(c)); aux.addLine(to: toView(c + u))
                    aux.move(to: toView(c)); aux.addLine(to: toView(c + v))
                }
                stroke(ctx, aux, col, 0.6, width: 1, dash: [3, 3])
            }
        }
        ctx.setLineDash(phase: 0, lengths: [])
        guard editing else { return }
        for (h, p) in GuideEditor.handles(for: r) {
            if case .rulerMove = h { OverlayStyle.circleHandle(ctx, at: toView(p), size: 9) } else { OverlayStyle.handle(ctx, at: toView(p), size: 8, filled: true) }
        }
    }
}

// MARK: - On-canvas editing

enum GuideHandle: Equatable {
    case vp(Int)
    case center
    /// Rotates the horizon of a 1-point guide / the 2D grid.
    case angle
    case ruler(UUID, Int)
    /// Moves a whole ruler.
    case rulerMove(UUID)
}

final class GuideEditor {
    static let shared = GuideEditor()
    private var monitor: Any?
    private var dragging: GuideHandle?
    private var moved = false
    private var lastDoc: CGPoint = .zero

    static func label(_ h: GuideHandle) -> String? {
        switch h {
        case .vp(let i): return "VP\(i + 1)"
        case .center: return "Centre"
        case .angle: return "Angle"
        default: return nil
        }
    }

    /// All draggable handles (document positions).
    static func handles(_ data: ArtistDocData) -> [(GuideHandle, CGPoint)] {
        var out: [(GuideHandle, CGPoint)] = []
        let g = data.guide
        if g.kind != .none && g.visible {
            for (i, p) in g.vps.enumerated() { out.append((.vp(i), p)) }
            let arm = CGFloat(max(60, g.spacing * 3))
            switch g.kind {
            case .perspective1:
                if let vp = g.vps.first { out.append((.angle, vp + AssistGeometry.unit(g.horizonAngle) * arm)) }
            case .grid:
                out.append((.center, g.center))
                out.append((.angle, g.center + AssistGeometry.unit(g.gridAngle) * arm))
            case .radial:
                out.append((.center, g.center))
            default: break
            }
        }
        for r in data.rulers where r.isValid { out += handles(for: r) }
        return out
    }

    static func handles(for r: AssistRuler) -> [(GuideHandle, CGPoint)] {
        var out: [(GuideHandle, CGPoint)] = []
        switch r.kind {
        case .straight:
            out = [(.ruler(r.id, 0), r.points[0]), (.ruler(r.id, 1), r.points[1]), (.rulerMove(r.id), (r.points[0] + r.points[1]) / 2)]
        case .ellipse:
            let (c, u, v) = r.ellipseAxes
            out = [(.rulerMove(r.id), c), (.ruler(r.id, 1), c + u), (.ruler(r.id, 2), c + v)]
        case .curve:
            out = r.points.enumerated().map { (.ruler(r.id, $0.offset), $0.element) }
            out.append((.rulerMove(r.id), r.bezier(0.5)))
        }
        return out
    }

    /// Handle under a view point (within `tolerance` screen px).
    static func hit(_ data: ArtistDocData, view p: CGPoint, toView: (CGPoint) -> CGPoint, tolerance: CGFloat = 9) -> GuideHandle? {
        var best: (GuideHandle, CGFloat)?
        for (h, dp) in handles(data) {
            let d = toView(dp).distance(to: p)
            if d <= tolerance && d < (best?.1 ?? .infinity) { best = (h, d) }
        }
        return best?.0
    }

    /// Moves a handle to a document point (`delta` = movement since the last call, used for whole-ruler moves).
    static func move(_ h: GuideHandle, to p: CGPoint, delta: CGPoint, in data: inout ArtistDocData) {
        switch h {
        case .vp(let i):
            if data.guide.vps.indices.contains(i) { data.guide.vps[i] = p }
        case .center:
            data.guide.center = p
        case .angle:
            let o = data.guide.kind == .perspective1 ? (data.guide.vps.first ?? data.guide.center) : data.guide.center
            let a = Double(atan2(p.y - o.y, p.x - o.x)) * 180 / .pi
            if data.guide.kind == .perspective1 { data.guide.horizonAngle = a } else { data.guide.gridAngle = a }
        case .ruler(let id, let i):
            guard let ri = data.rulers.firstIndex(where: { $0.id == id }), data.rulers[ri].points.indices.contains(i) else { return }
            if data.rulers[ri].kind == .ellipse && i == 2 {
                // the second axis handle slides along the perpendicular of the first axis
                let (c, u, _) = data.rulers[ri].ellipseAxes
                let n = CGPoint(x: -u.y, y: u.x).normalized
                data.rulers[ri].points[2] = c + n * max(1, abs((p - c).dot(n)))
            } else if data.rulers[ri].kind == .ellipse && i == 1 {
                let (c, _, v) = data.rulers[ri].ellipseAxes
                data.rulers[ri].points[1] = p
                let u = p - c
                data.rulers[ri].points[2] = c + CGPoint(x: -u.y, y: u.x).normalized * v.length
            } else {
                data.rulers[ri].points[i] = p
            }
        case .rulerMove(let id):
            guard let ri = data.rulers.firstIndex(where: { $0.id == id }) else { return }
            data.rulers[ri].points = data.rulers[ri].points.map { $0 + delta }
        }
    }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let canvas = AppActions.canvas, let d = canvas.document, e.window === canvas.window else { dragging = nil; return false }
        let v = canvas.convert(e.locationInWindow, from: nil)
        switch e.type {
        case .leftMouseDown:
            guard ArtistSettings.shared.editGuides, AppModel.shared.dialog == nil, !RadialMenuController.shared.isOpen,
                  canvas.bounds.contains(v), canvas.window?.contentView?.hitTest(e.locationInWindow) === canvas,
                  !e.modifierFlags.contains(.command) else { return false }
            let data = d.state.artist
            guard data.guide.kind != .none || !data.rulers.isEmpty,
                  let h = GuideEditor.hit(data, view: v, toView: { canvas.docToView($0) }) else { return false }
            if e.modifierFlags.contains(.option), case .ruler(let id, _) = h { DrawingGuides.removeRuler(id); return true }
            if e.modifierFlags.contains(.option), case .rulerMove(let id) = h { DrawingGuides.removeRuler(id); return true }
            dragging = h
            moved = false
            lastDoc = canvas.viewToDoc(v)
            return true
        case .leftMouseDragged:
            guard let h = dragging else { return false }
            let p = canvas.viewToDoc(v)
            GuideEditor.move(h, to: p, delta: p - lastDoc, in: &d.state.artist)
            lastDoc = p
            moved = true
            canvas.overlay.needsDisplay = true
            return true
        case .leftMouseUp:
            guard dragging != nil else { return false }
            dragging = nil
            if moved { d.commit("Edit Drawing Guide") }
            canvas.overlay.needsDisplay = true
            return true
        default:
            return false
        }
    }
}
