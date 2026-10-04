import Foundation
import CoreML
import CoreImage
import Accelerate
import ImageCratCore

/// Image embedding of one region (whole image or a crop) produced by the SAM 2.1 image encoder.
final class SAMEmbedding: @unchecked Sendable {
    let imageEmbedding: MLMultiArray
    let feats0: MLMultiArray
    let feats1: MLMultiArray
    /// Doc-space region (y-down) this embedding covers (stretched to 1024×1024 by the encoder).
    let rect: CGRect
    let canvasW: Int, canvasH: Int
    let key: String

    init(imageEmbedding: MLMultiArray, feats0: MLMultiArray, feats1: MLMultiArray, rect: CGRect, canvasW: Int, canvasH: Int, key: String) {
        self.imageEmbedding = imageEmbedding; self.feats0 = feats0; self.feats1 = feats1
        self.rect = rect; self.canvasW = canvasW; self.canvasH = canvasH; self.key = key
    }

    /// Doc point → 1024×1024 model space.
    func toModel(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - rect.minX) / rect.width * SAMSegmenter.inputSize, y: (p.y - rect.minY) / rect.height * SAMSegmenter.inputSize)
    }
    /// Low-res (256) pixel → doc point.
    func lowResToDoc(_ p: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + p.x / CGFloat(SAMSegmenter.maskSize) * rect.width, y: rect.minY + p.y / CGFloat(SAMSegmenter.maskSize) * rect.height)
    }
    func lowResToDoc(_ r: CGRect) -> CGRect {
        let a = lowResToDoc(r.origin), b = lowResToDoc(CGPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
}

/// A SAM prompt in doc coordinates.
struct SAMPrompt {
    enum Label: Int { case negative = 0, positive = 1 }
    var points: [(CGPoint, Label)] = []
    var box: CGRect? = nil

    static func point(_ p: CGPoint) -> SAMPrompt { SAMPrompt(points: [(p, .positive)]) }
    static func box(_ r: CGRect) -> SAMPrompt { SAMPrompt(points: [], box: r) }
}

/// One predicted low-res mask (256×256 logits over the embedding rect).
struct SAMMask {
    var logits: [Float]
    var score: Float
    let emb: SAMEmbedding
    var w: Int { SAMSegmenter.maskSize }
    var h: Int { SAMSegmenter.maskSize }

    /// Full-res CI mask on the canvas.
    func ciMask(guide: CIImage?, hard: Bool) -> CIImage {
        SegMask.fullMask(logits, w: w, h: h, rect: emb.rect, canvasW: emb.canvasW, canvasH: emb.canvasH, guide: guide, hard: hard)
    }
    func buffer(guide: CIImage?, hard: Bool) -> PixelBuffer {
        SegMask.buffer(ciMask(guide: guide, hard: hard), width: emb.canvasW, height: emb.canvasH)
    }
    /// Fraction of the embedding area covered.
    var coverage: Float { Float(SegMask.count(logits, above: 0)) / Float(logits.count) }
    /// Doc-space bounding box.
    var docBounds: CGRect? { SegMask.bbox(SegMask.binary(logits), w: w, h: h).map { emb.lowResToDoc($0) } }
    func contains(_ docPoint: CGPoint) -> Bool {
        let m = emb.toModel(docPoint)
        let x = Int(m.x / 4), y = Int(m.y / 4)
        guard x >= 0, y >= 0, x < w, y < h else { return false }
        return logits[y * w + x] > 0
    }
}

/// An automatically found object (Mask All Objects / Show All Objects).
struct SAMObject {
    var mask: SAMMask
    var stability: Float
    var bin: [Float]
    var area: Float
    var box: CGRect      // low-res coords
}

enum SAMError: LocalizedError {
    case notInstalled, failed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "The SAM 2.1 model is not installed. Download it in Preferences ▸ AI Models."
        case .failed(let s): return "Segmentation failed: \(s)"
        }
    }
}

/// Segment Anything 2.1 (Small) running on Core ML: encoder once per image/crop, cheap prompt decoding after.
final class SAMSegmenter: @unchecked Sendable {
    static let shared = SAMSegmenter()
    static let inputSize: CGFloat = 1024
    static let maskSize = 256

    private let lock = NSRecursiveLock()
    private var cache: [(key: String, emb: SAMEmbedding)] = []
    private let cacheLimit = 6

    var isAvailable: Bool { SegModels.samInstalled }

    private func models() throws -> (MLModel, MLModel, MLModel) {
        guard isAvailable else { throw SAMError.notInstalled }
        let enc = try SegModels.model(SegModels.sam2, SegModels.samEncoder, units: .cpuAndNeuralEngine)
        let pe = try SegModels.model(SegModels.sam2, SegModels.samPrompt, units: .cpuOnly)
        let dec = try SegModels.model(SegModels.sam2, SegModels.samDecoder, units: .cpuAndGPU)
        return (enc, pe, dec)
    }

    /// Loads the models (first call compiles/caches the ANE/GPU plans).
    func warmUp() throws { _ = try models() }

    // MARK: Encoding

    /// Embedding of the whole image, or of `crop` (doc rect). Cached by image id + region.
    func embedding(_ img: SegImage, crop: CGRect? = nil) throws -> SAMEmbedding {
        let rect = (crop ?? img.canvas).intersection(img.canvas).integral
        let key = "\(img.id)|\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"
        lock.lock(); defer { lock.unlock() }
        if let i = cache.firstIndex(where: { $0.key == key }) {
            let e = cache.remove(at: i)
            cache.append(e)
            return e.emb
        }
        let (enc, _, _) = try models()
        guard let pb = img.pixelBuffer(rect: rect, w: 1024, h: 1024) else { throw SAMError.failed("could not prepare the image") }
        let out = try segTime("sam.encode") { try enc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)])) }
        guard let e = out.featureValue(for: "image_embedding")?.multiArrayValue,
              let f0 = out.featureValue(for: "feats_s0")?.multiArrayValue,
              let f1 = out.featureValue(for: "feats_s1")?.multiArrayValue else { throw SAMError.failed("encoder output") }
        let emb = SAMEmbedding(imageEmbedding: e, feats0: f0, feats1: f1, rect: rect, canvasW: img.width, canvasH: img.height, key: key)
        cache.append((key, emb))
        if cache.count > cacheLimit { cache.removeFirst(cache.count - cacheLimit) }
        return emb
    }

    func cachedEmbedding(_ img: SegImage) -> SAMEmbedding? {
        let key = "\(img.id)|0,0,\(img.width),\(img.height)"
        lock.lock(); defer { lock.unlock() }
        return cache.first { $0.key == key }?.emb
    }

    func clearCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    // MARK: Decoding

    /// Sparse/dense prompt embeddings for model-space points (label 0 neg, 1 pos, 2/3 box corners).
    private func encodePrompt(_ pts: [(CGPoint, Float)]) throws -> (MLMultiArray, MLMultiArray) {
        let (_, pe, _) = try models()
        let n = pts.count
        let points = try MLMultiArray(shape: [1, NSNumber(value: n), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
        let pp = points.dataPointer.assumingMemoryBound(to: Float.self)
        let lp = labels.dataPointer.assumingMemoryBound(to: Float.self)
        for (i, (p, l)) in pts.enumerated() {
            pp[i * 2] = Float(p.x); pp[i * 2 + 1] = Float(p.y); lp[i] = l
        }
        let out = try pe.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": points, "labels": labels]))
        guard let sparse = out.featureValue(for: "sparse_embeddings")?.multiArrayValue,
              let dense = out.featureValue(for: "dense_embeddings")?.multiArrayValue else { throw SAMError.failed("prompt encoder output") }
        return (sparse, dense)
    }

    /// All three multimask candidates for a prompt, sorted by predicted IoU (best first).
    func candidates(_ prompt: SAMPrompt, emb: SAMEmbedding) throws -> [SAMMask] {
        var pts: [(CGPoint, Float)] = []
        if let b = prompt.box {
            pts.append((emb.toModel(CGPoint(x: b.minX, y: b.minY)), 2))
            pts.append((emb.toModel(CGPoint(x: b.maxX, y: b.maxY)), 3))
        }
        for (p, l) in prompt.points.prefix(12 - pts.count) { pts.append((emb.toModel(p), Float(l.rawValue))) }
        guard !pts.isEmpty else { throw SAMError.failed("empty prompt") }
        lock.lock(); defer { lock.unlock() }
        let (_, _, dec) = try models()
        let (sparse, dense) = try encodePrompt(pts)
        let out = try segTime("sam.decode", false) {
            try dec.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                "image_embedding": emb.imageEmbedding, "sparse_embedding": sparse, "dense_embedding": dense,
                "feats_s0": emb.feats0, "feats_s1": emb.feats1,
            ]))
        }
        guard let masks = out.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = out.featureValue(for: "scores")?.multiArrayValue else { throw SAMError.failed("decoder output") }
        let k = masks.shape[1].intValue
        let n = SAMSegmenter.maskSize * SAMSegmenter.maskSize
        var res: [SAMMask] = []
        let all = SAMSegmenter.floats(masks)
        let sc = SAMSegmenter.floats(scores)
        for i in 0..<k {
            res.append(SAMMask(logits: Array(all[(i * n)..<((i + 1) * n)]), score: sc[i], emb: emb))
        }
        return res.sorted { $0.score > $1.score }
    }

    /// Memory pressure / idle: the decoder workers and cached embeddings go (models reload on next use).
    func release() {
        workerLock.lock(); workers = []; workerLock.unlock()
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    /// Extra decoder/prompt-encoder instances so automatic mask generation can decode on several threads.
    private var workers: [(MLModel, MLModel)] = []
    private let workerLock = NSLock()
    static let amgThreads = 4

    private func workerModels() throws -> [(MLModel, MLModel)] {
        workerLock.lock(); defer { workerLock.unlock() }
        if workers.count == SAMSegmenter.amgThreads { return workers }
        let pe = try ModelManager.shared.file(SegModels.sam2, SegModels.samPrompt)
        let dec = try ModelManager.shared.file(SegModels.sam2, SegModels.samDecoder)
        workers = try (0..<SAMSegmenter.amgThreads).map { _ in
            let c1 = MLModelConfiguration(); c1.computeUnits = .cpuOnly
            let c2 = MLModelConfiguration(); c2.computeUnits = .cpuAndGPU
            return (try MLModel(contentsOf: pe, configuration: c1), try MLModel(contentsOf: dec, configuration: c2))
        }
        return workers
    }

    /// Multimask candidates for many single-point prompts, decoded on several threads (automatic mask generation).
    func pointCandidatesParallel(_ points: [CGPoint], emb: SAMEmbedding) throws -> [[SAMMask]] {
        let ws = try workerModels()
        let n = SAMSegmenter.maskSize * SAMSegmenter.maskSize
        var results = [[SAMMask]](repeating: [], count: points.count)
        var firstError: Error?
        let rl = NSLock()
        DispatchQueue.concurrentPerform(iterations: ws.count) { w in
            let (pe, dec) = ws[w]
            var i = w
            while i < points.count {
                do {
                    let mp = emb.toModel(points[i])
                    let pts = try MLMultiArray(shape: [1, 1, 2], dataType: .float32)
                    let lbl = try MLMultiArray(shape: [1, 1], dataType: .float32)
                    let pp = pts.dataPointer.assumingMemoryBound(to: Float.self)
                    pp[0] = Float(mp.x); pp[1] = Float(mp.y)
                    lbl.dataPointer.assumingMemoryBound(to: Float.self)[0] = 1
                    let po = try pe.prediction(from: MLDictionaryFeatureProvider(dictionary: ["points": pts, "labels": lbl]))
                    guard let sparse = po.featureValue(for: "sparse_embeddings")?.multiArrayValue,
                          let dense = po.featureValue(for: "dense_embeddings")?.multiArrayValue else { throw SAMError.failed("prompt encoder output") }
                    let f = try dec.prediction(from: MLDictionaryFeatureProvider(dictionary: [
                        "image_embedding": emb.imageEmbedding, "sparse_embedding": sparse, "dense_embedding": dense,
                        "feats_s0": emb.feats0, "feats_s1": emb.feats1,
                    ]))
                    guard let masks = f.featureValue(for: "low_res_masks")?.multiArrayValue, let scores = f.featureValue(for: "scores")?.multiArrayValue else { throw SAMError.failed("decoder output") }
                    let all = SAMSegmenter.floats(masks), sc = SAMSegmenter.floats(scores)
                    let r = (0..<masks.shape[1].intValue).map { k in SAMMask(logits: Array(all[(k * n)..<((k + 1) * n)]), score: sc[k], emb: emb) }
                    rl.lock(); results[i] = r; rl.unlock()
                } catch {
                    rl.lock(); if firstError == nil { firstError = error }; rl.unlock()
                }
                i += ws.count
            }
        }
        if let e = firstError { throw e }
        return results
    }

    /// Best mask for a prompt (holes and sprinkles removed, like SAM 2's post-processing).
    func predict(_ prompt: SAMPrompt, emb: SAMEmbedding) throws -> SAMMask {
        var m = try predictRaw(prompt, emb: emb)
        m.logits = segTime("sam.clean", false) { SAMSegmenter.cleaned(m.logits, w: m.w, h: m.h) }
        return m
    }

    /// Fills enclosed background holes and removes foreground islands smaller than `maxArea` low-res pixels.
    static func cleaned(_ logits: [Float], w: Int, h: Int, maxArea: Int = 48) -> [Float] {
        var out = logits
        for fg in [false, true] {
            // components of pixels whose sign == fg (fg=false: holes; fg=true: islands)
            var label = [Int32](repeating: -1, count: w * h)
            var stack: [Int] = []
            var comp: [Int] = []
            for start in 0..<(w * h) where label[start] < 0 && ((out[start] > 0) == fg) {
                comp.removeAll(keepingCapacity: true)
                stack.append(start); label[start] = 1
                var touchesBorder = false
                while let i = stack.popLast() {
                    comp.append(i)
                    let x = i % w, y = i / w
                    if x == 0 || y == 0 || x == w - 1 || y == h - 1 { touchesBorder = true }
                    if x > 0, label[i - 1] < 0, (out[i - 1] > 0) == fg { label[i - 1] = 1; stack.append(i - 1) }
                    if x < w - 1, label[i + 1] < 0, (out[i + 1] > 0) == fg { label[i + 1] = 1; stack.append(i + 1) }
                    if y > 0, label[i - w] < 0, (out[i - w] > 0) == fg { label[i - w] = 1; stack.append(i - w) }
                    if y < h - 1, label[i + w] < 0, (out[i + w] > 0) == fg { label[i + w] = 1; stack.append(i + w) }
                }
                if comp.count <= maxArea && (fg || !touchesBorder) {
                    for i in comp { out[i] = fg ? -1 : 1 }
                }
            }
        }
        return out
    }

    func predictRaw(_ prompt: SAMPrompt, emb: SAMEmbedding) throws -> SAMMask {
        let c = try candidates(prompt, emb: emb)
        guard var best = c.first else { throw SAMError.failed("no mask") }
        // Box prompts: prefer the candidate that best fills the box among near-best scores (whole object, not a part).
        if let b = prompt.box {
            func fill(_ m: SAMMask) -> CGFloat {
                guard let r = m.docBounds else { return 0 }
                let i = r.intersection(b)
                return i.isNull ? 0 : (i.width * i.height) / max(1, b.width * b.height)
            }
            for m in c.dropFirst() where m.score > best.score - 0.04 && fill(m) > fill(best) + 0.15 { best = m }
        }
        return best
    }

    /// Converts an MLMultiArray (float16/float32/double, contiguous) to [Float].
    static func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        var out = [Float](repeating: 0, count: n)
        switch a.dataType {
        case .float16:
            var src = vImage_Buffer(data: a.dataPointer, height: 1, width: vImagePixelCount(n), rowBytes: n * 2)
            out.withUnsafeMutableBytes { d in
                var dst = vImage_Buffer(data: d.baseAddress!, height: 1, width: vImagePixelCount(n), rowBytes: n * 4)
                vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
        case .float32:
            memcpy(&out, a.dataPointer, n * 4)
        case .double:
            let p = a.dataPointer.assumingMemoryBound(to: Double.self)
            for i in 0..<n { out[i] = Float(p[i]) }
        default:
            for i in 0..<n { out[i] = a[i].floatValue }
        }
        return out
    }

    // MARK: Automatic mask generation

    /// SAM "everything" mode: a point grid on the embedding, filtered by predicted IoU and stability,
    /// de-duplicated by box NMS and mask IoU. Sorted by area (largest first).
    func automaticMasks(emb: SAMEmbedding, grid: Int = 32, minScore: Float = 0.80, minStability: Float = 0.88,
                        nms: CGFloat = 0.7, minArea: Float = 0.0006, maxArea: Float = 0.92,
                        progress: ((Double) -> Void)? = nil) throws -> [SAMObject] {
        let n = Float(SAMSegmenter.maskSize * SAMSegmenter.maskSize)
        var cands: [SAMObject] = []
        var done = 0
        for gy in 0..<grid {
            let row = (0..<grid).map { gx in
                CGPoint(x: emb.rect.minX + (CGFloat(gx) + 0.5) / CGFloat(grid) * emb.rect.width,
                        y: emb.rect.minY + (CGFloat(gy) + 0.5) / CGFloat(grid) * emb.rect.height)
            }
            for masks in try pointCandidatesParallel(row, emb: emb) {
                for m in masks where m.score >= minScore {
                    let hi = Float(SegMask.count(m.logits, above: 1)), lo = Float(SegMask.count(m.logits, above: -1))
                    guard lo > 0 else { continue }
                    let stab = hi / lo
                    guard stab >= minStability else { continue }
                    let bin = SegMask.binary(m.logits)
                    let area = SegMask.sum(bin)
                    guard area / n >= minArea, area / n <= maxArea, let box = SegMask.bbox(bin, w: SAMSegmenter.maskSize, h: SAMSegmenter.maskSize) else { continue }
                    cands.append(SAMObject(mask: m, stability: stab, bin: bin, area: area, box: box))
                }
                done += 1
            }
            progress?(Double(done) / Double(grid * grid))
        }
        // NMS by quality (score × stability)
        cands.sort { $0.mask.score * $0.stability > $1.mask.score * $1.stability }
        var kept: [SAMObject] = []
        for c in cands {
            var dup = false
            for k in kept {
                let i = c.box.intersection(k.box)
                if i.isNull { continue }
                let bi = (i.width * i.height) / (c.box.width * c.box.height + k.box.width * k.box.height - i.width * i.height)
                if bi > nms { dup = true; break }
                if bi > 0.3, SegMask.iou(c.bin, k.bin, areaA: c.area, areaB: k.area) > 0.75 { dup = true; break }
            }
            if !dup { kept.append(c) }
        }
        return kept.sorted { $0.area > $1.area }
    }
}
