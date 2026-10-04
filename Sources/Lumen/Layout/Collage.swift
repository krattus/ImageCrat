import AppKit
import SwiftUI
import ImageCratCore

struct CollageSettings: Equatable {
    enum Style: String, CaseIterable, Identifiable {
        case justified = "Justified Rows", masonry = "Masonry", mosaic = "Mosaic"
        var id: String { rawValue }
    }
    enum Area: String, CaseIterable, Identifiable {
        case canvas = "Canvas", artboard = "Artboard", layers = "Area of the Layers"
        var id: String { rawValue }
    }
    var style: Style = .justified
    var area: Area = .canvas
    var gutter: Double = 12
    var margin: Double = 12
    var cornerRadius: Double = 0
    /// Masonry columns (0 = automatic).
    var columns = 0
    /// Never crop: cells keep each image's proportions (the grid may then not fill the whole area).
    var keepAspect = false
    var shuffle = false
    var seed = 1
}

/// Auto Collage: lays images out as a justified grid, masonry columns or a mosaic. Every cell is a frame
/// (a group clipped by a vector mask) so the picture inside can be moved or swapped later.
enum Collage {
    // MARK: Layout maths

    /// Cell rects for images with the given aspect ratios (width / height), in order.
    static func layout(aspects: [CGFloat], in area: CGRect, _ s: CollageSettings) -> [CGRect] {
        let a = aspects.map { max(0.05, min(20, $0)) }
        let r = area.insetBy(dx: CGFloat(s.margin), dy: CGFloat(s.margin))
        guard !a.isEmpty, r.width > 4, r.height > 4 else { return [] }
        let g = CGFloat(max(0, s.gutter))
        switch s.style {
        case .justified: return justified(a, r, g, keepAspect: s.keepAspect)
        case .masonry: return masonry(a, r, g, columns: s.columns, keepAspect: s.keepAspect)
        case .mosaic:
            var out = [CGRect](repeating: .zero, count: a.count)
            mosaic(Array(a.indices), a, r, g, &out)
            return out.map { $0.integral }
        }
    }

    /// Splits the sequence into `rows` contiguous runs with roughly equal aspect sums.
    static func partition(_ a: [CGFloat], rows: Int) -> [[Int]] {
        let total = a.reduce(0, +)
        var out: [[Int]] = []
        var acc: CGFloat = 0
        var cur: [Int] = []
        for (i, v) in a.enumerated() {
            let remainingItems = a.count - i, remainingRows = rows - out.count
            // close the row when its share is reached (or when the rest is needed to fill the remaining rows)
            if !cur.isEmpty, out.count < rows - 1,
               acc + v / 2 > total * CGFloat(out.count + 1) / CGFloat(rows) || remainingItems < remainingRows {
                out.append(cur); cur = []
            }
            cur.append(i)
            acc += v
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private static func justified(_ a: [CGFloat], _ r: CGRect, _ g: CGFloat, keepAspect: Bool) -> [CGRect] {
        // pick the row count whose natural height is closest to the area
        var best: (rows: [[Int]], heights: [CGFloat], total: CGFloat)?
        for n in 1...a.count {
            let rows = partition(a, rows: n)
            let heights = rows.map { row -> CGFloat in max(1, (r.width - g * CGFloat(row.count - 1)) / row.map { a[$0] }.reduce(0, +)) }
            let total = heights.reduce(0, +) + g * CGFloat(rows.count - 1)
            if best == nil || abs(log(total / r.height)) < abs(log(best!.total / r.height)) { best = (rows, heights, total) }
        }
        guard let b = best else { return [] }
        var out = [CGRect](repeating: .zero, count: a.count)
        if keepAspect {
            // true proportions: shrink uniformly when too tall, centre in the area
            let f = min(1, (r.height - g * CGFloat(b.rows.count - 1)) / max(1, b.heights.reduce(0, +)))
            let totalH = b.heights.reduce(0, +) * f + g * CGFloat(b.rows.count - 1)
            var y = r.minY + (r.height - totalH) / 2
            for (row, h0) in zip(b.rows, b.heights) {
                let h = h0 * f
                let w = row.map { a[$0] * h }.reduce(0, +) + g * CGFloat(row.count - 1)
                var x = r.minX + (r.width - w) / 2
                for i in row { out[i] = CGRect(x: x, y: y, width: a[i] * h, height: h); x += a[i] * h + g }
                y += h + g
            }
            return out.map { CGRect(x: $0.minX.rounded(), y: $0.minY.rounded(), width: $0.width.rounded(), height: $0.height.rounded()) }
        }
        // fill exactly: stretch the row heights to the area, cells crop their image
        let k = (r.height - g * CGFloat(b.rows.count - 1)) / max(1, b.heights.reduce(0, +))
        var y = r.minY
        for (ri, row) in b.rows.enumerated() {
            let bottom = ri == b.rows.count - 1 ? r.maxY : (y + b.heights[ri] * k).rounded()
            let sum = row.map { a[$0] }.reduce(0, +)
            let avail = r.width - g * CGFloat(row.count - 1)
            var x = r.minX
            for (ci, i) in row.enumerated() {
                let right = ci == row.count - 1 ? r.maxX : (x + avail * a[i] / sum).rounded()
                out[i] = CGRect(x: x, y: y, width: right - x, height: bottom - y)
                x = right + g
            }
            y = bottom + g
        }
        return out
    }

    private static func masonry(_ a: [CGFloat], _ r: CGRect, _ g: CGFloat, columns: Int, keepAspect: Bool) -> [CGRect] {
        // automatic column count: the one whose natural height is closest to the area
        func build(_ c: Int) -> (cols: [[Int]], heights: [[CGFloat]], cw: CGFloat, tallest: CGFloat) {
            let cw = max(1, (r.width - g * CGFloat(c - 1)) / CGFloat(c))
            var cols = [[Int]](repeating: [], count: c), hs = [[CGFloat]](repeating: [], count: c)
            var tops = [CGFloat](repeating: 0, count: c)
            for (i, v) in a.enumerated() {
                let k = tops.indices.min { tops[$0] < tops[$1] } ?? 0
                cols[k].append(i); hs[k].append(cw / v)
                tops[k] += cw / v + g
            }
            return (cols, hs, cw, (tops.max() ?? g) - g)
        }
        var c = min(a.count, max(0, columns))
        if c == 0 {
            var bestErr = CGFloat.infinity
            for n in 1...a.count {
                let t = build(n).tallest
                let err = abs(log(max(1, t) / r.height))
                if err < bestErr { bestErr = err; c = n }
            }
        }
        let b = build(max(1, c))
        var out = [CGRect](repeating: .zero, count: a.count)
        if keepAspect {
            let f = min(1, r.height / max(1, b.tallest))
            let cw = b.cw * f
            let totalW = cw * CGFloat(b.cols.count) + g * CGFloat(b.cols.count - 1)
            var x = r.minX + (r.width - totalW) / 2
            for (col, hs) in zip(b.cols, b.heights) {
                var y = r.minY + (r.height - min(r.height, b.tallest * f)) / 2
                for (i, h) in zip(col, hs) { out[i] = CGRect(x: x.rounded(), y: y.rounded(), width: cw.rounded(), height: (h * f).rounded()); y += h * f + g }
                x += cw + g
            }
            return out
        }
        var x = r.minX
        for (ci, (col, hs)) in zip(b.cols, b.heights).enumerated() {
            let right = ci == b.cols.count - 1 ? r.maxX : (x + b.cw).rounded()
            guard !col.isEmpty else { x = right + g; continue }
            let k = (r.height - g * CGFloat(col.count - 1)) / max(1, hs.reduce(0, +))
            var y = r.minY
            for (ri, (i, h)) in zip(col, hs).enumerated() {
                let bottom = ri == col.count - 1 ? r.maxY : (y + h * k).rounded()
                out[i] = CGRect(x: x, y: y, width: right - x, height: bottom - y)
                y = bottom + g
            }
            x = right + g
        }
        return out
    }

    /// Recursive split: halves the list and cuts the rect across its longer side, sized by what each half needs.
    private static func mosaic(_ idx: [Int], _ a: [CGFloat], _ r: CGRect, _ g: CGFloat, _ out: inout [CGRect]) {
        guard !idx.isEmpty else { return }
        if idx.count == 1 { out[idx[0]] = r; return }
        let half = (idx.count + 1) / 2
        let first = Array(idx[..<half]), second = Array(idx[half...])
        if r.width >= r.height {
            let wa = first.map { a[$0] }.reduce(0, +), wb = second.map { a[$0] }.reduce(0, +)
            let f = max(0.3, min(0.7, wa / (wa + wb)))
            let w = ((r.width - g) * f).rounded()
            mosaic(first, a, CGRect(x: r.minX, y: r.minY, width: w, height: r.height), g, &out)
            mosaic(second, a, CGRect(x: r.minX + w + g, y: r.minY, width: r.width - w - g, height: r.height), g, &out)
        } else {
            let ha = first.map { 1 / a[$0] }.reduce(0, +), hb = second.map { 1 / a[$0] }.reduce(0, +)
            let f = max(0.3, min(0.7, ha / (ha + hb)))
            let h = ((r.height - g) * f).rounded()
            mosaic(first, a, CGRect(x: r.minX, y: r.minY, width: r.width, height: h), g, &out)
            mosaic(second, a, CGRect(x: r.minX, y: r.minY + h + g, width: r.width, height: r.height - h - g), g, &out)
        }
    }

    // MARK: Document

    /// Layers that can go into a collage cell.
    static func sources(_ ids: [UUID], _ st: DocumentState) -> [UUID] {
        ids.filter { id in
            guard let l = st.layer(id), !l.isAdjustment, !l.isFill, !l.isArtboard, !l.locks.positionLocked else { return false }
            return Compositor.shared.contentBounds(l, state: st).map { $0.width > 1 && $0.height > 1 } ?? false
        }
    }

    /// A smart object layer for an image file that is not in the document yet.
    static func imageLayer(_ buf: PixelBuffer, name: String) -> Layer {
        let r = CGRect(x: 0, y: 0, width: buf.width, height: buf.height)
        return Layer(name: name, content: .smartObject(SmartObjectContent(source: .image(buf), quad: Quad(rect: r), sourceName: name)))
    }

    /// The layer scaled to cover `cell` (centred). Pixel layers become smart objects so they can be re-scaled losslessly later.
    static func fitted(_ layer: Layer, bounds b: CGRect, cell: CGRect, cover: Bool, space: CanvasSpace) -> Layer {
        var l = layer
        l.isClipped = false
        let k = cover ? max(cell.width / b.width, cell.height / b.height) : min(cell.width / b.width, cell.height / b.height)
        let target = CGRect(x: cell.midX - b.width * k / 2, y: cell.midY - b.height * k / 2, width: b.width * k, height: b.height * k)
        if let r = l.raster, l.mask == nil, let ob = r.buffer.opaqueBounds() {
            let so = SmartObjectContent(source: .image(r.buffer.cropped(to: ob)), quad: Quad(rect: target), sourceName: l.name)
            l.content = .smartObject(so)
            return l
        }
        if var so = l.smart, so.quad.isAffine, so.warp == nil, abs(so.quad.tl.y - so.quad.tr.y) < 0.01, abs(so.quad.tl.x - so.quad.bl.x) < 0.01,
           so.quad.tr.x > so.quad.tl.x, so.quad.bl.y > so.quad.tl.y {
            so.quad = Quad(rect: target)
            l.smart = so
            return l
        }
        return LayoutGeom.transformed(l, LayoutGeom.map(b, to: target), space: space, scaleEffects: Double(k))
    }

    struct Built {
        var state: DocumentState
        var group: UUID?
        var cells: [CGRect] = []
        var frames: [UUID] = []
    }

    /// Replaces the source layers (plus `extra` layers that are not in the document yet) by a "Collage" group of frames.
    /// `idMap` keeps the generated ids stable across live-preview rebuilds.
    static func build(_ s: CollageSettings, base: DocumentState, ids: [UUID], extra: [Layer] = [], area: CGRect, idMap: inout [UUID: UUID]) -> Built {
        var st = base
        let sp = CanvasSpace(width: base.width, height: base.height)
        var items: [(layer: Layer, bounds: CGRect, inDoc: Bool)] = []
        for id in sources(ids, base).reversed() {       // panel order: top layer first
            if let l = base.layer(id), let b = Compositor.shared.contentBounds(l, state: base) { items.append((l, b, true)) }
        }
        for l in extra { if let b = Compositor.shared.contentBounds(l, state: base) { items.append((l, b, false)) } }
        guard !items.isEmpty else { return Built(state: base) }
        if s.shuffle {
            var rng = SeededGenerator(seed: UInt64(max(1, s.seed)) &* 9176)
            items.shuffle(using: &rng)
        }
        let cells = layout(aspects: items.map { $0.bounds.width / $0.bounds.height }, in: area, s)
        guard cells.count == items.count else { return Built(state: base) }

        func stable(_ key: UUID) -> UUID {
            if let v = idMap[key] { return v }
            let v = UUID(); idMap[key] = v; return v
        }
        let groupKey = UUID(uuidString: "00000000-0000-0000-0000-00000000C011")!
        let groupID = stable(groupKey)

        // where the collage goes: at the topmost source layer (keeps it inside its artboard / group), else on top
        let docIDs = items.filter(\.inDoc).map(\.layer.id)
        let anchor = base.allLayers.map(\.id).last { docIDs.contains($0) }
        var placeholder = Layer(name: "Collage", content: .group(GroupContent()))
        placeholder.id = groupID
        if let a = anchor { st.insertLayer(placeholder, above: a) } else { st.layers.append(placeholder) }
        for id in docIDs { st.removeLayer(id) }

        var frames: [Layer] = []
        for (it, cell) in zip(items, cells) where cell.width >= 1 && cell.height >= 1 {
            let content = fitted(it.layer, bounds: it.bounds, cell: cell, cover: true, space: sp)
            var frame = Layer(name: it.layer.name, content: .group(GroupContent(children: [content], isExpanded: false)))
            frame.id = stable(it.layer.id)
            frame.vectorMask = VectorPath.rect(cell, radius: min(s.cornerRadius, Double(min(cell.width, cell.height)) / 2))
            frames.append(frame)
        }
        let kept = Set(frames.map(\.id))
        st.toolData.frames.removeAll { kept.contains($0.id) }
        st.toolData.frames += frames.map { FrameInfo(id: $0.id, ellipse: false) }
        st.updateLayer(groupID) { $0.children = frames.reversed() }     // first image on top, like the panel order it came from
        return Built(state: st, group: groupID, cells: cells, frames: frames.map(\.id))
    }

    /// The artboard that holds the active layer (or is active).
    static func activeArtboard(_ d: Document, _ st: DocumentState) -> Layer? {
        var id = d.activeLayerID
        while let i = id, let l = st.layer(i) {
            if l.isArtboard { return l }
            id = st.parentID(of: i)
        }
        return nil
    }

    static func areaRect(_ s: CollageSettings, base: DocumentState, ids: [UUID], doc d: Document) -> CGRect {
        switch s.area {
        case .canvas: return base.canvasCGRect
        case .artboard: return activeArtboard(d, base)?.artboard?.rect ?? base.canvasCGRect
        case .layers: return LayoutGeom.union(LayoutGeom.items(sources(ids, base), base).map(\.rect)) ?? base.canvasCGRect
        }
    }
}

/// Layer ▸ Pack & Fill ▸ Auto Collage…
struct CollageDialog: View {
    @State private var s = CollageSettings()
    @State private var session = LayoutPreviewSession()
    @State private var ready = false
    @State private var extra: [Layer] = []
    @State private var idMap: [UUID: UUID] = [:]
    @State private var count = 0
    @State private var hasArtboard = false

    var body: some View {
        DialogFrame(title: "Auto Collage", width: 340, okTitle: "Create", onOK: { finish(true) }, onCancel: { finish(false) }) {
            Picker("", selection: $s.style) { ForEach(CollageSettings.Style.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            Picker("Fill", selection: $s.area) {
                ForEach(CollageSettings.Area.allCases.filter { $0 != .artboard || hasArtboard }) { Text($0.rawValue).tag($0) }
            }
            ValueSlider(label: "Gutter", value: $s.gutter, range: 0...120, unit: "px", labelWidth: 84)
            ValueSlider(label: "Margin", value: $s.margin, range: 0...300, unit: "px", labelWidth: 84)
            ValueSlider(label: "Corner radius", value: $s.cornerRadius, range: 0...200, unit: "px", labelWidth: 84)
            if s.style == .masonry {
                ValueSlider(label: "Columns", value: Binding(get: { Double(s.columns) }, set: { s.columns = Int($0) }), range: 0...12, step: 1, labelWidth: 84)
                if s.columns == 0 { Text("0 = choose automatically").font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
            }
            if s.style != .mosaic { Toggle2(label: "Keep proportions (never crop)", on: $s.keepAspect) }
            HStack {
                Toggle2(label: "Shuffle", on: $s.shuffle)
                if s.shuffle { Button("Again") { s.seed = Int.random(in: 1...9999) }.buttonStyle(PanelButtonStyle()) }
                Spacer()
                Button("Add Images…") { chooseFiles() }.buttonStyle(PanelButtonStyle())
            }
            Text(count == 0 ? "Select image layers, or add image files." : "\(count) image\(count == 1 ? "" : "s") · each cell is a frame: select the picture inside to move or scale it.")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            guard !ready, let d = AppActions.doc else { return }
            session.begin()
            hasArtboard = Collage.activeArtboard(d, d.state) != nil
            if hasArtboard { s.area = .artboard }
            ready = true
            update()
        }
        .onChange(of: s) { _, _ in update() }
    }

    private func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.image]
        p.prompt = "Add"
        guard p.runModal() == .OK else { return }
        for u in p.urls {
            guard let (cg, _) = DocumentIO.loadImage(url: u) else { continue }
            extra.append(Collage.imageLayer(PixelBuffer(cgImage: cg), name: u.deletingPathExtension().lastPathComponent))
        }
        update()
    }

    private func update() {
        guard ready else { return }
        var n = 0
        var group: UUID?
        session.preview { base, ids, d in
            let b = Collage.build(s, base: base, ids: ids, extra: extra, area: Collage.areaRect(s, base: base, ids: ids, doc: d), idMap: &idMap)
            n = b.frames.count
            group = b.group
            return b.state
        }
        count = n
        if let g = group, let d = AppActions.doc { d.activeLayerID = g; d.selectedLayerIDs = [g] }
    }

    private func finish(_ apply: Bool) {
        session.finish(apply: apply && count > 0, name: "Auto Collage")
    }
}
