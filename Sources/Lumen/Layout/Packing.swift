import AppKit
import SwiftUI
import ImageCratCore

// MARK: - Pack into Shape

struct PackSettings: Equatable {
    enum Shape: String, CaseIterable, Identifiable {
        case circle = "Circle", rectangle = "Rectangle", custom = "Custom Shape", selection = "Selection", path = "Active Path", canvas = "Canvas"
        var id: String { rawValue }
    }
    enum Mode: String, CaseIterable, Identifiable {
        case boxes = "Boxes", circles = "Circles"
        var id: String { rawValue }
    }
    var shape: Shape = .circle
    var mode: Mode = .boxes
    var width: Double = 500
    var height: Double = 500
    var centerX: Double = 0
    var centerY: Double = 0
    var customID = "heart"
    var padding: Double = 8
    var scaleToFit = true
    var shuffle = false
    var seed = 1
}

/// Packs rectangles or circles into an arbitrary outline without overlaps.
/// Works on a coarse occupancy mask of the outline, so every placement test is O(1) (summed-area table / distance map).
enum Packing {
    struct Result {
        var frames: [CGRect?]     // per input size, nil when it did not fit
        var scale: CGFloat
        var placed: Int { frames.compactMap { $0 }.count }
    }

    private struct Mask {
        var w: Int, h: Int
        var k: CGFloat             // mask pixels per document pixel
        var origin: CGPoint        // document position of mask pixel (0,0)
        var inside: [UInt8]        // 1 = inside the outline
        var order: [Int32]         // inside pixels sorted by distance from the centroid
        var sat: [Int32]           // summed-area table of `inside`, (w + 1) × (h + 1)
        var dist: [Float]          // distance (mask px) from each pixel to the nearest pixel outside the outline
    }

    /// The last outline's mask: dialogs pack into the same outline again and again while other settings change.
    private static var lastMask: (path: CGPath, evenOdd: Bool, resolution: Int, circles: Bool, mask: Mask)?

    private static func makeMask(_ path: CGPath, evenOdd: Bool, resolution: Int, circles: Bool) -> Mask? {
        if let c = lastMask, c.evenOdd == evenOdd, c.resolution == resolution, c.circles == circles, c.path == path { return c.mask }
        let box = path.boundingBoxOfPath
        guard box.width > 1, box.height > 1, !box.isInfinite, !box.isNull else { return nil }
        let k = CGFloat(resolution) / max(box.width, box.height)
        let w = max(2, Int(ceil(box.width * k))), h = max(2, Int(ceil(box.height * k)))
        var t = CGAffineTransform(translationX: -box.minX, y: -box.minY).concatenating(CGAffineTransform(scaleX: k, y: k))
        guard let p = path.copy(using: &t) else { return nil }
        let buf = SelectionOps.mask(fromPath: p, width: w, height: h, antialias: true, evenOdd: evenOdd)
        let src = buf.data.assumingMemoryBound(to: UInt8.self)
        var inside = [UInt8](repeating: 0, count: w * h)
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<h {
            let row = src + y * buf.bytesPerRow
            for x in 0..<w where row[x] >= 250 {   // fully covered pixels only (conservative)
                inside[y * w + x] = 1
                sx += Double(x); sy += Double(y); n += 1
            }
        }
        guard n > 0 else { return nil }
        let cx = sx / n, cy = sy / n
        // sort the inside pixels by distance from the centroid (packed keys: no comparison closure)
        var keys: [UInt64] = []
        keys.reserveCapacity(Int(n))
        for y in 0..<h {
            for x in 0..<w where inside[y * w + x] == 1 {
                let dx = Double(x) - cx, dy = Double(y) - cy
                keys.append(UInt64(dx * dx + dy * dy) << 32 | UInt64(y * w + x))
            }
        }
        keys.sort()
        let order = keys.map { Int32(truncatingIfNeeded: $0 & 0xFFFF_FFFF) }
        // boxes need the summed-area table, circles the distance map
        let m = Mask(w: w, h: h, k: k, origin: box.origin, inside: inside, order: order, sat: circles ? [] : integral(inside, w, h),
                     dist: circles ? distanceSquared(inside, w, h).map { $0.squareRoot() } : [])
        lastMask = (path, evenOdd, resolution, circles, m)
        return m
    }

    /// Summed-area table of the free pixels ((w+1) × (h+1)).
    private static func integral(_ free: [UInt8], _ w: Int, _ h: Int) -> [Int32] {
        var sat = [Int32](repeating: 0, count: (w + 1) * (h + 1))
        free.withUnsafeBufferPointer { f in
            sat.withUnsafeMutableBufferPointer { s in
                for y in 0..<h {
                    var row: Int32 = 0
                    for x in 0..<w {
                        row += Int32(f[y * w + x])
                        s[(y + 1) * (w + 1) + x + 1] = s[y * (w + 1) + x + 1] + row
                    }
                }
            }
        }
        return sat
    }

    /// Exact squared Euclidean distance to the nearest blocked pixel (Felzenszwalb & Huttenlocher).
    private static func distanceSquared(_ free: [UInt8], _ w: Int, _ h: Int) -> [Float] {
        let inf = 1e12
        let n = max(w, h)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)
        var line = [Double](repeating: 0, count: n)
        var out = [Double](repeating: 0, count: n)
        /// Lower envelope of the parabolas rooted at line[0..<len]; result in out[0..<len].
        func transform(_ len: Int) {
            var k = 0
            v[0] = 0; z[0] = -inf * 4; z[1] = inf * 4
            if len > 1 {
                for q in 1..<len {
                    var s = 0.0
                    while true {
                        let p = v[k]
                        s = ((line[q] + Double(q * q)) - (line[p] + Double(p * p))) / Double(2 * (q - p))
                        if s <= z[k] && k > 0 { k -= 1 } else { break }
                    }
                    k += 1
                    v[k] = q; z[k] = s; z[k + 1] = inf * 4
                }
            }
            k = 0
            for q in 0..<len {
                while z[k + 1] < Double(q) { k += 1 }
                let p = v[k]
                out[q] = Double((q - p) * (q - p)) + line[p]
            }
        }
        var f = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) { f[i] = free[i] == 1 ? inf : 0 }
        for x in 0..<w {
            for y in 0..<h { line[y] = f[y * w + x] }
            transform(h)
            for y in 0..<h { f[y * w + x] = out[y] }
        }
        for y in 0..<h {
            for x in 0..<w { line[x] = f[y * w + x] }
            transform(w)
            for x in 0..<w { f[y * w + x] = out[x] }
        }
        // pixels next to the mask border touch the outside
        var res = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let edge = Double(min(min(x, w - 1 - x), min(y, h - 1 - y)) + 1)
                res[y * w + x] = Float(min(f[y * w + x], edge * edge))
            }
        }
        return res
    }

    /// One greedy pass at a fixed scale: largest first, each as close to the middle of the outline as it fits.
    /// "Inside the outline" is an O(1) lookup (summed-area table / distance map); overlaps with the items placed so far
    /// are tested exactly, after a one-byte occupancy check that rejects most candidates.
    private static func attempt(_ sizes: [CGSize], order: [Int], mask m: Mask, mode: PackSettings.Mode, padding: CGFloat, scale s: CGFloat) -> [CGRect?] {
        var free = m.inside
        var frames = [CGRect?](repeating: nil, count: sizes.count)
        let w = m.w, h = m.h
        let pad = padding * m.k                    // in mask pixels
        var placed: [(x: Float, y: Float, hw: Float, hh: Float)] = []     // mask space; circles use hw as the radius
        free.withUnsafeMutableBufferPointer { fr in
            m.order.withUnsafeBufferPointer { ord in
                m.sat.withUnsafeBufferPointer { sat in
                    m.dist.withUnsafeBufferPointer { dist in
                        for i in order {
                            let sz = CGSize(width: sizes[i].width * s, height: sizes[i].height * s)
                            var found: (Int, Int)?
                            switch mode {
                            case .boxes:
                                let fw = Float(sz.width * m.k / 2), fh = Float(sz.height * m.k / 2)
                                // pixel block that contains the box plus half the padding (keeps it off the outline)
                                let hw = Int(ceil(CGFloat(fw) + pad / 2)), hh = Int(ceil(CGFloat(fh) + pad / 2))
                                let need = Int32((2 * hw + 1) * (2 * hh + 1))
                                let gap = Float(pad)
                                for n in 0..<ord.count {
                                    let idx = Int(ord[n])
                                    if fr[idx] == 0 { continue }
                                    let x = idx % w, y = idx / w
                                    let x0 = x - hw, y0 = y - hh, x1 = x + hw + 1, y1 = y + hh + 1
                                    if x0 < 0 || y0 < 0 || x1 > w || y1 > h { continue }
                                    let sum = sat[y1 * (w + 1) + x1] - sat[y0 * (w + 1) + x1] - sat[y1 * (w + 1) + x0] + sat[y0 * (w + 1) + x0]
                                    if sum != need { continue }
                                    let fx = Float(x), fy = Float(y)
                                    var clear = true
                                    for p in placed where abs(fx - p.x) < fw + p.hw + gap && abs(fy - p.y) < fh + p.hh + gap { clear = false; break }
                                    if clear { found = (x, y); break }
                                }
                                if let (x, y) = found {
                                    placed.append((Float(x), Float(y), fw, fh))
                                    // centres inside the placed box can never be used again
                                    let bx = Int(fw), by = Int(fh)
                                    for yy in max(0, y - by)...min(h - 1, y + by) { for xx in max(0, x - bx)...min(w - 1, x + bx) { fr[yy * w + xx] = 0 } }
                                }
                            case .circles:
                                let r = Float(max(sz.width, sz.height) * m.k / 2)
                                let need = r + Float(pad / 2) + 1
                                let gap = Float(pad)
                                for n in 0..<ord.count {
                                    let idx = Int(ord[n])
                                    if fr[idx] == 0 || dist[idx] < need { continue }
                                    let fx = Float(idx % w), fy = Float(idx / w)
                                    var clear = true
                                    for p in placed {
                                        let dx = fx - p.x, dy = fy - p.y, rr = r + p.hw + gap
                                        if dx * dx + dy * dy < rr * rr { clear = false; break }
                                    }
                                    if clear { found = (idx % w, idx / w); break }
                                }
                                if let (x, y) = found {
                                    placed.append((Float(x), Float(y), r, r))
                                    let ri = Int(r)
                                    for yy in max(0, y - ri)...min(h - 1, y + ri) {
                                        for xx in max(0, x - ri)...min(w - 1, x + ri) where Float((xx - x) * (xx - x) + (yy - y) * (yy - y)) <= r * r { fr[yy * w + xx] = 0 }
                                    }
                                }
                            }
                            if let (x, y) = found {
                                let c = CGPoint(x: m.origin.x + (CGFloat(x) + 0.5) / m.k, y: m.origin.y + (CGFloat(y) + 0.5) / m.k)
                                frames[i] = CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height)
                            }
                        }
                    }
                }
            }
        }
        return frames
    }

    /// Packs `sizes` into `path`. With `scaleToFit` every item gets the same scale, chosen as large as possible.
    static func pack(sizes: [CGSize], in path: CGPath, evenOdd: Bool = false, mode: PackSettings.Mode, padding: CGFloat, scaleToFit: Bool,
                     shuffle: Bool = false, seed: Int = 1, resolution: Int = 200) -> Result {
        guard !sizes.isEmpty, let mask = makeMask(path, evenOdd: evenOdd, resolution: resolution, circles: mode == .circles) else {
            return Result(frames: [CGRect?](repeating: nil, count: sizes.count), scale: 1)
        }
        func weight(_ s: CGSize) -> CGFloat { mode == .circles ? max(s.width, s.height) : s.width * s.height }
        var order = Array(sizes.indices).sorted { weight(sizes[$0]) > weight(sizes[$1]) }
        if shuffle {
            // keep "largest first" in three size classes but vary the order inside each, so different seeds give different layouts
            var rng = SeededGenerator(seed: UInt64(max(1, seed)) &* 40503)
            let third = max(1, order.count / 3)
            var out: [Int] = []
            var i = 0
            while i < order.count { out += Array(order[i..<min(order.count, i + third)]).shuffled(using: &rng); i += third }
            order = out
        }
        if !scaleToFit {
            return Result(frames: attempt(sizes, order: order, mask: mask, mode: mode, padding: padding, scale: 1), scale: 1)
        }
        let area = CGFloat(mask.order.count) / (mask.k * mask.k)
        let total = sizes.reduce(CGFloat(0)) { $0 + (mode == .circles ? .pi / 4 * max($1.width, $1.height) * max($1.width, $1.height) : $1.width * $1.height) }
        guard total > 0 else { return Result(frames: [CGRect?](repeating: nil, count: sizes.count), scale: 1) }
        var lo: CGFloat = 0, hi = sqrt(area / total)
        var best: [CGRect?]?
        var bestScale: CGFloat = 1
        for _ in 0..<10 {
            let mid = (lo + hi) / 2
            let f = attempt(sizes, order: order, mask: mask, mode: mode, padding: padding, scale: mid)
            if f.allSatisfy({ $0 != nil }) { best = f; bestScale = mid; lo = mid } else { hi = mid }
        }
        if let b = best { return Result(frames: b, scale: bestScale) }
        return Result(frames: [CGRect?](repeating: nil, count: sizes.count), scale: 1)
    }

    // MARK: Document

    /// The outline to pack into (document space).
    static func outline(_ s: PackSettings, doc d: Document, base: DocumentState) -> (path: CGPath, evenOdd: Bool)? {
        let r = CGRect(x: s.centerX - s.width / 2, y: s.centerY - s.height / 2, width: max(2, s.width), height: max(2, s.height))
        switch s.shape {
        case .circle: return (CGPath(ellipseIn: r, transform: nil), false)
        case .rectangle: return (CGPath(rect: r, transform: nil), false)
        case .custom:
            guard let sh = ShapeLibrary.shape(s.customID) else { return nil }
            let res = sh.path(in: r).resolved
            return (res.path, res.evenOdd)
        case .selection:
            guard let sel = base.selection else { return nil }
            return (LayoutGeom.regionPath(fromMask: sel), true)
        case .path:
            guard let pid = d.activePathID, let np = base.paths.first(where: { $0.id == pid }) else { return nil }
            let res = np.path.resolved
            return (res.path, res.evenOdd)
        case .canvas: return (CGPath(rect: base.canvasCGRect, transform: nil), false)
        }
    }

    static func packed(_ s: PackSettings, base: DocumentState, ids: [UUID], doc d: Document) -> (state: DocumentState, placed: Int, scale: CGFloat, outline: CGPath?) {
        let items = LayoutGeom.items(ids, base)
        guard items.count >= 1, let o = outline(s, doc: d, base: base) else { return (base, 0, 1, nil) }
        let res = pack(sizes: items.map(\.rect.size), in: o.path, evenOdd: o.evenOdd, mode: s.mode, padding: CGFloat(s.padding),
                       scaleToFit: s.scaleToFit, shuffle: s.shuffle, seed: s.seed)
        var st = base
        for (it, f) in zip(items, res.frames) {
            guard let f else { continue }
            LayoutGeom.place(&st, it.id, center: CGPoint(x: f.midX, y: f.midY), scale: res.scale)
        }
        return (st, res.placed, res.scale, o.path)
    }

    static func defaults(_ d: Document) -> PackSettings {
        var s = PackSettings()
        let rects = LayoutGeom.items(LayoutGeom.movable(d), d.state).map(\.rect)
        let canvas = d.state.canvasCGRect
        let u = LayoutGeom.union(rects) ?? canvas
        s.centerX = Double(u.midX.rounded()); s.centerY = Double(u.midY.rounded())
        let area = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        let side = min(Double(min(canvas.width, canvas.height)) * 0.9, max(80, Double(sqrt(area * 2.2))))
        s.width = side.rounded(); s.height = side.rounded()
        if d.state.selection != nil { s.shape = .selection }
        return s
    }
}

/// Layer ▸ Pack & Fill ▸ Pack into Shape…
struct PackDialog: View {
    @State private var s = PackSettings()
    @State private var session = LayoutPreviewSession()
    @State private var ready = false
    @State private var info = ""
    @State private var showGuide = true

    var body: some View {
        DialogFrame(title: "Pack into Shape", width: 340, onOK: { session.finish(apply: true, name: "Pack into \(s.shape.rawValue)") },
                    onCancel: { session.finish(apply: false, name: "") }) {
            if ready && session.ids.count < 2 {
                Text("Select two or more layers to pack.").foregroundStyle(Theme.textFaint)
            } else {
                Picker("Shape", selection: $s.shape) { ForEach(PackSettings.Shape.allCases) { Text(tr($0.rawValue)).tag($0) } }
                if s.shape == .custom { HStack { Text("Custom shape").foregroundStyle(Theme.textDim); ShapeLibraryPicker(id: $s.customID) } }
                if [.circle, .rectangle, .custom].contains(s.shape) {
                    ValueSlider(label: "Width", value: $s.width, range: 20...4000, unit: "px", labelWidth: 70)
                    ValueSlider(label: "Height", value: $s.height, range: 20...4000, unit: "px", labelWidth: 70)
                    HStack {
                        NumberField(label: "Centre X", value: $s.centerX, width: 54)
                        NumberField(label: "Y", value: $s.centerY, width: 54)
                        Button("Canvas centre") { if let b = session.base { s.centerX = Double(b.width) / 2; s.centerY = Double(b.height) / 2 } }.buttonStyle(PanelButtonStyle())
                    }
                }
                Picker("Treat layers as", selection: $s.mode) { ForEach(PackSettings.Mode.allCases) { Text(tr($0.rawValue)).tag($0) } }.pickerStyle(.segmented)
                ValueSlider(label: "Padding", value: $s.padding, range: 0...100, unit: "px", labelWidth: 70)
                Toggle2(label: "Scale layers to fill the shape", on: $s.scaleToFit)
                HStack {
                    Toggle2(label: "Shuffle", on: $s.shuffle)
                    if s.shuffle { Button("Again") { s.seed = Int.random(in: 1...9999) }.buttonStyle(PanelButtonStyle()) }
                    Spacer()
                    Toggle2(label: "Show guide", on: $showGuide)
                }
                if !info.isEmpty { Text(tr(info)).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            }
        }
        .onAppear {
            guard !ready, let d = AppActions.doc else { return }
            session.begin()
            s = Packing.defaults(d)
            ready = true
            update()
        }
        .onChange(of: s) { _, _ in update() }
        .onChange(of: showGuide) { _, _ in update() }
    }

    private func update() {
        guard ready, session.ids.count >= 2 else { return }
        var outline: CGPath?
        var text = ""
        session.preview { base, ids, d in
            let movable = ids.filter { base.layer($0).map { !$0.locks.positionLocked } ?? false }
            let r = Packing.packed(s, base: base, ids: movable, doc: d)
            outline = r.outline
            if r.outline == nil { text = s.shape == .selection ? "Make a selection first." : "Select a path in the Paths panel first." }
            else if r.placed < movable.count { text = "\(r.placed) of \(movable.count) layers fit — make the shape larger or turn on scaling." }
            else { text = "\(r.placed) layers" + (s.scaleToFit ? String(format: " at %.0f%%", r.scale * 100) : "") }
            return r.state
        }
        info = text
        ArrangeGuide.path = showGuide ? outline : nil
        AppActions.canvas?.overlay.needsDisplay = true
    }
}
