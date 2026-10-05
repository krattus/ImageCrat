import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Tidy Up

/// Tidy Up: detects the rows and columns the selected layers roughly form and equalises the gaps (like Figma's Tidy Up).
enum TidyUp {
    enum Structure: Equatable { case row, column, grid(rows: Int, columns: Int) }

    /// Groups indices into bands along one axis: an item joins a band when its centre falls inside the band's extent.
    static func bands(_ rects: [CGRect], vertical: Bool) -> [[Int]] {
        func lo(_ r: CGRect) -> CGFloat { vertical ? r.minY : r.minX }
        func hi(_ r: CGRect) -> CGFloat { vertical ? r.maxY : r.maxX }
        func mid(_ r: CGRect) -> CGFloat { vertical ? r.midY : r.midX }
        let order = rects.indices.sorted { mid(rects[$0]) < mid(rects[$1]) }
        var out: [[Int]] = []
        var bandLo: CGFloat = 0, bandHi: CGFloat = 0
        for i in order {
            let r = rects[i]
            if !out.isEmpty {
                // overlap of at least half of the smaller extent keeps the item in the current band
                let overlap = min(bandHi, hi(r)) - max(bandLo, lo(r))
                let need = min(bandHi - bandLo, hi(r) - lo(r)) * 0.5
                if overlap >= need && overlap > 0 {
                    out[out.count - 1].append(i)
                    bandLo = min(bandLo, lo(r)); bandHi = max(bandHi, hi(r))
                    continue
                }
            }
            out.append([i])
            bandLo = lo(r); bandHi = hi(r)
        }
        return out
    }

    /// Target rects (same sizes, new origins) and the structure that was detected.
    static func tidy(_ rects: [CGRect]) -> (rects: [CGRect], structure: Structure) {
        guard rects.count >= 2, let all = LayoutGeom.union(rects) else { return (rects, .row) }
        let rows = bands(rects, vertical: true)
        let cols = bands(rects, vertical: false)
        var out = rects

        /// Positions of bands of the given sizes spread evenly between `lo` and `hi` (first and last stay put).
        func spread(_ sizes: [CGFloat], lo: CGFloat, hi: CGFloat) -> (starts: [CGFloat], gap: CGFloat) {
            let total = sizes.reduce(0, +)
            let gap = sizes.count > 1 ? ((hi - lo - total) / CGFloat(sizes.count - 1)).rounded() : 0
            var starts: [CGFloat] = []
            var x = lo.rounded()
            for s in sizes { starts.append(x); x += s + gap }
            return (starts, gap)
        }

        if rows.count == 1 || cols.count == 1 {
            let horizontal = rows.count == 1 && (cols.count > 1 || all.width >= all.height)
            let order = rects.indices.sorted { horizontal ? rects[$0].minX < rects[$1].minX : rects[$0].minY < rects[$1].minY }
            let sizes = order.map { horizontal ? rects[$0].width : rects[$0].height }
            let sp = spread(sizes, lo: horizontal ? all.minX : all.minY, hi: horizontal ? all.maxX : all.maxY)
            // align on the shared centre line
            let center = (order.map { horizontal ? rects[$0].midY : rects[$0].midX }.reduce(0, +) / CGFloat(order.count)).rounded()
            for (k, i) in order.enumerated() {
                if horizontal { out[i].origin = CGPoint(x: sp.starts[k], y: (center - rects[i].height / 2).rounded()) }
                else { out[i].origin = CGPoint(x: (center - rects[i].width / 2).rounded(), y: sp.starts[k]) }
            }
            return (out, horizontal ? .row : .column)
        }

        // grid: every item sits in a (row, column) cell; cells are as large as their biggest item
        var rowOf = [Int](repeating: 0, count: rects.count), colOf = rowOf
        for (r, band) in rows.enumerated() { for i in band { rowOf[i] = r } }
        for (c, band) in cols.enumerated() { for i in band { colOf[i] = c } }
        let colW = cols.map { $0.map { rects[$0].width }.max() ?? 0 }
        let rowH = rows.map { $0.map { rects[$0].height }.max() ?? 0 }
        let xs = spread(colW, lo: all.minX, hi: all.maxX)
        let ys = spread(rowH, lo: all.minY, hi: all.maxY)
        for i in rects.indices {
            let c = colOf[i], r = rowOf[i]
            out[i].origin = CGPoint(x: (xs.starts[c] + (colW[c] - rects[i].width) / 2).rounded(), y: (ys.starts[r] + (rowH[r] - rects[i].height) / 2).rounded())
        }
        return (out, .grid(rows: rows.count, columns: cols.count))
    }

    static func tidied(_ base: DocumentState, ids: [UUID]) -> (state: DocumentState, structure: Structure)? {
        let items = LayoutGeom.items(ids, base)
        guard items.count >= 2 else { return nil }
        let result = tidy(items.map(\.rect))
        var st = base
        for (item, target) in zip(items, result.rects) {
            LayoutGeom.translate(&st, item.id, dx: target.minX - item.rect.minX, dy: target.minY - item.rect.minY)
        }
        return (st, result.structure)
    }

    static func run() {
        guard let d = AppActions.doc else { return }
        guard let r = tidied(d.state, ids: LayoutGeom.movable(d)) else { Beep.play(); return }
        d.state = r.state
        d.commit("Tidy Up")
        switch r.structure {
        case .row: AppModel.shared.setStatus("Tidy Up: row — equal gaps")
        case .column: AppModel.shared.setStatus("Tidy Up: column — equal gaps")
        case .grid(let rows, let cols): AppModel.shared.setStatus("Tidy Up: \(rows) × \(cols) grid")
        }
    }

    // MARK: Exact spacing

    /// Lays the layers out along one axis with an exact gap, keeping the first one where it is.
    static func distributed(_ base: DocumentState, ids: [UUID], gap: CGFloat, horizontal: Bool) -> DocumentState {
        var items = LayoutGeom.items(ids, base)
        guard items.count >= 2 else { return base }
        items.sort { horizontal ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        var st = base
        var pos = horizontal ? items[0].rect.minX : items[0].rect.minY
        for it in items {
            if horizontal { LayoutGeom.translate(&st, it.id, dx: pos - it.rect.minX, dy: 0); pos += it.rect.width + gap }
            else { LayoutGeom.translate(&st, it.id, dx: 0, dy: pos - it.rect.minY); pos += it.rect.height + gap }
        }
        return st
    }

    /// Average gap currently between the layers along an axis.
    static func currentGap(_ st: DocumentState, ids: [UUID], horizontal: Bool) -> CGFloat {
        var r = LayoutGeom.items(ids, st).map(\.rect)
        guard r.count >= 2 else { return 0 }
        r.sort { horizontal ? $0.minX < $1.minX : $0.minY < $1.minY }
        var sum: CGFloat = 0
        for i in 1..<r.count { sum += horizontal ? r[i].minX - r[i - 1].maxX : r[i].minY - r[i - 1].maxY }
        return (sum / CGFloat(r.count - 1)).rounded()
    }

    // MARK: Swap / match

    /// Two layers trade places; more than two rotate through each other's positions (centres).
    static func swapped(_ base: DocumentState, ids: [UUID]) -> DocumentState {
        let items = LayoutGeom.items(ids, base)
        guard items.count >= 2 else { return base }
        var st = base
        for (i, it) in items.enumerated() {
            let target = items[(i + 1) % items.count].rect
            LayoutGeom.translate(&st, it.id, dx: target.midX - it.rect.midX, dy: target.midY - it.rect.midY)
        }
        return st
    }

    static func swapPositions() {
        guard let d = AppActions.doc else { return }
        let ids = LayoutGeom.movable(d)
        guard ids.count >= 2 else { Beep.play(); return }
        d.state = swapped(d.state, ids: ids)
        d.commit("Swap Positions")
    }

    /// Resizes the layers to the key layer's width and / or height around their own centres.
    static func matched(_ base: DocumentState, ids: [UUID], key: UUID, width: Bool, height: Bool) -> DocumentState {
        guard let k = LayoutGeom.bounds(key, base), k.width > 0, k.height > 0 else { return base }
        var st = base
        for id in ids where id != key {
            guard let b = LayoutGeom.bounds(id, st), b.width > 0, b.height > 0 else { continue }
            let w = width ? k.width : b.width, h = height ? k.height : b.height
            LayoutGeom.setFrame(&st, id, to: CGRect(x: (b.midX - w / 2).rounded(), y: (b.midY - h / 2).rounded(), width: w, height: h))
        }
        return st
    }

    static func matchSize(width: Bool, height: Bool) {
        guard let d = AppActions.doc else { return }
        let ids = LayoutGeom.movable(d)
        // the key layer is the active one (the last layer clicked)
        guard ids.count >= 2, let key = d.activeLayerID.flatMap({ ids.contains($0) ? $0 : nil }) ?? ids.last else { Beep.play(); return }
        d.state = matched(d.state, ids: ids, key: key, width: width, height: height)
        d.commit(width && height ? "Match Size" : width ? "Match Width" : "Match Height")
    }
}

/// Layer ▸ Arrange ▸ Distribute with Spacing…
struct DistributeSpacingDialog: View {
    @State private var gap: Double = 20
    @State private var horizontal = true
    @State private var session = LayoutPreviewSession()
    @State private var ready = false

    var body: some View {
        DialogFrame(title: "Distribute with Spacing", width: 320, onOK: { session.finish(apply: true, name: "Distribute with Spacing") },
                    onCancel: { session.finish(apply: false, name: "") }) {
            if ready && session.ids.count < 2 {
                Text("Select two or more layers.").foregroundStyle(Theme.textFaint)
            } else {
                Picker("", selection: $horizontal) { Text("Horizontal").tag(true); Text("Vertical").tag(false) }.pickerStyle(.segmented).labelsHidden()
                ValueSlider(label: "Gap", value: $gap, range: -200...600, unit: "px", labelWidth: 50)
                Text("The \(horizontal ? "leftmost" : "topmost") layer stays where it is.").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
            }
        }
        .onAppear {
            guard !ready, let d = AppActions.doc else { return }
            session.begin()
            let ids = LayoutGeom.movable(d)
            if let u = LayoutGeom.union(LayoutGeom.items(ids, d.state).map(\.rect)) { horizontal = u.width >= u.height }
            gap = Double(max(0, TidyUp.currentGap(d.state, ids: ids, horizontal: horizontal)))
            ready = true
            update()
        }
        .onChange(of: gap) { _, _ in update() }
        .onChange(of: horizontal) { _, _ in update() }
    }

    private func update() {
        guard ready else { return }
        session.preview { base, ids, _ in TidyUp.distributed(base, ids: ids, gap: CGFloat(gap.rounded()), horizontal: horizontal) }
    }
}

// MARK: - On-canvas spacing handles

/// When three or more selected layers are evenly spaced in a row or column, the Move tool shows pink handles
/// between them; dragging one changes every gap at once.
final class SpacingHandles {
    static let shared = SpacingHandles()

    struct Run: Equatable {
        var horizontal: Bool
        var ids: [UUID]          // in order along the axis
        var rects: [CGRect]
        var gap: CGFloat
    }

    var enabled: Bool = UserDefaults.standard.object(forKey: "Lumen.SpacingHandles") as? Bool ?? true {
        didSet { LayoutPrefs.set(enabled, "Lumen.SpacingHandles") }
    }

    func toggle() {
        enabled.toggle()
        AppModel.shared.setStatus("Spacing Handles: \(enabled ? "on" : "off")")
        AppActions.canvas?.overlay.needsDisplay = true
    }

    static let pink = NSColor(calibratedRed: 1, green: 0.22, blue: 0.62, alpha: 1)

    // MARK: Maths

    /// A row / column of evenly spaced, non-overlapping rects (≥ 3), or nil.
    static func detect(_ items: [(id: UUID, rect: CGRect)], tolerance: CGFloat = 1.5) -> Run? {
        guard items.count >= 3 else { return nil }
        for horizontal in [true, false] {
            let sorted = items.sorted { horizontal ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
            // all of them share a line across the other axis
            let lo = sorted.map { horizontal ? $0.rect.minY : $0.rect.minX }.max() ?? 0
            let hi = sorted.map { horizontal ? $0.rect.maxY : $0.rect.maxX }.min() ?? 0
            guard hi > lo else { continue }
            var gaps: [CGFloat] = []
            for i in 1..<sorted.count {
                gaps.append(horizontal ? sorted[i].rect.minX - sorted[i - 1].rect.maxX : sorted[i].rect.minY - sorted[i - 1].rect.maxY)
            }
            guard let first = gaps.first, gaps.allSatisfy({ abs($0 - first) <= tolerance && $0 >= -0.5 }) else { continue }
            let mean = gaps.reduce(0, +) / CGFloat(gaps.count)
            return Run(horizontal: horizontal, ids: sorted.map(\.id), rects: sorted.map(\.rect), gap: mean)
        }
        return nil
    }

    /// Centre of each gap (document space).
    static func handles(_ run: Run) -> [CGPoint] {
        let lo = run.rects.map { run.horizontal ? $0.minY : $0.minX }.max() ?? 0
        let hi = run.rects.map { run.horizontal ? $0.maxY : $0.maxX }.min() ?? 0
        let mid = (lo + hi) / 2
        return (0..<(run.rects.count - 1)).map { i in
            let a = run.rects[i], b = run.rects[i + 1]
            return run.horizontal ? CGPoint(x: (a.maxX + b.minX) / 2, y: mid) : CGPoint(x: mid, y: (a.maxY + b.minY) / 2)
        }
    }

    /// The gap that keeps handle `index` under the cursor after it moved by `delta` along the axis.
    /// The first layer is the anchor, so handle i travels (i + ½) px per px of gap.
    static func gap(for run: Run, handle index: Int, delta: CGFloat) -> CGFloat {
        max(0, (run.gap + delta / (CGFloat(index) + 0.5)).rounded())
    }

    static func apply(_ base: DocumentState, run: Run, gap: CGFloat) -> DocumentState {
        var st = base
        var pos = run.horizontal ? run.rects[0].minX : run.rects[0].minY
        for (id, r) in zip(run.ids, run.rects) {
            if run.horizontal { LayoutGeom.translate(&st, id, dx: pos - r.minX, dy: 0); pos += r.width + gap }
            else { LayoutGeom.translate(&st, id, dx: 0, dy: pos - r.minY); pos += r.height + gap }
        }
        return st
    }

    // MARK: Interaction (called by the Move tool)

    private var cache: (key: String, run: Run?)?
    private var drag: (run: Run, index: Int, start: CGPoint, base: DocumentState, gap: CGFloat)?

    func current(_ d: Document) -> Run? {
        guard enabled, d.selectedLayerIDs.count >= 3 else { return nil }
        if let dr = drag { var r = dr.run; r.gap = dr.gap; return r }
        let key = "\(ObjectIdentifier(d).hashValue)-\(d.revision)-\(d.renderVersion)-\(d.selectedLayerIDs.hashValue)"
        if let c = cache, c.key == key { return c.run }
        let ids = d.orderedSelection.filter { d.state.layer($0).map { !$0.locks.positionLocked && !$0.isAdjustment } ?? false }
        let run = ids.count == d.selectedLayerIDs.count ? SpacingHandles.detect(LayoutGeom.items(ids, d.state)) : nil
        cache = (key, run)
        return run
    }

    private func usable(_ canvas: CanvasView) -> Bool {
        AppModel.shared.tool == .move && !canvas.tool(for: .move).isBusy && AppModel.shared.dialog == nil
    }

    func mouseDown(_ e: ToolEvent, canvas: CanvasView) -> Bool {
        guard let d = canvas.document, usable(canvas), !e.option, !e.command, let run = current(d) else { return false }
        let pts = SpacingHandles.handles(run)
        guard let i = pts.firstIndex(where: { canvas.docToView($0).distance(to: e.view) < 9 }) else { return false }
        drag = (run, i, e.doc, d.state, run.gap)
        return true
    }

    func mouseDragged(_ e: ToolEvent, canvas: CanvasView) -> Bool {
        guard var dr = drag, let d = canvas.document else { return false }
        let delta = dr.run.horizontal ? e.doc.x - dr.start.x : e.doc.y - dr.start.y
        let g = SpacingHandles.gap(for: dr.run, handle: dr.index, delta: delta)
        if g != dr.gap {
            dr.gap = g
            drag = dr
            d.state = SpacingHandles.apply(dr.base, run: dr.run, gap: g)
        }
        AppModel.shared.setStatus("Spacing: \(Int(g)) px")
        return true
    }

    func mouseUp(_ e: ToolEvent, canvas: CanvasView) -> Bool {
        guard let dr = drag, let d = canvas.document else { return false }
        drag = nil
        cache = nil
        if dr.gap != dr.run.gap { d.commit("Change Spacing") }
        return true
    }

    // MARK: Drawing

    func draw(_ ctx: CGContext, canvas: CanvasView, doc d: Document) {
        guard usable(canvas) || drag != nil, let base = current(d) else { return }
        // while dragging, show the live positions
        var run = base
        if let dr = drag {
            var pos = run.horizontal ? run.rects[0].minX : run.rects[0].minY
            for i in run.rects.indices {
                if run.horizontal { run.rects[i].origin.x = pos; pos += run.rects[i].width + dr.gap }
                else { run.rects[i].origin.y = pos; pos += run.rects[i].height + dr.gap }
            }
        }
        let pts = SpacingHandles.handles(run)
        ctx.saveGState()
        let pink = SpacingHandles.pink
        for (i, p) in pts.enumerated() {
            let v = canvas.docToView(p)
            if drag != nil {
                // tint the gaps while they change
                let a = run.rects[i], b = run.rects[i + 1]
                let gapRect = run.horizontal ? CGRect(x: a.maxX, y: max(a.minY, b.minY), width: b.minX - a.maxX, height: min(a.maxY, b.maxY) - max(a.minY, b.minY))
                                             : CGRect(x: max(a.minX, b.minX), y: a.maxY, width: min(a.maxX, b.maxX) - max(a.minX, b.minX), height: b.minY - a.maxY)
                if gapRect.width > 0, gapRect.height > 0 {
                    ctx.setFillColor(pink.withAlphaComponent(0.18).cgColor)
                    ctx.addPath(canvas.docToViewPath(gapRect))
                    ctx.fillPath()
                }
            }
            // the handle: a short bar across the gap's axis
            let half: CGFloat = 8
            let bar = run.horizontal ? CGRect(x: v.x - 1.5, y: v.y - half, width: 3, height: 2 * half) : CGRect(x: v.x - half, y: v.y - 1.5, width: 2 * half, height: 3)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: -1, dy: -1), cornerWidth: 2, cornerHeight: 2, transform: nil)); ctx.fillPath()
            ctx.setFillColor(pink.cgColor)
            ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.fillPath()
        }
        if let dr = drag, dr.index < pts.count {
            let v = canvas.docToView(pts[dr.index])
            NSGraphicsContext.saveGraphicsState()
            ExtraOverlays.badge("\(Int(dr.gap)) px", at: CGPoint(x: v.x + 8, y: v.y + 10), color: pink)
            NSGraphicsContext.restoreGraphicsState()
        }
        ctx.restoreGState()
    }
}
