import Foundation
import CoreML
import CoreImage
import CoreVideo
import Accelerate
import ImageCratCore

/// Model ids used by Neural Filters, Remove (LaMa), Super Zoom and AI Denoise.
enum NeuralModelID {
    static let lama = "big-lama"
    static let esrgan = "realesrgan-x4plus"
    static let depth = "depth-anything-v2-small"
    static let ddcolor = "ddcolor-tiny"
    static let nafnetDenoise = "nafnet-sidd-w32"
    static let nafnetDeblur = "nafnet-gopro-w32"
    static let gfpgan = "gfpgan-v1.4"

    /// Relative path of the (compiled) model inside each model folder.
    static let modelFile: [String: String] = [
        lama: "LaMa.mlpackage",
        esrgan: "RealESRGAN-x4plus.mlpackage",
        depth: "DepthAnythingV2SmallF16.mlpackage",
        ddcolor: "DDColor_Tiny.mlpackage",
        nafnetDenoise: "NAFNet_SIDD_w32.mlpackage",
        nafnetDeblur: "NAFNet_GoPro_w32.mlpackage",
        gfpgan: "GFPGANv1.4.mlpackage",
    ]

    /// Placeholder host for models converted by the ImageCrat team (NAFNet, GFPGAN). Replace with a real
    /// repository (e.g. a Hugging Face repo) before shipping; until then they are installed locally.
    static let lumenModelsRepo = "imagecrat-app/neural-models"
}

enum NeuralModels {
    static func registerSpecs() {
        let mm = ModelManager.shared
        typealias F = ModelSpec.File
        mm.register(ModelSpec(
            id: NeuralModelID.lama, name: "LaMa (big-lama)", purpose: "Generative Remove, Find Distractions, scratch repair",
            license: "Apache-2.0", approxMB: 95,
            files: [F(url: ModelManager.hf("Jia-Liu/big-lama-coreml", "big-lama-coreml.zip", revision: "5bc9fc233547beca7ca4307be4bbca5e04e57e66"),
                      path: "big-lama-coreml.zip", sha256: "8e1fb17d1f21233c350524453a6f58fe986f919eead26067afb2f3814f5e5adf")],
            compile: ["LaMa.mlpackage"]))
        mm.register(ModelSpec(
            id: NeuralModelID.esrgan, name: "Real-ESRGAN x4plus", purpose: "Super Zoom / AI upscaling",
            license: "BSD-3-Clause", approxMB: 33,
            files: [F(url: ModelManager.hf("LocalMuseAI/coreml-realesrgan-x4plus", "RealESRGAN-x4plus.mlpackage.zip", revision: "4f6c21f7c431ae4e52ae45d11d6195fd96d93fcc"),
                      path: "RealESRGAN-x4plus.mlpackage.zip", sha256: "61d44a58bb8549a0c0485c95d2b384c598b48a648231206b3e7c2ac221e64599")],
            compile: ["RealESRGAN-x4plus.mlpackage"]))
        let depthRev = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
        let dp = "DepthAnythingV2SmallF16.mlpackage"
        mm.register(ModelSpec(
            id: NeuralModelID.depth, name: "Depth Anything V2 Small", purpose: "Depth Blur, Sky Replacement lighting",
            license: "Apache-2.0", approxMB: 50,
            files: [
                F(url: ModelManager.hf("apple/coreml-depth-anything-v2-small", dp + "/Manifest.json", revision: depthRev), path: dp + "/Manifest.json"),
                F(url: ModelManager.hf("apple/coreml-depth-anything-v2-small", dp + "/Data/com.apple.CoreML/model.mlmodel", revision: depthRev),
                  path: dp + "/Data/com.apple.CoreML/model.mlmodel", sha256: "44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042"),
                F(url: ModelManager.hf("apple/coreml-depth-anything-v2-small", dp + "/Data/com.apple.CoreML/weights/weight.bin", revision: depthRev),
                  path: dp + "/Data/com.apple.CoreML/weights/weight.bin", sha256: "fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed"),
            ],
            compile: [dp]))
        let ddRev = "48c9a506b578460681078e31378e2eaae424a044"
        let dd = "DDColor_Tiny.mlpackage"
        mm.register(ModelSpec(
            id: NeuralModelID.ddcolor, name: "DDColor Tiny", purpose: "Colorize",
            license: "Apache-2.0", approxMB: 242,
            files: [
                F(url: ModelManager.hf("mlboydaisuke/DDColor-Tiny-CoreML", dd + "/Manifest.json", revision: ddRev), path: dd + "/Manifest.json"),
                F(url: ModelManager.hf("mlboydaisuke/DDColor-Tiny-CoreML", dd + "/Data/com.apple.CoreML/model.mlmodel", revision: ddRev),
                  path: dd + "/Data/com.apple.CoreML/model.mlmodel", sha256: "258385e6eea40b0f3cfc429a2c4039b152a90fd90713006ac8a4ed079d5f6daa"),
                F(url: ModelManager.hf("mlboydaisuke/DDColor-Tiny-CoreML", dd + "/Data/com.apple.CoreML/weights/weight.bin", revision: ddRev),
                  path: dd + "/Data/com.apple.CoreML/weights/weight.bin", sha256: "118a042707379a12e62b159b0b2a6ef82db909098eab0eef695718be3e41b85d"),
            ],
            compile: [dd]))
        // Converted by Lumen (see report): hosted locally until a public repository exists.
        // Conversion scripts: scripts/neural/convert_nafnet.py, scripts/neural/convert_gfpgan.py (fp16 ML programs).
        for (id, name, purpose, lic, mb, sha) in [
            (NeuralModelID.nafnetDenoise, "NAFNet SIDD (width 32)", "AI Denoise, JPEG Artifacts Removal, Photo Restoration", "MIT", 54,
             "951e22afe88c8deb0bd034a5b1d9316810ae1856dfa7677b2e702271da456f11"),
            (NeuralModelID.nafnetDeblur, "NAFNet GoPro (width 32)", "AI Sharpen / Deblur, Photo Restoration", "MIT", 32,
             "8a1bf91b0aa2d3b1d8658f7d0b40e444af6de795c1d2f45c3cce68a113a14502"),
            (NeuralModelID.gfpgan, "GFPGAN v1.4", "Face restoration (Super Zoom, Photo Restoration)",
             "Apache-2.0 + NVIDIA Source Code License (StyleGAN2 parts, non-commercial)", 161,
             "bc0ade0802f2aed3c2c0ecf3db9ee3029eb75ba0dc3438c4151a4aa388b3b8e0"),
        ] {
            let file = NeuralModelID.modelFile[id]!
            mm.register(ModelSpec(id: id, name: name, purpose: purpose, license: lic, approxMB: mb,
                                  files: [F(url: ModelManager.hf(NeuralModelID.lumenModelsRepo, file + ".zip"), path: file + ".zip", sha256: sha)],
                                  compile: [file]))
        }
    }

    static func isInstalled(_ id: String) -> Bool { ModelManager.shared.isInstalled(id) }

    /// LUMEN_NEURAL_VERBOSE=1 prints per-inference timings.
    static let verbose = ProcessInfo.processInfo.environment["LUMEN_NEURAL_VERBOSE"] != nil

    /// Downloads (if needed) and loads a model, cached per id / compute units.
    static func load(_ id: String, units: MLComputeUnits = .all) async throws -> MLModel {
        try await ModelManager.shared.ensure(id)
        MemoryHygiene.modelUsed()
        return try cache.get(id, units: units)
    }

    private static let cache = ModelCache()

    final class ModelCache: @unchecked Sendable {
        private var models: [String: MLModel] = [:]
        private let lock = NSLock()
        func get(_ id: String, units: MLComputeUnits) throws -> MLModel {
            let key = "\(id)#\(units.rawValue)"
            lock.lock(); defer { lock.unlock() }
            if let m = models[key] { return m }
            guard let rel = NeuralModelID.modelFile[id] else { throw ModelError.notInstalled(id) }
            let m = try ModelManager.shared.loadModel(id, rel, units: units)
            models[key] = m
            return m
        }
        func purge() { lock.lock(); models.removeAll(); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return models.count }
    }

    /// Drops the loaded LaMa / Depth Anything / … models (reloaded on next use).
    static func unloadAll() { cache.purge() }
    static var loadedCount: Int { cache.count }
}

// MARK: - Tensor helpers

/// Planar float image (CHW), values usually 0…1.
struct PlanarImage {
    var width: Int
    var height: Int
    var channels: Int
    var data: [Float]

    init(width: Int, height: Int, channels: Int, fill: Float = 0) {
        self.width = width; self.height = height; self.channels = channels
        data = [Float](repeating: fill, count: width * height * channels)
    }

    @inline(__always) func at(_ c: Int, _ x: Int, _ y: Int) -> Float { data[c * width * height + y * width + x] }

    /// Unpremultiplied RGB (0…1) of a CGImage, resized to w×h (default: native size).
    static func rgb(_ cg: CGImage, width w: Int? = nil, height h: Int? = nil) -> PlanarImage {
        let W = w ?? cg.width, H = h ?? cg.height
        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: sRGBSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        var p = PlanarImage(width: W, height: H, channels: 3)
        let n = W * H
        p.data.withUnsafeMutableBufferPointer { dst in
            for i in 0..<n {
                dst[i] = Float(bytes[i * 4]) / 255
                dst[n + i] = Float(bytes[i * 4 + 1]) / 255
                dst[2 * n + i] = Float(bytes[i * 4 + 2]) / 255
            }
        }
        return p
    }

    /// Gray (0…1) of a CGImage (luminance or single channel).
    static func gray(_ cg: CGImage, width w: Int? = nil, height h: Int? = nil) -> PlanarImage {
        let W = w ?? cg.width, H = h ?? cg.height
        var bytes = [UInt8](repeating: 0, count: W * H)
        let ctx = CGContext(data: &bytes, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W, space: graySpace,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
        var p = PlanarImage(width: W, height: H, channels: 1)
        for i in 0..<(W * H) { p.data[i] = Float(bytes[i]) / 255 }
        return p
    }

    /// Opaque RGB (or gray) CGImage.
    func cgImage() -> CGImage {
        let n = width * height
        if channels == 1 {
            var bytes = [UInt8](repeating: 0, count: n)
            for i in 0..<n { bytes[i] = UInt8(max(0, min(255, (data[i] * 255).rounded()))) }
            let prov = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width, space: graySpace,
                           bitmapInfo: CGBitmapInfo(rawValue: 0), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        }
        var bytes = [UInt8](repeating: 255, count: n * 4)
        data.withUnsafeBufferPointer { s in
            for i in 0..<n {
                bytes[i * 4] = UInt8(max(0, min(255, (s[i] * 255).rounded())))
                bytes[i * 4 + 1] = UInt8(max(0, min(255, (s[n + i] * 255).rounded())))
                bytes[i * 4 + 2] = UInt8(max(0, min(255, (s[2 * n + i] * 255).rounded())))
            }
        }
        let prov = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: sRGBSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)!
    }

    /// Copies a w×h window starting at (x0, y0) with edge clamping.
    func crop(x0: Int, y0: Int, w: Int, h: Int) -> PlanarImage {
        var o = PlanarImage(width: w, height: h, channels: channels)
        for c in 0..<channels {
            for y in 0..<h {
                let sy = max(0, min(height - 1, y0 + y))
                for x in 0..<w {
                    let sx = max(0, min(width - 1, x0 + x))
                    o.data[c * w * h + y * w + x] = data[c * width * height + sy * width + sx]
                }
            }
        }
        return o
    }

    /// Reflect-pads to a multiple of `m` (returns padded image and original size).
    func padded(toMultipleOf m: Int) -> PlanarImage {
        let W = (width + m - 1) / m * m, H = (height + m - 1) / m * m
        if W == width && H == height { return self }
        var o = PlanarImage(width: W, height: H, channels: channels)
        for c in 0..<channels {
            for y in 0..<H {
                var sy = y; if sy >= height { sy = max(0, 2 * height - 2 - sy) }
                for x in 0..<W {
                    var sx = x; if sx >= width { sx = max(0, 2 * width - 2 - sx) }
                    o.data[c * W * H + y * W + x] = data[c * width * height + sy * width + sx]
                }
            }
        }
        return o
    }
}

enum NeuralTensor {
    /// MLMultiArray [1, C, H, W] from a planar image, with optional per-channel affine (x * scale + bias).
    static func multiArray(_ p: PlanarImage, shape: [Int]? = nil, dataType: MLMultiArrayDataType = .float32, scale: Float = 1, bias: Float = 0) throws -> MLMultiArray {
        let shp = shape ?? [1, p.channels, p.height, p.width]
        let arr = try MLMultiArray(shape: shp.map { NSNumber(value: $0) }, dataType: dataType)
        let n = p.data.count
        switch dataType {
        case .float16:
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float16.self)
            p.data.withUnsafeBufferPointer { s in for i in 0..<n { ptr[i] = Float16(s[i] * scale + bias) } }
        case .double:
            let ptr = arr.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<n { ptr[i] = Double(p.data[i] * scale + bias) }
        default:
            let ptr = arr.dataPointer.assumingMemoryBound(to: Float.self)
            p.data.withUnsafeBufferPointer { s in for i in 0..<n { ptr[i] = s[i] * scale + bias } }
        }
        return arr
    }

    /// Planar image from an MLMultiArray shaped [1, C, H, W] / [C, H, W] / [1, H, W] / [H, W]. Handles strides.
    static func planar(_ a: MLMultiArray, scale: Float = 1, bias: Float = 0) -> PlanarImage {
        let shp = a.shape.map { $0.intValue }
        let st = a.strides.map { $0.intValue }
        let r = shp.count
        let W = shp[r - 1], H = shp[r - 2]
        let C = r >= 3 ? shp[r - 3] : 1
        let sw = st[r - 1], sh = st[r - 2], sc = r >= 3 ? st[r - 3] : 0
        var p = PlanarImage(width: W, height: H, channels: C)
        func read<T>(_ t: T.Type, _ conv: (T) -> Float) {
            let ptr = a.dataPointer.assumingMemoryBound(to: T.self)
            for c in 0..<C { for y in 0..<H { for x in 0..<W {
                p.data[c * W * H + y * W + x] = conv(ptr[c * sc + y * sh + x * sw]) * scale + bias
            } } }
        }
        switch a.dataType {
        case .float16: read(Float16.self) { Float($0) }
        case .double: read(Double.self) { Float($0) }
        case .int32: read(Int32.self) { Float($0) }
        default: read(Float.self) { $0 }
        }
        return p
    }

    /// BGRA / OneComponent8 CVPixelBuffer from a CGImage resized to w×h.
    static func pixelBuffer(_ cg: CGImage, width w: Int, height h: Int, gray: Bool = false) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let fmt = gray ? kCVPixelFormatType_OneComponent8 : kCVPixelFormatType_32BGRA
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary, kCVPixelBufferCGImageCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, w, h, fmt, attrs as CFDictionary, &pb) == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let info: UInt32 = gray ? CGImageAlphaInfo.none.rawValue : (CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: gray ? graySpace : sRGBSpace, bitmapInfo: info) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    /// Planar image (0…1) from a BGRA / gray CVPixelBuffer.
    static func planar(_ pb: CVPixelBuffer) -> PlanarImage {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!
        switch fmt {
        case kCVPixelFormatType_OneComponent8:
            var p = PlanarImage(width: w, height: h, channels: 1)
            let s = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w { p.data[y * w + x] = Float(s[y * rb + x]) / 255 } }
            return p
        case kCVPixelFormatType_OneComponent16Half:
            var p = PlanarImage(width: w, height: h, channels: 1)
            for y in 0..<h {
                let row = (base + y * rb).assumingMemoryBound(to: Float16.self)
                for x in 0..<w { p.data[y * w + x] = Float(row[x]) }
            }
            return p
        case kCVPixelFormatType_OneComponent32Float:
            var p = PlanarImage(width: w, height: h, channels: 1)
            for y in 0..<h {
                let row = (base + y * rb).assumingMemoryBound(to: Float.self)
                for x in 0..<w { p.data[y * w + x] = row[x] }
            }
            return p
        default:
            var p = PlanarImage(width: w, height: h, channels: 3)
            let s = base.assumingMemoryBound(to: UInt8.self)
            let n = w * h
            let rgba = fmt == kCVPixelFormatType_32RGBA
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * rb + x * 4
                    let r = rgba ? s[i] : s[i + 2], b = rgba ? s[i + 2] : s[i]
                    p.data[y * w + x] = Float(r) / 255
                    p.data[n + y * w + x] = Float(s[i + 1]) / 255
                    p.data[2 * n + y * w + x] = Float(b) / 255
                }
            }
            return p
        }
    }

    /// Feature value for `desc`, from an RGB planar image (0…1). Image inputs are filled via CVPixelBuffer,
    /// multi-array inputs with `scale`/`bias` applied.
    static func feature(_ desc: MLFeatureDescription, rgb: PlanarImage, scale: Float = 1, bias: Float = 0) throws -> MLFeatureValue {
        if desc.type == .image, let c = desc.imageConstraint {
            let gray = c.pixelFormatType == kCVPixelFormatType_OneComponent8
            let src = gray && rgb.channels == 3 ? luminance(rgb) : rgb
            guard let pb = pixelBuffer(src.cgImage(), width: c.pixelsWide, height: c.pixelsHigh, gray: gray) else { throw ModelError.compile("pixel buffer") }
            return MLFeatureValue(pixelBuffer: pb)
        }
        let c = desc.multiArrayConstraint
        let shape = c?.shape.map { $0.intValue } ?? [1, rgb.channels, rgb.height, rgb.width]
        return MLFeatureValue(multiArray: try multiArray(rgb, shape: shape.count == 4 ? [shape[0], rgb.channels, rgb.height, rgb.width] : shape,
                                                         dataType: c?.dataType ?? .float32, scale: scale, bias: bias))
    }

    /// Planar image from any output feature (image or multi-array).
    static func planar(_ v: MLFeatureValue, scale: Float = 1, bias: Float = 0) -> PlanarImage? {
        if let pb = v.imageBufferValue {
            var p = planar(pb)
            if scale != 1 || bias != 0 { for i in p.data.indices { p.data[i] = p.data[i] * scale + bias } }
            return p
        }
        if let a = v.multiArrayValue { return planar(a, scale: scale, bias: bias) }
        return nil
    }

    static func luminance(_ p: PlanarImage) -> PlanarImage {
        guard p.channels == 3 else { return p }
        let n = p.width * p.height
        var o = PlanarImage(width: p.width, height: p.height, channels: 1)
        for i in 0..<n { o.data[i] = 0.299 * p.data[i] + 0.587 * p.data[n + i] + 0.114 * p.data[2 * n + i] }
        return o
    }

    /// Description of a model's inputs/outputs (for diagnostics / self test).
    static func describe(_ m: MLModel) -> String {
        func d(_ f: MLFeatureDescription) -> String {
            switch f.type {
            case .image: let c = f.imageConstraint!; return "\(f.name): image \(c.pixelsWide)x\(c.pixelsHigh) fmt=\(c.pixelFormatType)"
            case .multiArray: let c = f.multiArrayConstraint!; return "\(f.name): array \(c.shape) \(c.dataType.rawValue) shapeConstraint=\(c.shapeConstraint.type.rawValue)"
            default: return "\(f.name): \(f.type.rawValue)"
            }
        }
        let i = m.modelDescription.inputDescriptionsByName.values.map(d).sorted().joined(separator: "; ")
        let o = m.modelDescription.outputDescriptionsByName.values.map(d).sorted().joined(separator: "; ")
        return "in[\(i)] out[\(o)]"
    }
}
