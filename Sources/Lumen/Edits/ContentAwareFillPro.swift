import SwiftUI
import CoreImage
import ImageCratCore

// MARK: - Content-Aware Fill workspace (Edit ▸ Content-Aware Fill…) and Delete and Fill Selection

enum CAFSampling: String, CaseIterable, Identifiable { case auto = "Auto", rectangular = "Rectangular", custom = "Custom"; var id: String { rawValue } }
enum CAFRotation: String, CaseIterable, Identifiable {
    case none = "None", low = "Low", medium = "Medium", high = "High", full = "Full"
    var id: String { rawValue }
    /// Extra source rotations (degrees) tried besides the unrotated source.
    var angles: [Double] {
        switch self {
        case .none: return []
        case .low: return [-10, 10]
        case .medium: return [-20, -10, 10, 20]
        case .high: return [-45, -30, -15, 15, 30, 45]
        case .full: return [-45, 45, 90, 180, 270]
        }
    }
}
enum CAFOutput: String, CaseIterable, Identifiable { case current = "Current Layer", newLayer = "New Layer", duplicate = "Duplicate Layer"; var id: String { rawValue } }
enum CAFColorAdaptation: Int, CaseIterable, Identifiable {
    case none, standard, high, veryHigh
    var id: Int { rawValue }
    var name: String { ["None", "Default", "High", "Very High"][rawValue] }
    /// Healing radius used to match low-frequency colour to the hole's surroundings.
    var radius: Double { [0, 6, 12, 24][rawValue] }
}

struct CAFSettings: Equatable {
    var sampling: CAFSampling = .auto
    var colorAdaptation: CAFColorAdaptation = .standard
    var rotation: CAFRotation = .none
    var scale = false
    var mirror = false
    var output: CAFOutput = .newLayer
    var sampleAllLayers = false
}

enum ContentAwareFillEngine {
    /// Binary hole (255 where the selection is > 10), grown by `grow` px.
    static func holeMask(_ sel: PixelBuffer, grow: Double = 2) -> PixelBuffer {
        let e = grow > 0 ? SelectionOps.expand(sel, by: grow) : sel
        let out = PixelBuffer(width: e.width, height: e.height, format: .gray)
        let a = e.data.assumingMemoryBound(to: UInt8.self), o = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<e.height { for x in 0..<e.width { o[y * out.bytesPerRow + x] = a[y * e.bytesPerRow + x] > 10 ? 255 : 0 } }
        out.markDirty()
        return out
    }

    static func count(_ m: PixelBuffer) -> Int {
        let a = m.data.assumingMemoryBound(to: UInt8.self)
        var n = 0
        for y in 0..<m.height { for x in 0..<m.width where a[y * m.bytesPerRow + x] > 127 { n += 1 } }
        return n
    }

    static func ringRadius(_ hole: PixelBuffer) -> Double {
        max(24, 1.6 * Double(count(hole)).squareRoot())
    }

    /// Auto: a ring around the hole, keeping only colours similar to the hole's border.
    static func autoSampling(hole: PixelBuffer, image: PixelBuffer) -> PixelBuffer {
        let R = ringRadius(hole)
        let inner = SelectionOps.expand(hole, by: 2)
        let ring = SelectionOps.combine(SelectionOps.expand(hole, by: R), inner, mode: .subtract)
        let border = SelectionOps.combine(SelectionOps.expand(hole, by: 8), inner, mode: .subtract)
        // border colour statistics
        var n = 0.0, s = SIMD3<Double>(repeating: 0), s2 = SIMD3<Double>(repeating: 0)
        let bp = border.data.assumingMemoryBound(to: UInt8.self)
        for y in stride(from: 0, to: image.height, by: 2) { for x in stride(from: 0, to: image.width, by: 2) where bp[y * border.bytesPerRow + x] > 127 {
            let (r, g, b, a) = image.pixel(x, y)
            if a < 128 { continue }
            let c = SIMD3(Double(r), Double(g), Double(b))
            n += 1; s += c; s2 += c * c
        } }
        guard n > 10 else { return ring }
        let mean = s / n
        let sd = (s2 / n - mean * mean)
        let std = SIMD3(max(18, sd.x.squareRoot()), max(18, sd.y.squareRoot()), max(18, sd.z.squareRoot()))
        let out = PixelBuffer(width: ring.width, height: ring.height, format: .gray)
        let rp = ring.data.assumingMemoryBound(to: UInt8.self), op = out.data.assumingMemoryBound(to: UInt8.self)
        var kept = 0, total = 0
        for y in 0..<ring.height { for x in 0..<ring.width where rp[y * ring.bytesPerRow + x] > 127 {
            total += 1
            let (r, g, b, _) = image.pixel(x, y)
            let d = (SIMD3(Double(r), Double(g), Double(b)) - mean) / std
            if (d * d).sum() < 3.5 * 3.5 * 3 { op[y * out.bytesPerRow + x] = 255; kept += 1 }
        } }
        out.markDirty()
        if Double(kept) < 0.35 * Double(total) { return ring }
        // close small gaps so patches fit
        return SelectionOps.contract(SelectionOps.expand(out, by: 3), by: 3)
    }

    /// Rectangular: the hole's bounding box grown by the ring radius, minus the hole.
    static func rectangularSampling(hole: PixelBuffer) -> PixelBuffer {
        guard let b = hole.opaqueBounds(threshold: 127) else { return PixelBuffer(width: hole.width, height: hole.height, format: .gray) }
        let R = Int(ringRadius(hole))
        let r = IRect(x: b.x - R, y: b.y - R, width: b.width + 2 * R, height: b.height + 2 * R)
        let m = SelectionOps.rectMask(r.cgRect, width: hole.width, height: hole.height)
        return SelectionOps.combine(m, SelectionOps.expand(hole, by: 2), mode: .subtract)
    }

    static func sampling(_ mode: CAFSampling, hole: PixelBuffer, image: PixelBuffer, custom: PixelBuffer?) -> PixelBuffer {
        switch mode {
        case .auto: return autoSampling(hole: hole, image: image)
        case .rectangular: return rectangularSampling(hole: hole)
        case .custom: return custom ?? autoSampling(hole: hole, image: image)
        }
    }

    /// Source transforms for rotation / scale / mirror adaptation (identity first).
    static func transforms(_ s: CAFSettings) -> [CGAffineTransform] {
        var t: [CGAffineTransform] = [.identity]
        for a in s.rotation.angles { t.append(CGAffineTransform(rotationAngle: CGFloat(a * .pi / 180))) }
        if s.scale { t += [CGAffineTransform(scaleX: 0.8, y: 0.8), CGAffineTransform(scaleX: 1.25, y: 1.25)] }
        if s.mirror {
            let m = CGAffineTransform(scaleX: -1, y: 1)
            t.append(m)
            if let a = s.rotation.angles.first { t.append(m.rotated(by: CGFloat(a * .pi / 180))) }
        }
        return t
    }

    /// Fills `hole` (binary, canvas size) of `image` from the `sampling` area. Returns a canvas-size RGBA buffer
    /// whose hole pixels are synthesized (other pixels equal `image`).
    static func fill(image: PixelBuffer, hole: PixelBuffer, sampling: PixelBuffer, settings s: CAFSettings,
                     progress: ((Double) -> Void)? = nil) -> PixelBuffer {
        let src = SelectionOps.combine(sampling, hole, mode: .subtract)
        let ts = transforms(s)
        var filled: PixelBuffer
        if ts.count <= 1 {
            filled = Inpainter.inpaint(image, hole: hole, sourceMask: src, progress: progress)
        } else {
            filled = augmentedInpaint(image: image, hole: hole, source: src, transforms: ts, progress: progress)
        }
        if s.colorAdaptation != .none {
            let sp = CanvasSpace(width: image.width, height: image.height)
            let adapted = colorAdapt(dest: image.ciImage, filled: filled.ciImage, hole: hole.ciImage, radius: s.colorAdaptation.radius, extent: sp.ciCanvas)
            let hb = RenderEngine.renderBuffer(adapted, docRect: IRect(x: 0, y: 0, width: image.width, height: image.height), space: sp)
            // keep original pixels outside the hole exactly
            let out = image.copy()
            out.context.saveGState()
            out.clip(toMask: hole.makeCGImage(), in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            out.context.setBlendMode(.copy)
            out.drawImage(hb.makeCGImage(), in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            out.context.restoreGState()
            out.markDirty()
            filled = out
        }
        return filled
    }

    /// Low-frequency colour correction of the synthesized pixels towards the hole's surroundings: the difference between
    /// the (normalized) blurred known surroundings and the blurred fill, faded out where no known pixels are within reach.
    static let adaptKernel = CIColorKernel(source: """
    kernel vec4 editsCafAdapt(__sample s, __sample bd, __sample bk, __sample bs, __sample hm) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float k = bk.r;
        vec3 D = k > 0.0001 ? bd.rgb / k : bs.rgb;
        vec3 corr = (D - bs.rgb) * smoothstep(0.03, 0.35, k);
        vec3 r = clamp(S + corr * hm.r, 0.0, 1.0);
        return vec4(r * s.a, s.a);
    }
    """)

    static func colorAdapt(dest: CIImage, filled: CIImage, hole: CIImage, radius: Double, extent: CGRect) -> CIImage {
        guard let k = adaptKernel else { return filled }
        let keep = hole.inverted().cropped(to: extent)
        let opaqueDest = dest.composited(over: CIImage.color(.black, extent))
        let destMasked = opaqueDest.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: keep])
        let bd = destMasked.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        let bk = keep.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        let bs = filled.composited(over: CIImage.color(.black, extent)).clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: extent)
        return k.apply(extent: extent, arguments: [filled.cropped(to: extent), bd, bk, bs, hole.cropped(to: extent)]) ?? filled
    }

    /// PatchMatch over an augmented image: the hole's context plus transformed (rotated / scaled / mirrored) copies of
    /// the sampling area laid out side by side, far enough from the hole that only they act as patch sources.
    static func augmentedInpaint(image: PixelBuffer, hole: PixelBuffer, source: PixelBuffer, transforms ts: [CGAffineTransform],
                                 progress: ((Double) -> Void)?) -> PixelBuffer {
        guard let hb = hole.opaqueBounds(threshold: 127) else { return image.copy() }
        let full = IRect(x: 0, y: 0, width: image.width, height: image.height)
        let m = Int(max(40, 1.5 * Double(max(hb.width, hb.height)))) + 12
        let C = IRect(x: hb.x - m, y: hb.y - m, width: hb.width + 2 * m, height: hb.height + 2 * m).intersection(full)
        guard var S = source.opaqueBounds(threshold: 127) else { return image.copy() }
        S = S.intersection(IRect(x: hb.x - 2 * m, y: hb.y - 2 * m, width: hb.width + 4 * m, height: hb.height + 4 * m))
        if S.isEmpty { return Inpainter.inpaint(image, hole: hole, sourceMask: source, progress: progress) }
        // Tile sizes
        let corners = [CGPoint(x: -S.width / 2, y: -S.height / 2), CGPoint(x: S.width / 2, y: -S.height / 2),
                       CGPoint(x: S.width / 2, y: S.height / 2), CGPoint(x: -S.width / 2, y: S.height / 2)]
        let sizes: [(Int, Int)] = ts.map { t in
            let b = CGRect.bounding(corners.map { $0.applying(t) })
            return (Int(b.width.rounded(.up)) + 4, Int(b.height.rounded(.up)) + 4)
        }
        let gap = 2 * m + 64, tileGap = 12
        let W = C.width + gap + sizes.map(\.0).reduce(0, +) + tileGap * ts.count
        let H = max(C.height, sizes.map(\.1).max() ?? 0)
        let work = PixelBuffer(width: W, height: H)
        let wHole = PixelBuffer(width: W, height: H, format: .gray)
        let wSrc = PixelBuffer(width: W, height: H, format: .gray)
        // context region (no sources here)
        work.copyPixels(from: image.cropped(to: C), at: .zero)
        wHole.copyPixels(from: hole.cropped(to: C), at: .zero)
        let sImg = image.cropped(to: S).makeCGImage()
        let sMask = source.cropped(to: S).makeCGImage()
        var x = C.width + gap
        for (t, sz) in zip(ts, sizes) {
            let center = CGPoint(x: CGFloat(x) + CGFloat(sz.0) / 2, y: CGFloat(sz.1) / 2)
            for (buf, img, interp) in [(work, sImg, CGInterpolationQuality.high), (wSrc, sMask, .none)] {
                let ctx = buf.context
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.concatenate(t)
                ctx.translateBy(x: -CGFloat(S.width) / 2, y: -CGFloat(S.height) / 2)
                buf.drawImage(img, in: CGRect(x: 0, y: 0, width: S.width, height: S.height), interpolation: interp)
                ctx.restoreGState()
            }
            x += sz.0 + tileGap
        }
        work.markDirty(); wHole.markDirty(); wSrc.markDirty()
        // Rotated tiles have antialiased mask edges: keep only solid source pixels.
        let sp = wSrc.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<H { for xx in 0..<W { let i = y * wSrc.bytesPerRow + xx; sp[i] = sp[i] > 200 ? 255 : 0 } }
        wSrc.markDirty()
        let res = Inpainter.inpaint(work, hole: wHole, sourceMask: wSrc, progress: progress)
        // copy the synthesized hole back
        let out = image.copy()
        let op = out.data.assumingMemoryBound(to: UInt8.self), rp = res.data.assumingMemoryBound(to: UInt8.self)
        let hp = hole.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<C.height { for xx in 0..<C.width {
            let gx = C.x + xx, gy = C.y + y
            guard hp[gy * hole.bytesPerRow + gx] > 127 else { continue }
            let o = op + gy * out.bytesPerRow + gx * 4, r = rp + y * res.bytesPerRow + xx * 4
            o[0] = r[0]; o[1] = r[1]; o[2] = r[2]; o[3] = r[3]
        } }
        out.markDirty()
        return out
    }

    // MARK: Commands

    /// Source pixels (canvas size): the active layer or all layers.
    static func sourceImage(_ d: Document, allLayers: Bool) -> PixelBuffer? {
        let sp = AppActions.space(d)
        let img: CIImage
        if allLayers { img = Compositor.shared.composite(d.committedState) }
        else if let l = d.activeLayer, let c = Compositor.shared.contentImage(l, space: sp) { img = c }
        else { return nil }
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp)
    }

    /// Writes a fill result into the document per the output setting. `filled` is canvas-size.
    static func commit(_ d: Document, filled: PixelBuffer, hole: PixelBuffer, output: CAFOutput, name: String) {
        guard let id = d.activeLayerID else { return }
        let soft = SelectionOps.feather(hole, radius: 1)
        let W = d.state.width, H = d.state.height
        switch output {
        case .newLayer:
            let b = PixelBuffer(width: W, height: H)
            b.context.saveGState()
            b.clip(toMask: soft.makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
            b.drawImage(filled.makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
            b.context.restoreGState()
            b.markDirty()
            d.addLayer(Layer.raster(name: d.nextLayerName("Content-Aware Fill"), buffer: b))
            d.state.selection = nil
            d.commit(name)
        case .current, .duplicate:
            var target = id
            if output == .duplicate, let l = d.state.layer(id) {
                let c = l.duplicated(newName: l.name + " copy")
                d.state.insertLayer(c, above: id)
                d.activeLayerID = c.id
                d.selectedLayerIDs = [c.id]
                target = c.id
            }
            guard let l = d.state.layer(target), l.isRaster, let (w, o) = d.beginPixelEdit(layerID: target, target: .content) else { return }
            w.context.saveGState()
            w.clip(toMask: soft.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: W, height: H))
            w.context.setBlendMode(.copy)
            w.drawImage(filled.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: W, height: H))
            w.context.restoreGState()
            w.markDirty()
            d.state.selection = nil
            d.commit(name)
        }
        d.setNeedsRender()
    }

    /// Edit ▸ Delete and Fill Selection: removes the selected content and fills it from its surroundings.
    static func deleteAndFill() {
        guard let d = AppActions.doc, let sel = d.state.selection, let l = d.activeLayer else { NSSound.beep(); return }
        if !l.isRaster { AppActions.offerRasterize(layer: l.id); return }
        guard let img = sourceImage(d, allLayers: false) else { return }
        AppModel.shared.setStatus("Filling…")
        let hole = holeMask(sel)
        // Sample from everywhere outside the hole (like Edit ▸ Fill ▸ Content-Aware).
        let everywhere = PixelBuffer(width: img.width, height: img.height, gray: 255)
        let filled = fill(image: img, hole: hole, sampling: everywhere, settings: CAFSettings(), progress: nil)
        commit(d, filled: filled, hole: hole, output: .current, name: "Delete and Fill Selection")
        AppModel.shared.setStatus("")
    }

    static func register() {
        MenuRegistry.add("Edit", "Delete and Fill Selection", key: .delete, modifiers: [.shift, .command],
                         enabled: { AppActions.doc?.state.selection != nil }) { deleteAndFill() }
        MenuRegistry.add("Edit", "Content-Aware Fill…", enabled: { AppActions.doc?.state.selection != nil }) {
            guard AppActions.doc?.state.selection != nil else { NSSound.beep(); return }
            DialogRegistry.show("edits.caf")
        }
        DialogRegistry.register("edits.caf") { AnyView(ContentAwareFillDialog()) }
    }
}

// MARK: - Workspace dialog

final class CAFModel: ObservableObject {
    let doc: Document
    let hole: PixelBuffer
    var image: PixelBuffer
    @Published var settings = CAFSettings()
    @Published var custom: PixelBuffer?
    @Published var sampling: PixelBuffer
    @Published var overlay: CGImage?
    @Published var result: CGImage?
    @Published var busy = false
    @Published var progress = 0.0
    @Published var showSampling = true
    @Published var overlayOpacity = 50.0
    @Published var brushSize = 60.0
    @Published var subtract = false
    let base: CGImage
    let holeOutline: CGPath
    private var generation = 0

    init?(doc: Document) {
        guard let sel = doc.state.selection, let img = ContentAwareFillEngine.sourceImage(doc, allLayers: false) else { return nil }
        self.doc = doc
        hole = ContentAwareFillEngine.holeMask(sel)
        image = img
        let sp = AppActions.space(doc)
        base = RenderEngine.cgImage(Compositor.shared.composite(doc.committedState).cropped(to: sp.ciCanvas), rect: sp.ciCanvas) ?? img.makeCGImage()
        holeOutline = SelectionOps.outline(hole)
        sampling = ContentAwareFillEngine.autoSampling(hole: hole, image: img)
        rebuildOverlay()
        recompute()
    }

    func updateSampling() {
        if settings.sampling == .custom, custom == nil { custom = sampling.copy() }
        sampling = ContentAwareFillEngine.sampling(settings.sampling, hole: hole, image: image, custom: custom)
        rebuildOverlay()
        recompute()
    }

    func reloadSource() {
        if let img = ContentAwareFillEngine.sourceImage(doc, allLayers: settings.sampleAllLayers) { image = img }
        recompute()
    }

    /// Paints the custom sampling area at doc point `p`.
    func paint(at p: CGPoint, from q: CGPoint?) {
        if settings.sampling != .custom { settings.sampling = .custom }
        if custom == nil { custom = sampling.copy() }
        guard let c = custom else { return }
        let ctx = c.context
        ctx.saveGState()
        ctx.setFillColor(gray: subtract ? 0 : 1, alpha: 1)
        ctx.setStrokeColor(gray: subtract ? 0 : 1, alpha: 1)
        ctx.setBlendMode(.copy)
        let r = CGFloat(brushSize / 2)
        if let q {
            ctx.setLineWidth(r * 2); ctx.setLineCap(.round)
            ctx.move(to: q); ctx.addLine(to: p); ctx.strokePath()
        }
        ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        ctx.restoreGState()
        c.markDirty()
        sampling = c
        rebuildOverlay()
    }

    func rebuildOverlay() {
        let W = image.width, H = image.height
        let s = min(1, 900 / Double(max(W, H)))
        let w = max(1, Int(Double(W) * s)), h = max(1, Int(Double(H) * s))
        let o = PixelBuffer(width: w, height: h)
        let ctx = o.context
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(s), y: CGFloat(s))
        o.clip(toMask: SelectionOps.combine(sampling, hole, mode: .subtract).makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setFillColor(RGBA(r: 0.1, g: 0.85, b: 0.25, a: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.restoreGState()
        o.markDirty()
        overlay = o.makeCGImage()
    }

    func recompute() {
        generation += 1
        let gen = generation
        let img = image.copy(), h = hole.copy(), smp = sampling.copy(), st = settings, baseImg = base
        busy = true; progress = 0
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = ContentAwareFillEngine.fill(image: img, hole: h, sampling: smp, settings: st) { p in
                DispatchQueue.main.async { if self?.generation == gen { self?.progress = p } }
            }
            // preview: result composited over the document image
            let prev = PixelBuffer(width: out.width, height: out.height)
            prev.drawImage(baseImg, in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
            prev.context.saveGState()
            prev.clip(toMask: h.makeCGImage(), in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
            prev.drawImage(out.makeCGImage(), in: CGRect(x: 0, y: 0, width: out.width, height: out.height))
            prev.context.restoreGState()
            prev.markDirty()
            let cg = prev.makeCGImage()
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.result = cg
                self.lastFilled = out
                self.busy = false
            }
        }
    }

    var lastFilled: PixelBuffer?

    func apply() {
        let st = settings
        let filled = lastFilled ?? ContentAwareFillEngine.fill(image: image, hole: hole, sampling: sampling, settings: st)
        ContentAwareFillEngine.commit(doc, filled: filled, hole: hole, output: st.output, name: "Content-Aware Fill")
    }
}

struct ContentAwareFillDialog: View {
    @StateObject private var m: CAFModelBox = CAFModelBox()

    var body: some View {
        if let model = m.model { ContentAwareFillWorkspace(m: model) } else {
            DialogFrame(title: "Content-Aware Fill", onOK: {}) { Text("Make a selection on a pixel layer first.") }
        }
    }
}

final class CAFModelBox: ObservableObject {
    let model: CAFModel?
    init() { model = AppActions.doc.flatMap { CAFModel(doc: $0) } }
}

struct ContentAwareFillWorkspace: View {
    @ObservedObject var m: CAFModel
    @State private var lastDoc: CGPoint?
    let frame = CGSize(width: 520, height: 400)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Content-Aware Fill").font(.system(size: 13, weight: .semibold))
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 4) {
                    IconButton(symbol: "paintbrush.pointed", help: "Sampling Brush: add to the sampling area", active: !m.subtract, size: 30) { m.subtract = false }
                    IconButton(symbol: "eraser", help: "Sampling Brush: subtract from the sampling area", active: m.subtract, size: 30) { m.subtract = true }
                }
                VStack(spacing: 4) {
                    samplingPane
                    Text("Sampling area (green) · paint to add, ⌥ or eraser to subtract").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
                VStack(spacing: 4) {
                    ZStack {
                        Color.black
                        if let r = m.result { Image(decorative: r, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit) }
                        if m.busy { ProgressView(value: m.progress).progressViewStyle(.linear).frame(width: 160).padding(6).background(Color.black.opacity(0.6)) }
                    }
                    .frame(width: 360, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("Preview").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                }
                settingsPanel.frame(width: 230)
            }
            HStack {
                Button("Reset") { m.settings = CAFSettings(); m.custom = nil; m.updateSampling() }.buttonStyle(PanelButtonStyle())
                Spacer()
                Button("Cancel") { AppModel.shared.dialog = nil }.buttonStyle(PanelButtonStyle()).keyboardShortcut(.cancelAction)
                Button("OK") { FieldEdits.commit(); AppModel.shared.dialog = nil; m.apply() }.buttonStyle(PanelButtonStyle(prominent: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    func fit() -> (CGFloat, CGPoint) {
        let W = CGFloat(m.image.width), H = CGFloat(m.image.height)
        let s = min(frame.width / W, frame.height / H)
        return (s, CGPoint(x: (frame.width - W * s) / 2, y: (frame.height - H * s) / 2))
    }

    var samplingPane: some View {
        let (s, o) = fit()
        return ZStack(alignment: .topLeading) {
            Color.black
            Canvas { ctx, _ in
                let r = CGRect(x: o.x, y: o.y, width: CGFloat(m.image.width) * s, height: CGFloat(m.image.height) * s)
                ctx.draw(Image(decorative: m.base, scale: 1), in: r)
                if m.showSampling, let ov = m.overlay {
                    ctx.opacity = m.overlayOpacity / 100
                    ctx.draw(Image(decorative: ov, scale: 1), in: r)
                    ctx.opacity = 1
                }
                var t = CGAffineTransform(translationX: o.x, y: o.y).scaledBy(x: s, y: s)
                if let p = m.holeOutline.copy(using: &t) {
                    ctx.stroke(Path(p), with: .color(.black), lineWidth: 2)
                    ctx.stroke(Path(p), with: .color(.white), style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let p = CGPoint(x: (v.location.x - o.x) / s, y: (v.location.y - o.y) / s)
            let sub = NSEvent.modifierFlags.contains(.option)
            let was = m.subtract
            if sub { m.subtract = true }
            m.paint(at: p, from: lastDoc)
            if sub { m.subtract = was }
            lastDoc = p
        }.onEnded { _ in lastDoc = nil; m.recompute() })
    }

    var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Caption("Sampling Area Options")
            Picker("", selection: Binding(get: { m.settings.sampling }, set: { m.settings.sampling = $0; m.updateSampling() })) {
                ForEach(CAFSampling.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Toggle2(label: "Show Sampling Area", on: $m.showSampling)
            ValueSlider(label: "Opacity", value: $m.overlayOpacity, range: 0...100, unit: "%", labelWidth: 60)
            ValueSlider(label: "Brush", value: $m.brushSize, range: 2...400, unit: " px", labelWidth: 60)
            Toggle2(label: "Sample All Layers", on: Binding(get: { m.settings.sampleAllLayers }, set: { m.settings.sampleAllLayers = $0; m.reloadSource() }))
            Divider()
            Caption("Fill Settings")
            Picker("Color Adaptation", selection: Binding(get: { m.settings.colorAdaptation }, set: { m.settings.colorAdaptation = $0; m.recompute() })) {
                ForEach(CAFColorAdaptation.allCases) { Text($0.name).tag($0) }
            }
            Picker("Rotation Adaptation", selection: Binding(get: { m.settings.rotation }, set: { m.settings.rotation = $0; m.recompute() })) {
                ForEach(CAFRotation.allCases) { Text($0.rawValue).tag($0) }
            }
            Toggle2(label: "Scale", on: Binding(get: { m.settings.scale }, set: { m.settings.scale = $0; m.recompute() }))
            Toggle2(label: "Mirror", on: Binding(get: { m.settings.mirror }, set: { m.settings.mirror = $0; m.recompute() }))
            Divider()
            Caption("Output Settings")
            Picker("Output To", selection: $m.settings.output) { ForEach(CAFOutput.allCases) { Text($0.rawValue).tag($0) } }
            Spacer()
        }
    }
}
