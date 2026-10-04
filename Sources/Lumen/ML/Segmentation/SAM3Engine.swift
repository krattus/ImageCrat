import Foundation
import CoreImage
#if canImport(SAM31)
import SAM31
import ImageCratCore
#endif

/// SAM 3.1 (Meta, via sam31-swift on MLX): open-vocabulary text → instance masks. Used as the
/// "High Quality" engine for text prompts when its weights (≈3.3 GB) and MLX's Metal kernels are installed.
enum SAM3Engine {
    struct Result {
        var box: CGRect           // doc coords
        var score: Float
        var logits: [Float]
        var w: Int, h: Int
        func ciMask(canvasW: Int, canvasH: Int, guide: CIImage?, hard: Bool) -> CIImage {
            SegMask.fullMask(logits, w: w, h: h, rect: CGRect(x: 0, y: 0, width: canvasW, height: canvasH), canvasW: canvasW, canvasH: canvasH, guide: guide, hard: hard)
        }
    }

    /// MLX loads its Metal kernels from `mlx.metallib` next to the executable (SwiftPM builds don't produce it;
    /// see scripts/build_mlx_metallib.sh) or from an Xcode-built `mlx-swift_Cmlx.bundle`.
    static var metalKernelsPresent: Bool {
        let fm = FileManager.default
        var cands: [URL] = []
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            cands += [exe.appendingPathComponent("mlx.metallib"), exe.appendingPathComponent("Resources/mlx.metallib")]
        }
        let b = Bundle.main.bundleURL
        cands += [b.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
                  b.appendingPathComponent("mlx-swift_Cmlx.bundle/default.metallib")]
        if let r = Bundle.main.resourceURL {
            cands += [r.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"), r.appendingPathComponent("mlx.metallib")]
        }
        return cands.contains { fm.fileExists(atPath: $0.path) }
    }

    static var isCompiledIn: Bool {
        #if canImport(SAM31)
        return true
        #else
        return false
        #endif
    }

    /// The SAM31 package reads its CLIP tokenizer files through SwiftPM's `Bundle.module`; Lumen finds the bundle in
    /// `Lumen.app/Contents/Resources` (copied by scripts/build_app.sh) or next to a development binary and points the
    /// package at it (see `SAM3Resources`). Without the files the package would trap, so SAM 3.1 stays off then.
    static var tokenizerResourcesPresent: Bool { SAM3Resources.bundleURL != nil }

    static var isAvailable: Bool { isCompiledIn && SegModels.sam3Installed && metalKernelsPresent && tokenizerResourcesPresent }

    static var unavailableReason: String? {
        if !isCompiledIn { return "SAM 3.1 support is not built into this copy of ImageCrat." }
        if !SegModels.sam3Installed { return "SAM 3.1 weights are not installed (Preferences ▸ AI Models)." }
        if !metalKernelsPresent { return "SAM 3.1 needs MLX's Metal kernels (mlx.metallib), which are missing from this copy of ImageCrat (a build made without scripts/build_mlx_metallib.sh)." }
        if !tokenizerResourcesPresent {
            return "SAM 3.1's tokenizer files (\(SAM3Resources.bundleName): clip-vocab.json, clip-merges.txt) are missing from this copy of ImageCrat — they belong in ImageCrat.app/Contents/Resources. Reinstall ImageCrat (a development build gets them from swift build)."
        }
        return nil
    }

    #if canImport(SAM31)
    private final class Holder: @unchecked Sendable {
        var model: SAM31Model?
        var features: (key: String, f: FrameFeatures)?
    }
    private static let holder = Holder()
    private static let lock = NSLock()

    private static func model() async throws -> SAM31Model {
        MemoryHygiene.modelUsed()
        if let m = lock.withLock({ holder.model }) { return m }
        let dir = ModelManager.shared.folder(SegModels.sam3)
        SAM3Resources.installLookup()   // the package's tokenizer lookup → the bundle in Contents/Resources (before its first use)
        let t0 = CFAbsoluteTimeGetCurrent()
        let m = try await SAM31Model.load(from: dir)
        SegLog.record("sam3.load", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        // MLX keeps freed GPU buffers for reuse, by default up to its whole memory limit (seen as IOAccelerator memory).
        await m.setCacheLimit(bytes: 256 << 20)
        lock.withLock { holder.model = m }
        return m
    }

    static var isLoaded: Bool { lock.withLock { holder.model != nil } }

    static func unload() {
        let m = lock.withLock { () -> SAM31Model? in
            let m = holder.model
            holder.model = nil; holder.features = nil
            return m
        }
        if let m { Task { await m.setCacheLimit(bytes: 0) } }   // hand MLX's buffer cache back as the weights are released
    }

    /// Detects every instance matching `text`. Boxes are in doc coordinates.
    static func detect(_ img: SegImage, text: String, threshold: Float = 0.4) async throws -> [Result] {
        guard isAvailable else { throw SAMError.failed(unavailableReason ?? "SAM 3.1 unavailable") }
        let m = try await model()
        let feats: FrameFeatures
        if let f = lock.withLock({ holder.features }), f.key == img.id {
            feats = f.f
        } else {
            // the model resizes to 1008² itself; feed a ≤2048 px rendition to keep preprocessing cheap
            let scale = min(1, 2048 / CGFloat(max(img.width, img.height)))
            let w = max(1, Int(CGFloat(img.width) * scale)), h = max(1, Int(CGFloat(img.height) * scale))
            let bytes = img.rgba(rect: img.canvas, w: w, h: h)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGBSpace,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { throw SAMError.failed("image") }
            let t0 = CFAbsoluteTimeGetCurrent()
            feats = try await m.encode(cg)
            SegLog.record("sam3.encode", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
            lock.withLock { holder.features = (img.id, feats) }
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let dets = try await m.detect(feats, text: text, scoreThreshold: threshold)
        SegLog.record("sam3.detect", (CFAbsoluteTimeGetCurrent() - t1) * 1000)
        let sx = CGFloat(img.width) / feats.sourceSize.width, sy = CGFloat(img.height) / feats.sourceSize.height
        return dets.map { d in
            Result(box: CGRect(x: d.box.minX * sx, y: d.box.minY * sy, width: d.box.width * sx, height: d.box.height * sy),
                   score: d.score, logits: d.mask.values, w: d.mask.width, h: d.mask.height)
        }
    }
    #else
    static var isLoaded: Bool { false }
    static func unload() {}
    static func detect(_ img: SegImage, text: String, threshold: Float = 0.4) async throws -> [Result] {
        throw SAMError.failed(unavailableReason ?? "SAM 3.1 unavailable")
    }
    #endif

    /// SAM License notice (the SAM 3.1 weights are Meta's, under the SAM License; commercial use permitted
    /// subject to its terms). Shown in Select by Description ▸ Licenses.
    static let licenseNotice = SAMLicenseText.text
}
