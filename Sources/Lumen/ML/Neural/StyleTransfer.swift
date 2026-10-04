import Foundation
import CoreImage
import CoreML
import CreateML
import Combine
import ImageCratCore

/// Style Transfer: Create ML `MLStyleTransfer` models trained on-device (once per style, cached), with a fast
/// Filter Gallery fallback. Built-in style images are generated procedurally (no downloads).
enum StyleTransfer {
    struct Preset {
        let id: String
        let name: String
        /// Fast-mode look: Filter Gallery filter and values.
        let look: GalleryFilter
        let lookValues: [String: Double]
        /// Procedural style image (square).
        let make: (Int) -> CIImage
    }

    static func palette(_ hexes: [String]) -> [RGBA] { hexes.compactMap { RGBA(hex: $0) } }

    /// Maps a gray image through a multi-stop palette.
    static func colorMap(_ gray: CIImage, _ colors: [RGBA]) -> CIImage {
        let n = 64
        let grad = PixelBuffer(width: n, height: 1)
        let cg = CGGradient(colorsSpace: sRGBSpace, colors: colors.map(\.cgColor) as CFArray,
                            locations: colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) })!
        grad.context.drawLinearGradient(cg, start: .zero, end: CGPoint(x: n, y: 0), options: [])
        grad.markDirty()
        return gray.applyingFilter("CIColorMap", parameters: ["inputGradientImage": grad.ciImage])
    }

    static func clouds(_ s: Int, scale: Double, seed: Double) -> CIImage {
        FilterKind.clouds(extent: CGRect(x: 0, y: 0, width: s, height: s), scale: scale, seed: seed, fg: .black, bg: .white)
    }

    static let presets: [Preset] = [
        Preset(id: "swirls", name: "Starry Swirls", look: .paintDaubs, lookValues: ["size": 10, "sharpness": 10]) { s in
            var img = colorMap(clouds(s, scale: Double(s) / 5, seed: 3), palette(["0B1A4A", "1E3F8C", "3C6FC2", "8FB8E8", "F2D35B", "F7E9A0"]))
            let r = CGRect(x: 0, y: 0, width: s, height: s)
            for (i, c) in [(0.3, 0.7), (0.72, 0.62), (0.5, 0.3), (0.15, 0.25), (0.85, 0.2)].enumerated() {
                img = img.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
                    kCIInputCenterKey: CIVector(x: CGFloat(c.0) * CGFloat(s), y: CGFloat(c.1) * CGFloat(s)),
                    kCIInputRadiusKey: Double(s) * (0.18 + 0.03 * Double(i)), kCIInputAngleKey: (i % 2 == 0 ? 1 : -1) * 3.5]).cropped(to: r)
            }
            return GalleryFilter.angledStrokes.apply(img, values: ["length": 22, "sharpness": 6], fg: .black, bg: .white, canvas: r)
        },
        Preset(id: "stainedglass", name: "Stained Glass", look: .stainedGlass, lookValues: ["cell": 14, "border": 4]) { s in
            let r = CGRect(x: 0, y: 0, width: s, height: s)
            let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.transformed(by: CGAffineTransform(scaleX: 40, y: 40))
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 2.2]).cropped(to: r)
            return GalleryFilter.stainedGlass.apply(noise, values: ["cell": 18, "border": 5, "light": 4], fg: .black, bg: .white, canvas: r)
        },
        Preset(id: "ink", name: "Ink Wash", look: .sumie, lookValues: ["width": 10, "pressure": 3, "contrast": 20]) { s in
            let r = CGRect(x: 0, y: 0, width: s, height: s)
            let g = colorMap(clouds(s, scale: Double(s) / 4, seed: 7), palette(["111111", "3A3A3A", "8C8577", "E8E0CC", "F6F1E4"]))
            return GalleryFilter.inkOutlines.apply(GalleryFilter.sumie.apply(g, values: ["width": 12, "pressure": 4, "contrast": 24], fg: .black, bg: .white, canvas: r),
                                                  values: ["length": 8, "dark": 25, "light": 12], fg: .black, bg: .white, canvas: r)
        },
        Preset(id: "pop", name: "Pop Halftone", look: .halftonePattern, lookValues: ["size": 3, "contrast": 20]) { s in
            let r = CGRect(x: 0, y: 0, width: s, height: s)
            let g = colorMap(clouds(s, scale: Double(s) / 3, seed: 11), palette(["E6194B", "F58231", "FFE119", "3CB44B", "4363D8", "911EB4"]))
                .applyingFilter("CIColorPosterize", parameters: ["inputLevels": 4])
            let dots = g.applyingFilter("CICMYKHalftone", parameters: [kCIInputWidthKey: Double(s) / 60, kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: r)
            return dots.applyingFilter("CIMultiplyBlendMode", parameters: [kCIInputBackgroundImageKey: g]).cropped(to: r)
        },
        Preset(id: "watercolor", name: "Watercolor", look: .watercolor, lookValues: ["detail": 11, "shadow": 1, "texture": 2]) { s in
            let r = CGRect(x: 0, y: 0, width: s, height: s)
            let g = colorMap(clouds(s, scale: Double(s) / 3, seed: 5), palette(["2D5E8C", "7BB3D9", "F2E6C9", "E89B8B", "B85C7A"]))
            return GalleryFilter.watercolor.apply(g, values: ["detail": 6, "shadow": 2, "texture": 3], fg: .black, bg: .white, canvas: r)
        },
        Preset(id: "mosaic", name: "Mosaic", look: .mosaicTiles, lookValues: ["size": 14, "grout": 2]) { s in
            let r = CGRect(x: 0, y: 0, width: s, height: s)
            let g = colorMap(clouds(s, scale: Double(s) / 4, seed: 9), palette(["7A1F1F", "C8553D", "F2B134", "2E8B57", "1D4E89", "F4F1DE"]))
            return GalleryFilter.mosaicTiles.apply(g, values: ["size": 16, "grout": 3, "lighten": 8], fg: .black, bg: .white, canvas: r)
        },
    ]

    static func preset(_ i: Int) -> Preset { presets[max(0, min(presets.count - 1, i))] }

    static func styleImage(_ p: Preset, size: Int = 512) -> CGImage? {
        NImg.cg(p.make(size), rect: CGRect(x: 0, y: 0, width: size, height: size))
    }

    // MARK: Cache / training

    static var cacheDir: URL {
        let base = Brand.supportFolder.appendingPathComponent("StyleTransfer")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func compiledURL(_ id: String) -> URL { cacheDir.appendingPathComponent("\(id).mlmodelc") }
    static func isTrained(_ id: String) -> Bool { FileManager.default.fileExists(atPath: compiledURL(id).path) }

    /// Observable training state for the dialog.
    @Observable final class Trainer {
        static let shared = Trainer()
        var progress: [String: Double] = [:]
        var errors: [String: String] = [:]
        @ObservationIgnored private var tasks: [String: Task<URL, Error>] = [:]
        @ObservationIgnored private var bag: [String: AnyCancellable] = [:]

        func train(_ p: Preset, content: CGImage, iterations: Int = 120) async throws -> URL {
            if isTrained(p.id) { return compiledURL(p.id) }
            if let t = tasks[p.id] { return try await t.value }
            let t = Task<URL, Error> { try await self.run(p, content: content, iterations: iterations) }
            tasks[p.id] = t
            defer { tasks[p.id] = nil }
            return try await t.value
        }

        private func run(_ p: Preset, content: CGImage, iterations: Int) async throws -> URL {
            await MainActor.run { self.progress[p.id] = 0; self.errors[p.id] = nil }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-style-\(p.id)-\(UUID().uuidString)")
            let contentDir = work.appendingPathComponent("content")
            try FileManager.default.createDirectory(at: contentDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            guard let style = styleImage(p, size: 512) else { throw ModelError.compile("style image") }
            let styleURL = work.appendingPathComponent("style.png")
            try writePNG(style, styleURL)
            // content set: the image + crops + generated scenes
            var contents: [CGImage] = [NImg.fitted(content, maxSide: 512)]
            let w = content.width, h = content.height
            for (fx, fy) in [(0.0, 0.0), (0.5, 0.0), (0.0, 0.5), (0.5, 0.5), (0.25, 0.25)] {
                if let c = content.cropping(to: CGRect(x: Double(w) * fx, y: Double(h) * fy, width: Double(w) * 0.5, height: Double(h) * 0.5)) { contents.append(NImg.fitted(c, maxSide: 512)) }
            }
            for seed in [1.0, 2.0] {
                let g = colorMap(clouds(512, scale: 90, seed: seed), palette(["203040", "5A7D9A", "C9B79C", "F3E9D2"]))
                if let c = NImg.cg(g, rect: CGRect(x: 0, y: 0, width: 512, height: 512)) { contents.append(c) }
            }
            for (i, c) in contents.enumerated() { try writePNG(c, contentDir.appendingPathComponent("c\(i).png")) }
            let data = MLStyleTransfer.DataSource.images(styleImage: styleURL, contentDirectory: contentDir, processingOption: nil)
            let params = MLStyleTransfer.ModelParameters(algorithm: .cnnLite, validation: .none, maxIterations: iterations, textelDensity: 256, styleStrength: 5)
            let job = try MLStyleTransfer.train(trainingData: data, parameters: params,
                                                sessionParameters: MLTrainingSessionParameters(sessionDirectory: work.appendingPathComponent("session"),
                                                                                               reportInterval: 10, checkpointInterval: 1000, iterations: iterations))
            let model: MLStyleTransfer = try await withCheckedThrowingContinuation { cont in
                var done = false
                let c = job.result.sink(receiveCompletion: { r in
                    if case .failure(let e) = r, !done { done = true; cont.resume(throwing: e) }
                }, receiveValue: { m in
                    if !done { done = true; cont.resume(returning: m) }
                })
                self.bag[p.id] = c
                // progress polling
                Task.detached {
                    while !done {
                        let f = job.progress.fractionCompleted
                        await MainActor.run { self.progress[p.id] = f }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
            }
            bag[p.id] = nil
            let raw = work.appendingPathComponent("\(p.id).mlmodel")
            try model.write(to: raw)
            let compiled = try await MLModel.compileModel(at: raw)
            let dest = compiledURL(p.id)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: compiled, to: dest)
            await MainActor.run { self.progress[p.id] = nil }
            return dest
        }
    }

    static func writePNG(_ cg: CGImage, _ url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { throw ModelError.compile("png") }
        CGImageDestinationAddImage(d, cg, nil)
        if !CGImageDestinationFinalize(d) { throw ModelError.compile("png") }
    }

    private static var loaded: [String: MLModel] = [:]
    private static let lock = NSLock()

    static func unloadAll() { lock.lock(); loaded.removeAll(); lock.unlock() }

    static func model(_ id: String) throws -> MLModel {
        MemoryHygiene.modelUsed()
        lock.lock(); defer { lock.unlock() }
        if let m = loaded[id] { return m }
        let m = try MLModel(contentsOf: compiledURL(id))
        loaded[id] = m
        return m
    }

    /// Runs a trained style model (image in → image out), tiling when the model has a fixed size.
    static func stylize(_ cg: CGImage, model: MLModel) throws -> CGImage {
        guard let (inName, inDesc) = model.modelDescription.inputDescriptionsByName.first,
              let outName = model.modelDescription.outputDescriptionsByName.keys.first else { throw ModelError.compile("style I/O") }
        var w = inDesc.imageConstraint?.pixelsWide ?? 512, h = inDesc.imageConstraint?.pixelsHigh ?? 512
        // fixed-size model: keep the aspect ratio — run overlapping tiles on the image scaled to ~1.5 tiles high
        if inDesc.imageConstraint?.sizeConstraint.type != .range, w == h {
            let T = w
            let s = min(2.0, max(1.0, Double(T) * 1.5 / Double(min(cg.width, cg.height))))
            let sw = max(T, Int(Double(cg.width) * s)), sh = max(T, Int(Double(cg.height) * s))
            let src = PlanarImage.rgb(cg, width: sw, height: sh)
            let res = try TiledRunner.run(src, tile: T, overlap: T / 8, scale: 1) { t in
                guard let pb = NeuralTensor.pixelBuffer(t.cgImage(), width: T, height: T) else { throw ModelError.compile("style input") }
                let o = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(pixelBuffer: pb)]))
                guard let v = o.featureValue(for: outName), let p = NeuralTensor.planar(v) else { throw ModelError.compile("style output") }
                return p
            }
            return NImg.resized(res.cgImage(), cg.width, cg.height)
        }
        // flexible sizes: run the whole image (rounded to a multiple of 4)
        if let sc = inDesc.imageConstraint?.sizeConstraint, sc.type == .range {
            let side = max(cg.width, cg.height)
            let s = min(1, 1024 / Double(side))
            w = max(64, Int(Double(cg.width) * s) / 4 * 4); h = max(64, Int(Double(cg.height) * s) / 4 * 4)
            w = min(max(w, sc.pixelsWideRange.location), sc.pixelsWideRange.location + sc.pixelsWideRange.length)
            h = min(max(h, sc.pixelsHighRange.location), sc.pixelsHighRange.location + sc.pixelsHighRange.length)
        }
        guard let pb = NeuralTensor.pixelBuffer(cg, width: w, height: h) else { throw ModelError.compile("style input") }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(pixelBuffer: pb)]))
        guard let v = out.featureValue(for: outName), let p = NeuralTensor.planar(v) else { throw ModelError.compile("style output") }
        return NImg.resized(p.cgImage(), cg.width, cg.height)
    }

    /// Fast approximation: the preset's Filter Gallery look + palette transfer from the style image.
    static func fast(_ cg: CGImage, _ p: Preset, preserveColor: Bool) -> CGImage {
        let img = CIImage(cgImage: cg)
        let r = img.extent
        var out = p.look.apply(img, values: p.lookValues, fg: .black, bg: .white, canvas: r)
        if !preserveColor, let st = styleImage(p, size: 256), let stats = ColorStats.lab(CIImage(cgImage: st)), let t = ColorStats.lab(out) {
            var m = MatchColorSettings(); m.target = t; m.source = stats; m.fade = 25
            out = AdjustmentEngine.applyMatchColor(m, out)
        }
        return NImg.cg(out.cropped(to: r), rect: r) ?? cg
    }

    static func apply(_ cg: CGImage, v: (String) -> Double, progress: ((Double) -> Void)?) async throws -> CGImage {
        let p = preset(Int(v("style")))
        let preserve = v("preserveColor") > 0.5
        var out: CGImage
        if v("mode") < 0.5 {
            _ = try await Trainer.shared.train(p, content: cg)
            out = try stylize(cg, model: try model(p.id))
        } else {
            out = fast(cg, p, preserveColor: preserve)
        }
        let img = CIImage(cgImage: cg)
        var o = CIImage(cgImage: out)
        if preserve { o = o.applyingFilter("CILuminosityBlendMode", parameters: [kCIInputBackgroundImageKey: img]) }
        if v("blur") > 0 {
            let b = img.clampedToExtent().applyingGaussianBlur(sigma: v("blur") / 10).cropped(to: img.extent)
            _ = b
            let ob = o.clampedToExtent().applyingGaussianBlur(sigma: v("blur") / 8).cropped(to: img.extent)
            if let pm = PortraitFilters.personMask(cg) { o = o.mixed(with: ob, mask: pm) } else { o = ob }
        }
        let res = NImg.cg(o.cropped(to: img.extent).masked(byAlphaOf: img), rect: img.extent) ?? out
        return NeuralFilterEngine.blend(cg, res, v("strength") / 100)
    }
}
