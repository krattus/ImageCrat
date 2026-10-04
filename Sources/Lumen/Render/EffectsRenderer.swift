import CoreImage
import ImageCratCore

struct EffectPiece {
    var image: CIImage
    var mode: BlendMode
}

struct RenderedEffects {
    var below: [EffectPiece] = []     // drawn onto the backdrop before the layer
    var interior: [EffectPiece] = []  // inside the layer's shape (overlays, inner shadow/glow, satin)
    var above: [EffectPiece] = []     // drawn on top of the layer (stroke, bevel shading)
}

enum EffectsRenderer {
    /// `content` is the layer content (before fill opacity) in CI space. `bounds` is the content bounds in CI space.
    ///
    /// Stacking follows Photoshop (top → bottom): Bevel & Emboss, Stroke, Inner Shadow, Inner Glow, Satin,
    /// Color Overlay, Gradient Overlay, Pattern Overlay, [layer content], Outer Glow, Drop Shadow.
    /// Within a multi-instance effect the first instance in the list is drawn on top.
    static func render(_ fx: LayerEffects, content: CIImage, bounds: CGRect, space: CanvasSpace, globalLight: GlobalLight = GlobalLight()) -> RenderedEffects {
        var out = RenderedEffects()
        guard fx.enabled, fx.hasAny, !bounds.isEmpty else { return out }
        let pad = CGFloat(fx.extent + 8)
        let work = bounds.insetBy(dx: -pad, dy: -pad)
        let base = content.cropped(to: work).composited(over: CIImage.clearImage.cropped(to: work))
        let ctx = Ctx(base: base, alphaWhite: base.colorized(.white), alphaGray: base.alphaAsGray, work: work, bounds: bounds, space: space, light: globalLight)

        // Below the layer (bottom first)
        for d in fx.dropShadows.reversed() where d.enabled { out.below.append(dropShadow(d, ctx)) }
        if fx.outerGlow.enabled { out.below.append(glow(fx.outerGlow, inner: false, ctx)) }
        let bevelParts = fx.bevel.enabled ? bevel(fx.bevel, ctx) : ([], [])
        out.below += bevelParts.0

        // Inside the layer (bottom first)
        if fx.patternOverlay.enabled { out.interior.append(patternOverlay(fx.patternOverlay, ctx)) }
        for g in fx.gradientOverlays.reversed() where g.enabled { out.interior.append(gradientOverlay(g, ctx)) }
        for c in fx.colorOverlays.reversed() where c.enabled { out.interior.append(EffectPiece(image: base.colorized(c.color.withAlpha(c.opacity)), mode: c.blendMode)) }
        if fx.satin.enabled { out.interior.append(satin(fx.satin, ctx)) }
        if fx.innerGlow.enabled { out.interior.append(glow(fx.innerGlow, inner: true, ctx)) }
        for d in fx.innerShadows.reversed() where d.enabled { out.interior.append(innerShadow(d, ctx)) }

        // Above: strokes, then the bevel's interior shading on top
        for st in fx.strokes.reversed() where st.enabled && st.size > 0 { out.above.append(stroke(st, ctx)) }
        out.above += bevelParts.1
        return out
    }

    private struct Ctx {
        let base: CIImage
        let alphaWhite: CIImage
        let alphaGray: CIImage       // opaque gray, white = inside
        var invGray: CIImage { alphaGray.inverted() }
        let work: CGRect
        let bounds: CGRect
        let space: CanvasSpace
        let light: GlobalLight
    }

    private static func offset(_ angle: Double, _ dist: Double) -> CGAffineTransform {
        let a = angle * .pi / 180
        return CGAffineTransform(translationX: CGFloat(-cos(a) * dist), y: CGFloat(-sin(a) * dist))
    }

    // MARK: Helpers

    static let noiseKernel = CIColorKernel(source: """
    kernel vec4 alphaNoise(__sample s, __sample n, float amt) {
        float f = clamp(1.0 - amt * n.r, 0.0, 1.0);
        return s * f;
    }
    """)

    /// Dithers alpha with random noise (Photoshop's "Noise" in shadows and glows).
    static func addNoise(_ img: CIImage, amount: Double) -> CIImage {
        guard amount > 0.001, let k = noiseKernel else { return img }
        let n = CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIColorClamp").cropped(to: img.extent)
        return k.apply(extent: img.extent, arguments: [img, n, Float(amount)]) ?? img
    }

    /// Distance-based ramp (1 at the shape edge → 0 at `size` px away) — used by Precise glows.
    static func distanceRamp(_ alphaGray: CIImage, size: Double, inside: Bool, work: CGRect) -> CIImage {
        let maskImg = inside ? alphaGray.inverted() : alphaGray
        let big = work.insetBy(dx: -CGFloat(size) - 4, dy: -CGFloat(size) - 4)
        let finite = maskImg.cropped(to: work).composited(over: CIImage.color(inside ? .white : .black, big))
        let d = finite.applyingFilter("CIDistanceGradientFromRedMask", parameters: ["inputMaximumDistance": max(1, size)]).cropped(to: work)
        return d.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: -1, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: -1, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 1)]).applyingFilter("CIColorClamp")
    }

    // MARK: Shadows

    private static func dropShadow(_ d: ShadowEffect, _ c: Ctx) -> EffectPiece {
        let angle = d.useGlobalLight ? c.light.angle : d.angle
        let spread = d.size * d.spread / 100
        var sh = c.alphaWhite.dilatedAlpha(spread)
        sh = sh.softBlurred(max(0, (d.size - spread)) / 2.2)
        sh = d.contour.apply(toAlphaOf: sh)
        sh = addNoise(sh, amount: d.noise / 100)
        sh = sh.transformed(by: offset(angle, d.distance))
        if d.layerKnocksOut {
            let area = sh.extent.union(c.work)
            sh = sh.masked(byGray: c.invGray.composited(over: CIImage.color(.white, area)).cropped(to: area))
        }
        return EffectPiece(image: sh.colorized(d.color.withAlpha(d.opacity)), mode: d.blendMode)
    }

    private static func innerShadow(_ d: ShadowEffect, _ c: Ctx) -> EffectPiece {
        let angle = d.useGlobalLight ? c.light.angle : d.angle
        let choke = d.size * d.spread / 100
        let big = c.work.insetBy(dx: -CGFloat(d.distance + d.size * 2), dy: -CGFloat(d.distance + d.size * 2))
        var inv = CIImage.color(.white, big).masked(byGray: c.invGray.clampedToExtent().cropped(to: big))
        inv = inv.dilatedAlpha(choke)
        inv = inv.transformed(by: offset(angle, d.distance)).softBlurred(max(0, d.size - choke) / 2.2)
        inv = d.contour.apply(toAlphaOf: inv)
        inv = addNoise(inv, amount: d.noise / 100)
        let sh = inv.cropped(to: c.work).colorized(d.color.withAlpha(d.opacity)).masked(byGray: c.alphaGray)
        return EffectPiece(image: sh, mode: d.blendMode)
    }

    // MARK: Glows

    private static func glow(_ g: GlowEffect, inner: Bool, _ c: Ctx) -> EffectPiece {
        let spread = g.size * g.spread / 100
        // Intensity ramp in gray (1 = strongest, at the edge / center)
        var ramp: CIImage
        if g.technique == .precise {
            if inner && g.source == .center {
                ramp = distanceRamp(c.alphaGray, size: g.size, inside: false, work: c.work).inverted()
            } else {
                ramp = distanceRamp(c.alphaGray, size: max(1, g.size - spread), inside: inner, work: c.work)
            }
        } else {
            // Photoshop's softer glow is a Gaussian of σ ≈ 0.41 × size (measured on real files: a 70 px glow fades out at ~60 px)
            let sigma = 0.41
            var a: CIImage
            if inner {
                if g.source == .edge {
                    let big = c.work.insetBy(dx: -CGFloat(g.size * 2), dy: -CGFloat(g.size * 2))
                    a = CIImage.color(.white, big).masked(byGray: c.invGray.clampedToExtent().cropped(to: big))
                    a = a.dilatedAlpha(spread).softBlurred(max(0.5, g.size - spread) * sigma).cropped(to: c.work)
                } else {
                    a = c.alphaWhite.erodedAlpha(max(1, g.size - spread)).softBlurred(max(0.5, g.size) * sigma).cropped(to: c.work)
                }
            } else {
                a = c.alphaWhite.dilatedAlpha(spread).softBlurred(max(0.5, g.size - spread) * sigma).cropped(to: c.work)
            }
            ramp = a.composited(over: CIImage.clearImage.cropped(to: c.work)).alphaAsGray
        }
        // Range: the contour spans the outer `range` of the ramp and the rest is full strength (Photoshop's default 50 %
        // puts full strength where the blurred shape reaches half coverage, i.e. at the edge)
        let r = clamp(g.range / 100, 0.01, 1)
        if r < 0.999 {
            let k = CGFloat(1 / r)
            ramp = ramp.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)]).applyingFilter("CIColorClamp")
        }
        ramp = g.contour.apply(toGray: ramp)
        var img: CIImage
        if g.useGradient {
            // gradient position 0 at the edge (full intensity) → 1 at the far end
            var lutG = g.gradient
            if g.jitter > 0 {
                var rng = SeededRandom(seed: 99)
                lutG.stops = lutG.stops.map { var s = $0; s.location = clamp(s.location + (rng.next() - 0.5) * g.jitter / 100 * 0.3, 0, 1); return s }
            }
            let lut = Kernels.gradientLUT(lutG, reverse: true)
            img = ramp.applyingFilter("CIColorMap", parameters: ["inputGradientImage": lut])
            let presence = ramp.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 50, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 50, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 50, y: 0, z: 0, w: 0)]).applyingFilter("CIColorClamp")
            img = img.masked(byGray: presence).withOpacity(g.opacity)
        } else {
            img = ramp.colorizedGray(g.color.withAlpha(g.opacity))
        }
        img = addNoise(img, amount: g.noise / 100)
        img = img.cropped(to: c.work)
        img = inner ? img.masked(byGray: c.alphaGray) : img.masked(byGray: c.invGray)
        return EffectPiece(image: img, mode: g.blendMode)
    }

    // MARK: Bevel

    /// Returns (pieces below the layer, pieces on top of the layer).
    private static func bevel(_ b: BevelEffect, _ c: Ctx) -> ([EffectPiece], [EffectPiece]) {
        let (hi, sh) = bevelShading(b, c)
        let hiColor = b.highlightColor.withAlpha(b.highlightOpacity), shColor = b.shadowColor.withAlpha(b.shadowOpacity)
        func pieces(_ h: CIImage, _ s: CIImage, mask: CIImage) -> [EffectPiece] {
            [EffectPiece(image: s.masked(byGray: mask).colorizedGray(shColor), mode: b.shadowMode),
             EffectPiece(image: h.masked(byGray: mask).colorizedGray(hiColor), mode: b.highlightMode)]
        }
        switch b.style {
        case .innerBevel:
            return ([], pieces(hi, sh, mask: c.alphaGray))
        case .outerBevel:
            return (pieces(hi, sh, mask: c.invGray), [])
        case .emboss:
            return (pieces(hi, sh, mask: c.invGray), pieces(hi, sh, mask: c.alphaGray))
        case .pillowEmboss:
            return (pieces(sh, hi, mask: c.invGray), pieces(hi, sh, mask: c.alphaGray))
        }
    }

    /// Returns (highlight, shadow) gray intensity images.
    private static func bevelShading(_ b: BevelEffect, _ c: Ctx) -> (CIImage, CIImage) {
        let work = c.work
        let size = max(1, b.size)
        // Float height map from the exact distance to the layer's edge (see BevelHeightMap): the style decides which side
        // of the edge the bevel occupies, the technique its profile; Soften smooths it. No 8-bit or half-float steps
        // and no downsampled blur pyramid before the shading takes its derivative.
        let params = BevelHeightMap.Params(style: b.style, technique: b.technique, size: size, soften: max(0, b.soften),
                                           contour: b.contourEnabled ? profileContourTable(b) : nil)
        var height = BevelHeightMap.image(alphaGray: c.alphaGray, work: work, params: params)
        // Texture: pattern luminance bumps the height map inside the shape
        if b.textureEnabled, let p = PatternLibrary.pattern(id: b.texturePatternID, custom: AppModel.shared.customPatterns) {
            let s = CGFloat(max(0.01, b.textureScale))
            let tex = p.image.ciImage.transformed(by: CGAffineTransform(scaleX: s, y: s))
                .applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()]).cropped(to: work)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            var d = CGFloat(b.textureDepth / 100 * 0.15)
            if b.textureInvert { d = -d }
            let bump = tex.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: d, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: d, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: d, w: 0), "inputBiasVector": CIVector(x: -d / 2, y: -d / 2, z: -d / 2, w: 0)])
                .masked(byGray: c.alphaGray)
            height = bump.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: height]).cropped(to: work)
        }
        let angle = b.useGlobalLight ? c.light.angle : b.angle
        let altitude = b.useGlobalLight ? c.light.altitude : b.altitude
        let a = angle * .pi / 180
        let alt = max(1, min(89, altitude)) * .pi / 180
        let cot = cos(alt) / sin(alt)
        let light = CIVector(x: CGFloat(cos(a) * cot), y: CGFloat(sin(a) * cot))
        // the height spans 0…1 over `size` px: scaling the slope by `size` keeps the look independent of Size
        let depth = Float(size * b.depth / 100 * 0.45)
        guard let k = Kernels.bevelKernel,
              let shade = k.apply(extent: work, roiCallback: { _, r in r.insetBy(dx: -2, dy: -2) },
                                  arguments: [height.clampedToExtent(), light, depth, Float(b.directionUp ? 1 : -1)]) else {
            let z = CIImage.color(.black, work)
            return (z, z)
        }
        var hi = shade.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 1, y: 0, z: 0, w: 0), "inputBVector": CIVector(x: 1, y: 0, z: 0, w: 0)])
        var sh = shade.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 1, z: 0, w: 0)])
        // Gloss contour reshapes the lighting response
        if !b.glossContour.isLinear {
            hi = b.glossContour.apply(toGray: hi.applyingFilter("CIColorClamp"))
            sh = b.glossContour.apply(toGray: sh.applyingFilter("CIColorClamp"))
        }
        return (hi.cropped(to: work), sh.cropped(to: work))
    }

    /// The bevel's Contour with its Range, as a fine table (1024 entries, interpolated linearly by the height map), or nil
    /// when it leaves the profile unchanged.
    static func profileContourTable(_ b: BevelEffect) -> [Float]? {
        let r = clamp(b.contourRange / 100, 0.05, 1)
        if b.contour.isLinear && abs(r - 1) < 0.001 { return nil }
        let n = 1024
        let customLUT = b.contour.preset == .custom ? b.contour.custom.lut(n) : nil
        func base(_ u: Double) -> Double {
            if let l = customLUT {
                let x = clamp(u, 0, 1) * Double(n - 1), i0 = Int(x), i1 = min(i0 + 1, n - 1), f = x - Double(i0)
                return clamp(l[i0] * (1 - f) + l[i1] * f, 0, 1)
            }
            return b.contour.value(u)
        }
        return (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            if abs(r - 1) < 0.001 { return Float(base(t)) }
            return t < 1 - r ? 0 : Float(base(clamp((t - (1 - r)) / r, 0, 1)))
        }
    }

    // MARK: Satin, overlays, stroke

    private static func satin(_ s: SatinEffect, _ c: Ctx) -> EffectPiece {
        let a = s.angle * .pi / 180
        let dx = CGFloat(cos(a) * s.distance), dy = CGFloat(sin(a) * s.distance)
        let blurA = c.alphaGray.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: dy))
        let blurB = c.alphaGray.clampedToExtent().transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
        var diff = blurA.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blurB])
            .applyingGaussianBlur(sigma: max(0.5, s.size / 2.2)).cropped(to: c.work)
        diff = s.contour.apply(toGray: diff.applyingFilter("CIColorClamp"))
        if s.invert { diff = diff.inverted() }
        return EffectPiece(image: diff.colorizedGray(s.color.withAlpha(s.opacity)).masked(byGray: c.alphaGray), mode: s.blendMode)
    }

    private static func patternOverlay(_ p: PatternOverlayEffect, _ c: Ctx) -> EffectPiece {
        let img = PaintRenderer.image(.pattern(id: p.patternID, scale: p.scale), bounds: c.space.docRect(c.work), space: c.space)
        return EffectPiece(image: img.masked(byGray: c.alphaGray).withOpacity(p.opacity), mode: p.blendMode)
    }

    private static func gradientOverlay(_ g: GradientOverlayEffect, _ c: Ctx) -> EffectPiece {
        let img = PaintRenderer.image(.gradient(g.fill), bounds: c.space.docRect(c.work), refBounds: c.space.docRect(c.bounds), space: c.space)
        return EffectPiece(image: img.masked(byGray: c.alphaGray).withOpacity(g.opacity), mode: g.blendMode)
    }

    private static func stroke(_ s: StrokeEffect, _ c: Ctx) -> EffectPiece {
        let aw = c.alphaWhite
        let region: CIImage
        switch s.position {
        case .outside:
            region = aw.dilatedAlpha(s.size).applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: aw])
        case .inside:
            region = aw.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: aw.erodedAlpha(s.size)])
        case .center:
            region = aw.dilatedAlpha(s.size / 2).applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: aw.erodedAlpha(s.size / 2)])
        }
        let paintImg = PaintRenderer.image(s.paint, bounds: c.space.docRect(region.extent), refBounds: c.space.docRect(c.bounds), space: c.space)
        return EffectPiece(image: paintImg.masked(byAlphaOf: region).withOpacity(s.opacity), mode: s.blendMode)
    }
}

extension CIImage {
    /// Uses the gray level as alpha of a solid color.
    func colorizedGray(_ c: RGBA) -> CIImage {
        let col = CIImage.color(c.withAlpha(1), extent)
        return col.masked(byGray: self).withOpacity(c.a)
    }
}
