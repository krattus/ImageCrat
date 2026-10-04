import Foundation
import CoreImage
import Vision
import ImageCratCore

// MARK: - Filter definitions

enum NeuralFilterKind: String, CaseIterable, Identifiable, Codable {
    case skinSmoothing, smartPortrait, colorize, depthBlur, superZoom, jpegArtifacts, photoRestoration, styleTransfer, harmonization, colorTransfer, landscapeMixer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skinSmoothing: return "Skin Smoothing"
        case .smartPortrait: return "Smart Portrait"
        case .colorize: return "Colorize"
        case .depthBlur: return "Depth Blur"
        case .superZoom: return "Super Zoom"
        case .jpegArtifacts: return "JPEG Artifacts Removal"
        case .photoRestoration: return "Photo Restoration"
        case .styleTransfer: return "Style Transfer"
        case .harmonization: return "Harmonization"
        case .colorTransfer: return "Color Transfer"
        case .landscapeMixer: return "Landscape Mixer"
        }
    }

    var group: String {
        switch self {
        case .skinSmoothing, .smartPortrait: return "Portraits"
        case .styleTransfer, .landscapeMixer: return "Creative"
        case .colorize, .harmonization, .colorTransfer: return "Color"
        case .depthBlur, .superZoom: return "Photography"
        case .jpegArtifacts, .photoRestoration: return "Restoration"
        }
    }

    static let groups = ["Portraits", "Creative", "Color", "Photography", "Restoration"]

    var symbol: String {
        switch self {
        case .skinSmoothing: return "face.smiling"
        case .smartPortrait: return "person.crop.square"
        case .colorize: return "paintpalette"
        case .depthBlur: return "camera.aperture"
        case .superZoom: return "plus.magnifyingglass"
        case .jpegArtifacts: return "square.grid.3x3"
        case .photoRestoration: return "photo.badge.checkmark"
        case .styleTransfer: return "paintbrush.pointed"
        case .harmonization: return "circle.lefthalf.filled"
        case .colorTransfer: return "drop.halffull"
        case .landscapeMixer: return "mountain.2"
        }
    }

    /// Models required (downloaded on first use).
    var models: [String] {
        switch self {
        case .colorize: return [NeuralModelID.ddcolor]
        case .depthBlur: return [NeuralModelID.depth]
        case .superZoom: return [NeuralModelID.esrgan]
        case .jpegArtifacts: return [NeuralModelID.nafnetDenoise]
        case .photoRestoration: return [NeuralModelID.nafnetDenoise]
        default: return []
        }
    }

    /// Optional models used by some settings.
    var optionalModels: [String] {
        switch self {
        case .superZoom: return [NeuralModelID.gfpgan, NeuralModelID.nafnetDenoise]
        case .photoRestoration: return [NeuralModelID.gfpgan, NeuralModelID.lama]
        default: return []
        }
    }

    var isCloud: Bool { self == .landscapeMixer }

    /// Changes the image size (always output to a new document).
    var resizes: Bool { self == .superZoom }

    var note: String {
        switch self {
        case .skinSmoothing: return "Detects faces (Vision) and smooths skin only."
        case .smartPortrait: return "Light direction and brightness run on-device. Expression, age, gaze, hair and head direction need a Generative AI provider."
        case .colorize: return "DDColor predicts colour; lightness is kept from the original. Click the preview to add a colour hint (foreground colour)."
        case .depthBlur: return "Depth Anything V2 estimates depth. Click the preview to set the focal point."
        case .superZoom: return "Real-ESRGAN ×2/×4 with tiling. Output opens as a new document."
        case .jpegArtifacts: return "Deblocking + NAFNet restoration."
        case .photoRestoration: return "NAFNet enhancement, GFPGAN faces, scratch reduction."
        case .styleTransfer: return "Neural mode trains a small Create ML style model once per style (cached). Fast mode uses Filter Gallery looks."
        case .harmonization: return "Matches the layer's colour and luminance to the layers below it."
        case .colorTransfer: return "Transfers the colour statistics of a reference image or preset."
        case .landscapeMixer: return "Requires a Generative AI provider."
        }
    }

    var params: [FilterParam] {
        func s(_ k: String, _ l: String, _ r: ClosedRange<Double>, _ d: Double, _ u: String = "") -> FilterParam { FilterParam(key: k, label: l, kind: .slider(r), defaultValue: d, unit: u) }
        func t(_ k: String, _ l: String, _ d: Double) -> FilterParam { FilterParam(key: k, label: l, kind: .toggle, defaultValue: d) }
        func c(_ k: String, _ l: String, _ o: [String], _ d: Double = 0) -> FilterParam { FilterParam(key: k, label: l, kind: .choice(o), defaultValue: d) }
        switch self {
        case .skinSmoothing: return [s("blur", "Blur", 0...100, 50), s("smoothness", "Smoothness", -50...50, 0)]
        case .smartPortrait: return [
            s("lightDirection", "Light Direction", -50...50, 0), s("lightStrength", "Light Strength", 0...100, 0), s("brightness", "Face Brightness", -50...50, 0),
            s("happiness", "Happiness ☁︎", -50...50, 0), s("surprise", "Surprise ☁︎", -50...50, 0), s("anger", "Anger ☁︎", -50...50, 0),
            s("age", "Facial Age ☁︎", -50...50, 0), s("gaze", "Gaze ☁︎", -50...50, 0), s("hair", "Hair Thickness ☁︎", -50...50, 0),
            s("head", "Head Direction ☁︎", -50...50, 0)]
        case .colorize: return [s("saturation", "Saturation", 0...200, 100, "%"), s("cyanRed", "Cyan / Red", -50...50, 0), s("magentaGreen", "Magenta / Green", -50...50, 0),
                                s("yellowBlue", "Yellow / Blue", -50...50, 0), s("strength", "Strength", 0...100, 100, "%")]
        case .depthBlur: return [
            t("focusSubject", "Focus Subject", 1), s("focalDistance", "Focal Distance", 0...100, 50), s("focalRange", "Focal Range", 0...100, 20),
            s("strength", "Blur Strength", 0...100, 50), s("haze", "Haze", 0...100, 0), s("warmth", "Warmness", -50...50, 0),
            s("brightness", "Brightness", -50...50, 0), s("saturation", "Saturation", -50...50, 0), s("grain", "Grain", 0...100, 0),
            t("depthMap", "Output Depth Map Only", 0)]
        case .superZoom: return [c("scale", "Zoom", ["×2", "×4"]), t("faces", "Enhance Face Details", 1), s("jpeg", "Remove JPEG Artifacts", 0...100, 0),
                                 s("noise", "Reduce Noise", 0...100, 0), s("sharpen", "Sharpen", 0...100, 0)]
        case .jpegArtifacts: return [c("strength", "Strength", ["Low", "Medium", "High"], 1)]
        case .photoRestoration: return [s("enhance", "Photo Enhancement", 0...100, 50), s("face", "Enhance Face", 0...100, 50), s("scratch", "Scratch Reduction", 0...100, 0),
                                        s("contrast", "Contrast", -50...50, 0), s("color", "Color Enhancement", 0...100, 0),
                                        s("colorNoise", "Color Noise Reduction", 0...100, 0), s("halftone", "Halftone Reduction", 0...100, 0)]
        case .styleTransfer: return [c("style", "Style", StyleTransfer.presets.map(\.name)), c("mode", "Mode", ["Neural (train once)", "Fast (Filter Gallery)"]),
                                     s("strength", "Style Strength", 0...100, 100, "%"), t("preserveColor", "Preserve Color", 0), s("blur", "Background Blur", 0...100, 0)]
        case .harmonization: return [s("strength", "Strength", 0...100, 50), s("cyanRed", "Cyan / Red", -50...50, 0), s("magentaGreen", "Magenta / Green", -50...50, 0),
                                     s("yellowBlue", "Yellow / Blue", -50...50, 0), s("saturation", "Saturation", -50...50, 0), s("brightness", "Brightness", -50...50, 0)]
        case .colorTransfer: return [c("preset", "Reference", ColorTransfer.presets.map(\.name) + ["Custom Image…"]), s("luminance", "Luminance", 0...200, 100, "%"),
                                     s("intensity", "Color Intensity", 0...200, 100, "%"), s("strength", "Strength", 0...100, 100, "%"), t("preserveLuminance", "Preserve Luminance", 1)]
        case .landscapeMixer: return [c("preset", "Preset", ["Spring", "Summer", "Autumn", "Winter", "Sunset", "Night"]), s("strength", "Strength", 0...100, 50)]
        }
    }

    func defaults() -> [String: Double] { Dictionary(uniqueKeysWithValues: params.map { ($0.key, $0.defaultValue) }) }
}

/// Everything the dialog passes to a run.
struct NeuralContext {
    var below: CGImage? = nil            // composite of layers below (Harmonization)
    var reference: CGImage? = nil        // Color Transfer custom reference
    var focalPoint: CGPoint? = nil       // normalized 0…1 (Depth Blur)
    var hints: [(CGPoint, RGBA)] = []    // normalized points (Colorize)
    var preview = false
    var progress: ((String, Double) -> Void)? = nil
}

enum NeuralFilterError: LocalizedError {
    case noFace, needsProvider(String), missingInput(String)
    var errorDescription: String? {
        switch self {
        case .noFace: return "No face was found."
        case .needsProvider(let f): return "\(f) requires a Generative AI provider."
        case .missingInput(let m): return m
        }
    }
}

enum NeuralFilterEngine {
    /// Applies the enabled filters in list order.
    static func runStack(_ kinds: [NeuralFilterKind], values: [NeuralFilterKind: [String: Double]], input: CGImage, ctx: NeuralContext) async throws -> CGImage {
        var cur = input
        for k in NeuralFilterKind.allCases where kinds.contains(k) {
            try Task.checkCancellation()
            ctx.progress?(k.title, 0)
            cur = try await run(k, values: values[k] ?? k.defaults(), input: cur, ctx: ctx)
        }
        return cur
    }

    static func run(_ k: NeuralFilterKind, values v: [String: Double], input cg: CGImage, ctx: NeuralContext) async throws -> CGImage {
        func val(_ key: String) -> Double { v[key] ?? k.params.first { $0.key == key }?.defaultValue ?? 0 }
        let prog: (Double) -> Void = { p in ctx.progress?(k.title, p) }
        switch k {
        case .skinSmoothing:
            return try PortraitFilters.skinSmoothing(cg, blur: val("blur"), smoothness: val("smoothness"))
        case .smartPortrait:
            return try await PortraitFilters.smartPortrait(cg, v: val)
        case .colorize:
            let hints = ctx.hints.map { (CGPoint(x: $0.0.x * CGFloat(cg.width), y: $0.0.y * CGFloat(cg.height)), $0.1) }
            let out = try await Colorizer.colorize(cg, saturation: val("saturation") / 100,
                                                   abShift: (Float(val("cyanRed") * 0.6 - val("magentaGreen") * 0.3), Float(-val("magentaGreen") * 0.3 - val("yellowBlue") * 0.6)),
                                                   hints: hints, progress: prog)
            return blend(cg, out, val("strength") / 100)
        case .depthBlur:
            return try await DepthBlur.apply(cg, v: val, focal: ctx.focalPoint)
        case .superZoom:
            var src = cg
            let clean = max(val("jpeg"), val("noise")) / 100
            if clean > 0.01, Restoration.isAvailable(.denoise) || (!ctx.preview && ModelManager.shared.canObtain(NeuralModelID.nafnetDenoise)) {   // (skipped when it can only come from a models pack)
                if val("jpeg") > 0 { src = Deblock.apply(src, strength: val("jpeg") / 100) }
                src = try await Restoration.run(src, .denoise, strength: clean)
            }
            let f = val("scale") >= 0.5 ? 4.0 : 2.0
            var out = try await SuperResolution.upscale(src, factor: f, progress: prog)
            if val("faces") > 0.5, FaceTools.gfpganAvailable || (!ctx.preview && ModelManager.shared.canObtain(NeuralModelID.gfpgan)), let (r, _) = try await FaceTools.restoreFaces(out, strength: 0.8) { out = r }
            if val("sharpen") > 0 {
                out = NImg.cg(CIImage(cgImage: out).applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: val("sharpen") / 100])) ?? out
            }
            return out
        case .jpegArtifacts:
            let st = [0.4, 0.7, 1.0][max(0, min(2, Int(val("strength"))))]
            let deblocked = Deblock.apply(cg, strength: st)
            return try await Restoration.run(deblocked, .denoise, strength: st)
        case .photoRestoration:
            return try await PhotoRestoration.apply(cg, v: val, preview: ctx.preview)
        case .styleTransfer:
            return try await StyleTransfer.apply(cg, v: val, progress: prog)
        case .harmonization:
            guard let below = ctx.below else { throw NeuralFilterError.missingInput("Harmonization needs visible layers below the active layer.") }
            return Harmonize.harmonize(cg, to: below, v: val)
        case .colorTransfer:
            let idx = Int(val("preset"))
            let ref: LabStats
            if idx >= ColorTransfer.presets.count {
                guard let r = ctx.reference, let st = ColorStats.lab(CIImage(cgImage: r)) else { throw NeuralFilterError.missingInput("Choose a reference image.") }
                ref = st
            } else { ref = ColorTransfer.presets[idx].stats }
            return ColorTransfer.transfer(cg, to: ref, luminance: val("luminance") / 100, intensity: val("intensity") / 100,
                                          strength: val("strength") / 100, preserveLuminance: val("preserveLuminance") > 0.5)
        case .landscapeMixer:
            guard let hook = NeuralCloudHook.mixLandscape else { throw NeuralFilterError.needsProvider("Landscape Mixer") }
            let names = ["spring", "summer", "autumn", "winter", "sunset", "night"]
            let out = try await hook(cg, "Transform this landscape to \(names[max(0, min(5, Int(val("preset"))))]) (strength \(Int(val("strength")))%).")
            return NImg.resized(out, cg.width, cg.height)
        }
    }

    /// Linear mix of two same-size images (keeps `a`'s alpha).
    static func blend(_ a: CGImage, _ b: CGImage, _ t: Double) -> CGImage {
        if t >= 0.999 { return b }
        if t <= 0.001 { return a }
        let A = CIImage(cgImage: a), B = CIImage(cgImage: b)
        let m = CIImage(color: CIColor(red: CGFloat(t), green: CGFloat(t), blue: CGFloat(t))).cropped(to: A.extent)
        return NImg.cg(B.mixed(with: A, mask: m), rect: A.extent) ?? b
    }
}

// MARK: - Smart filter output

enum NeuralSmartFilter {
    /// Baked neural result stored in `payload` (canvas-size); shown inside the smart object's alpha.
    static func apply(_ f: FilterInstance, _ img: CIImage, canvas: CGRect) -> CIImage {
        guard let p = f.payload, CGFloat(p.width) == canvas.width, CGFloat(p.height) == canvas.height else { return img }
        let placed = p.ciImage.transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
        return placed.cropped(to: img.extent).masked(byAlphaOf: img).cropped(to: img.extent)
    }
}

// MARK: - Portrait filters

enum PortraitFilters {
    /// Person segmentation mask (gray, image size), or nil.
    static func personMask(_ cg: CGImage) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .accurate
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let h = VNImageRequestHandler(cgImage: cg)
        guard (try? h.perform([req])) != nil, let pb = req.results?.first?.pixelBuffer else { return nil }
        let m = CIImage(cvPixelBuffer: pb)
        return m.transformed(by: CGAffineTransform(scaleX: CGFloat(cg.width) / m.extent.width, y: CGFloat(cg.height) / m.extent.height))
    }

    /// Soft skin mask (CI space, gray) for detected faces.
    static func skinMask(_ cg: CGImage, faces: [DetectedFace]) -> CIImage {
        let W = cg.width, H = cg.height
        let buf = PixelBuffer(width: W, height: H, format: .gray)
        let c = buf.context
        for f in faces {
            // face region: ellipse from jaw contour extended upward to the forehead
            let b = f.bounds
            let ell = CGRect(x: b.minX - b.width * 0.02, y: b.minY - b.height * 0.28, width: b.width * 1.04, height: b.height * 1.3)
            c.setFillColor(gray: 1, alpha: 1)
            c.fillEllipse(in: ell)
            if f.contour.count > 2 {
                let p = CGMutablePath(); p.addLines(between: f.contour); p.closeSubpath()
                c.addPath(p); c.fillPath()
            }
            // exclude eyes, brows, lips, nostrils
            c.setFillColor(gray: 0, alpha: 1)
            let r = b.width * 0.035
            for part in [f.leftEye, f.rightEye, f.lips] where part.count > 2 {
                let p = CGMutablePath(); p.addLines(between: part); p.closeSubpath()
                c.addPath(p); c.setLineWidth(r * 2); c.setStrokeColor(gray: 0, alpha: 1); c.drawPath(using: .fillStroke)
            }
            if f.brows.count > 2 {
                c.setLineWidth(b.width * 0.06); c.setLineCap(.round)
                let half = f.brows.count / 2
                for seg in [Array(f.brows[..<half]), Array(f.brows[half...])] where seg.count > 1 { c.addLines(between: seg); c.strokePath() }
            }
        }
        buf.markDirty()
        let space = CanvasSpace(width: W, height: H)
        var m = space.place(buf, at: .zero)
        // skin-colour likelihood relative to the median face colour
        let img = CIImage(cgImage: cg)
        if let ref = faces.first.flatMap({ medianSkin(cg, $0) }), let k = skinKernel {
            let like = k.apply(extent: img.extent, arguments: [img, CIVector(x: CGFloat(ref.0), y: CGFloat(ref.1))]) ?? img
            m = m.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: like])
        }
        if let pm = personMask(cg) { m = m.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: pm]) }
        let soft = Double(faces.map { $0.bounds.width }.max() ?? 100) * 0.02
        return m.clampedToExtent().applyingGaussianBlur(sigma: soft).cropped(to: img.extent)
    }

    static let skinKernel = CIColorKernel(source: """
    kernel vec4 skinLike(__sample s, vec2 ref) {
        vec3 c = s.a > 0.0 ? s.rgb / s.a : vec3(0.0);
        float cb = -0.1687 * c.r - 0.3313 * c.g + 0.5 * c.b;
        float cr = 0.5 * c.r - 0.4187 * c.g - 0.0813 * c.b;
        float d = length(vec2(cb, cr) - ref);
        float w = 1.0 - smoothstep(0.035, 0.09, d);
        return vec4(w, w, w, 1.0);
    }
    """)

    /// Median CbCr of the cheeks.
    static func medianSkin(_ cg: CGImage, _ f: DetectedFace) -> (Float, Float)? {
        let b = f.bounds
        let r = CGRect(x: b.minX + b.width * 0.15, y: b.minY + b.height * 0.45, width: b.width * 0.7, height: b.height * 0.2).integral
        guard let crop = cg.cropping(to: r) else { return nil }
        let p = PlanarImage.rgb(crop, width: 32, height: 12)
        let n = p.width * p.height
        var cbs: [Float] = [], crs: [Float] = []
        for i in 0..<n {
            let R = p.data[i], G = p.data[n + i], B = p.data[2 * n + i]
            cbs.append(-0.1687 * R - 0.3313 * G + 0.5 * B); crs.append(0.5 * R - 0.4187 * G - 0.0813 * B)
        }
        cbs.sort(); crs.sort()
        return (cbs[n / 2], crs[n / 2])
    }

    static func skinSmoothing(_ cg: CGImage, blur: Double, smoothness: Double) throws -> CGImage {
        let faces = FaceTools.detect(cg)
        guard !faces.isEmpty else { throw NeuralFilterError.noFace }
        let img = CIImage(cgImage: cg)
        let ext = img.extent
        let faceW = Double(faces.map { $0.bounds.width }.max() ?? 200)
        let mask = skinMask(cg, faces: faces)
        // edge-preserving smoothing (surface blur) scaled to face size
        let radius = max(1, faceW * 0.05 * blur / 50)
        let thr = 0.06 + (smoothness + 50) / 100 * 0.12
        var smooth = img
        if let k = FilterExtras.bilateralKernel {
            let step = max(1.0, radius / 5)
            smooth = k.apply(extent: ext, roiCallback: { _, rr in rr.insetBy(dx: -CGFloat(radius) - 1, dy: -CGFloat(radius) - 1) },
                             arguments: [img.clampedToExtent(), Float(radius), Float(step), Float(thr)]) ?? img
        }
        // frequency separation: keep a little fine texture so skin doesn't look plastic
        let fine = img.clampedToExtent().applyingGaussianBlur(sigma: max(0.6, faceW * 0.003)).cropped(to: ext)
        let keep = max(0, 0.45 - (smoothness + 50) / 100 * 0.4)
        let textured = texturedKernel?.apply(extent: ext, arguments: [smooth, img, fine, Float(keep)]) ?? smooth
        let amount = min(1, blur / 50)
        let m = mask.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: CGFloat(amount), y: 0, z: 0, w: 0),
                                                                   "inputGVector": CIVector(x: 0, y: CGFloat(amount), z: 0, w: 0),
                                                                   "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amount), w: 0)])
        return NImg.cg(textured.mixed(with: img, mask: m).cropped(to: ext), rect: ext) ?? cg
    }

    static let texturedKernel = CIColorKernel(source: """
    kernel vec4 texturedK(__sample sm, __sample orig, __sample fine, float keep) {
        vec3 d = orig.rgb - fine.rgb;
        return vec4(clamp(sm.rgb + d * keep, 0.0, 1.0) , sm.a);
    }
    """)

    /// Face-aware relight (on-device) + generative options through `NeuralCloudHook.editPortrait`.
    static func smartPortrait(_ cg: CGImage, v: (String) -> Double) async throws -> CGImage {
        var cur = cg
        let cloudKeys = ["happiness", "surprise", "anger", "age", "gaze", "hair", "head"]
        let cloud = cloudKeys.filter { abs(v($0)) > 0.5 }
        if !cloud.isEmpty {
            guard let hook = NeuralCloudHook.editPortrait else { throw NeuralFilterError.needsProvider("Smart Portrait (\(cloud.joined(separator: ", ")))") }
            let desc: [String: (String, String)] = ["happiness": ("happier", "less happy"), "surprise": ("more surprised", "less surprised"),
                                                    "anger": ("angrier", "calmer"), "age": ("older", "younger"), "gaze": ("looking right", "looking left"),
                                                    "hair": ("thicker hair", "thinner hair"), "head": ("head turned right", "head turned left")]
            let parts = cloud.map { k -> String in let d = desc[k]!; return "\(v(k) > 0 ? d.0 : d.1) (\(Int(abs(v(k)) * 2))%)" }
            cur = NImg.resized(try await hook(cur, "Edit the portrait, keep identity and background: " + parts.joined(separator: ", ") + "."), cg.width, cg.height)
        }
        let strength = v("lightStrength") / 100, bright = v("brightness") / 100
        if strength < 0.01 && abs(bright) < 0.01 { return cur }
        let faces = FaceTools.detect(cur)
        guard !faces.isEmpty else { throw NeuralFilterError.noFace }
        let W = cur.width, H = cur.height
        var p = PlanarImage.rgb(cur)
        let n = W * H
        // pseudo-normals: ellipsoid over each face + detail from blurred luminance gradients
        let lum = MaskMath.boxBlur(NeuralTensor.luminance(p), max(2, Int(Double(faces[0].bounds.width) * 0.02)))
        let ang = v("lightDirection") / 50 * Double.pi / 2.2
        let L = (Float(sin(ang)), Float(-0.35), Float(cos(ang)))
        let ln = sqrt(L.0 * L.0 + L.1 * L.1 + L.2 * L.2)
        for f in faces {
            let b = f.bounds.insetBy(dx: -f.bounds.width * 0.25, dy: -f.bounds.height * 0.35)
            let cx = Float(b.midX), cy = Float(b.midY), rx = Float(b.width / 2), ry = Float(b.height / 2)
            let x0 = max(0, Int(b.minX)), x1 = min(W - 1, Int(b.maxX)), y0 = max(0, Int(b.minY)), y1 = min(H - 1, Int(b.maxY))
            if x1 <= x0 || y1 <= y0 { continue }
            for y in y0...y1 {
                for x in x0...x1 {
                    let dx = (Float(x) - cx) / rx, dy = (Float(y) - cy) / ry
                    let r2 = dx * dx + dy * dy
                    if r2 >= 1 { continue }
                    let i = y * W + x
                    let gx = (lum.data[y * W + min(W - 1, x + 1)] - lum.data[y * W + max(0, x - 1)]) * 4
                    let gy = (lum.data[min(H - 1, y + 1) * W + x] - lum.data[max(0, y - 1) * W + x]) * 4
                    var nx = dx * 0.8 - gx, ny = dy * 0.8 - gy, nz = sqrt(max(0.05, 1 - r2))
                    let nl = sqrt(nx * nx + ny * ny + nz * nz); nx /= nl; ny /= nl; nz /= nl
                    let shade = max(0, (nx * L.0 + ny * L.1 + nz * L.2) / ln)
                    let fall = (1 - smoothstepF(0.55, 1, sqrtf(r2)))       // fade at the ellipse edge
                    let delta = shade - 0.55
                    let gain = 1 + (Float(strength) * (delta > 0 ? delta * 1.3 : delta * 0.8) + Float(bright) * 0.5) * fall
                    for c in 0..<3 { p.data[c * n + i] = min(1, max(0, p.data[c * n + i] * gain)) }
                }
            }
        }
        return NImg.withAlpha(p.cgImage(), NImg.alpha(cur))
    }

    @inline(__always) static func smoothstepF(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - a) / (b - a))); return t * t * (3 - 2 * t)
    }
}

// MARK: - Depth Blur

enum DepthBlur {
    static let cocKernel = CIColorKernel(source: """
    kernel vec4 cocK(__sample d, float focal, float range, float subj) {
        float diff = abs(d.r - focal);
        float c = clamp((diff - range * 0.5) / max(0.02, 0.35 - range * 0.3), 0.0, 1.0);
        c = c * (1.0 - subj);
        return vec4(c, c, c, 1.0);
    }
    """)

    static let hazeKernel = CIColorKernel(source: """
    kernel vec4 hazeK(__sample s, __sample d, float amount, vec3 col) {
        float f = clamp((1.0 - d.r) * amount, 0.0, 0.85);
        return vec4(mix(s.rgb, col * s.a, f), s.a);
    }
    """)

    static func apply(_ cg: CGImage, v: (String) -> Double, focal: CGPoint?, depth given: PlanarImage? = nil) async throws -> CGImage {
        let depth: PlanarImage
        if let g = given { depth = g } else { depth = try await DepthEstimator.depth(cg) }
        let dcg = depth.cgImage()
        if v("depthMap") > 0.5 { return dcg }
        let img = CIImage(cgImage: cg)
        let ext = img.extent
        let dImg = CIImage(cgImage: dcg)
        // subject (foreground instance) for "Focus Subject"
        var subject: CIImage? = nil
        var focalDepth = Float(1 - v("focalDistance") / 100)
        if let fp = focal {
            let x = Int(fp.x * CGFloat(depth.width)), y = Int(fp.y * CGFloat(depth.height))
            var s: Float = 0, n: Float = 0
            for yy in max(0, y - 3)...min(depth.height - 1, y + 3) { for xx in max(0, x - 3)...min(depth.width - 1, x + 3) { s += depth.data[yy * depth.width + xx]; n += 1 } }
            focalDepth = s / max(1, n)
        } else if v("focusSubject") > 0.5, let (m, med) = subjectMask(cg, depth: depth) {
            subject = m
            focalDepth = med
        }
        let range = Float(v("focalRange") / 100)
        var coc = cocKernel?.apply(extent: ext, arguments: [dImg, focalDepth, range, Float(0)]) ?? dImg
        if let s = subject { coc = coc.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: s.inverted()]) }
        coc = coc.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: ext)
        let maxR = Double(max(ext.width, ext.height)) * 0.02 * v("strength") / 50
        var out = img
        if maxR > 0.3 {
            // brighten highlights a little before blurring for a lens-like bokeh
            let boosted = img.applyingFilter("CIHighlightShadowAdjust", parameters: ["inputHighlightAmount": 1.0])
            out = boosted.clampedToExtent().applyingFilter("CIMaskedVariableBlur", parameters: ["inputMask": coc, kCIInputRadiusKey: maxR]).cropped(to: ext)
        }
        if v("haze") > 0, let k = hazeKernel {
            out = k.apply(extent: ext, arguments: [out, dImg, Float(v("haze") / 100 * 1.2), CIVector(x: 0.85, y: 0.9, z: 0.95)]) ?? out
        }
        if v("warmth") != 0 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 + CGFloat(v("warmth")) * 40, y: 0)])
        }
        if v("brightness") != 0 || v("saturation") != 0 {
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: v("brightness") / 250, kCIInputSaturationKey: 1 + v("saturation") / 50])
        }
        if v("grain") > 0 {
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: ext)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            let amt = v("grain") / 100 * 0.12
            out = noise.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: CGFloat(amt), y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: CGFloat(amt), z: 0, w: 0),
                                                                      "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(amt), w: 0), "inputBiasVector": CIVector(x: CGFloat(-amt / 2), y: CGFloat(-amt / 2), z: CGFloat(-amt / 2), w: 0)])
                .applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: out]).cropped(to: ext)
        }
        out = out.cropped(to: ext).masked(byAlphaOf: img)
        return NImg.cg(out, rect: ext) ?? cg
    }

    /// Foreground-instance mask and its median depth.
    static func subjectMask(_ cg: CGImage, depth: PlanarImage) -> (CIImage, Float)? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let h = VNImageRequestHandler(cgImage: cg)
        guard (try? h.perform([req])) != nil, let obs = req.results?.first,
              let pb = try? obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: h) else { return nil }
        let m = CIImage(cvPixelBuffer: pb)
        let scaled = m.transformed(by: CGAffineTransform(scaleX: CGFloat(cg.width) / m.extent.width, y: CGFloat(cg.height) / m.extent.height))
        guard let mcg = NImg.grayCG(scaled, rect: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)) else { return nil }
        let mp = PlanarImage.gray(mcg, width: depth.width, height: depth.height)
        var vals: [Float] = []
        for i in mp.data.indices where mp.data[i] > 0.5 { vals.append(depth.data[i]) }
        guard vals.count > 50 else { return nil }
        vals.sort()
        let soft = scaled.clampedToExtent().applyingGaussianBlur(sigma: 1.5).cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (soft, vals[vals.count / 2])
    }
}

// MARK: - JPEG deblocking

enum Deblock {
    static let kernel = CIKernel(source: """
    kernel vec4 deblock(sampler s, float strength) {
        vec2 dc = destCoord();
        vec4 c = sample(s, samplerTransform(s, dc));
        vec2 p = floor(dc);
        float bx = mod(p.x, 8.0), by = mod(p.y, 8.0);
        vec4 acc = c; float w = 1.0;
        if (bx < 0.5 || bx > 6.5) {
            vec4 l = sample(s, samplerTransform(s, dc + vec2(-1.0, 0.0)));
            vec4 r = sample(s, samplerTransform(s, dc + vec2(1.0, 0.0)));
            float d = max(length(l.rgb - c.rgb), length(r.rgb - c.rgb));
            float k = strength * (1.0 - smoothstep(0.03, 0.12, d));
            acc += (l + r) * k; w += 2.0 * k;
        }
        if (by < 0.5 || by > 6.5) {
            vec4 u = sample(s, samplerTransform(s, dc + vec2(0.0, -1.0)));
            vec4 b = sample(s, samplerTransform(s, dc + vec2(0.0, 1.0)));
            float d = max(length(u.rgb - c.rgb), length(b.rgb - c.rgb));
            float k = strength * (1.0 - smoothstep(0.03, 0.12, d));
            acc += (u + b) * k; w += 2.0 * k;
        }
        return acc / w;
    }
    """)

    static func apply(_ cg: CGImage, strength: Double) -> CGImage {
        let img = CIImage(cgImage: cg)
        guard let k = kernel else { return cg }
        // JPEG blocks are aligned to the top-left corner: CI is y-up, so shift by the height remainder
        let shiftY = CGFloat(cg.height % 8)
        let src = img.transformed(by: CGAffineTransform(translationX: 0, y: -shiftY))
        let out = k.apply(extent: src.extent, roiCallback: { _, r in r.insetBy(dx: -1, dy: -1) }, arguments: [src.clampedToExtent(), Float(strength)])?
            .transformed(by: CGAffineTransform(translationX: 0, y: shiftY)).cropped(to: img.extent)
        return out.flatMap { NImg.cg($0, rect: img.extent) } ?? cg
    }
}

// MARK: - Photo Restoration

enum PhotoRestoration {
    static func apply(_ cg: CGImage, v: (String) -> Double, preview: Bool) async throws -> CGImage {
        var cur = cg
        // scratches are found on the original (denoising softens them), filled after enhancement
        let scratches = v("scratch") > 0.5 ? ScratchReduction.mask(cg, amount: v("scratch") / 100) : nil
        if v("enhance") > 0.5 {
            cur = try await Restoration.run(cur, .denoise, strength: v("enhance") / 100)
        }
        if v("halftone") > 0.5 {
            let r = v("halftone") / 100 * 1.6
            let img = CIImage(cgImage: cur)
            cur = NImg.cg(img.clampedToExtent().applyingGaussianBlur(sigma: r).cropped(to: img.extent)
                .applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: r * 2, kCIInputIntensityKey: 0.6]), rect: img.extent) ?? cur
        }
        if let m = scratches {
            cur = try await ScratchReduction.fill(cur, mask: m)
        }
        if v("face") > 0.5, FaceTools.gfpganAvailable || !preview {
            if let (r, _) = try await FaceTools.restoreFaces(cur, strength: v("face") / 100) { cur = r }
        }
        if v("colorNoise") > 0.5 {
            // blur chroma only (Lab), keep L
            let img = CIImage(cgImage: cur)
            let blurred = img.clampedToExtent().applyingGaussianBlur(sigma: v("colorNoise") / 100 * 4).cropped(to: img.extent)
            cur = NImg.cg(blurred.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: blurred])
                .applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: img]), rect: img.extent) ?? cur
        }
        if v("contrast") != 0 || v("color") > 0 {
            let img = CIImage(cgImage: cur)
            var o = img.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + v("contrast") / 150])
            if v("color") > 0 { o = o.applyingFilter("CIVibrance", parameters: ["inputAmount": v("color") / 100]) }
            cur = NImg.cg(o, rect: img.extent) ?? cur
        }
        return cur
    }
}

/// Detects thin, long, high-contrast lines (scratches / dust) and fills them.
enum ScratchReduction {
    static func mask(_ cg: CGImage, amount: Double) -> PlanarImage {
        let W = cg.width, H = cg.height
        let lum = NeuralTensor.luminance(PlanarImage.rgb(cg))
        let r = max(2, min(W, H) / 300)
        let minLen = max(12, Double(max(W, H)) * 0.03)
        var total = PlanarImage(width: W, height: H, channels: 1)
        // bright and dark scratches separately (a line's flanks respond with the opposite polarity)
        for polarity in [1, -1] {
            let resp = ThinStructures.ridgeResponse(lum, smooth: 1, polarity: polarity)
            let sorted = resp.data.sorted()
            let median = sorted[sorted.count / 2], p90 = sorted[Int(Double(sorted.count - 1) * 0.9)]
            var thr = max(0.012, max(6 * median, 2.0 * p90)) * Float(1.3 - 0.5 * amount)
            var keep = PlanarImage(width: W, height: H, channels: 1)
            for _ in 0..<5 {
                var bin = PlanarImage(width: W, height: H, channels: 1)
                for i in bin.data.indices { bin.data[i] = resp.data[i] > thr ? 1 : 0 }
                // drop dense (textured) areas: isolated lines have low local density
                let density = MaskMath.boxBlur(bin, 4)
                for i in bin.data.indices where density.data[i] > 0.3 { bin.data[i] = 0 }
                keep = PlanarImage(width: W, height: H, channels: 1)
                var covered = 0
                for c in ThinStructures.components(bin) {
                    let scratch = c.length >= minLen && c.thickness <= 3.5 && ThinStructures.sideDifference(c, lum: lum, offset: Double(r + 3)) <= 0.1
                    var meanResp: Float = 0
                    if !scratch && c.pixels.count <= 20 {
                        for p in c.pixels { meanResp += resp.data[Int(p)] }
                        meanResp /= Float(c.pixels.count)
                    }
                    let dust = !scratch && c.pixels.count >= 2 && c.pixels.count <= 20 && meanResp > 2.5 * thr
                    if scratch || dust { for p in c.pixels { keep.data[Int(p)] = 1 }; covered += c.pixels.count }
                }
                // never let the mask swallow the picture: tighten until coverage is plausible
                if Double(covered) / Double(W * H) < 0.03 { break }
                thr *= 1.3
            }
            for i in total.data.indices where keep.data[i] > 0.5 { total.data[i] = 1 }
        }
        return MaskMath.dilate(total, max(2, r / 2 + 1))
    }

    static func apply(_ cg: CGImage, amount: Double) async throws -> CGImage {
        try await fill(cg, mask: mask(cg, amount: amount))
    }

    static func fill(_ cg: CGImage, mask m: PlanarImage) async throws -> CGImage {
        if !(m.data.contains { $0 > 0.5 }) { return cg }
        if LamaInpainter.isAvailable { return try await LamaInpainter.inpaint(cg, hole: m) }
        // fallback: PatchMatch inpainting
        let buf = PixelBuffer(cgImage: cg)
        let hole = PixelBuffer(cgImage: m.cgImage(), format: .gray)
        return Inpainter.inpaint(buf, hole: hole).makeCGImage()
    }
}

// MARK: - Harmonization / Color Transfer

enum Harmonize {
    static func harmonize(_ cg: CGImage, to below: CGImage, v: (String) -> Double) -> CGImage {
        let img = CIImage(cgImage: cg)
        guard let t = ColorStats.lab(img), let s = ColorStats.lab(CIImage(cgImage: below)) else { return cg }
        var m = MatchColorSettings()
        m.target = t
        var src = s
        // colour-balance offsets (a: green–red, b: blue–yellow)
        src.mean[1] += v("cyanRed") * 0.4 - v("magentaGreen") * 0.4
        src.mean[2] += -v("yellowBlue") * 0.4
        src.mean[0] += v("brightness") * 0.3
        m.source = src
        let k = v("strength") / 100
        m.luminance = 100
        m.intensity = max(1, 100 + v("saturation") * 2)
        m.fade = (1 - k) * 100
        let out = AdjustmentEngine.applyMatchColor(m, img)
        return NImg.cg(out.masked(byAlphaOf: img), rect: img.extent) ?? cg
    }
}

enum ColorTransfer {
    struct Preset { let name: String; let stats: LabStats }
    static let presets: [Preset] = [
        Preset(name: "Golden Hour", stats: LabStats(mean: [58, 12, 38], std: [22, 9, 16])),
        Preset(name: "Teal & Orange", stats: LabStats(mean: [52, -4, 6], std: [24, 16, 24])),
        Preset(name: "Blue Hour", stats: LabStats(mean: [42, 4, -28], std: [20, 8, 14])),
        Preset(name: "Autumn", stats: LabStats(mean: [48, 16, 34], std: [21, 12, 18])),
        Preset(name: "Pastel", stats: LabStats(mean: [74, 6, 4], std: [12, 8, 9])),
        Preset(name: "Moody Green", stats: LabStats(mean: [40, -12, 10], std: [18, 8, 10])),
    ]

    /// Reinhard-style Lab statistics transfer.
    static func transfer(_ cg: CGImage, to ref: LabStats, luminance: Double, intensity: Double, strength: Double, preserveLuminance: Bool) -> CGImage {
        let img = CIImage(cgImage: cg)
        guard let t = ColorStats.lab(img) else { return cg }
        var m = MatchColorSettings()
        m.target = t
        var src = ref
        if preserveLuminance { src.mean[0] = t.mean[0]; src.std[0] = t.std[0] }
        m.source = src
        m.luminance = max(1, luminance * 100)
        m.intensity = max(1, intensity * 100)
        m.fade = (1 - strength) * 100
        return NImg.cg(AdjustmentEngine.applyMatchColor(m, img).masked(byAlphaOf: img), rect: img.extent) ?? cg
    }
}
