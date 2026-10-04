import AppKit
import ImageCratCore

/// "Intelligent scissors": shortest path along strong edges between two points.
final class LiveWire {
    let width: Int, height: Int
    private var cost: [Float]        // per-pixel traversal cost (low on edges)

    /// `src`: canvas-size RGBA composite. `contrast` 1…100 (edge contrast threshold, %).
    init(src: PixelBuffer, contrast: Double) {
        width = src.width; height = src.height
        let w = width, h = height
        var lum = [Float](repeating: 0, count: w * h)
        let p = src.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = p + y * src.bytesPerRow
            for x in 0..<w {
                let i = x * 4
                lum[y * w + x] = (0.299 * Float(row[i]) + 0.587 * Float(row[i + 1]) + 0.114 * Float(row[i + 2])) / 255
            }
        }
        // Sobel gradient magnitude
        var grad = [Float](repeating: 0, count: w * h)
        var maxG: Float = 0.0001
        if w > 2 && h > 2 {
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    @inline(__always) func L(_ dx: Int, _ dy: Int) -> Float { lum[(y + dy) * w + x + dx] }
                    let gx = -L(-1, -1) - 2 * L(-1, 0) - L(-1, 1) + L(1, -1) + 2 * L(1, 0) + L(1, 1)
                    let gy = -L(-1, -1) - 2 * L(0, -1) - L(1, -1) + L(-1, 1) + 2 * L(0, 1) + L(1, 1)
                    let g = sqrt(gx * gx + gy * gy)
                    grad[y * w + x] = g
                    maxG = max(maxG, g)
                }
            }
        }
        let thr = Float(contrast / 100) * 0.5
        cost = grad.map { g in
            let n = g / maxG
            let e = n < thr ? n * 0.3 : n
            return 1.02 - min(1, e * 1.4)
        }
    }

    /// Path (pixel centers, doc coords) from `a` to `b`, searching within a band around the segment.
    func path(from a: CGPoint, to b: CGPoint, band: Int = 40) -> [CGPoint] {
        let ax = clamp(Int(a.x), 0, width - 1), ay = clamp(Int(a.y), 0, height - 1)
        let bx = clamp(Int(b.x), 0, width - 1), by = clamp(Int(b.y), 0, height - 1)
        if ax == bx && ay == by { return [a] }
        let x0 = max(0, min(ax, bx) - band), x1 = min(width - 1, max(ax, bx) + band)
        let y0 = max(0, min(ay, by) - band), y1 = min(height - 1, max(ay, by) + band)
        let ww = x1 - x0 + 1, hh = y1 - y0 + 1
        let n = ww * hh
        if n > 2_000_000 { return [a, b] }
        var dist = [Float](repeating: .infinity, count: n)
        var prev = [Int32](repeating: -1, count: n)
        var done = [Bool](repeating: false, count: n)
        let start = (ay - y0) * ww + (ax - x0), goal = (by - y0) * ww + (bx - x0)
        dist[start] = 0
        var heap = MinHeap()
        heap.push(0, Int32(start))
        let nx = [-1, 0, 1, -1, 1, -1, 0, 1], ny = [-1, -1, -1, 0, 0, 1, 1, 1]
        let nd: [Float] = [1.414, 1, 1.414, 1, 1, 1.414, 1, 1.414]
        while let (d, idx32) = heap.pop() {
            let idx = Int(idx32)
            if done[idx] { continue }
            done[idx] = true
            if idx == goal { break }
            let cx = idx % ww, cy = idx / ww
            for k in 0..<8 {
                let xx = cx + nx[k], yy = cy + ny[k]
                if xx < 0 || yy < 0 || xx >= ww || yy >= hh { continue }
                let j = yy * ww + xx
                if done[j] { continue }
                let c = cost[(yy + y0) * width + xx + x0] * nd[k]
                let nd2 = d + c
                if nd2 < dist[j] {
                    dist[j] = nd2
                    prev[j] = Int32(idx)
                    heap.push(nd2, Int32(j))
                }
            }
        }
        var out: [CGPoint] = []
        var cur = goal
        var guardCount = 0
        while cur >= 0 && guardCount < n {
            out.append(CGPoint(x: Double(cur % ww + x0) + 0.5, y: Double(cur / ww + y0) + 0.5))
            if cur == start { break }
            cur = Int(prev[cur])
            guardCount += 1
        }
        if out.last.map({ Int($0.x) != ax || Int($0.y) != ay }) ?? true { return [a, b] }
        return out.reversed()
    }
}

/// Binary min-heap keyed by Float.
struct MinHeap {
    private var keys: [Float] = []
    private var vals: [Int32] = []
    mutating func push(_ k: Float, _ v: Int32) {
        keys.append(k); vals.append(v)
        var i = keys.count - 1
        while i > 0 {
            let p = (i - 1) / 2
            if keys[p] <= keys[i] { break }
            keys.swapAt(p, i); vals.swapAt(p, i); i = p
        }
    }
    mutating func pop() -> (Float, Int32)? {
        guard !keys.isEmpty else { return nil }
        let r = (keys[0], vals[0])
        let lk = keys.removeLast(), lv = vals.removeLast()
        if !keys.isEmpty {
            keys[0] = lk; vals[0] = lv
            var i = 0
            while true {
                let l = 2 * i + 1, rr = l + 1
                var m = i
                if l < keys.count && keys[l] < keys[m] { m = l }
                if rr < keys.count && keys[rr] < keys[m] { m = rr }
                if m == i { break }
                keys.swapAt(m, i); vals.swapAt(m, i); i = m
            }
        }
        return r
    }
}

final class MagneticLassoTool: SelectionToolBase {
    private var wire: LiveWire?
    private var anchors: [CGPoint] = []
    private var committedPath: [CGPoint] = []   // path through fixed anchors
    private var live: [CGPoint] = []            // from last anchor to cursor
    private var lastAutoAnchorLen = 0

    override var isBusy: Bool { validate(); return !anchors.isEmpty }
    /// Edit ▸ Undo takes back the last anchor (the first one cancels the outline).
    override func undoPending() -> Bool {
        if anchors.count > 1 { removeLastAnchor() } else { reset() }
        canvas.overlay.needsDisplay = true
        return true
    }
    override func deactivate() { super.deactivate(); reset() }

    /// The edge map belongs to one canvas size: drop the outline when another command changed the canvas.
    private func validate() {
        guard let w = wire, let d = doc, w.width != d.state.width || w.height != d.state.height else { return }
        reset()
    }

    private func removeLastAnchor() {
        anchors.removeLast()
        guard let w = wire else { return }
        committedPath = [anchors[0]]
        for i in 1..<anchors.count { committedPath += w.path(from: anchors[i - 1], to: anchors[i], band: Int(app.magneticWidth * 2)).dropFirst() }
        live = []
    }

    override func mouseDown(_ e: ToolEvent) {
        validate()
        guard let d = doc else { return }
        if anchors.isEmpty {
            combine = combineMode(e)
            if beginMoveSelection(e) { return }
            guard let src = AppActions.sampleSource(allLayers: true) else { return }
            wire = LiveWire(src: src, contrast: app.magneticContrast)
            anchors = [clampPoint(e.doc, d)]
            committedPath = [anchors[0]]
            live = []
            return
        }
        if let f = anchors.first, (canvas.docToView(f).distance(to: e.view) < 8 && anchors.count > 1) || e.clickCount >= 2 {
            finish(close: true)
            return
        }
        addAnchor(clampPoint(e.doc, d))
    }

    override func mouseDragged(_ e: ToolEvent) {
        if movingSelection != nil { updateMoveSelection(e); return }
        mouseMoved(e)
    }

    override func mouseUp(_ e: ToolEvent) {
        if movingSelection != nil { endMoveSelection() }
    }

    override func mouseMoved(_ e: ToolEvent) {
        validate()
        guard let w = wire, let last = anchors.last, let d = doc else { return }
        live = w.path(from: last, to: clampPoint(e.doc, d), band: Int(app.magneticWidth * 2))
        // automatic anchors (frequency)
        let freq = max(10, 110 - Int(app.magneticFrequency))
        if live.count > freq, live.count - lastAutoAnchorLen > freq {
            addAnchor(live[live.count - freq / 3])
        }
    }

    private func clampPoint(_ p: CGPoint, _ d: Document) -> CGPoint {
        CGPoint(x: clamp(p.x, 0, CGFloat(d.state.width - 1)), y: clamp(p.y, 0, CGFloat(d.state.height - 1)))
    }

    private func addAnchor(_ p: CGPoint) {
        guard let w = wire, let last = anchors.last else { return }
        let seg = w.path(from: last, to: p, band: Int(app.magneticWidth * 2))
        committedPath += seg.dropFirst()
        anchors.append(p)
        live = []
        lastAutoAnchorLen = 0
    }

    private func finish(close: Bool) {
        guard let d = doc, let w = wire, let last = anchors.last, let first = anchors.first else { reset(); return }
        var pts = committedPath
        if close { pts += w.path(from: last, to: first, band: Int(app.magneticWidth * 2)).dropFirst() }
        guard pts.count > 2 else { reset(); return }
        let p = CGMutablePath()
        p.addLines(between: pts)
        p.closeSubpath()
        apply(SelectionOps.mask(fromPath: p, width: d.state.width, height: d.state.height, antialias: app.selection.antialias), name: "Magnetic Lasso")
        reset()
    }

    private func reset() { anchors = []; committedPath = []; live = []; wire = nil }

    override func commit() { if anchors.count > 1 { finish(close: true) } }
    override func cancel() { reset() }

    override func keyDown(_ e: NSEvent) -> Bool {
        if e.keyCode == 51, anchors.count > 1 {
            removeLastAnchor()      // rebuilds the committed path
            return true
        }
        return false
    }

    override func drawOverlay(_ ctx: CGContext) {
        validate()
        guard !anchors.isEmpty else {
            if let m = canvas.lastMouseView {
                let r = CGFloat(app.magneticWidth) * canvas.zoom
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
                ctx.strokeEllipse(in: CGRect(x: m.x - r, y: m.y - r, width: 2 * r, height: 2 * r))
            }
            return
        }
        let p = CGMutablePath()
        p.addLines(between: (committedPath + live).map { canvas.docToView($0) })
        OverlayStyle.contrastStroke(ctx, p)
        for a in anchors { OverlayStyle.handle(ctx, at: canvas.docToView(a), size: 5) }
    }
}
