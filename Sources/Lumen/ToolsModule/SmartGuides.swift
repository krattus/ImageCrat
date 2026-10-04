import AppKit
import ImageCratCore

/// Smart Guides: while moving layers, magenta lines show alignment with other layers' edges / centres and the
/// canvas; the moved bounds snap to them, and distance labels show the gaps to the nearest neighbours.
final class SmartGuides {
    static let shared = SmartGuides()

    var enabled: Bool = UserDefaults.standard.object(forKey: "Lumen.SmartGuides") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "Lumen.SmartGuides") }
    }

    /// Current guide lines (doc space) and distance labels.
    private(set) var lines: [(CGPoint, CGPoint)] = []
    private(set) var gaps: [(CGPoint, CGPoint, String)] = []
    private var cache: (key: String, rects: [CGRect])?

    func toggle() {
        enabled.toggle()
        AppModel.shared.setStatus("Smart Guides: \(enabled ? "on" : "off")")
    }

    func clear() {
        lines = []; gaps = []; cache = nil
    }

    /// Bounds of layers that don't move (visible, non-group leaves outside the moved set and their descendants).
    func targets(_ d: Document, excluding moved: [UUID]) -> [CGRect] {
        let key = "\(ObjectIdentifier(d).hashValue)-\(d.revision)-\(moved.map(\.uuidString).joined())"
        if let c = cache, c.key == key { return c.rects }
        var excluded = Set<UUID>()
        for id in moved { if let l = d.state.layer(id) { excluded.formUnion(l.allIDs) } }
        var rects: [CGRect] = []
        func walk(_ layers: [Layer]) {
            for l in layers where l.isVisible && !excluded.contains(l.id) {
                if l.isGroup {
                    if let ab = l.artboard { rects.append(ab.rect) }
                    walk(l.children)
                    continue
                }
                if l.isAdjustment || l.isFill { continue }
                if let b = Compositor.shared.contentBounds(l, state: d.state), b.width > 0, b.height > 0 { rects.append(b.integral) }
            }
        }
        walk(d.state.layers)
        cache = (key, rects)
        return rects
    }

    /// Adjusts a move delta so the moved bounds snap to other layers; records guide lines for drawing.
    func adjust(_ delta: CGPoint, moving b0: CGRect, doc d: Document, movedIDs: [UUID], zoom: CGFloat, snap: Bool) -> CGPoint {
        lines = []; gaps = []
        guard enabled else { return delta }
        let others = targets(d, excluding: movedIDs)
        let canvasR = d.state.canvasCGRect
        let all = others + [canvasR]
        var dl = delta
        let t = 5 / max(0.01, zoom)
        var moved = b0.offsetBy(dx: dl.x, dy: dl.y)

        func xs(_ r: CGRect) -> [CGFloat] { [r.minX, r.midX, r.maxX] }
        func ys(_ r: CGRect) -> [CGFloat] { [r.minY, r.midY, r.maxY] }
        if snap {
            var bestX: CGFloat?, bestY: CGFloat?
            for r in all {
                for x in xs(r) { for v in xs(moved) where abs(x - v) < t && (bestX == nil || abs(x - v) < abs(bestX!)) { bestX = x - v } }
                for y in ys(r) { for v in ys(moved) where abs(y - v) < t && (bestY == nil || abs(y - v) < abs(bestY!)) { bestY = y - v } }
            }
            if let bx = bestX { dl.x += bx.rounded() }
            if let by = bestY { dl.y += by.rounded() }
            moved = b0.offsetBy(dx: dl.x, dy: dl.y)
        }
        // alignment lines
        for r in all {
            for x in xs(r) where xs(moved).contains(where: { abs($0 - x) < 0.5 }) {
                lines.append((CGPoint(x: x, y: min(r.minY, moved.minY)), CGPoint(x: x, y: max(r.maxY, moved.maxY))))
            }
            for y in ys(r) where ys(moved).contains(where: { abs($0 - y) < 0.5 }) {
                lines.append((CGPoint(x: min(r.minX, moved.minX), y: y), CGPoint(x: max(r.maxX, moved.maxX), y: y)))
            }
        }
        // distances to the nearest neighbours that overlap on the other axis
        var left: (CGFloat, CGRect)?, right: (CGFloat, CGRect)?, up: (CGFloat, CGRect)?, down: (CGFloat, CGRect)?
        for r in others {
            let vOverlap = r.maxY > moved.minY && r.minY < moved.maxY
            let hOverlap = r.maxX > moved.minX && r.minX < moved.maxX
            if vOverlap {
                if r.maxX <= moved.minX { let g = moved.minX - r.maxX; if left == nil || g < left!.0 { left = (g, r) } }
                if r.minX >= moved.maxX { let g = r.minX - moved.maxX; if right == nil || g < right!.0 { right = (g, r) } }
            }
            if hOverlap {
                if r.maxY <= moved.minY { let g = moved.minY - r.maxY; if up == nil || g < up!.0 { up = (g, r) } }
                if r.minY >= moved.maxY { let g = r.minY - moved.maxY; if down == nil || g < down!.0 { down = (g, r) } }
            }
        }
        func midY(_ r: CGRect) -> CGFloat { (max(r.minY, moved.minY) + min(r.maxY, moved.maxY)) / 2 }
        func midX(_ r: CGRect) -> CGFloat { (max(r.minX, moved.minX) + min(r.maxX, moved.maxX)) / 2 }
        if let (g, r) = left, g > 0 { gaps.append((CGPoint(x: r.maxX, y: midY(r)), CGPoint(x: moved.minX, y: midY(r)), "\(Int(g.rounded())) px")) }
        if let (g, r) = right, g > 0 { gaps.append((CGPoint(x: moved.maxX, y: midY(r)), CGPoint(x: r.minX, y: midY(r)), "\(Int(g.rounded())) px")) }
        if let (g, r) = up, g > 0 { gaps.append((CGPoint(x: midX(r), y: r.maxY), CGPoint(x: midX(r), y: moved.minY), "\(Int(g.rounded())) px")) }
        if let (g, r) = down, g > 0 { gaps.append((CGPoint(x: midX(r), y: moved.maxY), CGPoint(x: midX(r), y: r.minY), "\(Int(g.rounded())) px")) }
        return dl
    }

    static let magenta = NSColor(calibratedRed: 1, green: 0.1, blue: 0.75, alpha: 1)

    func draw(_ ctx: CGContext, canvas: CanvasView) {
        guard enabled, !lines.isEmpty || !gaps.isEmpty else { return }
        ctx.saveGState()
        ctx.setStrokeColor(SmartGuides.magenta.cgColor)
        ctx.setLineWidth(1)
        for (a, b) in lines {
            ctx.move(to: canvas.docToView(a)); ctx.addLine(to: canvas.docToView(b))
        }
        ctx.strokePath()
        for (a, b, label) in gaps {
            let va = canvas.docToView(a), vb = canvas.docToView(b)
            ctx.setLineDash(phase: 0, lengths: [3, 2])
            ctx.move(to: va); ctx.addLine(to: vb); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            let m = (va + vb) / 2
            NSGraphicsContext.saveGraphicsState()
            ExtraOverlays.badge(label, at: CGPoint(x: m.x + 4, y: m.y + 4), color: SmartGuides.magenta)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }
}
