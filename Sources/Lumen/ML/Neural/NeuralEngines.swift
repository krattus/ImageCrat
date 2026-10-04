import Foundation
import CoreML
import CoreImage
import Vision
import ImageCratCore

// MARK: - LaMa inpainting

enum LamaInpainter {
    static let size = 800

    static var isAvailable: Bool { NeuralModels.isInstalled(NeuralModelID.lama) }

    /// Fills `hole` (gray, white = fill; same size as `image`) and returns the full image with holes replaced.
    /// Compact holes: a square context crop (≥ 2.2× the hole) is scaled to 800×800. Long thin holes spread over a
    /// large area (wires): processed in native-resolution 800×800 windows. Results are composited back through a
    /// feathered mask.
    static func inpaint(_ image: CGImage, hole: PlanarImage, progress: ((Double) -> Void)? = nil) async throws -> CGImage {
        let model = try await NeuralModels.load(NeuralModelID.lama)
        let W = image.width, H = image.height
        precondition(hole.width == W && hole.height == H)
        let ds = max(1, max(W, H) / 512)
        let small = hole.resized(max(1, W / ds), max(1, H / ds))
        let boxes = MaskMath.regions(small, thr: 0.1, mergeDistance: max(4, 96 / ds)).map {
            IRect(x: $0.x * ds, y: $0.y * ds, width: $0.width * ds + ds, height: $0.height * ds + ds)
        }
        var result = PlanarImage.rgb(image)
        var windows: [IRect] = []
        for b in boxes {
            var count = 0
            for y in max(0, b.y)..<min(H, b.y + b.height) { for x in max(0, b.x)..<min(W, b.x + b.width) where hole.data[y * W + x] > 0.1 { count += 1 } }
            let coverage = Double(count) / Double(max(1, b.width * b.height))
            if max(b.width, b.height) > 1000 && coverage < 0.12 {
                // native-resolution windows along the thin hole
                let step = size - 96
                let ex0 = max(0, b.x - 48), ey0 = max(0, b.y - 48), ex1 = min(W, b.x + b.width + 48), ey1 = min(H, b.y + b.height + 48)
                var ty = ey0
                while true {
                    var tx = ex0
                    let wy = max(0, min(H - min(size, H), ty))
                    while true {
                        let wx = max(0, min(W - min(size, W), tx))
                        let r = IRect(x: wx, y: wy, width: min(size, W), height: min(size, H))
                        var has = false
                        check: for y in stride(from: r.y, to: r.y + r.height, by: 2) { for x in stride(from: r.x, to: r.x + r.width, by: 2) where hole.data[y * W + x] > 0.1 { has = true; break check } }
                        if has && !windows.contains(r) { windows.append(r) }
                        if tx + size >= ex1 { break }
                        tx += step
                    }
                    if ty + size >= ey1 { break }
                    ty += step
                }
            } else {
                let side = min(max(Int(Double(max(b.width, b.height)) * 2.2), min(size, max(W, H))), max(W, H))
                var cx = b.x + b.width / 2 - side / 2, cy = b.y + b.height / 2 - side / 2
                cx = max(0, min(W - min(side, W), cx)); cy = max(0, min(H - min(side, H), cy))
                windows.append(IRect(x: cx, y: cy, width: min(side, W), height: min(side, H)))
            }
        }
        for (i, r) in windows.enumerated() {
            try Task.checkCancellation()
            try await runWindow(model, r, hole: hole, result: &result)
            progress?(Double(i + 1) / Double(max(1, windows.count)))
        }
        return NImg.withAlpha(result.cgImage(), NImg.alpha(image))
    }

    /// Inpaints one window (scaled into the 800×800 input when larger) and composites it into `result`.
    private static func runWindow(_ model: MLModel, _ r: IRect, hole: PlanarImage, result: inout PlanarImage) async throws {
        let W = result.width, H = result.height
        let cx = r.x, cy = r.y, cw = r.width, ch = r.height
        let crop = result.crop(x0: cx, y0: cy, w: cw, h: ch)
        let mcrop = hole.crop(x0: cx, y0: cy, w: cw, h: ch)
        let s = min(1, Float(size) / Float(max(cw, ch)))
        let iw = max(1, min(size, Int((Float(cw) * s).rounded()))), ih = max(1, min(size, Int((Float(ch) * s).rounded())))
        let rin = crop.resizedFloat(iw, ih).crop(x0: 0, y0: 0, w: size, h: size)   // edge-replicated padding
        var mm = mcrop.resizedFloat(iw, ih)
        for i in mm.data.indices { mm.data[i] = mm.data[i] > 0.05 ? 1 : 0 }
        mm = MaskMath.dilate(mm, 2)
        var m800 = PlanarImage(width: size, height: size, channels: 1)
        for y in 0..<ih { for x in 0..<iw { m800.data[y * size + x] = mm.data[y * iw + x] } }
        let fp = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: try NeuralTensor.multiArray(rin)),
            "mask": MLFeatureValue(multiArray: try NeuralTensor.multiArray(m800)),
        ])
        let t0 = CFAbsoluteTimeGetCurrent()
        let out = try await model.prediction(from: fp)
        if NeuralModels.verbose { print(String(format: "    LaMa window %d×%d → inference %.0f ms", cw, ch, (CFAbsoluteTimeGetCurrent() - t0) * 1000)) }
        guard let ov = out.featureValue(for: "output"), var op = NeuralTensor.planar(ov) else { throw ModelError.compile("LaMa output") }
        // big-lama Core ML outputs 0…255
        if (op.data.max() ?? 1) > 2 { for i in op.data.indices { op.data[i] /= 255 } }
        let back = op.crop(x0: 0, y0: 0, w: iw, h: ih).resizedFloat(cw, ch)
        var soft = MaskMath.dilate(mcrop, max(1, Int(2 / s)))
        soft = MaskMath.boxBlur(soft, max(1, Int(1.5 / s)))
        let n = cw * ch, N = W * H
        for y in 0..<ch {
            for x in 0..<cw {
                let a = min(1, max(0, soft.data[y * cw + x] * 1.5))
                if a <= 0 { continue }
                // don't touch the outer 16 px of interior windows edges (seams)
                let gi = (cy + y) * W + cx + x
                for c in 0..<3 {
                    let v = back.data[c * n + y * cw + x]
                    result.data[c * N + gi] = result.data[c * N + gi] * (1 - a) + max(0, min(1, v)) * a
                }
            }
        }
        _ = H
    }
}

// MARK: - Real-ESRGAN

enum SuperResolution {
    static var isAvailable: Bool { NeuralModels.isInstalled(NeuralModelID.esrgan) }

    /// Upscales ×factor (Real-ESRGAN ×4, resampled for other factors). Alpha is upscaled with Lanczos.
    static func upscale(_ cg: CGImage, factor: Double, progress: ((Double) -> Void)? = nil) async throws -> CGImage {
        let model = try await NeuralModels.load(NeuralModelID.esrgan)
        var cur = cg
        var remaining = factor
        // repeated ×4 passes for very large factors
        while remaining > 1.01 {
            let rgb = PlanarImage.rgb(cur)
            let out = try TiledRunner.runModel(model, rgb, tile: 256, overlap: 24, scale: 4, progress: progress)
            var up = out.cgImage()
            let pass = min(4, remaining)
            if pass < 3.999 {
                up = NImg.resized(up, Int((Double(cur.width) * pass).rounded()), Int((Double(cur.height) * pass).rounded()))
            }
            cur = up
            remaining /= pass
        }
        let w = Int((Double(cg.width) * factor).rounded()), h = Int((Double(cg.height) * factor).rounded())
        if cur.width != w || cur.height != h { cur = NImg.resized(cur, w, h) }
        if let a = NImg.alpha(cg) { cur = NImg.withAlpha(cur, a.resized(w, h)) }
        return cur
    }
}

/// Upscaler hook for Image Size (merge: register into `UpscalerRegistry` if/when it exists).
enum NeuralUpscalers {
    static let name = "Real-ESRGAN (AI, on-device)"
    static func upscale(_ cg: CGImage, factor: Double) async throws -> CGImage {
        try await SuperResolution.upscale(cg, factor: factor)
    }
}

// MARK: - NAFNet restoration

enum Restoration {
    enum Kind { case denoise, deblur }

    static func isAvailable(_ k: Kind) -> Bool { NeuralModels.isInstalled(k == .denoise ? NeuralModelID.nafnetDenoise : NeuralModelID.nafnetDeblur) }

    /// Runs NAFNet (SIDD denoise or GoPro deblur) over the whole image; `strength` 0…1 blends with the input.
    /// The GoPro model can diverge on out-of-distribution blur: such tiles are detected and left unchanged.
    static func run(_ cg: CGImage, _ kind: Kind, strength: Double = 1, progress: ((Double) -> Void)? = nil) async throws -> CGImage {
        let id = kind == .denoise ? NeuralModelID.nafnetDenoise : NeuralModelID.nafnetDeblur
        // GoPro NAFNet: GPU (fp16 on the Neural Engine drifts on this deep encoder)
        let model = try await NeuralModels.load(id, units: kind == .deblur ? .cpuAndGPU : .all)
        let tile = kind == .denoise ? 512 : 384
        let rgb = PlanarImage.rgb(cg)
        let opts = MLPredictionOptions()
        var rejected = 0
        var out = try TiledRunner.run(rgb, tile: tile, overlap: 32, scale: 1, progress: progress) { t in
            let arr = try NeuralTensor.multiArray(t)
            let o = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]), options: opts)
            guard let v = o.featureValue(for: "output"), let p = NeuralTensor.planar(v) else { throw ModelError.compile("NAFNet output") }
            // divergence guard: large excursions outside 0…1 or a big mean change
            var lo: Float = 0, hi: Float = 1, diff: Float = 0, bad = false
            for i in p.data.indices {
                let v = p.data[i]
                if !v.isFinite { bad = true; break }
                lo = min(lo, v); hi = max(hi, v); diff += abs(v - t.data[i])
            }
            diff /= Float(p.data.count)
            if bad || lo < -0.3 || hi > 1.3 || !(diff <= 0.08) { rejected += 1; return t }
            return p
        }
        if rejected > 0 { print("NAFNet \(kind): \(rejected) tile(s) diverged and were left unchanged") }
        let k = Float(max(0, min(1, strength)))
        for i in out.data.indices { out.data[i] = max(0, min(1, rgb.data[i] + (out.data[i] - rgb.data[i]) * k)) }
        return NImg.withAlpha(out.cgImage(), NImg.alpha(cg))
    }

    /// "Restore by super-resolution": Real-ESRGAN ×4 then Lanczos back to the original size. Real-ESRGAN is trained
    /// on blur/noise/JPEG degradations, so this sharpens soft (defocus) images without NAFNet's motion prior.
    static func restoreViaSR(_ cg: CGImage, strength: Double = 1, progress: ((Double) -> Void)? = nil) async throws -> CGImage {
        let up = try await SuperResolution.upscale(cg, factor: 4, progress: progress)
        let img = CIImage(cgImage: up)
        let down = img.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(cg.width) / Double(up.width), kCIInputAspectRatioKey: 1])
        guard let d = NImg.cg(down, rect: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)) else { return cg }
        return NeuralFilterEngine.blend(cg, d, strength)
    }
}

// MARK: - Depth Anything V2

enum DepthEstimator {
    static var isAvailable: Bool { NeuralModels.isInstalled(NeuralModelID.depth) }

    /// Relative depth (0 = far, 1 = near) at the image's size.
    static func depth(_ cg: CGImage) async throws -> PlanarImage {
        let model = try await NeuralModels.load(NeuralModelID.depth)
        guard let (name, desc) = model.modelDescription.inputDescriptionsByName.first, let c = desc.imageConstraint else { throw ModelError.compile("depth I/O") }
        // the model is landscape (518×392): rotate portrait images 90° clockwise
        let portrait = cg.height > cg.width
        var src = PlanarImage.rgb(cg)
        if portrait { src = src.rotatedCW() }
        guard let pb = NeuralTensor.pixelBuffer(src.cgImage(), width: c.pixelsWide, height: c.pixelsHigh) else { throw ModelError.compile("depth input") }
        let out = try await model.prediction(from: try MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(pixelBuffer: pb)]))
        guard let oname = model.modelDescription.outputDescriptionsByName.keys.first, let v = out.featureValue(for: oname),
              var d = NeuralTensor.planar(v) else { throw ModelError.compile("depth output") }
        // normalise (robust min/max)
        let sorted = d.data.sorted()
        let lo = sorted[Int(Double(sorted.count) * 0.01)], hi = sorted[Int(Double(sorted.count - 1) * 0.995)]
        let span = max(1e-6, hi - lo)
        for i in d.data.indices { d.data[i] = max(0, min(1, (d.data[i] - lo) / span)) }
        var full = d.resizedFloat(src.width, src.height)
        if portrait { full = full.rotatedCCW() }
        return full
    }
}

// MARK: - DDColor

enum Colorizer {
    static var isAvailable: Bool { NeuralModels.isInstalled(NeuralModelID.ddcolor) }

    /// Colorizes: L from the original, a/b from DDColor (scaled by `saturation`, shifted by `abShift`).
    static func colorize(_ cg: CGImage, saturation: Double = 1, abShift: (Float, Float) = (0, 0),
                         hints: [(CGPoint, RGBA)] = [], progress: ((Double) -> Void)? = nil) async throws -> CGImage {
        let model = try await NeuralModels.load(NeuralModelID.ddcolor)
        guard let (inName, _) = model.modelDescription.inputDescriptionsByName.first,
              let outName = model.modelDescription.outputDescriptionsByName.keys.first else { throw ModelError.compile("ddcolor I/O") }
        let S = 512
        // model input: gray RGB made from L only (a = b = 0)
        let small = LabMath.lab(PlanarImage.rgb(cg, width: S, height: S))
        var grayLab = small
        let n = S * S
        for i in 0..<n { grayLab.data[n + i] = 0; grayLab.data[2 * n + i] = 0 }
        let grayRGB = LabMath.rgb(grayLab)
        let fp = try MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: try NeuralTensor.multiArray(grayRGB))])
        progress?(0.3)
        let out = try await model.prediction(from: fp)
        guard let v = out.featureValue(for: outName), let ab = NeuralTensor.planar(v) else { throw ModelError.compile("ddcolor output") }
        progress?(0.7)
        let W = cg.width, H = cg.height
        let abFull = ab.resizedFloat(W, H)
        var lab = LabMath.lab(PlanarImage.rgb(cg))
        let N = W * H
        let sat = Float(saturation)
        // colour hints: local a/b offsets with gaussian falloff
        var hintAB: [(Float, Float, Float, Float, Float)] = []   // x, y, a, b, radius
        for (p, c) in hints {
            let (_, ha, hb) = LabMath.toLab(Float(c.r), Float(c.g), Float(c.b))
            hintAB.append((Float(p.x), Float(p.y), ha, hb, Float(max(W, H)) * 0.07))
        }
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                var a = abFull.data[i] * sat + abShift.0
                var b = abFull.data[N + i] * sat + abShift.1
                for h in hintAB {
                    let dx = Float(x) - h.0, dy = Float(y) - h.1
                    let w = expf(-(dx * dx + dy * dy) / (2 * h.4 * h.4))
                    if w > 0.01 { a = a * (1 - w) + h.2 * w; b = b * (1 - w) + h.3 * w }
                }
                lab.data[N + i] = a; lab.data[2 * N + i] = b
            }
        }
        return NImg.withAlpha(LabMath.rgb(lab).cgImage(), NImg.alpha(cg))
    }
}

// MARK: - Face detection + GFPGAN restoration

struct DetectedFace {
    var bounds: CGRect                 // top-left image coordinates
    var fivePoints: [CGPoint]          // left eye, right eye, nose, left mouth, right mouth (image left/right)
    var contour: [CGPoint]             // face contour + eyebrows (top-left coords)
    var leftEye: [CGPoint], rightEye: [CGPoint], lips: [CGPoint], brows: [CGPoint], nose: [CGPoint]
}

enum FaceTools {
    static func detect(_ cg: CGImage) -> [DetectedFace] {
        let req = VNDetectFaceLandmarksRequest()
        let h = VNImageRequestHandler(cgImage: cg)
        try? h.perform([req])
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let size = CGSize(width: W, height: H)
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x, y: H - $0.y) }
        }
        func center(_ p: [CGPoint]) -> CGPoint? {
            guard !p.isEmpty else { return nil }
            return CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        return (req.results ?? []).compactMap { f in
            let bb = VNImageRectForNormalizedRect(f.boundingBox, Int(W), Int(H))
            let bounds = CGRect(x: bb.minX, y: H - bb.maxY, width: bb.width, height: bb.height)
            guard let lm = f.landmarks else { return nil }
            let le = pts(lm.leftEye), re = pts(lm.rightEye)
            let lips = pts(lm.outerLips)
            let nose = pts(lm.nose), crest = pts(lm.noseCrest)
            guard let c1 = center(le), let c2 = center(re), lips.count >= 2 else { return nil }
            let eyes = [c1, c2].sorted { $0.x < $1.x }
            let mouthL = lips.min { $0.x < $1.x }!, mouthR = lips.max { $0.x < $1.x }!
            // nose tip: lowest point of the nose crest, else nose centroid
            let tip = crest.max { $0.y < $1.y } ?? center(nose) ?? CGPoint(x: bounds.midX, y: bounds.midY)
            let contour = pts(lm.faceContour)
            let brows = pts(lm.leftEyebrow) + pts(lm.rightEyebrow)
            return DetectedFace(bounds: bounds, fivePoints: [eyes[0], eyes[1], tip, mouthL, mouthR], contour: contour,
                                leftEye: le, rightEye: re, lips: lips + pts(lm.innerLips), brows: brows, nose: nose)
        }
    }

    /// FFHQ 5-point template for 512×512 crops (facexlib).
    static let template: [CGPoint] = [CGPoint(x: 192.98138, y: 239.94708), CGPoint(x: 318.90277, y: 240.1936), CGPoint(x: 256.63416, y: 314.01935),
                                      CGPoint(x: 201.26117, y: 371.41043), CGPoint(x: 313.08905, y: 371.15118)]

    /// Least-squares similarity transform mapping `src` → `dst` (top-left coords).
    static func similarity(_ src: [CGPoint], _ dst: [CGPoint]) -> CGAffineTransform {
        let n = CGFloat(src.count)
        let sx = src.map(\.x).reduce(0, +) / n, sy = src.map(\.y).reduce(0, +) / n
        let dx = dst.map(\.x).reduce(0, +) / n, dy = dst.map(\.y).reduce(0, +) / n
        var a: CGFloat = 0, b: CGFloat = 0, ss: CGFloat = 0
        for (p, q) in zip(src, dst) {
            let px = p.x - sx, py = p.y - sy, qx = q.x - dx, qy = q.y - dy
            a += px * qx + py * qy
            b += px * qy - py * qx
            ss += px * px + py * py
        }
        a /= max(1e-6, ss); b /= max(1e-6, ss)
        // q = [a -b; b a] p + t
        let tx = dx - (a * sx - b * sy), ty = dy - (b * sx + a * sy)
        return CGAffineTransform(a: a, b: b, c: -b, d: a, tx: tx, ty: ty)
    }

    static var gfpganAvailable: Bool { NeuralModels.isInstalled(NeuralModelID.gfpgan) }

    /// Restores every detected face with GFPGAN (blend `strength` 0…1). Returns nil when no face is found.
    static func restoreFaces(_ cg: CGImage, strength: Double = 1, faces: [DetectedFace]? = nil) async throws -> (CGImage, Int)? {
        let found = faces ?? detect(cg)
        let usable = found.filter { $0.bounds.width >= 24 }
        guard !usable.isEmpty else { return nil }
        let model = try await NeuralModels.load(NeuralModelID.gfpgan)
        let W = cg.width, H = cg.height
        var base = CIImage(cgImage: cg)
        let space = CanvasSpace(width: W, height: H)
        for f in usable {
            try Task.checkCancellation()
            let t = similarity(f.fivePoints, template)          // image(top-left) → crop(top-left)
            // CI space: flip image to top-left, apply t, flip crop back
            let flipImg = space.flip
            let flipCrop = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 512)
            let toCrop = flipImg.concatenating(t).concatenating(flipCrop)
            let crop = CIImage(cgImage: cg).clampedToExtent().transformed(by: toCrop).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
            guard let ccg = NImg.cg(crop, rect: CGRect(x: 0, y: 0, width: 512, height: 512)) else { continue }
            let inp = PlanarImage.rgb(ccg)
            let arr = try NeuralTensor.multiArray(inp, scale: 2, bias: -1)
            let out = try await model.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["input": MLFeatureValue(multiArray: arr)]))
            guard let v = out.featureValue(for: "output"), var restored = NeuralTensor.planar(v, scale: 0.5, bias: 0.5) else { continue }
            for i in restored.data.indices { restored.data[i] = max(0, min(1, restored.data[i])) }
            guard let rcg = Optional(restored.cgImage()) else { continue }
            // soft mask in crop space (facexlib-like: eroded + blurred square)
            let maskCrop = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512).insetBy(dx: 40, dy: 40))
                .composited(over: CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512)))
                .applyingGaussianBlur(sigma: 18).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512))
            let back = toCrop.inverted()
            let rImg = CIImage(cgImage: rcg).clampedToExtent().cropped(to: CGRect(x: 0, y: 0, width: 512, height: 512)).transformed(by: back)
            let mImg = maskCrop.transformed(by: back).composited(over: CIImage(color: .black).cropped(to: space.ciCanvas)).cropped(to: space.ciCanvas)
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: CGFloat(strength), y: 0, z: 0, w: 0),
                                                              "inputGVector": CIVector(x: 0, y: CGFloat(strength), z: 0, w: 0),
                                                              "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(strength), w: 0)])
            base = rImg.cropped(to: space.ciCanvas).mixed(with: base, mask: mImg).cropped(to: space.ciCanvas)
        }
        guard let res = NImg.cg(base, rect: space.ciCanvas) else { return nil }
        return (res, usable.count)
    }
}
