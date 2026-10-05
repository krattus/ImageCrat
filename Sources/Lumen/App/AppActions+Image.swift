import AppKit
import CoreImage
import ImageCratCore

enum Histogram {
    /// [r, g, b, luminosity] × 256 counts. Samples at most ~250k pixels.
    static func compute(_ b: PixelBuffer) -> [[Int]] {
        var h = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 4)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        let total = b.width * b.height
        let step = max(1, Int(sqrt(Double(total) / 250_000)))
        var y = 0
        while y < b.height {
            let row = p + y * b.bytesPerRow
            var x = 0
            while x < b.width {
                let i = x * 4
                let a = Int(row[i + 3])
                if a > 0 {
                    let r = a == 255 ? Int(row[i]) : min(255, Int(row[i]) * 255 / a)
                    let g = a == 255 ? Int(row[i + 1]) : min(255, Int(row[i + 1]) * 255 / a)
                    let bb = a == 255 ? Int(row[i + 2]) : min(255, Int(row[i + 2]) * 255 / a)
                    h[0][r] += 1; h[1][g] += 1; h[2][bb] += 1
                    h[3][(r * 77 + g * 150 + bb * 29) >> 8] += 1
                }
                x += step
            }
            y += step
        }
        return h
    }

    static func clipPoints(_ hist: [Int], clip: Double = 0.001) -> (Int, Int) {
        let total = hist.reduce(0, +)
        guard total > 0 else { return (0, 255) }
        let thr = Int(Double(total) * clip)
        var acc = 0, lo = 0, hi = 255
        for i in 0..<256 { acc += hist[i]; if acc > thr { lo = i; break } }
        acc = 0
        for i in stride(from: 255, through: 0, by: -1) { acc += hist[i]; if acc > thr { hi = i; break } }
        return (lo, max(hi, lo + 1))
    }
}

extension AppActions {
    // MARK: Canvas geometry

    static func transformDocument(_ d: Document, h: Homography, newWidth: Int, newHeight: Int, name: String, nearest: Bool, scaleEffects: Double? = nil, guideMap: ((Guide) -> Guide)? = nil,
                                  strokeScale: Double? = nil) {
        canvas?.commitCurrentTool()
        let sp = space(d)
        var st = d.state
        st.layers = st.layers.map { LayerTransformer.apply(h, to: $0, space: sp, scaleEffects: scaleEffects, nearest: nearest, document: true, strokeScale: strokeScale) }
        syncStoredGeometry(from: d.state, to: &st, h: h)   // frames, comps, keyframes, slices … follow the document
        let newSpace = CanvasSpace(width: newWidth, height: newHeight)
        if let sel = st.selection {
            let img = LayerTransformer.warp(sel.ciImage, docRect: sel.bounds, h: h, space: sp, nearest: nearest)
            // re-express in new canvas: warp produced CI coords of old space; convert via doc rect
            let docR = sp.docRect(img.extent)
            let buf = RenderEngine.renderBuffer(img, docRect: IRect(enclosing: docR), space: sp, format: .gray)
            let out = PixelBuffer(width: newWidth, height: newHeight, format: .gray)
            out.copyPixels(from: buf, at: IRect(enclosing: docR).origin)
            out.markDirty()
            st.selection = out
            _ = newSpace
        }
        st.alphaChannels = st.alphaChannels.map { ch in
            var c = ch
            let img = LayerTransformer.warp(ch.buffer.ciImage, docRect: ch.buffer.bounds, h: h, space: sp, nearest: nearest)
            let docR = IRect(enclosing: sp.docRect(img.extent))
            let buf = RenderEngine.renderBuffer(img, docRect: docR, space: sp, format: .gray)
            let out = PixelBuffer(width: newWidth, height: newHeight, format: .gray)
            out.copyPixels(from: buf, at: docR.origin)
            out.markDirty()
            c.buffer = out
            return c
        }
        st.paths = st.paths.map { var p = $0; p.path = p.path.mapped(h.apply); return p }
        if let gm = guideMap { st.guides = st.guides.map(gm) }
        st.toolData = st.toolData.mapped(h.apply)
        st.width = newWidth
        st.height = newHeight
        d.state = st
        d.commit(name)
        Compositor.shared.clearCaches()
        d.needsFitOnScreen = true
        canvas?.fitOnScreen()
    }

    static func imageSize(width: Int, height: Int, resolution: Double, scaleStyles: Bool) {
        ActionRecorder.record(.imageSize(width: width, height: height, resolution: resolution, scaleStyles: scaleStyles))
        canvas?.commitCurrentTool()          // before the scale is computed: a pending crop changes the canvas size
        guard let d = doc, width > 0, height > 0 else { return }
        let width = min(width, maxCanvasDimension), height = min(height, maxCanvasDimension)
        let sx = Double(width) / Double(d.state.width), sy = Double(height) / Double(d.state.height)
        let h = Homography(affine: CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy)))
        d.state.resolution = validResolution(resolution)
        transformDocument(d, h: h, newWidth: width, newHeight: height, name: "Image Size", nearest: false, scaleEffects: scaleStyles ? sqrt(sx * sy) : nil,
                          guideMap: { g in var n = g; n.position *= g.isVertical ? sx : sy; return n }, strokeScale: sqrt(sx * sy))
    }

    /// anchor: (0,0)=top-left … (2,2)=bottom-right
    static func canvasSize(width: Int, height: Int, anchorX: Int, anchorY: Int, extension ext: RGBA?) {
        ActionRecorder.record(.canvasSize(width: width, height: height, anchorX: anchorX, anchorY: anchorY, ext: ext.map { [$0.r, $0.g, $0.b, $0.a] } ?? []))
        canvas?.commitCurrentTool()          // pending edits (type, transform, crop) are applied to the old canvas first
        guard let d = doc, width > 0, height > 0 else { return }
        let width = min(width, maxCanvasDimension), height = min(height, maxCanvasDimension)
        let dx = Double(width - d.state.width) * Double(anchorX) / 2
        let dy = Double(height - d.state.height) * Double(anchorY) / 2
        let idx = Int(dx.rounded()), idy = Int(dy.rounded())
        var st = d.state
        for i in st.layers.indices { st.layers[i].translate(dx: Double(idx), dy: Double(idy), document: true) }
        syncStoredGeometry(from: d.state, to: &st, dx: Double(idx), dy: Double(idy))
        // Extend background layer with color
        if let ext, let i = st.layers.firstIndex(where: { $0.name == "Background" }), let r = st.layers[i].raster {
            let nb = PixelBuffer(width: width, height: height)
            nb.context.setFillColor(ext.cgColor)
            nb.context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            nb.drawImage(r.buffer.makeCGImage(), in: CGRect(x: r.origin.x, y: r.origin.y, width: r.buffer.width, height: r.buffer.height))
            nb.markDirty()
            st.layers[i].raster = RasterContent(buffer: nb, origin: .zero)
        }
        func shift(_ b: PixelBuffer) -> PixelBuffer {
            let n = PixelBuffer(width: width, height: height, format: .gray)
            n.copyPixels(from: b, at: IPoint(x: idx, y: idy))
            n.markDirty()
            return n
        }
        if let s = st.selection { st.selection = shift(s) }
        st.alphaChannels = st.alphaChannels.map { var c = $0; c.buffer = shift(c.buffer); return c }
        st.paths = st.paths.map { var p = $0; p.path = p.path.applying(CGAffineTransform(translationX: CGFloat(idx), y: CGFloat(idy))); return p }
        st.guides = st.guides.map { var g = $0; g.position += g.isVertical ? Double(idx) : Double(idy); return g }
        st.toolData = st.toolData.mapped { CGPoint(x: $0.x + CGFloat(idx), y: $0.y + CGFloat(idy)) }
        st.width = width
        st.height = height
        LayoutConstraintEngine.canvasResized(&st, from: d.state)   // Layout module: per-layer constraints
        d.state = st
        d.commit("Canvas Size")
        Compositor.shared.clearCaches()
        d.needsFitOnScreen = true
        canvas?.fitOnScreen()
    }

    static func rotateCanvas(_ degrees: Int) {
        ActionRecorder.record(.rotateCanvas(degrees))
        canvas?.commitCurrentTool()          // before the new size is computed (a pending crop changes the canvas)
        guard let d = doc else { return }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        let t: CGAffineTransform
        var nw = d.state.width, nh = d.state.height
        switch degrees {
        case 90: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0); nw = d.state.height; nh = d.state.width
        case -90: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W); nw = d.state.height; nh = d.state.width
        default: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: W, ty: H)
        }
        transformDocument(d, h: Homography(affine: t), newWidth: nw, newHeight: nh, name: "Rotate Canvas", nearest: true, guideMap: { g in
            var n = g
            if degrees == 90 { n.isVertical.toggle(); n.position = g.isVertical ? g.position : Double(H) - g.position }
            else if degrees == -90 { n.isVertical.toggle(); n.position = g.isVertical ? Double(W) - g.position : g.position }
            else { n.position = (g.isVertical ? Double(W) : Double(H)) - g.position }
            return n
        })
    }

    static func flipCanvas(horizontal: Bool) {
        ActionRecorder.record(.flipCanvas(horizontal: horizontal))
        canvas?.commitCurrentTool()
        guard let d = doc else { return }
        let W = CGFloat(d.state.width), H = CGFloat(d.state.height)
        let t = horizontal ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: W, ty: 0) : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        transformDocument(d, h: Homography(affine: t), newWidth: d.state.width, newHeight: d.state.height, name: horizontal ? "Flip Canvas Horizontal" : "Flip Canvas Vertical", nearest: true, guideMap: { g in
            var n = g
            if horizontal && g.isVertical { n.position = Double(W) - g.position }
            if !horizontal && !g.isVertical { n.position = Double(H) - g.position }
            return n
        })
    }

    static func crop(to r: IRect, deletePixels: Bool) {
        canvas?.commitCurrentTool()          // pending edits are applied in the old coordinates first (the Crop tool resets its box before calling)
        guard let d = doc, !r.isEmpty else { return }
        let r = IRect(x: r.x, y: r.y, width: min(r.width, maxCanvasDimension), height: min(r.height, maxCanvasDimension))
        var st = d.state
        for i in st.layers.indices { st.layers[i].translate(dx: Double(-r.x), dy: Double(-r.y), document: true) }
        syncStoredGeometry(from: d.state, to: &st, dx: Double(-r.x), dy: Double(-r.y))
        if deletePixels {
            func cropLayer(_ l: inout Layer) {
                if var rc = l.raster {
                    let frame = rc.frame
                    let keep = frame.intersection(IRect(x: 0, y: 0, width: r.width, height: r.height))
                    if !keep.isEmpty {
                        rc.buffer = rc.buffer.cropped(to: keep.offsetBy(dx: -frame.x, dy: -frame.y))
                        rc.origin = keep.origin
                        l.raster = rc
                    }
                }
                if l.isGroup { var ch = l.children; for j in ch.indices { cropLayer(&ch[j]) }; l.children = ch }
            }
            for i in st.layers.indices { cropLayer(&st.layers[i]) }
        }
        func cropMask(_ b: PixelBuffer) -> PixelBuffer {
            let n = PixelBuffer(width: r.width, height: r.height, format: .gray)
            n.copyPixels(from: b, at: IPoint(x: -r.x, y: -r.y))
            n.markDirty()
            return n
        }
        if let s = st.selection { st.selection = nil; _ = s }
        st.alphaChannels = st.alphaChannels.map { var c = $0; c.buffer = cropMask(c.buffer); return c }
        st.paths = st.paths.map { var p = $0; p.path = p.path.applying(CGAffineTransform(translationX: CGFloat(-r.x), y: CGFloat(-r.y))); return p }
        st.guides = st.guides.map { var g = $0; g.position -= g.isVertical ? Double(r.x) : Double(r.y); return g }
        st.toolData = st.toolData.mapped { CGPoint(x: $0.x - CGFloat(r.x), y: $0.y - CGFloat(r.y)) }
        st.width = r.width
        st.height = r.height
        d.state = st
        d.commit("Crop")
        Compositor.shared.clearCaches()
        d.needsFitOnScreen = true
        canvas?.fitOnScreen()
    }

    static func cropToSelection() {
        guard let d = doc, let b = d.state.selection?.opaqueBounds() else { Beep.play(); return }
        crop(to: b, deletePixels: false)
    }

    static func trimTransparent() {
        guard let d = doc else { return }
        let sp = space(d)
        let buf = RenderEngine.renderBuffer(Compositor.shared.composite(d), docRect: d.state.canvasRect, space: sp)
        guard let b = buf.opaqueBounds() else { Beep.play(); return }
        crop(to: b, deletePixels: false)
    }

    static func revealAll() {
        guard let d = doc else { return }
        var u = d.state.canvasCGRect
        for l in d.state.allLayers { if let b = Compositor.shared.contentBounds(l, state: d.state) { u = u.union(b) } }
        let r = IRect(enclosing: u)
        guard r != d.state.canvasRect else { return }   // nothing outside the canvas: no empty "Crop" history step
        crop(to: r, deletePixels: false)
    }

    // MARK: Destructive adjustments & filters

    /// Renders `f(content)` back into the active layer (respecting selection). Returns false if not applicable.
    /// `layerPixels`: the edit is for the layer's pixels even while its layer mask is the edit target (Liquify).
    /// `coverCanvas`: the edit may put pixels anywhere on the canvas (Liquify): the layer's buffer first grows to cover the
    /// canvas (keeping everything outside it), so nothing is clipped to the layer's old bounds.
    @discardableResult
    static func applyToActiveLayer(name: String, layerPixels: Bool = false, coverCanvas: Bool = false, _ f: @escaping (CIImage) -> CIImage) -> Bool {
        if let d = doc, d.quickMask {
            // Quick Mask mode: filters and adjustments change the mask (the selection), not the layer
            let sp = space(d)
            guard let (w, o) = d.beginPixelEdit(layerID: d.activeLayerID ?? UUID(), target: .quickMask) else { return false }
            let orig = sp.place(w, at: o)
            RenderEngine.render(f(orig).cropped(to: orig.extent), into: w, docOrigin: o, space: sp)
            d.commit(name)
            return true
        }
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id) else { return false }
        let target = pixelTarget(d, l, layerPixels: layerPixels)
        if target == .content && !l.isRaster { offerRasterize(layer: id); return false }
        let sp = space(d)
        d.contentOverrides.removeValue(forKey: id)
        d.maskOverrides.removeValue(forKey: id)
        let edit = restricted(d, l, target: target, f)
        guard let (w, o) = d.beginPixelEdit(layerID: id, target: target, coverCanvas: coverCanvas) else { return false }
        let orig = sp.place(w, at: o)
        RenderEngine.render(edit(orig), into: w, docOrigin: o, space: sp)
        d.commit(name)
        return true
    }

    /// Liquify's OK, like Photoshop. The whole canvas is the working area: on a pixel layer the warp may push pixels
    /// anywhere on the canvas (the layer grows to hold them) and pixels outside the canvas are kept as they are. On a
    /// smart object (`smartLayer`, or the active layer when it is one) the warp becomes a Liquify smart filter — or
    /// updates `editingFilter` — whose result likewise reaches up to the canvas and follows later transforms. With a
    /// selection only the selected area changes (a new smart filter takes it as its filter mask).
    @discardableResult
    static func applyLiquify(_ field: DisplacementField, smartLayer: UUID? = nil, editingFilter: UUID? = nil) -> Bool {
        guard let d = doc else { return false }
        let sid = smartLayer ?? (!d.quickMask && d.activeLayer?.isSmartObject == true ? d.activeLayerID : nil)
        if let sid, let so = d.state.layer(sid)?.smart {
            let mesh = field.mesh(reference: so.quad)
            if let eid = editingFilter, let i = so.filters.firstIndex(where: { $0.id == eid }) {
                d.updateLayer(sid) { $0.smart?.filters[i].liquify = mesh }
            } else {
                guard !field.isIdentity else { return false }
                var f = FilterInstance(kind: .liquify)
                f.liquify = mesh
                f = withSelectionMask(f, d)
                d.updateLayer(sid) { $0.smart?.filters.append(f) }
            }
            d.commit("Liquify")
            return true
        }
        guard !field.isIdentity else { return false }
        let sp = space(d)
        return applyToActiveLayer(name: "Liquify", layerPixels: true, coverCanvas: true) { field.warp($0, space: sp) }
    }

    /// What a destructive filter or adjustment changes: the layer mask while it is the edit target (as in Photoshop),
    /// otherwise the layer's pixels. `layerPixels`: always the pixels.
    static func pixelTarget(_ d: Document, _ l: Layer, layerPixels: Bool = false) -> EditTarget {
        !layerPixels && d.editTarget == .mask && l.mask != nil ? .mask : .content
    }

    /// `f` applied to the placed pixels of `target`: the result inside the selection, blended by its (feathered) alpha,
    /// the original outside it, and only inside the layer's alpha when its transparency is locked. The live preview
    /// and the commit both run this, so what a dialog shows is exactly what OK applies.
    static func restricted(_ d: Document, _ l: Layer, target: EditTarget, _ f: @escaping (CIImage) -> CIImage) -> (CIImage) -> CIImage {
        let sel = d.state.selection?.ciImage
        let canvas = space(d).ciCanvas
        let lockAlpha = l.locks.transparency && target == .content
        return { orig in restrict(f(orig), original: orig, selection: sel, lockAlpha: lockAlpha, canvas: canvas) }
    }

    /// `result` of an edit of `orig`, kept to the selection (canvas-size gray, nil = everything) and, with
    /// `lockAlpha`, to the original's alpha.
    static func restrict(_ result: CIImage, original orig: CIImage, selection sel: CIImage?, lockAlpha: Bool, canvas: CGRect) -> CIImage {
        var r = result.cropped(to: orig.extent)
        if let sel { r = r.mixed(with: orig, mask: sel.composited(over: CIImage.color(.black, orig.extent.union(canvas)))).cropped(to: orig.extent) }
        if lockAlpha { r = r.masked(byAlphaOf: orig) }
        return r
    }

    /// Preview hook: applies f live to what the dialog's OK will change (the active layer's pixels, or its layer mask
    /// while that is the edit target), restricted like the commit (`restricted`).
    static func setPreview(_ f: ((CIImage) -> CIImage)?, layerPixels: Bool = false) {
        // The preview belongs to the dialog, not to whatever layer is active now: if the active layer or document
        // changed while the dialog was open, the preview set earlier must go too.
        DialogGuard.dropPreview()
        guard let d = doc, !d.quickMask, let id = d.activeLayerID, let l = d.state.layer(id) else { return }   // (Quick Mask: the result goes to the mask, not the layer)
        if let f {
            DialogGuard.notePreview(d, id)
            let target = pixelTarget(d, l, layerPixels: layerPixels)
            let edit = restricted(d, l, target: target, f)
            if target == .mask { d.maskOverrides[id] = edit } else { d.contentOverrides[id] = edit }
        } else {
            d.contentOverrides.removeValue(forKey: id)
            d.maskOverrides.removeValue(forKey: id)
        }
        d.setNeedsRender()
    }

    static func applyAdjustment(_ s: AdjustmentSettings) {
        ActionRecorder.record(.adjustment(s))
        applyToActiveLayer(name: s.kind.displayName) { AdjustmentEngine.apply(s, to: $0) }
    }

    static func applyFilter(_ f0: FilterInstance) {
        // a filter centred on the object or the selection is centred on them as they are now (Repeat Filter, actions)
        let f = FilterCenterResolver.resolved(f0, doc)
        ActionRecorder.record(.filter(f))
        guard let d = doc, let l = d.activeLayer else { return }
        if l.isSmartObject && !d.quickMask {
            addSmartFilter(f)
            return
        }
        let canvas = space(d).ciCanvas
        applyToActiveLayer(name: f.kind.displayName) { f.apply($0, canvas: canvas) }
        lastFilter = f
    }

    static var lastFilter: FilterInstance?

    /// A new smart filter takes the active selection as its filter mask, like Photoshop: the filter shows only inside
    /// the selection, blended by its (feathered) alpha. A filter that already has a mask keeps it.
    static func withSelectionMask(_ f: FilterInstance, _ d: Document?) -> FilterInstance {
        guard f.mask == nil, let s = d?.state.selection else { return f }
        var g = f
        g.mask = LayerMask(buffer: s.copy(), origin: .zero, outsideValue: 0)
        return g
    }

    /// Dialog title suffix naming what a destructive filter will change when that is not the layer's pixels.
    static func filterTargetSuffix(_ d: Document?) -> String {
        guard let d, let l = d.activeLayer else { return "" }
        if d.quickMask { return " (Quick Mask)" }
        return !l.isSmartObject && pixelTarget(d, l) == .mask ? " (Layer Mask)" : ""
    }

    static func repeatLastFilter() {
        guard let f = lastFilter else { Beep.play(); return }
        guard FilterLauncher.prepare() else { return }
        applyFilter(f)
    }

    static func addSmartFilter(_ f: FilterInstance) {
        guard let d = doc, let id = d.activeLayerID else { return }
        let f = withSelectionMask(f, d)
        d.updateLayer(id) { l in
            guard var so = l.smart else { return }
            so.filters.append(f)
            l.smart = so
        }
        d.commit(f.kind.displayName)
        lastFilter = f
    }

    static func invertActive() {
        ActionRecorder.record(.invert)
        var s = AdjustmentSettings(kind: .invert)
        s.kind = .invert
        applyAdjustment(s)
    }

    static func desaturateActive() { applyAdjustment(AdjustmentSettings(kind: .desaturate)) }

    static func autoLevels(perChannel: Bool) {
        ActionRecorder.record(.autoLevels(perChannel: perChannel))
        guard let src = sampleSource(allLayers: false) else { return }
        let h = Histogram.compute(src)
        var s = AdjustmentSettings(kind: .levels)
        if perChannel {
            for c in 0..<3 {
                let (lo, hi) = Histogram.clipPoints(h[c])
                s.levels[c + 1].inBlack = Double(lo); s.levels[c + 1].inWhite = Double(hi)
            }
        } else {
            let (lo, hi) = Histogram.clipPoints(h[3])
            s.levels[0].inBlack = Double(lo); s.levels[0].inWhite = Double(hi)
        }
        applyToActiveLayer(name: perChannel ? "Auto Tone" : "Auto Contrast") { AdjustmentEngine.apply(s, to: $0) }
    }

    static func autoColor() {
        ActionRecorder.record(.autoColor)
        guard let src = sampleSource(allLayers: false) else { return }
        let h = Histogram.compute(src)
        var s = AdjustmentSettings(kind: .levels)
        for c in 0..<3 {
            let (lo, hi) = Histogram.clipPoints(h[c], clip: 0.005)
            s.levels[c + 1].inBlack = Double(lo); s.levels[c + 1].inWhite = Double(hi)
            // neutralize midtones: gamma pushing the channel mean toward 0.5
            var sum = 0, n = 0
            for i in 0..<256 { sum += i * h[c][i]; n += h[c][i] }
            if n > 0 {
                let mean = (Double(sum) / Double(n) - Double(lo)) / Double(max(1, hi - lo))
                if mean > 0.05 && mean < 0.95 { s.levels[c + 1].gamma = clamp(log(0.5) / log(mean), 0.5, 2) }
            }
        }
        applyToActiveLayer(name: "Auto Color") { AdjustmentEngine.apply(s, to: $0) }
    }

    static func equalize() {
        ActionRecorder.record(.equalize)
        guard let src = sampleSource(allLayers: false) else { return }
        let h = Histogram.compute(src)[3]
        let total = max(1, h.reduce(0, +))
        var cdf = [Double](repeating: 0, count: 256)
        var acc = 0
        for i in 0..<256 { acc += h[i]; cdf[i] = Double(acc) / Double(total) }
        var s = AdjustmentSettings(kind: .curves)
        s.curves[0].points = stride(from: 0, through: 255, by: 17).map { CGPoint(x: Double($0) / 255, y: cdf[$0]) }
        applyToActiveLayer(name: "Equalize") { AdjustmentEngine.apply(s, to: $0) }
    }

    // MARK: Document level

    static func duplicateDocument() {
        guard let d = doc else { return }
        var st = d.state
        // Deep copy (own pixel buffers) that keeps the layer ids: frames, layer comps, timeline tracks, frame-tool and
        // generative metadata all refer to layers by id and would silently detach from re-identified copies.
        func copy(_ l: Layer) -> Layer {
            var n = l.duplicated()
            n.id = l.id
            if l.isGroup { n.children = l.children.map(copy) }
            return n
        }
        st.layers = st.layers.map(copy)
        let nd = Document(state: st, name: (d.name as NSString).deletingPathExtension + " copy")
        app.add(nd)
    }

    static func flattenImage() {
        ActionRecorder.record(.flatten)
        guard let d = doc else { return }
        let sp = space(d)
        let img = Compositor.shared.composite(d).composited(over: CIImage.color(.white, sp.ciCanvas))
        let buf = RenderEngine.renderBuffer(img, docRect: d.state.canvasRect, space: sp)
        let bg = Layer.raster(name: "Background", buffer: buf)
        d.state.layers = [bg]
        d.activeLayerID = bg.id
        d.selectedLayerIDs = [bg.id]
        d.commit("Flatten Image")
    }

    static func convertToGrayscale(commit: Bool = true) {
        if commit { ActionRecorder.record(.grayscale) }   // (as part of Image ▸ Mode the mode change itself is recorded)
        guard let d = doc else { return }
        let space = self.space(d)
        func conv(_ l: Layer) -> Layer {
            var n = l
            switch l.content {
            case .raster(var r):
                let img = AdjustmentEngine.apply(AdjustmentSettings(kind: .desaturate), to: space.place(r.buffer, at: r.origin))
                r.buffer = RenderEngine.renderBuffer(img, docRect: r.frame, space: space)
                n.content = .raster(r)
            case .group(var g):
                g.children = g.children.map(conv)
                n.content = .group(g)
            default: break
            }
            return n
        }
        d.state.layers = d.state.layers.map(conv)
        if commit { d.commit("Grayscale") }
    }
}
