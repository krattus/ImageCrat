import Foundation
import CoreML

/// Model ids and `ModelSpec` registrations for the segmentation stack
/// (Object Selection, Select Subject / People / Sky, Mask All Objects, text prompts, hair matting).
enum SegModels {
    static let sam2 = "sam2.1-small"
    static let birefnetLite = "birefnet-lite"
    static let birefnet = "birefnet"
    static let florence = "florence2-base"
    static let sam3 = "sam3.1"

    // Package names inside each model folder.
    static let samEncoder = "SAM2_1SmallImageEncoderFLOAT16.mlpackage"
    static let samPrompt = "SAM2_1SmallPromptEncoderFLOAT16.mlpackage"
    static let samDecoder = "SAM2_1SmallMaskDecoderFLOAT16.mlpackage"
    static let birefnetLitePkg = "BiRefNetLite.mlpackage"
    static let birefnetPkg = "BiRefNet_1024_fp16.mlpackage"
    static let florenceVision = "Florence2VisionEncoder.mlpackage"
    static let florenceText = "Florence2TextEncoder.mlpackage"
    static let florenceDecoder = "Florence2Decoder.mlpackage"

    static var mm: ModelManager { ModelManager.shared }
    static var samInstalled: Bool { mm.isInstalled(sam2) }
    static var florenceInstalled: Bool { mm.isInstalled(florence) }
    static var sam3Installed: Bool { mm.isInstalled(sam3) }
    static var mattingInstalled: Bool { mm.isInstalled(birefnetLite) || mm.isInstalled(birefnet) }

    /// Files of a `.mlpackage` (Manifest + model spec + weights) mapped from a remote folder to a local one.
    private static func package(_ repo: String, remote: String, local: String) -> [ModelSpec.File] {
        ["Manifest.json", "Data/com.apple.CoreML/model.mlmodel", "Data/com.apple.CoreML/weights/weight.bin"].map {
            ModelSpec.File(url: ModelManager.hf(repo, remote + "/" + $0), path: local + "/" + $0)
        }
    }

    static func registerSpecs() {
        let samRepo = "apple/coreml-sam2.1-small"
        ModelManager.shared.register(ModelSpec(
            id: sam2, name: "SAM 2.1 Small (Core ML)",
            purpose: "Object Selection tool, Object Finder hover, Select Subject / People, Mask All Objects",
            license: "Apache-2.0 (Apple / Meta)", approxMB: 94,
            files: [samEncoder, samPrompt, samDecoder].flatMap { package(samRepo, remote: $0, local: $0) },
            compile: [samEncoder, samPrompt, samDecoder]))

        let liteRepo = "metaclass/birefnet-lite-coreml"
        ModelManager.shared.register(ModelSpec(
            id: birefnetLite, name: "BiRefNet Lite (Core ML)",
            purpose: "Hair & fine-edge matting (fast): Refine Hair, hair-quality edges",
            license: "MIT", approxMB: 92,
            files: package(liteRepo, remote: "fp16compute-fp32io/r1/BiRefNetLite-1024-FP16Compute-FP32IO.mlpackage", local: birefnetLitePkg),
            compile: [birefnetLitePkg]))

        let fullRepo = "avencera/birefnet-coreml-gpu"
        ModelManager.shared.register(ModelSpec(
            id: birefnet, name: "BiRefNet (Core ML, High Quality)",
            purpose: "Hair & fine-edge matting (high quality)",
            license: "MIT", approxMB: 470,
            files: package(fullRepo, remote: birefnetPkg, local: birefnetPkg)
                + [ModelSpec.File(url: ModelManager.hf(fullRepo, "LICENSE"), path: "LICENSE")],
            compile: [birefnetPkg]))

        let flRepo = "mlboydaisuke/Florence-2-base-CoreML"
        ModelManager.shared.register(ModelSpec(
            id: florence, name: "Florence-2 Base (Core ML)",
            purpose: "Text prompts: Select by Description, options-bar Find field, Select Sky",
            license: "MIT (Microsoft)", approxMB: 260,
            files: [florenceVision, florenceText, florenceDecoder].flatMap { package(flRepo, remote: $0, local: $0) }
                + [ModelSpec.File(url: ModelManager.hf(flRepo, "florence2_vocab.json"), path: "florence2_vocab.json")],
            compile: [florenceVision, florenceText, florenceDecoder]))

        let s3Repo = "mlx-community/sam3.1-bf16"
        ModelManager.shared.register(ModelSpec(
            id: sam3, name: "SAM 3.1 (MLX)",
            purpose: "High Quality engine for text prompts (open-vocabulary detection + masks). Runs on MLX (its Metal kernels and tokenizer ship inside ImageCrat.app).",
            license: "SAM License (Meta) — see Select ▸ Select by Description ▸ Licenses", approxMB: 3330,
            files: ["config.json", "model.safetensors", "README.md"].map { ModelSpec.File(url: ModelManager.hf(s3Repo, $0), path: $0) }))
    }

    // MARK: Loaded model cache

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: MLModel] = [:]

    /// Loads (once) a compiled model of an installed spec.
    static func model(_ id: String, _ pkg: String, units: MLComputeUnits) throws -> MLModel {
        let key = "\(id)/\(pkg)/\(units.rawValue)"
        MemoryHygiene.modelUsed()
        lock.lock(); defer { lock.unlock() }
        if let m = loaded[key] { return m }
        let m = try ModelManager.shared.loadModel(id, pkg, units: units)
        loaded[key] = m
        return m
    }

    static func unload(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        loaded = loaded.filter { !$0.key.hasPrefix(id + "/") }
    }

    /// Every loaded segmentation / caption model (reloaded on next use).
    static func unloadAll() {
        lock.lock(); loaded.removeAll(); lock.unlock()
    }

    static var loadedCount: Int { lock.lock(); defer { lock.unlock() }; return loaded.count }
}

/// Time a block (ms) — used for status/latency reporting.
@inline(__always) func segTime<T>(_ label: String, _ log: Bool = SegLog.enabled, _ f: () throws -> T) rethrows -> T {
    let t0 = CFAbsoluteTimeGetCurrent()
    let r = try f()
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    SegLog.record(label, ms)
    if log { print(String(format: "[seg] %@: %.1f ms", label, ms)) }
    return r
}

enum SegLog {
    nonisolated(unsafe) static var enabled = ProcessInfo.processInfo.environment["LUMEN_SEG_LOG"] == "1"
    nonisolated(unsafe) static var last: [String: Double] = [:]
    private static let lock = NSLock()
    static func record(_ k: String, _ ms: Double) { lock.lock(); last[k] = ms; lock.unlock() }
    static func value(_ k: String) -> Double? { lock.lock(); defer { lock.unlock() }; return last[k] }
}
