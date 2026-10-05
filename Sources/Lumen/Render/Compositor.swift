import Foundation
import CoreImage
import ImageCratCore

private struct TextKey: Equatable { var t: TextContent; var w: Int; var h: Int }
private struct ShapeKey: Equatable { var s: ShapeContent; var w: Int; var h: Int }
private struct SmartKey: Equatable { var rev: Int; var bufferVersion: Int; var bufferID: ObjectIdentifier?; var quad: Quad; var warp: MeshWarpData?; var w: Int; var h: Int }
private struct VMaskKey: Equatable { var p: VectorPath; var w: Int; var h: Int }

/// Builds Core Image graphs for documents and layers.
final class Compositor {
    static let shared = Compositor()

    private let textCache = RenderCache<TextKey>()
    private let shapeCache = RenderCache<ShapeKey>()
    private let smartCache = RenderCache<SmartKey>()
    private let vmaskCache = RenderCache<VMaskKey>()
    private var fxCache: [UUID: (key: ObjectIdentifier, fx: LayerEffects, bounds: CGRect, light: GlobalLight, result: RenderedEffects)] = [:]

    private var maskedCache: [UUID: (content: ObjectIdentifier, sig: String, image: CIImage)] = [:]

    /// Content × mask, cached so the image object stays stable (keeps effect caching effective).
    private func maskedContent(_ layer: Layer, content: CIImage, mask: CIImage) -> CIImage {
        var sig = "\(layer.layerMaskHidesEffects)\(layer.vectorMaskHidesEffects)"
        if let m = layer.mask { sig = "\(ObjectIdentifier(m.buffer))-\(m.buffer.version)-\(m.origin.x),\(m.origin.y)-\(m.isEnabled)-\(m.density)-\(m.feather)-\(m.featherDirection?.rawValue ?? "")-\(m.outsideValue)" }
        if let vm = layer.vectorMask, layer.vectorMaskEnabled { 
            var h = 0.0
            for sp in vm.subpaths { for pt in sp.points {
                h = (h * 1.000_031).truncatingRemainder(dividingBy: 1e12) + Double(pt.anchor.x) * 3 + Double(pt.anchor.y) * 7 + Double(pt.inControl.x + pt.outControl.y) * 11 + Double(pt.inControl.y + pt.outControl.x) * 13
            } }
            sig += "|v\(h)-\(vm.subpaths.count)" }
        if let c = maskedCache[layer.id], c.content == ObjectIdentifier(content), c.sig == sig { return c.image }
        let img = content.masked(byGray: mask)
        maskedCache[layer.id] = (ObjectIdentifier(content), sig, img)
        return img
    }

    /// Effects are cached per layer while the content image object and settings are unchanged.
    private func effects(_ layer: Layer, content: CIImage, bounds: CGRect, space: CanvasSpace, light: GlobalLight) -> RenderedEffects {
        let key = ObjectIdentifier(content)
        if let c = fxCache[layer.id], c.key == key, c.fx == layer.effects, c.bounds == bounds, c.light == light { return c.result }
        var r = EffectsRenderer.render(layer.effects, content: content, bounds: bounds, space: space, globalLight: light)
        func cache(_ p: [EffectPiece]) -> [EffectPiece] { p.map { EffectPiece(image: $0.image.insertingIntermediate(cache: true), mode: $0.mode) } }
        r.below = cache(r.below); r.interior = cache(r.interior); r.above = cache(r.above)
        fxCache[layer.id] = (key, layer.effects, bounds, light, r)
        return r
    }

    struct Options {
        var overrides: [UUID: (CIImage) -> CIImage] = [:]
        /// Live previews of layer masks (`Document.maskOverrides`).
        var maskOverrides: [UUID: (CIImage) -> CIImage] = [:]
        var hidden: Set<UUID> = []
        var globalLight = GlobalLight()
        /// Bottom of the document, revealed by "Deep" knockouts.
        var rootBackdrop: CIImage? = nil
    }

    // MARK: Entry points

    func composite(_ doc: Document) -> CIImage {
        composite(doc.state, options: Options(overrides: doc.contentOverrides, maskOverrides: doc.maskOverrides, hidden: doc.hiddenLayers))
    }

    func composite(_ state: DocumentState, options: Options = Options()) -> CIImage {
        RecipeAmbient.push(.full(state)); defer { RecipeAmbient.pop() }   // Recipe layers resolve layer references through this
        let space = CanvasSpace(width: state.width, height: state.height)
        let backdrop = CIImage.clearImage.cropped(to: space.ciCanvas)
        var opts = options
        opts.globalLight = state.globalLight
        // Deep knockout reveals the Background layer (or transparency when there is none).
        if let bg = state.layers.first, bg.name == "Background", bg.isRaster, bg.isVisible, state.layers.count > 1 {
            opts.rootBackdrop = composite(layers: [bg], backdrop: backdrop, space: space, options: Options(globalLight: state.globalLight))
        }
        let img = composite(layers: state.layers, backdrop: backdrop, space: space, options: opts).cropped(to: space.ciCanvas)
        // A Grayscale document has one channel: whatever its layers keep in colour (smart object contents, type, shapes,
        // fills, adjustment and effect colours, which stay editable) composites to gray, on screen and in every export.
        return state.colorMode == .grayscale ? img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) : img
    }

    // MARK: Layer stack

    func composite(layers: [Layer], backdrop start: CIImage, space: CanvasSpace, options: Options) -> CIImage {
        var backdrop = start
        var clipBase: CIImage? = nil     // alpha source of current clipping base
        var clipBaseVisible = true
        var clipBaseOpacity = 1.0
        var i = 0

        while i < layers.count {
            let layer = layers[i]
            defer { i += 1 }
            if !layer.isClipped {
                clipBase = nil
                clipBaseVisible = layer.isVisible && !options.hidden.contains(layer.id)
                clipBaseOpacity = layer.opacity
            }
            let hidden = !layer.isVisible || options.hidden.contains(layer.id) || (layer.isClipped && !clipBaseVisible)
            if hidden {
                if !layer.isClipped { clipBase = CIImage.clearImage.cropped(to: space.ciCanvas) }
                continue
            }

            // "Blend Clipped Layers as Group": a non-normal base blends its whole clipping group with its mode.
            if !layer.isClipped, layer.blendClippedAsGroup, layer.blendMode != .normal, layer.blendMode != .passThrough, !layer.isAdjustment,
               i + 1 < layers.count, layers[i + 1].isClipped {
                var j = i + 1
                while j < layers.count && layers[j].isClipped { j += 1 }
                var baseNormal = layer
                baseNormal.blendMode = .normal
                baseNormal.opacity = 1
                baseNormal.knockout = .none
                let group = [baseNormal] + Array(layers[(i + 1)..<j])
                let isolated = composite(layers: group, backdrop: CIImage.clearImage.cropped(to: space.ciCanvas), space: space, options: options)
                backdrop = isolated.withOpacity(layer.opacity).blended(over: backdrop, mode: layer.blendMode).cropped(to: space.ciCanvas)
                i = j - 1
                continue
            }

            // Clipped layers inherit the base layer's opacity (Photoshop clipping-group semantics).
            let opacity = layer.isClipped ? layer.opacity * clipBaseOpacity : layer.opacity
            let clipAlpha = layer.isClipped ? clipBase : nil

            switch layer.content {
            case .adjustment(let adj):
                var adjusted = AdjustmentEngine.apply(adj, to: backdrop)
                if let o = options.overrides[layer.id] { adjusted = o(adjusted) }
                var piece = adjusted
                let adjMask = maskImage(layer, space: space, override: options.maskOverrides[layer.id])
                if let m = adjMask { piece = piece.masked(byGray: m) }
                if let c = clipAlpha { piece = piece.masked(byAlphaOf: c) }
                if !layer.blendIf.isDefault { piece = applyBlendIf(layer.blendIf, piece, backdrop) }
                piece = piece.withOpacity(opacity)
                let before = backdrop
                backdrop = piece.blended(over: backdrop, mode: layer.blendMode == .passThrough ? .normal : layer.blendMode).cropped(to: space.ciCanvas)
                backdrop = restrictChannels(layer, backdrop, before)
                if !layer.isClipped {
                    clipBase = adjMask.map { $0.grayAsAlpha.cropped(to: space.ciCanvas) } ?? CIImage.color(.white, space.ciCanvas)
                }

            case .group(let g) where layer.blendMode == .passThrough && g.artboard == nil && g.repeater == nil:
                var result = composite(layers: g.children, backdrop: backdrop, space: space, options: options)
                if let o = options.overrides[layer.id] { result = o(result) }
                var mask: CIImage? = maskImage(layer, space: space, override: options.maskOverrides[layer.id])
                if let c = clipAlpha {
                    let a = c.alphaAsGray
                    mask = mask.map { $0.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: a]) } ?? a
                }
                if opacity < 0.999 || mask != nil {
                    var m = mask ?? CIImage.color(.white, space.ciCanvas)
                    if opacity < 0.999 {
                        m = m.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: CGFloat(opacity), y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: CGFloat(opacity), z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(opacity), w: 0)])
                    }
                    result = result.mixed(with: backdrop, mask: m)
                }
                backdrop = result.cropped(to: space.ciCanvas)
                if !layer.isClipped {
                    var base = composite(layers: g.children, backdrop: CIImage.clearImage.cropped(to: space.ciCanvas), space: space, options: options)
                    if let m = maskImage(layer, space: space, override: options.maskOverrides[layer.id]) { base = base.masked(byGray: m) }
                    clipBase = base
                }

            default:
                guard var content = contentImage(layer, space: space, options: options, backdrop: backdrop) else { continue }
                if let o = options.overrides[layer.id] { content = o(content) }
                let bounds = content.extent.intersection(space.ciCanvas.insetBy(dx: -2000, dy: -2000))

                // Masks that shape the content (effects are generated from the masked shape) vs. masks that hide effects.
                let maskOverride = options.maskOverrides[layer.id]
                let shapeMask = maskImage(layer, space: space, raster: !layer.layerMaskHidesEffects, vector: !layer.vectorMaskHidesEffects, override: maskOverride)
                let hideMask = (layer.layerMaskHidesEffects || layer.vectorMaskHidesEffects)
                    ? maskImage(layer, space: space, raster: layer.layerMaskHidesEffects, vector: layer.vectorMaskHidesEffects, override: maskOverride) : nil
                let shaped = shapeMask.map { maskedContent(layer, content: content, mask: $0) } ?? content

                func finalize(_ img: CIImage) -> CIImage {
                    var out = img
                    if let h = hideMask { out = out.masked(byGray: h) }
                    if let c = clipAlpha { out = out.masked(byAlphaOf: c) }
                    return out.withOpacity(opacity)
                }

                // Knockout: reveal the bottom of the group (shallow) or the document background (deep) inside the layer.
                if layer.knockout != .none {
                    let target = layer.knockout == .deep ? (options.rootBackdrop ?? CIImage.clearImage.cropped(to: space.ciCanvas)) : start
                    var k = shaped
                    if let h = hideMask { k = k.masked(byGray: h) }
                    backdrop = target.mixed(with: backdrop, mask: k.alphaAsGray.cropped(to: space.ciCanvas).composited(over: CIImage.color(.black, space.ciCanvas))).cropped(to: space.ciCanvas)
                }

                let fx = layer.effects.enabled && layer.effects.hasAny
                    ? effects(layer, content: shaped, bounds: bounds, space: space, light: options.globalLight) : RenderedEffects()
                for p in fx.below {
                    backdrop = finalize(p.image).blended(over: backdrop, mode: p.mode).cropped(to: space.ciCanvas)
                }
                let mode = layer.blendMode == .passThrough ? .normal : layer.blendMode
                let before = backdrop
                var body = shaped
                if layer.blendInteriorEffectsAsGroup {
                    // Interior effects are merged with the content first, then faded by the fill opacity together with it
                    // (Photoshop: with "Blend Interior Effects as Group" Fill also fades Inner Glow, Satin, overlays…),
                    // then blended with the layer's mode.
                    for p in fx.interior { body = p.image.blended(over: body, mode: p.mode) }
                    body = body.withOpacity(layer.fillOpacity)
                    if !layer.blendIf.isDefault { body = applyBlendIf(layer.blendIf, body, backdrop) }
                    backdrop = finalize(body).blended(over: backdrop, mode: mode).cropped(to: space.ciCanvas)
                } else {
                    body = body.withOpacity(layer.fillOpacity)   // Fill fades the layer's own pixels, not its effects
                    if !layer.blendIf.isDefault { body = applyBlendIf(layer.blendIf, body, backdrop) }
                    backdrop = finalize(body).blended(over: backdrop, mode: mode).cropped(to: space.ciCanvas)
                    for p in fx.interior {
                        backdrop = finalize(p.image).blended(over: backdrop, mode: p.mode).cropped(to: space.ciCanvas)
                    }
                }
                for p in fx.above {
                    backdrop = finalize(p.image).blended(over: backdrop, mode: p.mode).cropped(to: space.ciCanvas)
                }
                backdrop = restrictChannels(layer, backdrop, before)
                if !layer.isClipped {
                    var base = shaped
                    if let h = hideMask { base = base.masked(byGray: h) }
                    clipBase = base
                }
            }
        }
        return backdrop
    }

    // MARK: Advanced blending

    static let blendIfKernel = CIColorKernel(source: """
    kernel vec4 blendIf(__sample s, __sample d, float ch, vec4 thisR, vec4 underR) {
        vec3 S = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        vec3 D = d.a > 0.0 ? d.rgb / d.a : vec3(0.0);
        float vs = ch < 0.5 ? dot(S, vec3(0.299, 0.587, 0.114)) : (ch < 1.5 ? S.r : (ch < 2.5 ? S.g : S.b));
        float vd = ch < 0.5 ? dot(D, vec3(0.299, 0.587, 0.114)) : (ch < 1.5 ? D.r : (ch < 2.5 ? D.g : D.b));
        float fs = smoothstep(thisR.x - 0.0001, thisR.y + 0.0001, vs) * (1.0 - smoothstep(thisR.z - 0.0001, thisR.w + 0.0001, vs));
        float fd = smoothstep(underR.x - 0.0001, underR.y + 0.0001, vd) * (1.0 - smoothstep(underR.z - 0.0001, underR.w + 0.0001, vd));
        if (d.a <= 0.0) { fd = 1.0; }
        return s * (fs * fd);
    }
    """)

    /// Photoshop "Blend If": hides layer pixels by the tonal value of this layer and the layers underneath.
    func applyBlendIf(_ b: BlendIf, _ layer: CIImage, _ under: CIImage) -> CIImage {
        guard let k = Compositor.blendIfKernel else { return layer }
        let ext = layer.extent
        let u = under.composited(over: CIImage.clearImage.cropped(to: ext))
        let ch: Float = b.channel == .gray ? 0 : b.channel == .red ? 1 : b.channel == .green ? 2 : 3
        func v(_ a: [Double], _ z: [Double]) -> CIVector {
            // x,y: fade-in range; z,w: fade-out range (0…1)
            CIVector(x: CGFloat(a[0] / 255), y: CGFloat(max(a[0], a[1]) / 255), z: CGFloat(z[0] / 255), w: CGFloat(max(z[0], z[1]) / 255 + (z[1] >= 255 && z[0] >= 255 ? 0.01 : 0)))
        }
        return k.apply(extent: ext, arguments: [layer, u, ch, v(b.thisLow, b.thisHigh), v(b.underLow, b.underHigh)]) ?? layer
    }

    static let channelKernel = CIColorKernel(source: """
    kernel vec4 channelMix(__sample a, __sample b, vec4 m) {
        return vec4(mix(b.r, a.r, m.x), mix(b.g, a.g, m.y), mix(b.b, a.b, m.z), mix(b.a, a.a, max(m.x, max(m.y, m.z))));
    }
    """)

    /// Advanced blending "Channels": only the checked RGB channels are affected by the layer.
    func restrictChannels(_ layer: Layer, _ result: CIImage, _ before: CIImage) -> CIImage {
        if layer.channelR && layer.channelG && layer.channelB { return result }
        guard let k = Compositor.channelKernel else { return result }
        let m = CIVector(x: layer.channelR ? 1 : 0, y: layer.channelG ? 1 : 0, z: layer.channelB ? 1 : 0, w: 1)
        return k.apply(extent: result.extent, arguments: [result, before.cropped(to: result.extent), m]) ?? result
    }

    // MARK: Layer content

    /// Layer pixels in CI space, without mask, effects or opacity. Groups return their isolated composite.
    func contentImage(_ layer: Layer, space: CanvasSpace, options: Options = Options(), backdrop: CIImage? = nil) -> CIImage? {
        switch layer.content {
        case .raster(let r):
            return r.buffer.placed(at: r.origin, space: space)
        case .text(let t):
            return textCache.get(layer.id, TextKey(t: t, w: space.width, h: space.height)) { TextRenderer.render(t, space: space) }
        case .shape(let s):
            return shapeCache.get(layer.id, ShapeKey(s: s, w: space.width, h: space.height)) { ShapeRenderer.render(s, space: space) }
        case .fill(let f):
            if let g = f.recipe { return RecipeRuntime.shared.layerContent(layer, graph: g, backdrop: backdrop, space: space) }   // Recipe layer
            return PaintRenderer.fillLayerImage(f, layer: layer, space: space)
        case .smartObject(let so):
            return smartImage(layer.id, so, space: space, filtersBelow: so.filters.count)
        case .group(let g):
            let clear = CIImage.clearImage.cropped(to: space.ciCanvas)
            if g.repeater != nil { return RepeaterRenderer.image(layer, g, space: space, options: options) }   // Layout module: live repeater
            if let ab = g.artboard {
                let r = space.ciRect(ab.rect).intersection(space.ciCanvas)
                if r.isEmpty { return clear }
                let bg = ab.background.map { CIImage.color($0, r).composited(over: clear) } ?? clear
                return composite(layers: g.children, backdrop: bg, space: space, options: options).cropped(to: r)
            }
            return composite(layers: g.children, backdrop: clear, space: space, options: options)
        case .adjustment:
            return nil
        }
    }

    /// Smart object content with its (enabled) smart filters up to, not including, index `filtersBelow`.
    func smartImage(_ id: UUID, _ so: SmartObjectContent, space: CanvasSpace, filtersBelow: Int) -> CIImage {
        var img = smartSourceImage(id, so, space: space)
        if so.filtersEnabled {
            // smart filters centred on the object follow it (moved, scaled, new contents); FilterCenterSupport.swift
            var center: FilterCenterContext? = nil
            for f in so.filters.prefix(max(0, filtersBelow)) where f.enabled {
                if f.kind.usesCenter && f.centerMode == .object {
                    let ctx = center ?? FilterCenterResolver.smartContext(so, space: space)
                    center = ctx
                    img = f.reresolvedCenter(ctx, modes: [.object]).applySmart(img, space: space, quad: so.quad)
                } else {
                    img = f.applySmart(img, space: space, quad: so.quad)
                }
            }
        }
        return img
    }

    /// Smart object source warped onto its quad (before smart filters).
    func smartSourceImage(_ id: UUID, _ so: SmartObjectContent, space: CanvasSpace) -> CIImage {
        var bufVersion = 0
        var bufID: ObjectIdentifier? = nil
        if case .image(let b) = so.source { bufVersion = b.version; bufID = ObjectIdentifier(b) }
        let key = SmartKey(rev: so.sourceRevision, bufferVersion: bufVersion, bufferID: bufID, quad: so.quad, warp: so.warp, w: space.width, h: space.height)
        return smartCache.get(id, key) {
            var src: CIImage
            switch so.source {
            case .image(let b): src = b.ciImage
            case .document(let st):
                // enlarged vector artwork is re-rendered at the shown size rather than scaled up from its 1:1 pixels
                src = so.stackMode.flatMap { StackModes.image(st, mode: $0) } ?? SmartVectorScale.image(st, quad: so.quad, composite: { self.composite($0) }) ?? composite(st)
            }
            let srcExt = src.extent
            // Pre-downsample for quality when shrinking a lot.
            let qb = so.quad.bounds
            let scale = min(qb.width / max(1, srcExt.width), qb.height / max(1, srcExt.height))
            if scale < 0.7 && scale > 0.001 {
                src = src.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
            let e = src.extent
            let q = so.quad.mapped { space.ciPoint($0) }
            var warped: CIImage
            if so.quad.isAffine {
                // map (minX,maxY)->tl, (maxX,maxY)->tr, (minX,minY)->bl
                let sx = (q.tr - q.tl) / e.width
                let sy = (q.tl - q.bl) / e.height
                let t = CGAffineTransform(a: sx.x, b: sx.y, c: sy.x, d: sy.y, tx: q.bl.x - sx.x * e.minX - sy.x * e.minY, ty: q.bl.y - sx.y * e.minX - sy.y * e.minY)
                warped = src.transformed(by: t, highQualityDownsample: true)
            } else {
                warped = src.applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputTopLeft": CIVector(cgPoint: q.tl), "inputTopRight": CIVector(cgPoint: q.tr),
                    "inputBottomRight": CIVector(cgPoint: q.br), "inputBottomLeft": CIVector(cgPoint: q.bl),
                ])
            }
            if let w = so.warp { warped = MeshWarp.warp(warped, from: w.from, to: w.to, space: space) }
            // Materialize for speed.
            let ext = warped.extent.intersection(space.ciCanvas.insetBy(dx: -64, dy: -64)).integral
            if ext.isEmpty { return CIImage.clearImage.cropped(to: .zero) }
            if let cg = RenderEngine.cgImage(warped, rect: ext) {
                return CIImage(cgImage: cg).translated(ext.minX, ext.minY)
            }
            return warped
        }
    }

    /// Combined gray mask (raster mask × vector mask) in CI space, or nil.
    /// `override`: live preview of an edit of the layer mask's pixels (`Document.maskOverrides`).
    func maskImage(_ layer: Layer, space: CanvasSpace, raster: Bool = true, vector: Bool = true, override: ((CIImage) -> CIImage)? = nil) -> CIImage? {
        var result: CIImage? = nil
        if raster, let m = layer.mask, m.isEnabled {
            let outside = CIImage.color(RGBA(gray: Double(m.outsideValue) / 255), space.ciCanvas.insetBy(dx: -4000, dy: -4000))
            var placed = space.place(m.buffer, at: m.origin)
            if let o = override { placed = o(placed) }
            var img = placed.composited(over: outside)
            if m.feather > 0 { img = SelectionOps.featherImage(img, radius: m.feather, direction: m.featherDirection ?? .centered).cropped(to: outside.extent) }
            if m.density < 0.999 {
                let d = CGFloat(m.density)
                img = img.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: d, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: d, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: d, w: 0), "inputBiasVector": CIVector(x: 1 - d, y: 1 - d, z: 1 - d, w: 0)])
            }
            result = img
        }
        if vector, let vm = layer.vectorMask, layer.vectorMaskEnabled, !vm.isEmpty {
            let v = vmaskCache.get(layer.id, VMaskKey(p: vm, w: space.width, h: space.height)) { ShapeRenderer.renderMask(vm, space: space) }
            let vv = v.composited(over: CIImage.color(.black, space.ciCanvas.insetBy(dx: -4000, dy: -4000)))
            result = result.map { $0.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: vv]) } ?? vv
        }
        return result
    }

    // MARK: Utilities

    /// Full appearance of a single layer (content + effects + mask + opacity) on transparent.
    func layerAppearance(_ layer: Layer, state: DocumentState) -> CIImage {
        RecipeAmbient.push(.isolated(state)); defer { RecipeAmbient.pop() }
        let space = CanvasSpace(width: state.width, height: state.height)
        var l = layer
        l.isClipped = false
        return composite(layers: [l], backdrop: CIImage.clearImage.cropped(to: space.ciCanvas), space: space, options: Options(globalLight: state.globalLight))
    }

    /// Rasterizes a layer into pixels covering the canvas plus the layer's off-canvas content (within 3× the canvas),
    /// so nothing is lost when the layer is moved back in. Hidden layers rasterize like visible ones.
    /// - includeEffects: bake the layer style (and fill opacity) in; otherwise fill opacity stays a layer attribute.
    /// - applyMasks: bake the layer / vector mask in (effects are then generated from the masked shape, as on screen).
    func rasterize(_ layer: Layer, state: DocumentState, includeEffects: Bool = true, applyMasks: Bool = false) -> RasterContent {
        RecipeAmbient.push(.isolated(state)); defer { RecipeAmbient.pop() }
        var l = layer
        l.isClipped = false
        l.isVisible = true
        l.opacity = 1
        l.blendMode = .normal
        if !includeEffects { l.effects = LayerEffects(); l.fillOpacity = 1 }
        if !applyMasks { l.mask = nil; l.vectorMask = nil }
        var rect = state.canvasRect
        // Fill layers are defined by the canvas itself (they cover it, gradients span it): never widen it for them.
        func hasFill(_ x: Layer) -> Bool { x.isFill || x.children.contains(where: hasFill) }
        if !hasFill(layer), let cb = contentBounds(layer, state: state) {
            let e = includeEffects && layer.effects.enabled ? CGFloat(layer.effects.extent) : 0
            let reach = IRect(x: -state.width, y: -state.height, width: state.width * 3, height: state.height * 3)
            rect = rect.union(IRect(enclosing: cb.insetBy(dx: -e, dy: -e)).intersection(reach))
        }
        // Text, shapes and smart objects only render a little beyond the canvas: draw into a canvas that covers `rect`.
        let space = CanvasSpace(width: rect.width, height: rect.height)
        if rect != state.canvasRect { l.translate(dx: Double(-rect.x), dy: Double(-rect.y), document: true) }
        let img = composite(layers: [l], backdrop: CIImage.clearImage.cropped(to: space.ciCanvas), space: space, options: Options(globalLight: state.globalLight))
        let buf = RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: rect.width, height: rect.height), space: space)
        return RasterContent(buffer: buf, origin: rect.origin)
    }

    /// Flattened composite as CGImage.
    func flatten(_ state: DocumentState, background: RGBA? = nil) -> CGImage? {
        let space = CanvasSpace(width: state.width, height: state.height)
        var img = composite(state)
        if let bg = background { img = img.composited(over: CIImage.color(bg, space.ciCanvas)) }
        return RenderEngine.cgImage(img, rect: space.ciCanvas)
    }

    /// Doc-space bounds of a layer's visible content (without effects).
    func contentBounds(_ layer: Layer, state: DocumentState) -> CGRect? {
        switch layer.content {
        case .raster(let r):
            guard let b = r.buffer.opaqueBounds() else { return nil }
            return b.offsetBy(dx: r.origin.x, dy: r.origin.y).cgRect
        case .text(let t): return TextRenderer.docBounds(t)
        case .shape(let s): return ShapeRenderer.visualBounds(s)
        case .smartObject(let s):
            // A mesh warp (Warp / Puppet / Perspective Warp) draws the object over its destination mesh, not its quad.
            if let w = s.warp, w.to.isValid, w.from.isValid { return w.mappedBounds(of: s.quad) }
            return s.quad.bounds
        case .fill: return state.canvasCGRect
        case .adjustment: return nil
        case .group(let g):
            if let ab = g.artboard { return ab.rect }   // an artboard draws (and clips to) its rectangle
            var u: CGRect? = nil
            for c in g.children {
                if let b = contentBounds(c, state: state) { u = u.map { $0.union(b) } ?? b }
            }
            return RepeaterRenderer.bounds(layer, g, source: u)
        }
    }

    func clearCaches() {
        textCache.removeAll(); shapeCache.removeAll(); smartCache.removeAll(); vmaskCache.removeAll(); fxCache.removeAll(); maskedCache.removeAll()
    }

    /// Forgets layers no open document has: every cache here is keyed by layer id and would otherwise keep a closed
    /// document's rendered content (and the pixel buffers it references) alive.
    func prune(keeping ids: Set<UUID>) {
        textCache.prune(keeping: ids); shapeCache.prune(keeping: ids); smartCache.prune(keeping: ids); vmaskCache.prune(keeping: ids)
        fxCache = fxCache.filter { ids.contains($0.key) }
        maskedCache = maskedCache.filter { ids.contains($0.key) }
    }

    /// Layer ids with cached renders (tests).
    var cachedLayerIDs: Set<UUID> {
        textCache.ids.union(shapeCache.ids).union(smartCache.ids).union(vmaskCache.ids).union(fxCache.keys).union(maskedCache.keys)
    }
}
