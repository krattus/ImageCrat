import AppKit
import CoreImage
import ImageIO
import ImageCratCore

/// Photomerge, Auto-Align / Auto-Blend Layers, Load Files into Stack (document-level glue).
enum MergeActions {
    // MARK: Sources

    static func source(url: URL) -> PanoSource? {
        guard let d = try? DocumentIO.load(url: url) else { return nil }
        return source(state: d.state, name: url.deletingPathExtension().lastPathComponent)
    }

    static func source(state st: DocumentState, name: String) -> PanoSource {
        let sp = CanvasSpace(width: st.width, height: st.height)
        let img = ImagingDisplay.inks(Compositor.shared.composite(st), state: st).cropped(to: sp.ciCanvas)
        if let cg = RenderEngine.readbackContext.createCGImage(img, from: sp.ciCanvas, format: .RGBA8, colorSpace: sRGBSpace) {
            return PanoSource(name: name, image: CIImage(cgImage: cg))
        }
        return PanoSource(name: name, image: img)
    }

    /// Output CI image rendered into a raster layer cropped to its content (with an optional mask).
    static func rasterLayer(name: String, image: CIImage, mask: CIImage?, W: Int, H: Int) -> Layer? {
        let sp = CanvasSpace(width: W, height: H)
        var ext = image.extent.intersection(sp.ciCanvas)
        if ext.isInfinite { ext = sp.ciCanvas }
        ext = ext.integral
        guard !ext.isEmpty else { return nil }
        let docRect = IRect(x: Int(ext.minX), y: H - Int(ext.maxY), width: Int(ext.width), height: Int(ext.height))
        let buf = RenderEngine.renderBuffer(image, docRect: docRect, space: sp)
        var l = Layer.raster(name: name, buffer: buf, origin: docRect.origin)
        if let m = mask {
            let mb = RenderEngine.renderBuffer(m, docRect: docRect, space: sp, format: .gray)
            l.mask = LayerMask(buffer: mb, origin: docRect.origin, outsideValue: 0)
        }
        return l
    }

    // MARK: Photomerge

    static func panoramaState(_ r: PanoResult, options o: PanoOptions, resolution: Double) -> DocumentState {
        var st = DocumentState(width: r.width, height: r.height, resolution: resolution)
        let sp = CanvasSpace(width: r.width, height: r.height)
        if o.asLayers {
            st.layers = r.layers.compactMap { rasterLayer(name: $0.name, image: $0.image, mask: $0.mask, W: r.width, H: r.height) }
        } else {
            st.layers = [Layer.raster(name: "Panorama", buffer: RenderEngine.renderBuffer(r.blended, docRect: st.canvasRect, space: sp))]
        }
        if o.contentAwareFill {
            let flat = RenderEngine.renderBuffer(r.blended, docRect: st.canvasRect, space: sp)
            let filled = fillTransparent(flat)
            let l = Layer.raster(name: o.asLayers ? "Content-Aware Fill" : "Panorama", buffer: filled)
            if o.asLayers { st.layers.append(l) } else { st.layers = [l] }
        }
        return st
    }

    /// Content-Aware Fill of transparent areas (PatchMatch inpainting of the empty borders).
    static func fillTransparent(_ buf: PixelBuffer) -> PixelBuffer {
        let hole = PixelBuffer(width: buf.width, height: buf.height, format: .gray)
        let src = buf.data.assumingMemoryBound(to: UInt8.self), dst = hole.data.assumingMemoryBound(to: UInt8.self)
        var any = false
        for y in 0..<buf.height {
            for x in 0..<buf.width where src[y * buf.bytesPerRow + x * 4 + 3] < 250 {
                dst[y * hole.bytesPerRow + x] = 255; any = true
            }
        }
        hole.markDirty()
        guard any else { return buf }
        // grow the hole by a pixel so half-transparent seams are replaced too
        let grown = RenderEngine.renderBuffer(hole.ciImage.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: 1.5]).cropped(to: CGRect(x: 0, y: 0, width: buf.width, height: buf.height)),
                                              docRect: buf.bounds, space: CanvasSpace(width: buf.width, height: buf.height), format: .gray)
        let out = Inpainter.inpaint(buf, hole: grown)
        // force opaque
        let p = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<out.height { for x in 0..<out.width { p[y * out.bytesPerRow + x * 4 + 3] = 255 } }
        out.markDirty()
        return out
    }

    static func photomerge(_ sources: [PanoSource], options o: PanoOptions, resolution: Double = 72) {
        let app = AppModel.shared
        app.setStatus("Photomerge: aligning \(sources.count) images…")
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Panorama.build(sources, options: o) { msg in DispatchQueue.main.async { app.setStatus("Photomerge: " + msg) } }
            let st = r.map { panoramaState($0, options: o, resolution: resolution) }
            DispatchQueue.main.async {
                guard let st else { AppActions.alert("Photomerge failed.", "The images could not be aligned — make sure they overlap by at least 25–40 %."); app.setStatus(""); return }
                let d = Document(state: st, name: "Untitled_Panorama")
                app.add(d)
                app.setStatus("Photomerge: \(r?.layout.rawValue ?? "") panorama \(st.width)×\(st.height)")
            }
        }
    }

    // MARK: Auto-Align Layers

    /// Canvas-size content image of a layer (with its mask / effects / opacity).
    static func layerImage(_ l: Layer, _ st: DocumentState) -> CIImage {
        let sp = CanvasSpace(width: st.width, height: st.height)
        var ll = l; ll.isClipped = false; ll.blendMode = ll.isGroup ? .passThrough : .normal
        return Compositor.shared.composite(layers: [ll], backdrop: CIImage.clearImage.cropped(to: sp.ciCanvas), space: sp, options: .init()).cropped(to: sp.ciCanvas)
    }

    /// Aligns the selected layers to a reference (the most connected one). Returns false when alignment failed.
    @discardableResult
    static func autoAlign(_ d: Document, ids: [UUID], layout: PanoLayout, vignette: Bool, distortion: Bool, commit: Bool = true) -> Bool {
        let st = d.state
        let layers = ids.compactMap { st.layer($0) }.filter { !$0.isAdjustment }
        guard layers.count >= 2 else { return false }
        let sp = CanvasSpace(width: st.width, height: st.height)
        let sources = layers.map { PanoSource(name: $0.name, image: materialize(layerImage($0, st), sp.ciCanvas)) }
        let sets = sources.map { Registration.prepare($0.image, maxSide: 1000, upright: layout != .collage) }
        var align = Registration.alignAll(sets, model: layout.model)
        var k1 = 0.0
        if distortion, layout.model == .homography {
            k1 = Panorama.estimateDistortion(align, sources: sources)
            if abs(k1) > 1e-4 { align = Panorama.refit(align, sources: sources, k1: k1) }
        }
        let ref = align.reference
        var proj = PanoProjection()
        proj.cx = Double(st.width - 1) / 2; proj.cy = Double(st.height - 1) / 2
        proj.f = Double(max(st.width, st.height))
        switch layout {
        case .cylindrical: proj.type = 1; proj.x0 = -proj.cx; proj.y0 = -proj.cy
        case .spherical: proj.type = 2; proj.x0 = -proj.cx; proj.y0 = -proj.cy
        default: proj.type = 0
        }
        var imgs: [PanoImage] = []
        for (i, s) in sources.enumerated() {
            guard let H = align.H[i], let Hi = H.inverted else { imgs.append(PanoImage(source: s, H: .identity, Hinv: .identity)); continue }
            imgs.append(PanoImage(source: s, H: H, Hinv: Registration.normalized(Hi), k1: k1))
        }
        if vignette {
            let grid = PanoGrid(imgs, proj: proj, W: st.width, H: st.height)
            let v = grid.estimateVignette()
            for i in imgs.indices { imgs[i].vignette = v }
        }
        var newState = st
        var aligned = 0
        for (i, l) in layers.enumerated() {
            if i == ref && proj.type == 0 && k1 == 0 && imgs[i].vignette == 0 { continue }
            guard align.H[i] != nil else { continue }
            // warp over a generous output rect so content moved off-canvas is kept
            let margin = max(st.width, st.height) / 2
            var p2 = proj
            p2.x0 -= Double(margin); p2.y0 -= Double(margin)
            let W2 = st.width + 2 * margin, H2 = st.height + 2 * margin
            imgs[i].bounds = Panorama.outputBounds(imgs[i], p2, W: W2, H: H2)
            let warped = Panorama.warp(imgs[i], proj: p2, outW: W2, outH: H2)
            guard var nl = rasterLayer(name: l.name, image: warped, mask: nil, W: W2, H: H2) else { continue }
            if var r = nl.raster { r.origin = IPoint(x: r.origin.x - margin, y: r.origin.y - margin); nl.raster = r }
            newState.updateLayer(l.id) { layer in
                layer.content = nl.content
                layer.mask = nil
                layer.effects = LayerEffects()
                layer.opacity = l.opacity
            }
            aligned += 1
        }
        let connected = align.H.compactMap { $0 }.count
        d.state = newState
        if commit { d.commit("Auto-Align Layers") }
        Compositor.shared.clearCaches()
        d.setNeedsRender()
        print("auto-align: reference \(layers[ref].name), \(connected)/\(layers.count) connected; " + align.pairs.map { "\($0.0)→\($0.1) \($0.2.method) \($0.2.inliers)" }.joined(separator: ", "))
        return connected == layers.count
    }

    static func materialize(_ img: CIImage, _ r: CGRect) -> CIImage {
        if let cg = RenderEngine.readbackContext.createCGImage(img, from: r, format: .RGBA8, colorSpace: sRGBSpace) { return CIImage(cgImage: cg).translated(r.minX, r.minY) }
        return img
    }

    // MARK: Auto-Blend Layers

    enum BlendMethod: String, CaseIterable, Identifiable { case panorama = "Panorama", stack = "Stack Images"; var id: String { rawValue } }

    /// Panorama: seam masks + exposure-balanced multi-band blend. Stack Images: focus stacking by per-pixel sharpness.
    static func autoBlend(_ d: Document, ids: [UUID], method: BlendMethod, seamless: Bool, commit: Bool = true) {
        let st = d.state
        let layers = ids.compactMap { st.layer($0) }.filter { !$0.isAdjustment }
        guard layers.count >= 2 else { return }
        let sp = CanvasSpace(width: st.width, height: st.height)
        let rect = sp.ciCanvas
        var images = layers.map { materialize(layerImage($0, st), rect) }
        var masks: [CIImage]
        if method == .stack {
            masks = FocusStack.masks(images, rect: rect)
        } else {
            // treat layers as already aligned: identity projection over the canvas
            var imgs = images.enumerated().map { PanoImage(source: PanoSource(name: layers[$0.offset].name, image: $0.element), H: .identity, Hinv: .identity) }
            let proj = PanoProjection()
            let grid = PanoGrid(imgs, proj: proj, W: st.width, H: st.height)
            if seamless {
                let g = grid.gains(vignette: 0)
                for i in imgs.indices { imgs[i].gain = g[i] }
                images = imgs.map { Panorama.warp($0, proj: proj, outW: st.width, outH: st.height) }
            }
            let labels = grid.seamLabels()
            masks = images.indices.map { grid.maskImage(labels, index: $0, W: st.width, H: st.height) }
        }
        let foot = images.reduce(CIImage.color(.black, rect)) { acc, im in
            im.alphaAsGray.composited(over: CIImage.clearImage.cropped(to: rect)).applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: acc]).cropped(to: rect)
        }
        var blended: CIImage? = nil
        if seamless {
            blended = (method == .stack ? FocusStack.fuse(images, rect: rect) : MultiBand.blend(images: images, masks: masks, rect: rect)).masked(byGray: foot)
        }
        let hardMasks = partition(masks, images: images, rect: rect)
        var newState = st
        for (i, l) in layers.enumerated() {
            let hard = hardMasks[i]
            let content = blended.map { $0.mixed(with: images[i], mask: hard) } ?? images[i]
            let buf = RenderEngine.renderBuffer(content.cropped(to: rect), docRect: st.canvasRect, space: sp)
            let mb = RenderEngine.renderBuffer(hard, docRect: st.canvasRect, space: sp, format: .gray)
            newState.updateLayer(l.id) { layer in
                layer.content = .raster(RasterContent(buffer: buf, origin: .zero))
                layer.effects = LayerEffects()
                layer.mask = LayerMask(buffer: mb, origin: .zero, outsideValue: 0)
            }
        }
        d.state = newState
        if commit { d.commit("Auto-Blend Layers") }
        Compositor.shared.clearCaches()
        d.setNeedsRender()
    }

    /// Hard (0/1) masks that exactly partition the covered area: masks above the first are thresholded,
    /// the first one takes whatever the others leave inside its footprint (no gaps, no double coverage).
    static func partition(_ soft: [CIImage], images: [CIImage], rect: CGRect) -> [CIImage] {
        var hard = soft.map { $0.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5]).cropped(to: rect) }
        guard hard.count > 1 else { return hard }
        // top-most wins where thresholded masks overlap
        var taken = CIImage.color(.black, rect)
        for i in stride(from: hard.count - 1, through: 1, by: -1) {
            let foot = images[i].alphaAsGray.composited(over: CIImage.color(.black, rect)).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
            let m = hard[i].applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: foot])
                .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: taken.inverted()]).cropped(to: rect)
            hard[i] = m
            taken = m.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: taken]).cropped(to: rect)
        }
        let foot0 = images[0].alphaAsGray.composited(over: CIImage.color(.black, rect)).applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
        hard[0] = taken.inverted().applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: foot0]).cropped(to: rect)
        return hard
    }

    // MARK: Load Files into Stack

    static func loadStack(_ sources: [PanoSource], align: Bool, smartObject: Bool, name: String = "Stack") -> Document? {
        guard !sources.isEmpty else { return nil }
        let W = sources.map(\.w).max()!, H = sources.map(\.h).max()!
        var st = DocumentState(width: W, height: H)
        let sp = CanvasSpace(width: W, height: H)
        st.layers = sources.map { s in
            let buf = RenderEngine.renderBuffer(s.image.translated(0, CGFloat(H - s.h)), docRect: IRect(x: 0, y: 0, width: s.w, height: s.h), space: sp)
            return Layer.raster(name: s.name, buffer: buf)
        }
        let d = Document(state: st, name: name)
        if align && sources.count > 1 { autoAlign(d, ids: d.state.layers.map(\.id), layout: .auto, vignette: false, distortion: false, commit: false) }
        if smartObject {
            var inner = d.state
            inner.layers = d.state.layers
            let so = SmartObjectContent(source: .document(inner), quad: Quad(rect: CGRect(x: 0, y: 0, width: W, height: H)), sourceName: name)
            d.state.layers = [Layer(name: name, content: .smartObject(so))]
        }
        d.activeLayerID = d.state.layers.last?.id
        d.selectedLayerIDs = Set(d.state.layers.map(\.id))
        d.commit("Load Layers")
        return d
    }
}

// MARK: - Focus stacking

enum FocusStack {
    static let energyKernel = CIColorKernel(source: """
    kernel vec4 lumenEnergy(__sample l, __sample s) {
        float e = s.a > 0.5 ? l.r * l.r * 40.0 : 0.0;
        return vec4(e, e, e, 1.0);
    }
    """)

    static let selectKernel = CIColorKernel(source: """
    kernel vec4 lumenFocusSelect(__sample bl, __sample be, __sample l, __sample e) {
        return e.r >= be.r ? l : bl;
    }
    """)
    static let absEnergyKernel = CIColorKernel(source: "kernel vec4 lumenLapEnergy(__sample l) { float v = dot(abs(l.rgb), vec3(0.333)); return vec4(v, v, v, 1.0); }")

    /// Laplacian-pyramid focus fusion: per level, the coefficient of the image with the largest local band energy.
    static func fuse(_ images: [CIImage], rect r0: CGRect) -> CIImage {
        guard let lapK = MultiBand.lapKernel, let selK = selectKernel, let eK = absEnergyKernel, let wK = MultiBand.wKernel, !images.isEmpty else { return images.first ?? .clearImage }
        let L = max(1, min(6, Int(log2(Double(min(r0.width, r0.height)) / 12))))
        var bestL = (0...L).map { CIImage.color(.black, MultiBand.rect(r0, $0)) }
        var bestE = (0...L).map { CIImage.color(RGBA(gray: 0, a: 1), MultiBand.rect(r0, $0)).applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -1, y: -1, z: -1, w: 0)]) }
        var top = CIImage.color(.black, MultiBand.rect(r0, L))
        for img in images {
            let F = MultiBand.extend(img, r0)
            var G = [F]
            for k in 1...L { G.append(MultiBand.materialize(MultiBand.down(G[k - 1], MultiBand.rect(r0, k)))) }
            for k in 0..<L {
                let rk = MultiBand.rect(r0, k)
                let lap = lapK.apply(extent: rk, arguments: [G[k], MultiBand.up(G[k + 1], rk)]) ?? G[k]
                let e = (eK.apply(extent: rk, arguments: [lap]) ?? lap).clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: rk)
                bestL[k] = selK.apply(extent: rk, arguments: [bestL[k], bestE[k], lap, e]) ?? bestL[k]
                bestE[k] = e.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: bestE[k]]).cropped(to: rk)
                bestL[k] = MultiBand.materialize(bestL[k]); bestE[k] = MultiBand.materialize(bestE[k])
            }
            let rL = MultiBand.rect(r0, L)
            top = MultiBand.materialize(MultiBand.accKernel?.apply(extent: rL, arguments: [top, G[L], CIImage.color(RGBA(gray: 1 / Double(images.count)), rL)]) ?? top)
        }
        bestL[L] = top
        let ones = (0...L).map { k -> CIImage in
            let rk = MultiBand.rect(r0, k)
            return wK.apply(extent: rk, arguments: [CIImage.color(.black, rk), CIImage.color(.white, rk)]) ?? CIImage.color(.white, rk)
        }
        return MultiBand.collapse(bestL, ones, r0)
    }

    /// Soft per-layer masks selecting the sharpest layer per pixel (Laplacian energy, smoothed).
    static func masks(_ images: [CIImage], rect: CGRect) -> [CIImage] {
        let w = Int(rect.width), h = Int(rect.height)
        let sc = min(1.0, 900.0 / Double(max(w, h)))
        let sw = max(4, Int(Double(w) * sc)), sh = max(4, Int(Double(h) * sc))
        let small = CGRect(x: 0, y: 0, width: sw, height: sh)
        var energies: [[Float]] = []
        for img in images {
            let gray = AdjustmentEngine.apply(AdjustmentSettings(kind: .desaturate), to: img.composited(over: CIImage.color(RGBA(gray: 0.5), rect)))
            let lap = gray.clampedToExtent().applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: [0, 1, 0, 1, -4, 1, 0, 1, 0], count: 9), "inputBias": 0.5]).cropped(to: rect)
            let centred = lap.applyingFilter("CIColorMatrix", parameters: ["inputBiasVector": CIVector(x: -0.5, y: -0.5, z: -0.5, w: 0)])
            var e = energyKernel?.apply(extent: rect, arguments: [centred, img.composited(over: CIImage.clearImage.cropped(to: rect))]) ?? centred
            e = e.clampedToExtent().applyingGaussianBlur(sigma: max(4, Double(max(w, h)) / 90)).cropped(to: rect)
            let es = e.transformed(by: CGAffineTransform(scaleX: CGFloat(sw) / rect.width, y: CGFloat(sh) / rect.height), highQualityDownsample: true)
            var f = [Float](repeating: 0, count: sw * sh * 4)
            RenderEngine.readbackContext.render(es, toBitmap: &f, rowBytes: sw * 16, bounds: small, format: .RGBAf, colorSpace: nil)
            energies.append(stride(from: 0, to: f.count, by: 4).map { f[$0] })
        }
        // argmax label
        var label = [Int](repeating: 0, count: sw * sh)
        for k in 0..<(sw * sh) {
            var b = 0; var bv: Float = -1
            for i in energies.indices where energies[i][k] > bv { bv = energies[i][k]; b = i }
            label[k] = b
        }
        // mode filter to remove speckle
        var lab2 = label
        for y in 0..<sh { for x in 0..<sw {
            var counts = [Int](repeating: 0, count: images.count)
            for dy in -2...2 { for dx in -2...2 {
                let xx = clamp(x + dx, 0, sw - 1), yy = clamp(y + dy, 0, sh - 1)
                counts[label[yy * sw + xx]] += 1
            } }
            lab2[y * sw + x] = counts.indices.max { counts[$0] < counts[$1] } ?? label[y * sw + x]
        } }
        label = lab2
        return images.indices.map { i in
            var bytes = [UInt8](repeating: 255, count: sw * sh * 4)
            for k in 0..<(sw * sh) { let v: UInt8 = label[k] == i ? 255 : 0; bytes[k * 4] = v; bytes[k * 4 + 1] = v; bytes[k * 4 + 2] = v }
            let img = CIImage(bitmapData: Data(bytes), bytesPerRow: sw * 4, size: CGSize(width: sw, height: sh), format: .RGBA8, colorSpace: nil)
            return img.clampedToExtent().transformed(by: CGAffineTransform(scaleX: rect.width / CGFloat(sw), y: rect.height / CGFloat(sh)))
                .applyingGaussianBlur(sigma: 1.5 / sc).cropped(to: rect)
        }
    }
}
