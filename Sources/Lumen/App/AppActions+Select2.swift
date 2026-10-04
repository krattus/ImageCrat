import AppKit
import CoreImage
import ImageCratCore

// MARK: - Select and Mask engine

enum RefineViewMode: String, CaseIterable, Identifiable {
    case onionSkin = "Onion Skin", marchingAnts = "Marching Ants", overlay = "Overlay", onBlack = "On Black", onWhite = "On White", blackWhite = "Black & White", onLayers = "On Layers"
    var id: String { rawValue }
}

enum RefineOutput: String, CaseIterable, Identifiable {
    case selection = "Selection", layerMask = "Layer Mask", newLayer = "New Layer", newLayerWithMask = "New Layer with Layer Mask", newDocument = "New Document"
    var id: String { rawValue }
}

struct RefineSettings: Equatable {
    var radius: Double = 0
    var smartRadius = false
    var smooth: Double = 0
    var feather: Double = 0
    var contrast: Double = 0      // %
    var shiftEdge: Double = 0     // -100…100 %
    var decontaminate = false
    var decontaminateAmount: Double = 50
    var viewMode: RefineViewMode = .onionSkin
    var opacity: Double = 50
    var output: RefineOutput = .selection
}

enum MaskRefiner {
    static let contrastKernel = CIColorKernel(source: """
    kernel vec4 maskContrast(__sample s, float c, float shift) {
        float m = s.r + shift;
        m = (m - 0.5) * c + 0.5;
        m = clamp(m, 0.0, 1.0);
        return vec4(m, m, m, 1.0);
    }
    """)

    /// Refines a gray selection mask (CI space, canvas extent) using the image as edge guide.
    static func refine(mask: CIImage, image: CIImage, canvas: CGRect, s: RefineSettings) -> CIImage {
        var m = mask.cropped(to: canvas)
        if s.radius > 0.5 {
            let guide = image.composited(over: CIImage.color(.white, canvas)).cropped(to: canvas)
            let r = s.radius
            let guided = m.applyingFilter("CIGuidedFilter", parameters: [
                "inputGuideImage": guide, kCIInputRadiusKey: max(1, r / (s.smartRadius ? 1.5 : 2.5)), "inputEpsilon": s.smartRadius ? 0.00005 : 0.0003,
            ]).cropped(to: canvas)
            // Only refine inside the edge band
            let dil = m.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r]).cropped(to: canvas)
            let ero = m.clampedToExtent().applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r]).cropped(to: canvas)
            let band = dil.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: ero]).cropped(to: canvas)
            let bandSoft = band.applyingGaussianBlur(sigma: 1).cropped(to: canvas)
            m = guided.mixed(with: m, mask: bandSoft).cropped(to: canvas)
        }
        if s.smooth > 0 {
            let blurred = m.clampedToExtent().applyingGaussianBlur(sigma: s.smooth / 12).cropped(to: canvas)
            m = contrastKernel?.apply(extent: canvas, arguments: [blurred, Float(1 + s.smooth / 25), Float(0)]) ?? blurred
        }
        if s.feather > 0 { m = m.clampedToExtent().applyingGaussianBlur(sigma: s.feather / 2).cropped(to: canvas) }
        if s.contrast != 0 || s.shiftEdge != 0 {
            m = contrastKernel?.apply(extent: canvas, arguments: [m, Float(1 + s.contrast / 100 * 8), Float(s.shiftEdge / 100 * 0.5)]) ?? m
        }
        return m
    }

    static let decontaminateKernel = CIColorKernel(source: """
    kernel vec4 decont(__sample img, __sample avg, __sample w, __sample m, float amt) {
        vec3 c = img.a > 0.0 ? img.rgb / img.a : vec3(0.0);
        vec3 inner = w.r > 0.0001 ? avg.rgb / w.r : c;
        float k = amt * (1.0 - m.r) * step(0.001, m.r);
        vec3 r = mix(c, inner, clamp(k * 1.5, 0.0, 1.0));
        return vec4(r * img.a, img.a);
    }
    """)

    /// Replaces fringe colors with colors from fully selected neighbours.
    static func decontaminate(image: CIImage, mask: CIImage, canvas: CGRect, amount: Double) -> CIImage {
        guard let k = decontaminateKernel else { return image }
        let solid = mask.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.95])
        let weighted = image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: solid])
        let avg = weighted.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: canvas)
        let w = solid.clampedToExtent().applyingGaussianBlur(sigma: 6).cropped(to: canvas)
        return k.apply(extent: canvas, arguments: [image.cropped(to: canvas), avg, w, mask, Float(amount / 100)]) ?? image
    }

    /// Display preview for a view mode.
    static func preview(composite: CIImage, layerImage: CIImage, mask: CIImage, canvas: CGRect, s: RefineSettings) -> CIImage {
        let op = s.opacity / 100
        switch s.viewMode {
        case .marchingAnts: return composite
        case .overlay:
            let red = CIImage.color(RGBA(r: 1, g: 0, b: 0, a: op), canvas).masked(byGray: mask.inverted())
            return red.composited(over: composite)
        case .onBlack: return layerImage.masked(byGray: mask).composited(over: CIImage.color(.black, canvas))
        case .onWhite: return layerImage.masked(byGray: mask).composited(over: CIImage.color(.white, canvas))
        case .blackWhite: return mask.cropped(to: canvas)
        case .onLayers: return layerImage.masked(byGray: mask)
        case .onionSkin:
            let hidden = layerImage.withOpacity(1 - op).masked(byGray: mask.inverted())
            return layerImage.masked(byGray: mask).composited(over: hidden)
        }
    }
}

extension AppActions {
    // MARK: Select Sky

    /// Heuristic sky segmentation: region-grows sky-colored, low-texture pixels connected to the top edge,
    /// then refines the edge with a guided filter.
    static func selectSky() {
        if ObjectSelectionModule.selectSky() { return }   // Florence-2 + SAM 2.1 path when installed
        guard let d = doc, let src = sampleSource(allLayers: true) else { return }
        let W = d.state.width, H = d.state.height
        let scale = min(1, 500 / Double(max(W, H)))
        let w = max(8, Int(Double(W) * scale)), h = max(8, Int(Double(H) * scale))
        let small = PixelBuffer(width: w, height: h)
        small.drawImage(src.makeCGImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = small.data.assumingMemoryBound(to: UInt8.self)
        func px(_ x: Int, _ y: Int) -> (Double, Double, Double) {
            let i = y * small.bytesPerRow + x * 4
            return (Double(p[i]) / 255, Double(p[i + 1]) / 255, Double(p[i + 2]) / 255)
        }
        // texture (gradient) map
        var grad = [Double](repeating: 0, count: w * h)
        for y in 1..<(h - 1) { for x in 1..<(w - 1) {
            let a = px(x - 1, y), b = px(x + 1, y), c = px(x, y - 1), e = px(x, y + 1)
            grad[y * w + x] = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) + abs(c.0 - e.0) + abs(c.1 - e.1) + abs(c.2 - e.2)
        } }
        // sky model from the top rows
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        let topRows = max(1, h / 30)
        for y in 0..<topRows { for x in 0..<w { let c = px(x, y); sr += c.0; sg += c.1; sb += c.2; n += 1 } }
        sr /= n; sg /= n; sb /= n
        let skyLike = sb >= sr * 0.9 || (sr + sg + sb) / 3 > 0.6   // blue-ish or bright/overcast
        guard skyLike else { alert("No sky was found.", "The top of the image doesn't look like sky."); return }
        var mask = [UInt8](repeating: 0, count: w * h)
        var queue: [Int] = []
        for x in 0..<w { queue.append(x) }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            if mask[i] != 0 { continue }
            let x = i % w, y = i / w
            let c = px(x, y)
            // local reference: running blend of the neighbour above for smooth gradients (sunsets)
            let ref: (Double, Double, Double) = y > 0 ? px(x, y - 1) : (sr, sg, sb)
            let dLocal = abs(c.0 - ref.0) + abs(c.1 - ref.1) + abs(c.2 - ref.2)
            let dGlobal = abs(c.0 - sr) + abs(c.1 - sg) + abs(c.2 - sb)
            if grad[i] > 0.35 || dLocal > 0.12 || dGlobal > 0.9 { continue }
            mask[i] = 255
            if x > 0 { queue.append(i - 1) }
            if x < w - 1 { queue.append(i + 1) }
            if y < h - 1 { queue.append(i + w) }
            if y > 0 { queue.append(i - w) }
        }
        let mb = PixelBuffer(width: w, height: h, format: .gray)
        let mp = mb.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { mp[y * mb.bytesPerRow + x] = mask[y * w + x] } }
        mb.markDirty()
        // upscale + guided refinement at full resolution
        let space = CanvasSpace(width: W, height: H)
        var up = mb.ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / CGFloat(w), y: CGFloat(H) / CGFloat(h)))
        up = up.clampedToExtent().applyingGaussianBlur(sigma: 1 / scale).cropped(to: space.ciCanvas)
        let guide = space.place(src, at: .zero)
        up = up.applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": guide, kCIInputRadiusKey: 4, "inputEpsilon": 0.0005]).cropped(to: space.ciCanvas)
        let full = RenderEngine.renderBuffer(up, docRect: d.state.canvasRect, space: space, format: .gray)
        guard full.opaqueBounds() != nil else { alert("No sky was found."); return }
        d.setSelection(full, commitName: "Select Sky")
    }

    // MARK: Focus Area

    static let absKernel = CIColorKernel(source: "kernel vec4 absK(__sample s) { vec3 a = abs(s.rgb - 0.5) * 2.0; return vec4(a, 1.0); }")

    /// Selects in-focus regions (high local detail). `range` 0…100: higher selects more.
    static func focusAreaMask(range: Double, noise: Double) -> PixelBuffer? {
        guard let d = doc else { return nil }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        let comp = Compositor.shared.composite(d).composited(over: CIImage.color(.white, space.ciCanvas)).cropped(to: space.ciCanvas)
        let gray = comp.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        var src = gray.clampedToExtent()
        if noise > 0 { src = src.applyingGaussianBlur(sigma: noise / 20) }
        let lap = src.applyingFilter("CIConvolution3X3", parameters: [
            "inputWeights": CIVector(values: [0, -1, 0, -1, 4, -1, 0, -1, 0], count: 9), "inputBias": 0.5])
        guard let k = absKernel, let a = k.apply(extent: space.ciCanvas, arguments: [lap.cropped(to: space.ciCanvas)]) else { return nil }
        let r = Double(max(d.state.width, d.state.height)) / 80
        let energy = a.clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: space.ciCanvas)
        // normalise by the maximum
        let mx = energy.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: space.ciCanvas)])
        var px = [Float](repeating: 0, count: 4)
        RenderEngine.readbackContext.render(mx, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: mx.extent.origin, size: CGSize(width: 1, height: 1)), format: .RGBAf, colorSpace: nil)
        let maxV = max(0.0001, Double(px[0]))
        let thr = maxV * (0.6 - range / 100 * 0.55)
        var m = energy.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": thr])
        m = m.clampedToExtent().applyingGaussianBlur(sigma: r / 3).cropped(to: space.ciCanvas)
            .applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": comp, kCIInputRadiusKey: 6, "inputEpsilon": 0.001]).cropped(to: space.ciCanvas)
        return RenderEngine.renderBuffer(m, docRect: d.state.canvasRect, space: space, format: .gray)
    }

    // MARK: Similar

    static func selectSimilar() {
        guard let d = doc, let sel = d.state.selection, let src = sampleSource(allLayers: true), let b = sel.opaqueBounds() else { NSSound.beep(); return }
        let seed = IPoint(x: b.x + b.width / 2, y: b.y + b.height / 2)
        let m = SelectionOps.floodMask(src: src, seed: seed, tolerance: app.selection.tolerance, contiguous: false, antialias: true)
        d.setSelection(SelectionOps.combine(sel, m, mode: .add), commitName: "Similar")
    }

    // MARK: Transform Selection

    static func transformSelection() {
        guard let c = canvas, let d = doc, d.state.selection != nil else { NSSound.beep(); return }
        c.commitCurrentTool()
        app.tool = .move
        (c.tool(for: .move) as? MoveTool)?.startTransform(selectionOnly: true)
    }

    // MARK: Select and Mask apply

    static func applyRefinedSelection(_ refined: PixelBuffer, settings: RefineSettings) {
        guard let d = doc else { return }
        let space = CanvasSpace(width: d.state.width, height: d.state.height)
        switch settings.output {
        case .selection:
            d.setSelection(refined, commitName: "Select and Mask")
        case .layerMask:
            guard let id = d.activeLayerID else { return }
            d.updateLayer(id) { $0.mask = LayerMask(buffer: refined, origin: .zero, outsideValue: 0) }
            d.state.selection = nil
            d.editTarget = .mask
            d.commit("Select and Mask")
        case .newLayer, .newLayerWithMask, .newDocument:
            guard let l = d.activeLayer, var img = Compositor.shared.contentImage(l, space: space) else { return }
            if settings.decontaminate {
                img = MaskRefiner.decontaminate(image: img, mask: refined.ciImage, canvas: space.ciCanvas, amount: settings.decontaminateAmount)
            }
            if settings.output == .newLayerWithMask {
                let buf = RenderEngine.renderBuffer(img.cropped(to: space.ciCanvas), docRect: d.state.canvasRect, space: space)
                var nl = Layer.raster(name: l.name + " copy", buffer: buf)
                nl.mask = LayerMask(buffer: refined, origin: .zero, outsideValue: 0)
                d.state.insertLayer(nl, above: l.id)
                d.updateLayer(l.id) { $0.isVisible = false }
                d.activeLayerID = nl.id; d.selectedLayerIDs = [nl.id]
                d.state.selection = nil
                d.commit("Select and Mask")
            } else {
                let masked = img.masked(byGray: refined.ciImage).cropped(to: space.ciCanvas)
                let buf = RenderEngine.renderBuffer(masked, docRect: d.state.canvasRect, space: space)
                if settings.output == .newDocument {
                    let nd = Document.newBlank(width: d.state.width, height: d.state.height, background: nil, name: "Untitled")
                    nd.state.layers = [Layer.raster(name: l.name, buffer: buf)]
                    nd.commit("Select and Mask")
                    app.add(nd)
                } else {
                    let nl = Layer.raster(name: l.name + " copy", buffer: buf)
                    d.state.insertLayer(nl, above: l.id)
                    d.updateLayer(l.id) { $0.isVisible = false }
                    d.activeLayerID = nl.id; d.selectedLayerIDs = [nl.id]
                    d.state.selection = nil
                    d.commit("Select and Mask")
                }
            }
        }
    }
}

// MARK: - Warp commands

extension AppActions {
    static func startInteractive(_ make: (Document, UUID) -> InteractiveSession?) {
        guard let c = canvas, let d = doc, let id = d.activeLayerID, let l = d.state.layer(id) else { return }
        if !WarpApply.canWarp(l) {
            offerRasterize(layer: id)
            return
        }
        if l.locks.positionLocked || (l.isRaster && l.locks.pixelsLocked) {     // like Free Transform
            app.setStatus("The layer is locked.")
            NSSound.beep()
            return
        }
        c.commitCurrentTool()
        app.tool = .move
        guard let mt = c.tool(for: .move) as? MoveTool, let s = make(d, id) else { NSSound.beep(); return }
        mt.interactive = s
        app.setStatus("\(s.title): press Return to apply, Esc to cancel.")
    }

    static func warp() { startInteractive { SplitWarpSession(doc: $0, layerID: $1) } }   // Edits/SplitWarp.swift (split grids + cylinder)
    static func puppetWarp() { startInteractive { PuppetWarpSession(doc: $0, layerID: $1) } }
    static func perspectiveWarp() { startInteractive { PerspectiveWarpSession(doc: $0, layerID: $1) } }
    static func contentAwareScale() {
        guard let d = doc, let l = d.activeLayer else { return }
        if !l.isRaster { offerRasterize(layer: l.id); return }
        startInteractive { ContentAwareScaleSession(doc: $0, layerID: $1) }
    }
}

extension AppActions {
    /// Image handed to the next Displace filter dialog.
    static var pendingFilterPayload: PixelBuffer?
}
