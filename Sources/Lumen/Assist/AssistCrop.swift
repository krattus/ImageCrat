import AppKit
import SwiftUI
import Vision
import Observation
import ImageCratCore

/// Image ▸ Suggest Crops…: for each aspect ratio, the best reframings of the image scored with attention saliency,
/// faces / people (never cut), subject boxes, rule-of-thirds placement and Vision's aesthetics score.
/// Crops are applied without deleting pixels, or turned into artboards / new documents.
enum AssistCrop {
    struct Ratio: Hashable, Identifiable {
        var w: Double
        var h: Double
        var label: String { "\(fmt(w)):\(fmt(h))" }
        var id: String { label }
        var value: Double { w / h }
        private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v) }
        static let standard = [Ratio(w: 1, h: 1), Ratio(w: 4, h: 5), Ratio(w: 9, h: 16), Ratio(w: 16, h: 9), Ratio(w: 3, h: 2)]
        /// "5:7", "2.35:1", "1.5" → ratio.
        static func parse(_ s: String) -> Ratio? {
            let parts = s.replacingOccurrences(of: "x", with: ":").replacingOccurrences(of: "/", with: ":").split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[0] > 0, parts[1] > 0 { return Ratio(w: parts[0], h: parts[1]) }
            if parts.count == 1, parts[0] > 0 { return Ratio(w: parts[0], h: 1) }
            return nil
        }
    }

    struct Candidate: Identifiable {
        let id = UUID()
        var ratio: Ratio
        var rect: CGRect            // image pixels, y-down
        var score: Double           // 0…100
        var aesthetics: Float?
        var notes: [String]
    }

    /// What the scorer knows about the image.
    struct Context {
        var width: Int
        var height: Int
        var grid: Int                       // importance grid is grid×grid
        var importance: [Double]            // sums to 1
        var integral: [Double]              // (grid+1)²
        var faces: [CGRect]                 // pixels
        var protected: [CGRect]             // faces expanded to head + shoulders, people
        var subjects: [CGRect]              // salient object boxes, pixels
        var tiltDegrees: Double?

        func sum(_ r: CGRect) -> Double {
            let g = Double(grid)
            let x0 = Int((Double(r.minX) / Double(width) * g).rounded()), x1 = Int((Double(r.maxX) / Double(width) * g).rounded())
            let y0 = Int((Double(r.minY) / Double(height) * g).rounded()), y1 = Int((Double(r.maxY) / Double(height) * g).rounded())
            let a = max(0, min(grid, x0)), b = max(0, min(grid, x1)), c = max(0, min(grid, y0)), d = max(0, min(grid, y1))
            guard b > a, d > c else { return 0 }
            let s = grid + 1
            return integral[d * s + b] - integral[c * s + b] - integral[d * s + a] + integral[c * s + a]
        }

        /// Importance-weighted centroid inside `r`, normalised to the rect.
        func centroid(_ r: CGRect) -> CGPoint? {
            let g = Double(grid)
            let x0 = max(0, Int(Double(r.minX) / Double(width) * g)), x1 = min(grid, Int((Double(r.maxX) / Double(width) * g).rounded(.up)))
            let y0 = max(0, Int(Double(r.minY) / Double(height) * g)), y1 = min(grid, Int((Double(r.maxY) / Double(height) * g).rounded(.up)))
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) { let v = importance[y * grid + x]; sx += v * (Double(x) + 0.5); sy += v * (Double(y) + 0.5); n += v } }
            guard n > 0 else { return nil }
            let px = sx / n / g * Double(width), py = sy / n / g * Double(height)
            return CGPoint(x: (px - Double(r.minX)) / Double(r.width), y: (py - Double(r.minY)) / Double(r.height))
        }
    }

    static func context(_ cg: CGImage) -> Context {
        let W = cg.width, H = cg.height
        let G = 64
        var imp = [Double](repeating: 0, count: G * G)
        var subjects: [CGRect] = []
        if let s = AssistVision.saliency(cg) {
            for y in 0..<G {
                for x in 0..<G {
                    let sx = min(s.w - 1, x * s.w / G), sy = min(s.h - 1, y * s.h / G)
                    imp[y * G + x] = Double(max(0, s.map[sy * s.w + sx]))
                }
            }
            subjects = s.boxes.map { CGRect(x: $0.minX * CGFloat(W), y: $0.minY * CGFloat(H), width: $0.width * CGFloat(W), height: $0.height * CGFloat(H)) }
        }
        var total = imp.reduce(0, +)
        if total <= 0 {
            // no saliency: gentle centre prior
            for y in 0..<G { for x in 0..<G { let dx = (Double(x) + 0.5) / Double(G) - 0.5, dy = (Double(y) + 0.5) / Double(G) - 0.5; imp[y * G + x] = exp(-(dx * dx + dy * dy) * 6) } }
            total = imp.reduce(0, +)
        }
        let faces = AssistVision.faces(cg).map(\.box)
        var protected: [CGRect] = faces.map { f in
            CGRect(x: f.minX - f.width * 0.35, y: f.minY - f.height * 0.55, width: f.width * 1.7, height: f.height * 2.0).intersection(CGRect(x: 0, y: 0, width: W, height: H))
        }
        let people = AssistVision.humans(cg)
        // faces and people attract attention even when the saliency map is elsewhere
        let boost = total * 0.6 / Double(max(1, protected.count + people.count))
        for r in protected + people {
            let x0 = max(0, Int(r.minX / CGFloat(W) * CGFloat(G))), x1 = min(G, Int((r.maxX / CGFloat(W) * CGFloat(G)).rounded(.up)))
            let y0 = max(0, Int(r.minY / CGFloat(H) * CGFloat(G))), y1 = min(G, Int((r.maxY / CGFloat(H) * CGFloat(G)).rounded(.up)))
            let cells = max(1, (x1 - x0) * (y1 - y0))
            for y in y0..<max(y0, y1) { for x in x0..<max(x0, x1) { imp[y * G + x] += boost / Double(cells) } }
        }
        protected += people.filter { p in !protected.contains { $0.intersects(p) } }
        total = imp.reduce(0, +)
        for i in imp.indices { imp[i] /= total }
        var integral = [Double](repeating: 0, count: (G + 1) * (G + 1))
        for y in 0..<G {
            var row = 0.0
            for x in 0..<G {
                row += imp[y * G + x]
                integral[(y + 1) * (G + 1) + x + 1] = integral[y * (G + 1) + x + 1] + row
            }
        }
        return Context(width: W, height: H, grid: G, importance: imp, integral: integral, faces: faces, protected: protected, subjects: subjects,
                       tiltDegrees: AssistVision.horizon(cg).map { $0 * 180 / .pi })
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        if i.isNull || i.isEmpty { return 0 }
        let ia = Double(i.width * i.height)
        return ia / (Double(a.width * a.height) + Double(b.width * b.height) - ia)
    }

    /// Scores one crop rectangle (0…1) with notes on why.
    static func score(_ r: CGRect, _ c: Context, relativeSize: Double) -> (Double, [String]) {
        var notes: [String] = []
        let inside = c.sum(r)
        // importance sitting on the crop border = something is being cut
        let bw = r.width * 0.06, bh = r.height * 0.06
        let inner = c.sum(r.insetBy(dx: bw, dy: bh))
        let borderFrac = inside > 0 ? (inside - inner) / inside : 0
        let expected = 1 - Double((r.width - 2 * bw) * (r.height - 2 * bh)) / Double(r.width * r.height)
        let cut = min(1, max(0, (borderFrac / max(1e-6, expected) - 0.8) / 1.6))
        // composition: weighted centroid near a thirds power point (or centred)
        var thirds = 0.5
        if let p = c.centroid(r) {
            let pts: [(CGPoint, Double)] = [(CGPoint(x: 1.0 / 3, y: 1.0 / 3), 1), (CGPoint(x: 2.0 / 3, y: 1.0 / 3), 1), (CGPoint(x: 1.0 / 3, y: 2.0 / 3), 1),
                                            (CGPoint(x: 2.0 / 3, y: 2.0 / 3), 1), (CGPoint(x: 0.5, y: 0.5), 1.15), (CGPoint(x: 0.5, y: 0.4), 1.05)]
            let d = pts.map { Double(p.distance(to: $0.0)) * $0.1 }.min() ?? 0.5
            thirds = exp(-(d / 0.17) * (d / 0.17))
        }
        // faces / people: fully inside or fully outside, never cut; keep headroom
        var faceTerm = 0.0, cutFaces = 0, keptFaces = 0
        for p in c.protected {
            let area = Double(p.width * p.height)
            guard area > 0 else { continue }
            let i = p.intersection(r)
            let f = (i.isNull || i.isEmpty) ? 0 : Double(i.width * i.height) / area
            if f >= 0.93 {
                keptFaces += 1; faceTerm += 1
                if p.minY - r.minY < r.height * 0.02 { faceTerm -= 0.25 }
            } else if f <= 0.05 { faceTerm += 0.1 } else { cutFaces += 1; faceTerm -= 1 }
        }
        if !c.protected.isEmpty { faceTerm /= Double(c.protected.count) }
        // salient objects should not be half in
        var subjectCut = 0.0
        for s in c.subjects {
            let area = Double(s.width * s.height)
            guard area > 0 else { continue }
            let i = s.intersection(r)
            let f = (i.isNull || i.isEmpty) ? 0 : Double(i.width * i.height) / area
            if f > 0.1 && f < 0.85 { subjectCut += (1 - abs(2 * f - 1)) }
        }
        subjectCut = min(1, subjectCut / Double(max(1, c.subjects.count)))

        var s: Double
        if c.protected.isEmpty {
            s = 0.55 * inside + 0.2 * thirds + 0.25 * relativeSize
        } else {
            s = 0.4 * inside + 0.15 * thirds + 0.17 * relativeSize + 0.28 * max(0, faceTerm)
            if cutFaces > 0 { s -= 0.45 }
        }
        s -= 0.22 * cut + 0.18 * subjectCut
        if inside > 0.85 { notes.append("keeps the subject") } else if inside > 0.6 { notes.append("keeps most of the subject") }
        if keptFaces > 0 { notes.append(keptFaces == 1 ? "face kept" : "\(keptFaces) faces kept") }
        if cutFaces > 0 { notes.append("cuts a face") }
        if thirds > 0.75 { notes.append("balanced") }
        if cut > 0.4 { notes.append("tight edge") }
        return (max(0, min(1, s)), notes)
    }

    /// Best crops for each ratio (`perRatio` distinct candidates, best first).
    static func suggest(_ cg: CGImage, ratios: [Ratio] = Ratio.standard, perRatio: Int = 3, context: Context? = nil, useAesthetics: Bool = true) async -> [Candidate] {
        let c = context ?? self.context(cg)
        let W = Double(c.width), H = Double(c.height)
        var out: [Candidate] = []
        for ratio in ratios {
            let rv = ratio.value
            let maxW = min(W, H * rv), maxH = maxW / rv
            var all: [(CGRect, Double, [String])] = []
            for scale in [1.0, 0.92, 0.84, 0.76, 0.68, 0.6, 0.52, 0.44] {
                let cw = maxW * scale, ch = maxH * scale
                if cw < 32 || ch < 32 { continue }
                let nx = max(1, Int(((W - cw) / (W / 28)).rounded(.up))), ny = max(1, Int(((H - ch) / (H / 28)).rounded(.up)))
                for iy in 0...ny {
                    for ix in 0...nx {
                        let x = nx == 0 ? 0 : (W - cw) * Double(ix) / Double(nx), y = ny == 0 ? 0 : (H - ch) * Double(iy) / Double(ny)
                        let r = CGRect(x: x, y: y, width: cw, height: ch)
                        let (s, notes) = score(r, c, relativeSize: scale * scale)
                        all.append((r, s, notes))
                    }
                }
            }
            all.sort { $0.1 > $1.1 }
            var picked: [(CGRect, Double, [String])] = []
            for cand in all {
                if picked.count >= perRatio { break }
                if picked.allSatisfy({ iou($0.0, cand.0) < 0.72 }) { picked.append(cand) }
            }
            for (r, s, notes) in picked {
                let ir = CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: min(CGFloat(c.width) - r.minX.rounded(), r.width.rounded()), height: min(CGFloat(c.height) - r.minY.rounded(), r.height.rounded()))
                var cand = Candidate(ratio: ratio, rect: ir, score: s * 100, aesthetics: nil, notes: notes)
                if useAesthetics, let crop = cg.cropping(to: ir) {
                    let small = NImg.fitted(crop, maxSide: 384)
                    if let a = await AssistVision.aesthetics(small) {
                        cand.aesthetics = a.score
                        cand.score = 0.82 * cand.score + 18 * Double((a.score + 1) / 2)
                    }
                }
                out.append(cand)
            }
        }
        // best first within each ratio, ratios in the requested order
        var ordered: [Candidate] = []
        for r in ratios { ordered += out.filter { $0.ratio == r }.sorted { $0.score > $1.score } }
        return ordered
    }

    // MARK: Applying

    private static func withActive<T>(_ d: Document, _ f: () -> T) -> T {
        let app = AppModel.shared
        let was = app.activeDocumentID
        if app.documents.contains(where: { $0.id == d.id }) { app.activeDocumentID = d.id }
        defer { if let w = was, app.documents.contains(where: { $0.id == w }) { app.activeDocumentID = w } }
        return f()
    }

    /// Non-destructive crop (pixels outside the frame are kept; Image ▸ Reveal All brings them back).
    static func apply(_ c: Candidate, to d: Document) {
        let r = IRect(x: Int(c.rect.minX), y: Int(c.rect.minY), width: Int(c.rect.width), height: Int(c.rect.height))
        if !AppModel.shared.documents.contains(where: { $0.id == d.id }) { AppModel.shared.add(d) }
        withActive(d) { AppActions.crop(to: r, deletePixels: false) }
        AppModel.shared.setStatus("Cropped to \(c.ratio.label) without deleting pixels (Image ▸ Reveal All restores the rest).")
    }

    /// Adds one artboard per candidate to the right of the canvas, each holding the reframed picture. One undo step.
    @discardableResult
    static func createArtboards(_ cands: [Candidate], in d: Document) -> [UUID] {
        guard !cands.isEmpty, let flat = Assist.compositeCG(d.state, background: nil) else { return [] }
        let gap: CGFloat = 80
        var x = CGFloat(d.state.width) + gap
        var rects: [CGRect] = []
        for c in cands { rects.append(CGRect(x: x, y: 0, width: c.rect.width, height: c.rect.height)); x += c.rect.width + gap }
        withActive(d) { AppActions.growCanvas(d, toInclude: rects.reduce(d.state.canvasCGRect) { $0.union($1) }) }
        var ids: [UUID] = []
        for (c, r) in zip(cands, rects) {
            guard let crop = flat.cropping(to: c.rect) else { continue }
            let pic = Layer.raster(name: "\(c.ratio.label) Reframe", buffer: PixelBuffer(cgImage: crop), origin: IPoint(x: Int(r.minX), y: Int(r.minY)))
            var ab = Layer(name: "\(c.ratio.label) — \(Int(r.width))×\(Int(r.height))", content: .group(GroupContent(children: [pic], isExpanded: true, artboard: Artboard(rect: r))))
            ab.blendMode = .normal
            d.state.layers.append(ab)
            ids.append(ab.id)
        }
        d.activeLayerID = ids.last; d.selectedLayerIDs = Set(ids)
        d.commit(ids.count == 1 ? "Reframe to Artboard" : "Reframe to \(ids.count) Artboards")
        Compositor.shared.clearCaches()
        AppActions.canvas?.fitOnScreen()
        return ids
    }

    /// Opens each candidate as its own document (layers intact, cropped without deleting pixels).
    @discardableResult
    static func newDocuments(_ cands: [Candidate], from d: Document) -> [Document] {
        var docs: [Document] = []
        for c in cands {
            let nd = Document(state: d.state, name: (d.name as NSString).deletingPathExtension + " – \(c.ratio.label.replacingOccurrences(of: ":", with: "x"))")
            AppModel.shared.add(nd)
            AppActions.crop(to: IRect(x: Int(c.rect.minX), y: Int(c.rect.minY), width: Int(c.rect.width), height: Int(c.rect.height)), deletePixels: false)
            docs.append(nd)
        }
        return docs
    }

    /// One click: level the horizon, then crop to the largest clean rectangle (pixels are kept).
    /// Returns the rotation in degrees, or nil when no tilt was found.
    @discardableResult
    static func autoStraightenAndCrop(_ d: Document, tiltDegrees: Double? = nil) -> Double? {
        var tilt = tiltDegrees
        if tilt == nil, let cg = Assist.compositeCG(d.state, maxSide: 1600) { tilt = AssistVision.horizon(cg).map { $0 * 180 / .pi } }
        guard let t = tilt, abs(t) >= 0.15, abs(t) <= 25 else { return nil }
        if !AppModel.shared.documents.contains(where: { $0.id == d.id }) { AppModel.shared.add(d) }
        withActive(d) {
            let old = AppModel.shared.crop.deleteCropped
            AppModel.shared.crop.deleteCropped = false
            StraightenCropTool.straighten(d, radians: CGFloat(-t * .pi / 180))
            AppModel.shared.crop.deleteCropped = old
        }
        return t
    }

    static func autoStraightenAction() {
        guard let d = AppActions.doc else { return }
        if let t = autoStraightenAndCrop(d) {
            AppModel.shared.setStatus(String(format: "Straightened %.1f° and cropped (pixels kept).", t))
        } else {
            AppModel.shared.setStatus("Auto-Straighten: no tilted horizon detected.")
            Beep.play()
        }
    }
}

// MARK: - Dialog

@Observable
final class AssistCropModel {
    var ratios: Set<String> = Set(AssistCrop.Ratio.standard.map(\.id))
    var custom = ""
    var candidates: [AssistCrop.Candidate] = []
    var selected: Set<UUID> = []
    var running = false
    var tilt: Double?
    var seconds = 0.0
    @ObservationIgnored var image: CGImage?
    @ObservationIgnored var context: AssistCrop.Context?
    @ObservationIgnored var thumbs: [UUID: CGImage] = [:]

    var activeRatios: [AssistCrop.Ratio] {
        var r = AssistCrop.Ratio.standard.filter { ratios.contains($0.id) }
        if let c = AssistCrop.Ratio.parse(custom), !r.contains(c) { r.append(c) }
        return r
    }

    func run() {
        guard let d = AppActions.doc else { return }
        if image == nil { image = Assist.compositeCG(d.state) }
        guard let cg = image else { return }
        running = true
        Task.detached(priority: .userInitiated) { await self.compute(cg) }
    }

    /// Analyses `cg` and publishes candidates + thumbnails.
    func compute(_ cg: CGImage) async {
        let (ratios, ctx) = await MainActor.run { (self.activeRatios, self.context) }
        let t0 = CFAbsoluteTimeGetCurrent()
        let c = ctx ?? AssistCrop.context(cg)
        let cands = await AssistCrop.suggest(cg, ratios: ratios, context: c)
        var made: [UUID: CGImage] = [:]
        for k in cands { if let crop = cg.cropping(to: k.rect) { made[k.id] = NImg.fitted(crop, maxSide: 220) } }
        let thumbs = made
        let dt = CFAbsoluteTimeGetCurrent() - t0
        await MainActor.run {
            self.image = cg
            self.context = c
            self.tilt = c.tiltDegrees
            self.thumbs = thumbs
            self.candidates = cands
            self.selected = cands.first.map { [$0.id] } ?? []
            self.seconds = dt
            self.running = false
        }
    }

    var chosen: [AssistCrop.Candidate] { candidates.filter { selected.contains($0.id) } }
}

struct AssistCropDialog: View {
    @State private var m: AssistCropModel
    /// `model`: a pre-computed model (tests); normally created and filled on appear.
    init(model: AssistCropModel = AssistCropModel()) { _m = State(initialValue: model) }

    var body: some View {
        DialogFrame(title: "Suggest Crops", width: 560, okTitle: "Apply Crop", onOK: {
            if let d = AppActions.doc, let c = m.chosen.first { AssistCrop.apply(c, to: d) }
        }, extraButtons: AnyView(HStack(spacing: 6) {
            Button("Artboards") { if let d = AppActions.doc { AssistCrop.createArtboards(m.chosen, in: d); AppModel.shared.dialog = nil } }
                .buttonStyle(PanelButtonStyle()).disabled(m.selected.isEmpty).help("Add the selected crops as artboards next to the image")
            Button("New Documents") { if let d = AppActions.doc { AssistCrop.newDocuments(m.chosen, from: d); AppModel.shared.dialog = nil } }
                .buttonStyle(PanelButtonStyle()).disabled(m.selected.isEmpty).help("Open each selected crop as its own version")
        })) {
            HStack(spacing: 6) {
                ForEach(AssistCrop.Ratio.standard) { r in
                    let on = m.ratios.contains(r.id)
                    Button(tr(r.label)) { if on { m.ratios.remove(r.id) } else { m.ratios.insert(r.id) }; m.run() }
                        .buttonStyle(.plain).font(Theme.font)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.accent.opacity(0.85) : Theme.fieldBG))
                        .foregroundStyle(on ? Color.white : Theme.text)
                }
                TextField("custom 5:7", text: $m.custom).textFieldStyle(.roundedBorder).font(Theme.font).frame(width: 90).onSubmit { m.run() }
                Spacer()
                if m.running { ProgressView().controlSize(.small) }
            }
            if let t = m.tilt, abs(t) >= 0.8 {
                HStack {
                    Image(systemName: "level").foregroundStyle(.orange)
                    Text(tr(String(format: "The horizon is tilted %.1f°.", abs(t)))).font(Theme.font)
                    Button("Straighten + Crop") {
                        if let d = AppActions.doc { AssistCrop.autoStraightenAndCrop(d, tiltDegrees: t); m.image = nil; m.context = nil; m.run() }
                    }.buttonStyle(PanelButtonStyle())
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(m.activeRatios) { r in
                        let list = m.candidates.filter { $0.ratio == r }
                        if !list.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Caption(r.label)
                                HStack(alignment: .top, spacing: 10) { ForEach(list) { c in cell(c) } }
                            }
                        }
                    }
                }
            }
            .frame(height: 360)
            Text(tr(m.candidates.isEmpty ? "Analysing saliency, faces and horizon…" :
                    String(format: "Click to choose, ⌘-click to choose several. Crops never delete pixels. (%.1f s)", m.seconds)))
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .onAppear { if m.candidates.isEmpty { m.run() } }
    }

    @ViewBuilder func cell(_ c: AssistCrop.Candidate) -> some View {
        let on = m.selected.contains(c.id)
        VStack(alignment: .leading, spacing: 2) {
            if let t = m.thumbs[c.id] {
                Image(decorative: t, scale: 2).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 150, maxHeight: 110)
                    .overlay(Rectangle().stroke(on ? Theme.accent : Theme.border, lineWidth: on ? 2 : 1))
            }
            HStack(spacing: 4) {
                Text("\(Int(c.score.rounded()))").font(Theme.fontBold).foregroundStyle(c.score > 70 ? Color.green : (c.score > 50 ? Color.orange : Theme.textDim))
                Text(tr(c.notes.prefix(2).joined(separator: ", "))).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Text("\(Int(c.rect.width))×\(Int(c.rect.height))").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .frame(width: 160, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) { if on { m.selected.remove(c.id) } else { m.selected.insert(c.id) } } else { m.selected = [c.id] }
        }
    }
}
