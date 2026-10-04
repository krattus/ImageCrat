import Foundation
import CoreML
import CoreImage
import AppKit
import ImageCratCore

/// `LUMEN_SELFTEST_ONLY=neural Lumen --selftest <dir>`: end-to-end tests of the neural features.
/// Sub-filter with LUMEN_NEURAL_ONLY=lama,esrgan,… (comma separated).
enum NeuralSelfTest {
    /// Runs an async body to completion from synchronous (main-thread) code, pumping the main run loop.
    static func sync<T>(_ body: @escaping () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        Task.detached { do { result = .success(try await body()) } catch { result = .failure(error) } }
        while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
        return try result!.get()
    }

    static func want(_ n: String) -> Bool {
        guard let only = ProcessInfo.processInfo.environment["LUMEN_NEURAL_ONLY"], !only.isEmpty else { return true }
        return only.split(separator: ",").contains { n.hasPrefix($0) }
    }

    static func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try body()
        print(String(format: "  ⏱ %@: %.2f s", label, CFAbsoluteTimeGetCurrent() - t0))
        return r
    }

    static func write(_ cg: CGImage, _ name: String, _ out: URL) {
        let url = out.appendingPathComponent(name + ".png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("wrote \(name)")
    }

    static func run(_ out: URL) {
        print("== neural self test")
        if want("models") {
            for id in NeuralModelID.modelFile.keys.sorted() {
                do {
                    let m = try time("load \(id)") { try sync { try await NeuralModels.load(id) } }
                    print("  \(id): \(NeuralTensor.describe(m))")
                } catch { print("  \(id): NOT AVAILABLE – \(error.localizedDescription)") }
            }
        }
        runEngineTests(out)
        NeuralSelfTest2.run(out)
    }

    // MARK: Sample images (generic system images only)

    static let aerialURL = URL(fileURLWithPath: "/System/Library/Wallpapers/.default/DefaultAerial.jpg")
    static func aerial(_ maxSide: Int = 1200) -> CGImage {
        if let cg = NImg.loadCG(aerialURL) { return NImg.fitted(cg, maxSide: maxSide) }
        return synthLandscape(maxSide, maxSide * 9 / 16)
    }

    /// Synthetic landscape: sky gradient, hills, a lake and a few rocks.
    static func synthLandscape(_ w: Int, _ h: Int) -> CGImage {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "3A7BD5")!.cgColor, RGBA(hex: "A8D8F0")!.cgColor] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: Double(h) * 0.55), options: [.drawsAfterEndLocation])
        c.setFillColor(RGBA(hex: "4E7D3A")!.cgColor)
        let p = CGMutablePath(); p.move(to: CGPoint(x: 0, y: Double(h) * 0.55))
        for i in 0...20 { p.addLine(to: CGPoint(x: Double(w) * Double(i) / 20, y: Double(h) * (0.5 + 0.06 * sin(Double(i) * 0.9)))) }
        p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.closeSubpath()
        c.addPath(p); c.fillPath()
        b.markDirty()
        return b.makeCGImage()
    }

    // MARK: Engines

    static func runEngineTests(_ out: URL) {
        let img = aerial(1200)
        print("  sample \(img.width)×\(img.height)")
        if want("lama"), LamaInpainter.isAvailable {
            // remove the big rock in the lower left (ellipse), measured on the 800-wide preview: centre (237,305), 70×30
            let s = Double(img.width) / 800
            let hole = PixelBuffer(width: img.width, height: img.height, format: .gray)
            hole.context.setFillColor(gray: 1, alpha: 1)
            hole.context.fillEllipse(in: CGRect(x: 150 * s, y: 262 * s, width: 172 * s, height: 92 * s))
            hole.markDirty()
            let hp = PlanarImage.gray(hole.makeCGImage())
            do {
                let r = try time("LaMa remove rock") { try sync { try await LamaInpainter.inpaint(img, hole: hp) } }
                write(img, "neural_lama_before", out); write(r, "neural_lama_after", out)
                if let c = NImg.crop(r, CGRect(x: 100 * s, y: 200 * s, width: 300 * s, height: 200 * s)) { write(c, "neural_lama_after_crop", out) }
            } catch { print("FAIL lama: \(error)") }
        }
        if want("esrgan"), SuperResolution.isAvailable, let crop = NImg.crop(aerial(800), CGRect(x: 380, y: 180, width: 160, height: 120)) {
            do {
                let r = try time("Real-ESRGAN ×4 (160×120 → 640×480)") { try sync { try await SuperResolution.upscale(crop, factor: 4) } }
                write(NImg.resized(crop, 640, 480), "neural_esrgan_bicubic", out); write(r, "neural_esrgan_x4", out)
            } catch { print("FAIL esrgan: \(error)") }
        }
        if want("nafnet"), Restoration.isAvailable(.denoise), let clean = NImg.crop(aerial(1200), CGRect(x: 350, y: 250, width: 512, height: 384)) {
            let noisy = addNoise(clean, sigma: 25)
            do {
                let r = try time("NAFNet denoise 512×384") { try sync { try await Restoration.run(noisy, .denoise) } }
                print(String(format: "  denoise PSNR: noisy %.2f dB → denoised %.2f dB", NImg.psnr(clean, noisy), NImg.psnr(clean, r)))
                write(noisy, "neural_denoise_noisy", out); write(r, "neural_denoise_result", out)
            } catch { print("FAIL denoise: \(error)") }
            if Restoration.isAvailable(.deblur), let blurred = NImg.cg(CIImage(cgImage: clean).clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: CGRect(x: 0, y: 0, width: 512, height: 384))) {
                do {
                    let r = try time("NAFNet deblur, Gaussian σ2 (out of distribution) 512×384") { try sync { try await Restoration.run(blurred, .deblur) } }
                    print(String(format: "  deblur PSNR: blurred %.2f dB → deblurred %.2f dB", NImg.psnr(clean, blurred), NImg.psnr(clean, r)))
                    write(blurred, "neural_deblur_input", out); write(r, "neural_deblur_result", out)
                } catch { print("FAIL deblur: \(error)") }
            }
        }
        if want("depth"), DepthEstimator.isAvailable {
            do {
                let d = try time("Depth Anything V2 (landscape)") { try sync { try await DepthEstimator.depth(img) } }
                write(d.cgImage(), "neural_depth_map", out)
                let portrait = NImg.crop(img, CGRect(x: 300, y: 0, width: 400, height: 600))!
                let dp = try time("Depth Anything V2 (portrait)") { try sync { try await DepthEstimator.depth(portrait) } }
                write(dp.cgImage(), "neural_depth_map_portrait", out)
            } catch { print("FAIL depth: \(error)") }
        }
        if want("colorize"), Colorizer.isAvailable {
            let gray = NImg.cg(CIImage(cgImage: img).applyingFilter("CIPhotoEffectMono"))!
            do {
                let r = try time("DDColor colorize") { try sync { try await Colorizer.colorize(gray) } }
                write(gray, "neural_colorize_input", out); write(r, "neural_colorize_result", out)
                if let parrot = NImg.loadCG(URL(fileURLWithPath: "/Library/User Pictures/Animals/Parrot.heic")) {
                    let g2 = NImg.cg(CIImage(cgImage: parrot).applyingFilter("CIPhotoEffectMono"))!
                    let r2 = try sync { try await Colorizer.colorize(g2) }
                    write(g2, "neural_colorize_parrot_input", out); write(r2, "neural_colorize_parrot", out)
                }
            } catch { print("FAIL colorize: \(error)") }
        }
    }

    static func addNoise(_ cg: CGImage, sigma: Double) -> CGImage {
        var p = PlanarImage.rgb(cg)
        var rng = SystemRandomNumberGenerator()
        var seed: UInt64 = 12345
        _ = rng
        func gauss() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u1 = max(1e-7, Double(seed >> 11) / Double(1 << 53))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let u2 = Double(seed >> 11) / Double(1 << 53)
            return Float(sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
        for i in p.data.indices { p.data[i] = max(0, min(1, p.data[i] + gauss() * Float(sigma / 255))) }
        return p.cgImage()
    }
}
