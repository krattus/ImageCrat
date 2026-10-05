import Foundation
import CoreImage
import ImageCratCore

extension FilterInstance {
    /// Applies the filter (with its opacity / blend) to an image in CI space. `quad`: where the smart object it
    /// belongs to is now (a Liquify mesh follows the object).
    func apply(_ img: CIImage, canvas: CGRect, quad: Quad? = nil) -> CIImage {
        let out: CIImage
        switch kind {
        case .filterGallery:
            var cur = img
            for e in gallery where e.visible {
                cur = e.filter.apply(cur, values: e.values, fg: colors.first ?? .black, bg: colors.count > 1 ? colors[1] : .white, canvas: canvas).cropped(to: img.extent)
            }
            out = cur
        case .fieldBlur, .irisBlur, .pathBlur, .displace:
            out = FilterExtras.apply(self, img, canvas: canvas)
        case .neuralFilter:
            out = NeuralSmartFilter.apply(self, img, canvas: canvas)
        case .recipe:
            out = RecipeRuntime.shared.smartFilter(self, img, canvas: canvas)
        case .liquify:
            out = LiquifySmartFilter.apply(self, img, space: CanvasSpace(width: Int(canvas.width.rounded()), height: Int(canvas.height.rounded())), quad: quad)
        default:
            out = kind.apply(img, values: values, colors: colors, canvas: canvas)
        }
        if opacity >= 0.999 && blendMode == .normal { return out }
        let ext = kind == .liquify ? img.extent.union(out.extent) : img.extent   // (Liquify may grow the layer)
        return out.withOpacity(opacity).blended(over: img, mode: blendMode).cropped(to: ext)
    }

    /// Applies the filter as a smart filter: through its filter mask (the result inside, the input outside).
    func applySmart(_ img: CIImage, space: CanvasSpace, quad: Quad? = nil) -> CIImage {
        let out = apply(img, canvas: space.ciCanvas, quad: quad)
        guard let m = mask, m.isEnabled, !img.extent.isEmpty, !img.extent.isInfinite else { return out }
        let outside = CIImage.color(RGBA(gray: Double(m.outsideValue) / 255), img.extent.union(out.extent).union(space.ciCanvas))
        let gray = space.place(m.buffer, at: m.origin).composited(over: outside)
        return out.mixed(with: img, mask: gray).cropped(to: img.extent.union(out.extent))
    }
}

extension FilterKind {
    // MARK: Apply

    func apply(_ input: CIImage, values v: [String: Double], colors: [RGBA], canvas: CGRect) -> CIImage {
        let ext = input.extent
        if ext.isEmpty || ext.isInfinite { return input }
        func val(_ k: String) -> Double { v[k] ?? params.first { $0.key == k }?.defaultValue ?? 0 }
        let minDim = Double(min(canvas.width, canvas.height))
        // Centre-based filters (FilterCenter.swift): the resolved centre (`cx`, `cy`, canvas-normalized, y down; the
        // canvas middle when absent) and the box radius-like parameters are relative to (`centerW` × `centerH`; the
        // canvas when absent, as before the Center option).
        func norm(_ k: String) -> CGFloat { CGFloat(v[k].flatMap { $0.isFinite ? $0 : nil } ?? params.first { $0.key == k }?.defaultValue ?? 0.5) }
        let center = CIVector(x: canvas.minX + norm(FilterCenterKey.x) * canvas.width, y: canvas.maxY - norm(FilterCenterKey.y) * canvas.height)
        let boxW = max(1, (v[FilterCenterKey.width].flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } ?? 1) * canvas.width)
        let boxH = max(1, (v[FilterCenterKey.height].flatMap { $0.isFinite && $0 > 0 ? CGFloat($0) : nil } ?? 1) * canvas.height)
        let boxMin = Double(min(boxW, boxH))
        let clamped = input.clampedToExtent()
        func finish(_ img: CIImage?) -> CIImage {
            guard let img else { return input }
            return img.cropped(to: ext)
        }
        func keepAlpha(_ img: CIImage) -> CIImage { img.cropped(to: ext).masked(byAlphaOf: input) }

        switch self {
        case .gaussianBlur:
            return input.softBlurred(val("radius")).cropped(to: ext)
        case .boxBlur:
            return finish(input.composited(over: CIImage.clearImage.cropped(to: ext.insetBy(dx: -200, dy: -200)))
                .applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: val("radius")]))
        case .motionBlur:
            return finish(clamped.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: val("distance") / 2, kCIInputAngleKey: val("angle") * .pi / 180]))
        case .radialBlur:
            return finish(clamped.applyingFilter("CIZoomBlur", parameters: [kCIInputCenterKey: center, "inputAmount": val("amount")]))
        case .spinBlur:
            // The average of copies rotated about the centre over the blur angle, added premultiplied: a true average,
            // so transparent pixels (an element on its own layer) spin symmetrically — source-over compositing of the
            // copies weighted them by their order there. 32 copies of the source, then passes that each average two
            // copies of the result turned ± a quarter of the sample spacing (halving it) until the arc of the farthest
            // pixel has samples ≤ 1 px apart: 16 fixed copies left ghost rings far from the centre.
            let c = center
            let total = val("angle") * .pi / 180
            guard total > 0.0001 else { return input }
            func turned(_ img: CIImage, _ a: Double, _ weight: Double) -> CIImage {
                img.transformed(by: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(a)).translatedBy(x: -c.x, y: -c.y)).withOpacity(weight)
            }
            func sum(_ a: CIImage, _ b: CIImage) -> CIImage { a.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: b]) }
            let copies = 32
            var img = turned(clamped, -total / 2 + total / Double(2 * copies), 1 / Double(copies))
            for i in 1..<copies { img = sum(turned(clamped, total * ((Double(i) + 0.5) / Double(copies) - 0.5), 1 / Double(copies)), img) }
            let rMax = [CGPoint(x: ext.minX, y: ext.minY), CGPoint(x: ext.maxX, y: ext.minY), CGPoint(x: ext.minX, y: ext.maxY), CGPoint(x: ext.maxX, y: ext.maxY)]
                .map { hypot(Double($0.x - c.x), Double($0.y - c.y)) }.max() ?? 0
            var spacing = total / Double(copies)
            while rMax * spacing > 1 && spacing > total / 4096 {
                img = img.insertingIntermediate(cache: false)
                img = sum(turned(img, spacing / 4, 0.5), turned(img, -spacing / 4, 0.5))
                spacing /= 2
            }
            return finish(img)
        case .lensBlur:
            return finish(clamped.applyingFilter("CIBokehBlur", parameters: [kCIInputRadiusKey: val("radius"), "inputRingAmount": val("ring"),
                                                                            "inputRingSize": val("ringSize"), "inputSoftness": val("softness")]))
        case .tiltShift:
            let fy = canvas.maxY - CGFloat(val("focus")) * canvas.height
            let half = CGFloat(val("width")) * canvas.height / 2
            let feather = max(1, CGFloat(val("feather")) * canvas.height)
            // mask: white = blurred, black = sharp
            let top = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: fy + half), "inputPoint1": CIVector(x: 0, y: fy + half + feather),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!
            let bottom = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: 0, y: fy - half), "inputPoint1": CIVector(x: 0, y: fy - half - feather),
                "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!
            let mask = top.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: bottom]).cropped(to: ext)
            return finish(clamped.applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": mask, kCIInputRadiusKey: val("radius")]))
        case .average:
            let avg = input.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ext)])
            return keepAlpha(avg.clampedToExtent().cropped(to: ext))
        case .sharpen:
            return finish(clamped.applyingFilter("CISharpenLuminance", parameters: ["inputSharpness": val("amount"), kCIInputRadiusKey: 1.69]))
        case .unsharpMask:
            return finish(clamped.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: val("radius"), kCIInputIntensityKey: val("amount") / 100]))
        case .addNoise:
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: ext)
            guard let k = Kernels.addNoiseKernel else { return input }
            return finish(k.apply(extent: ext, arguments: [input, noise, Float(val("amount") / 100 * 1.6), Float(val("mono"))]))
        case .reduceNoise:
            return finish(clamped.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": val("level"), "inputSharpness": val("sharpness")]))
        case .median:
            var img = clamped
            for _ in 0..<FilterInstance.count(val("passes")) { img = img.applyingFilter("CIMedianFilter") }
            return finish(img)
        case .twirl:
            return finish(clamped.applyingFilter("CITwirlDistortion", parameters: [kCIInputCenterKey: center, kCIInputRadiusKey: val("radius") * boxMin,
                                                                                  kCIInputAngleKey: val("angle") * .pi / 180]))
        case .pinch:
            return finish(clamped.applyingFilter("CIPinchDistortion", parameters: [kCIInputCenterKey: center,
                                                                                  kCIInputRadiusKey: val("radius") * boxMin, kCIInputScaleKey: val("amount") / 100 * 0.99]))
        case .spherize:
            return finish(clamped.applyingFilter("CIBumpDistortion", parameters: [kCIInputCenterKey: center,
                                                                                 kCIInputRadiusKey: val("radius") * boxMin, kCIInputScaleKey: val("amount") / 100]))
        case .ripple:
            guard let k = Kernels.rippleWarp else { return input }
            let a = val("amount")
            return finish(k.apply(extent: ext, roiCallback: { _, r in r.insetBy(dx: -CGFloat(a) - 2, dy: -CGFloat(a) - 2) }, image: clamped,
                                  arguments: [Float(a), Float(val("size"))]))
        case .wave:
            guard let k = Kernels.waveWarp else { return input }
            let a = val("amount")
            return finish(k.apply(extent: ext, roiCallback: { _, r in r.insetBy(dx: -CGFloat(a) - 2, dy: -CGFloat(a) - 2) }, image: clamped,
                                  arguments: [Float(a), Float(val("size")), Float(val("horizontal"))]))
        case .polarCoordinates:
            guard let k = Kernels.polarWarp else { return input }
            // the polar grid spans the centre's box (the canvas without a Center option)
            let box = CGRect(x: center.x - boxW / 2, y: center.y - boxH / 2, width: boxW, height: boxH)
            return finish(k.apply(extent: ext, roiCallback: { _, _ in ext }, image: clamped,
                                  arguments: [center, CIVector(cgRect: box), Float(val("mode") < 0.5 ? 1 : 0)]))
        case .vortex:
            return finish(clamped.applyingFilter("CIVortexDistortion", parameters: [kCIInputCenterKey: center,
                                                                                   kCIInputRadiusKey: val("radius") * boxMin, kCIInputAngleKey: val("angle") * .pi / 180]))
        case .glass:
            let tex = CIFilter(name: "CIRandomGenerator")!.outputImage!
                .transformed(by: CGAffineTransform(scaleX: CGFloat(val("scale")), y: CGFloat(val("scale"))))
                .applyingGaussianBlur(sigma: val("scale") / 2).cropped(to: ext)
            return finish(clamped.applyingFilter("CIGlassDistortion", parameters: ["inputTexture": tex, kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                                                                                  kCIInputScaleKey: val("distortion")]))
        case .mosaic:
            return keepAlpha(clamped.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: val("size"), kCIInputCenterKey: CIVector(x: 0, y: 0)]))
        case .crystallize:
            return keepAlpha(clamped.applyingFilter("CICrystallize", parameters: [kCIInputRadiusKey: val("size"), kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY)]))
        case .pointillize:
            let bg = CIImage.color(colors.count > 1 ? colors[1] : .white, ext)
            return finish(clamped.applyingFilter("CIPointillize", parameters: [kCIInputRadiusKey: val("size"), kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY)])
                .cropped(to: ext).composited(over: bg))
        case .hexagon:
            return keepAlpha(clamped.applyingFilter("CIHexagonalPixellate", parameters: [kCIInputScaleKey: val("size"), kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY)]))
        case .colorHalftone:
            return keepAlpha(clamped.applyingFilter("CICMYKHalftone", parameters: [kCIInputWidthKey: val("size") * 2, kCIInputAngleKey: val("angle") * .pi / 180,
                                                                                  kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY), kCIInputSharpnessKey: 0.7]))
        case .dotScreen:
            return keepAlpha(clamped.applyingFilter("CIDotScreen", parameters: [kCIInputWidthKey: val("size"), kCIInputAngleKey: val("angle") * .pi / 180,
                                                                               kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY), kCIInputSharpnessKey: 0.7]))
        case .lineScreen:
            return keepAlpha(clamped.applyingFilter("CILineScreen", parameters: [kCIInputWidthKey: val("size"), kCIInputAngleKey: val("angle") * .pi / 180,
                                                                                kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY), kCIInputSharpnessKey: 0.7]))
        case .emboss:
            let a = val("angle") * .pi / 180
            let h = val("height")
            let amt = val("amount") / 100
            let dx = cos(a), dy = sin(a)
            // Directional derivative kernel scaled by height/amount
            let w = CIVector(values: [
                CGFloat((-dx + dy) * amt), CGFloat(dy * amt), CGFloat((dx + dy) * amt),
                CGFloat(-dx * amt), 0, CGFloat(dx * amt),
                CGFloat((-dx - dy) * amt), CGFloat(-dy * amt), CGFloat((dx - dy) * amt),
            ], count: 9)
            let gray = clamped.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .transformed(by: .identity)
            var src = gray
            if h > 1 { src = src.applyingGaussianBlur(sigma: (h - 1) / 2) }
            // RGB-only convolution: with the RGBA variant the 0.5 bias also lands in the alpha channel, which makes an
            // opaque layer half transparent with colours brighter than its alpha (they clip differently once baked).
            let name = CIFilter(name: "CIConvolutionRGB3X3") != nil ? "CIConvolutionRGB3X3" : "CIConvolution3X3"
            let emb = src.applyingFilter(name, parameters: ["inputWeights": w, "inputBias": 0.5])
            return keepAlpha(emb)
        case .findEdges:
            let e = clamped.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: val("intensity")]).inverted()
            return keepAlpha(e)
        case .glowingEdges:
            var src = clamped
            if val("width") > 0 { src = src.applyingGaussianBlur(sigma: val("width")) }
            let e = src.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: val("intensity")])
            return keepAlpha(e.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]))
        case .edgeWork:
            let e = clamped.applyingFilter("CIEdgeWork", parameters: [kCIInputRadiusKey: val("radius")])
            return finish(e.composited(over: CIImage.color(.white, ext)))
        case .solarize:
            guard let k = Kernels.solarizeKernel else { return input }
            return finish(k.apply(extent: ext, arguments: [input]))
        case .oilPaint:
            guard let k = Kernels.kuwaharaKernel else { return input }
            let r = val("radius").rounded()
            return keepAlpha(k.apply(extent: ext, roiCallback: { _, rr in rr.insetBy(dx: -CGFloat(r) - 1, dy: -CGFloat(r) - 1) }, arguments: [clamped, Float(r)]) ?? input)
        case .comic:
            return keepAlpha(clamped.applyingFilter("CIComicEffect"))
        case .lineOverlay:
            let lo = clamped.applyingFilter("CILineOverlay", parameters: ["inputEdgeIntensity": val("edge"), "inputThreshold": val("threshold"),
                                                                        "inputContrast": val("contrast"), "inputNRNoiseLevel": 0.07, "inputNRSharpness": 0.71])
            return finish(lo.composited(over: CIImage.color(.white, ext)))
        case .bloom:
            return finish(clamped.applyingFilter("CIBloom", parameters: [kCIInputRadiusKey: val("radius"), kCIInputIntensityKey: val("intensity")]))
        case .gloom:
            return finish(clamped.applyingFilter("CIGloom", parameters: [kCIInputRadiusKey: val("radius"), kCIInputIntensityKey: val("intensity")]))
        case .kaleidoscope:
            return finish(clamped.applyingFilter("CIKaleidoscope", parameters: ["inputCount": val("count"), kCIInputCenterKey: center,
                                                                               kCIInputAngleKey: val("angle") * .pi / 180]))
        case .wind:
            let dir = val("direction") < 0.5 ? 0.0 : Double.pi
            let edges = clamped.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 3.0])
            let streak = edges.applyingFilter("CIMotionBlur", parameters: [kCIInputRadiusKey: val("distance"), kCIInputAngleKey: dir])
                .transformed(by: CGAffineTransform(translationX: CGFloat(dir == 0 ? -val("distance") / 2 : val("distance") / 2), y: 0))
            return keepAlpha(streak.applyingFilter("CILightenBlendMode", parameters: [kCIInputBackgroundImageKey: clamped]))
        case .clouds, .differenceClouds:
            let fg = colors.first ?? .black, bg = colors.count > 1 ? colors[1] : .white
            let cl = FilterKind.clouds(extent: ext, scale: val("scale"), seed: val("seed"), fg: fg, bg: bg)
            if self == .clouds { return cl.cropped(to: ext) }
            return finish(cl.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: input]).cropped(to: ext))
        case .lensFlare:
            let c = center
            let b = val("brightness") / 100
            let halo = CIFilter(name: "CILenticularHaloGenerator", parameters: [
                kCIInputCenterKey: c, kCIInputColorKey: CIColor(red: 1, green: 0.9, blue: 0.8),
                "inputHaloRadius": minDim * 0.12, "inputHaloWidth": minDim * 0.05, "inputHaloOverlap": 0.77,
                "inputStriationStrength": 0.5, "inputStriationContrast": 1.0, "inputTime": 0.0])!.outputImage!
            let sun = CIFilter(name: "CISunbeamsGenerator", parameters: [
                kCIInputCenterKey: c, kCIInputColorKey: CIColor(red: 1, green: 0.85, blue: 0.6),
                "inputSunRadius": minDim * 0.02, "inputMaxStriationRadius": 2.6, "inputStriationStrength": 0.5, "inputStriationContrast": 1.4, "inputTime": 0.0])!.outputImage!
            var flare = halo.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: sun])
            // secondary ghosts along the axis through the center
            let cc = CGPoint(x: canvas.midX, y: canvas.midY)
            for (i, t) in [0.5, 0.9, 1.3, 1.6].enumerated() {
                let p = CGPoint(x: c.x + (cc.x - c.x) * 2 * t, y: c.y + (cc.y - c.y) * 2 * t)
                let r = minDim * [0.03, 0.06, 0.02, 0.09][i]
                let ghost = CIFilter(name: "CIRadialGradient", parameters: [
                    kCIInputCenterKey: CIVector(x: p.x, y: p.y), "inputRadius0": r * 0.6, "inputRadius1": r,
                    "inputColor0": CIColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 0.25), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!
                flare = ghost.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: flare])
            }
            flare = flare.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(b), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(b), z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(b), w: 0)])
            return keepAlpha(flare.cropped(to: ext).applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: input]))
        case .vignette:
            return finish(clamped.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: center,
                                                                                 kCIInputRadiusKey: val("radius") * Double(max(boxW, boxH)) * 0.6,
                                                                                 kCIInputIntensityKey: val("intensity"), "inputFalloff": val("falloff")]))
        case .spotlight:
            let t = center
            return keepAlpha(clamped.applyingFilter("CISpotLight", parameters: [
                "inputLightPosition": CIVector(x: t.x - boxW * 0.2, y: t.y + boxH * 0.25, z: CGFloat(val("height"))),
                "inputLightPointsAt": CIVector(x: t.x, y: t.y, z: 0), "inputBrightness": val("brightness"),
                "inputConcentration": val("concentration"), "inputColor": CIColor.white]))
        case .cameraRaw:
            return keepAlpha(FilterKind.cameraRaw(clamped, v: val, ext: ext, canvas: canvas))
        case .sepia:
            return finish(clamped.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: val("intensity")]))
        case .noir: return keepAlpha(clamped.applyingFilter("CIPhotoEffectNoir"))
        case .chrome: return keepAlpha(clamped.applyingFilter("CIPhotoEffectChrome"))
        case .fade: return keepAlpha(clamped.applyingFilter("CIPhotoEffectFade"))
        case .instant: return keepAlpha(clamped.applyingFilter("CIPhotoEffectInstant"))
        case .mono: return keepAlpha(clamped.applyingFilter("CIPhotoEffectMono"))
        case .process: return keepAlpha(clamped.applyingFilter("CIPhotoEffectProcess"))
        case .tonal: return keepAlpha(clamped.applyingFilter("CIPhotoEffectTonal"))
        case .transfer: return keepAlpha(clamped.applyingFilter("CIPhotoEffectTransfer"))
        case .thermal: return keepAlpha(clamped.applyingFilter("CIThermal"))
        case .xray: return keepAlpha(clamped.applyingFilter("CIXRay"))
        case .highPass:
            guard let k = Kernels.highPassKernel else { return input }
            let bl = clamped.applyingGaussianBlur(sigma: val("radius")).cropped(to: ext)
            return finish(k.apply(extent: ext, arguments: [input, bl]))
        case .maximum:
            return finish(clamped.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: val("radius")]))
        case .minimum:
            return finish(clamped.applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: val("radius")]))
        case .filterGallery, .fieldBlur, .irisBlur, .pathBlur, .displace:
            return input   // handled by FilterInstance / FilterExtras
        case .neuralFilter, .recipe, .liquify:
            return input   // handled by FilterInstance / NeuralSmartFilter / RecipeRuntime / LiquifySmartFilter
        case .lensCorrection:
            return keepAlpha(FilterExtras.lensCorrection(clamped, v: val, ext: ext, canvas: canvas))
        case .smartSharpen:
            return finish(FilterExtras.smartSharpen(clamped, v: val, ext: ext))
        case .surfaceBlur:
            let r = val("radius"), t = val("threshold") / 255
            guard let k = FilterExtras.bilateralKernel else { return input }
            let step = max(1.0, r / 6)
            return finish(k.apply(extent: ext, roiCallback: { _, rr in rr.insetBy(dx: -CGFloat(r) - 1, dy: -CGFloat(r) - 1) },
                                  arguments: [clamped, Float(r), Float(step), Float(max(0.004, t))]))
        case .dustAndScratches:
            var med = clamped
            for _ in 0..<FilterInstance.count(val("radius")) { med = med.applyingFilter("CIMedianFilter") }
            let thr = Float(val("threshold") / 255)
            guard let k = FilterExtras.thresholdMixKernel else { return finish(med) }
            return finish(k.apply(extent: ext, arguments: [input, med.cropped(to: ext), thr]))
        case .offset:
            let dx = CGFloat(val("dx")), dy = CGFloat(-val("dy"))
            if val("wrap") > 0.5 {
                let tiled = input.cropped(to: ext).applyingFilter("CIAffineTile", parameters: [kCIInputTransformKey: NSAffineTransform()])
                return tiled.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: ext)
            }
            return input.transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: ext)
        }
    }

    static let rawToneKernel = CIColorKernel(source: """
    kernel vec4 rawTone(__sample s, float whites, float blacks, float dehaze) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        // whites / blacks: shape the ends of the tone curve
        c = c + whites * c * c * (1.0 - c) * 1.5;
        c = c + blacks * (1.0 - c) * (1.0 - c) * c * 1.5;
        // dehaze: subtract estimated veil and boost
        float veil = min(min(c.r, c.g), c.b);
        c = (c - dehaze * 0.6 * veil) / max(0.2, 1.0 - dehaze * 0.6 * veil);
        c = clamp(c, 0.0, 1.0);
        return vec4(c * s.a, s.a);
    }
    """)

    static func cameraRaw(_ input: CIImage, v: (String) -> Double, ext: CGRect, canvas: CGRect) -> CIImage {
        var img = input
        if v("temp") != 0 || v("tint") != 0 {
            img = img.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: CGFloat(6500 - v("temp") * 35), y: CGFloat(v("tint") * 1.2)),
            ])
        }
        if v("exposure") != 0 { img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: v("exposure")]) }
        if v("highlights") != 0 || v("shadows") != 0 {
            img = img.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 - max(0, -v("highlights")) / 100 * 0.9 + min(0, -v("highlights")) / 100 * 0,
                "inputShadowAmount": v("shadows") / 100,
                kCIInputRadiusKey: 8,
            ])
            if v("highlights") > 0 {
                img = img.applyingFilter("CIToneCurve", parameters: [
                    "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: 0.25), "inputPoint2": CIVector(x: 0.5, y: 0.5),
                    "inputPoint3": CIVector(x: 0.75, y: CGFloat(0.75 + v("highlights") / 100 * 0.12)), "inputPoint4": CIVector(x: 1, y: 1)])
            }
        }
        if v("whites") != 0 || v("blacks") != 0 || v("dehaze") != 0, let k = rawToneKernel {
            img = k.apply(extent: img.extent, arguments: [img, Float(v("whites") / 100), Float(-v("blacks") / 100), Float(v("dehaze") / 100)]) ?? img
        }
        if v("contrast") != 0 || v("saturation") != 0 {
            img = img.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: 1 + v("contrast") / 200 + v("dehaze") / 400,
                kCIInputSaturationKey: 1 + v("saturation") / 100,
            ])
        }
        if v("vibrance") != 0 { img = img.applyingFilter("CIVibrance", parameters: ["inputAmount": v("vibrance") / 100]) }
        if v("clarity") != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: Double(min(canvas.width, canvas.height)) * 0.02, kCIInputIntensityKey: v("clarity") / 100 * 0.8])
        }
        if v("texture") != 0 {
            img = img.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.5, kCIInputIntensityKey: v("texture") / 100 * 1.2])
        }
        if v("vignette") != 0 {
            img = img.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: canvas.midX, y: canvas.midY),
                                                                      kCIInputRadiusKey: Double(max(canvas.width, canvas.height)) * 0.55,
                                                                      kCIInputIntensityKey: v("vignette") / 100, "inputFalloff": 0.6])
        }
        if v("grain") > 0, let k = Kernels.addNoiseKernel {
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIColorClamp")
                .applyingGaussianBlur(sigma: 0.6).cropped(to: ext)
            img = k.apply(extent: ext, arguments: [img.cropped(to: ext), noise, Float(v("grain") / 100 * 0.35), Float(1)]) ?? img
        }
        return img
    }

    static let weightedAdd = CIColorKernel(source: """
    kernel vec4 weightedAdd(__sample acc, __sample n, float w) {
        return vec4(acc.rgb + vec3(n.r) * w, 1.0);
    }
    """)

    static func clouds(extent: CGRect, scale: Double, seed: Double, fg: RGBA, bg: RGBA) -> CIImage {
        let base = CIFilter(name: "CIRandomGenerator")!.outputImage!.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).applyingFilter("CIColorClamp")
        let work = extent.insetBy(dx: -4, dy: -4)
        var acc = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: work)
        var weight = 0.5, total = 0.0
        var s = scale
        for octave in 0..<7 {
            let off = CGFloat(seed * 37 + Double(octave) * 101)
            let n = base.transformed(by: CGAffineTransform(translationX: off, y: off * 0.7))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s)))
                .applyingGaussianBlur(sigma: s * 0.35).cropped(to: work)
            acc = weightedAdd?.apply(extent: work, arguments: [acc, n, Float(weight)]) ?? acc
            total += weight
            weight *= 0.5
            s = max(1, s / 2)
        }
        // normalize around 0.5 (measured mean) and boost contrast
        var px = [Float](repeating: 0, count: 4)
        let avg = acc.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: work)])
        RenderEngine.readbackContext.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: avg.extent.origin, size: CGSize(width: 1, height: 1)), format: .RGBAf, colorSpace: nil)
        let mean = Double(px[0]) / max(0.001, total)
        let k = CGFloat(2.6 / total)
        let b = CGFloat(0.5 - 2.6 * mean)
        let gray = acc.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0)])
            .applyingFilter("CIColorClamp")
        return gray.applyingFilter("CIFalseColor", parameters: ["inputColor0": fg.ciColor, "inputColor1": bg.ciColor]).cropped(to: extent)
    }
}

