import Foundation
import CoreML
import CoreImage
import ImageCratCore

/// Florence-2 Base (Core ML, 3 stateless packages) used for phrase grounding / open-vocabulary detection.
/// Vision encoder 768×768 → BART text encoder → autoregressive decoder (no KV cache; greedy).
final class Florence2Grounder: @unchecked Sendable {
    static let shared = Florence2Grounder()

    enum Task { case phraseGrounding, openVocabulary, objectDetection, referringSegmentation }

    struct Region {
        var label: String
        var box: CGRect      // doc coords
    }

    private let lock = NSLock()
    private var vocab: [Int: String] = [:]
    private var reverse: [String: Int] = [:]
    private var loaded = false

    var isAvailable: Bool { SegModels.florenceInstalled }

    private func loadVocab() throws {
        if loaded { return }
        let url = try ModelManager.shared.file(SegModels.florence, "florence2_vocab.json")
        let data = try Data(contentsOf: url)
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else { throw SAMError.failed("Florence vocabulary") }
        for (k, v) in dict { if let id = Int(k) { vocab[id] = v; reverse[v] = id } }
        loaded = true
    }

    // MARK: Tokenizer (byte-level BPE vocabulary, greedy longest match)

    private static let byteEncoder: [UInt8: Character] = {
        var direct = Set<UInt8>()
        for b in 0x21...0x7E { direct.insert(UInt8(b)) }
        for b in 0xA1...0xAC { direct.insert(UInt8(b)) }
        for b in 0xAE...0xFF { direct.insert(UInt8(b)) }
        var enc: [UInt8: Character] = [:]
        for b in direct { enc[b] = Character(UnicodeScalar(b)) }
        var n = 0
        for b: UInt8 in 0...255 where !direct.contains(b) { enc[b] = Character(UnicodeScalar(256 + n)!); n += 1 }
        return enc
    }()

    func tokenize(_ text: String) -> [Int32] {
        var tokens: [Int32] = [0]
        let pattern = "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+"
        let regex = try! NSRegularExpression(pattern: pattern)
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let piece = String(ns.substring(with: m.range).utf8.compactMap { Self.byteEncoder[$0] })
            var i = piece.startIndex
            while i < piece.endIndex {
                var bestEnd = piece.index(after: i)
                var bestID: Int?
                var j = piece.index(after: i)
                while true {
                    if let id = reverse[String(piece[i..<j])] { bestEnd = j; bestID = id }
                    if j == piece.endIndex { break }
                    j = piece.index(after: j)
                }
                if let id = bestID { tokens.append(Int32(id)) }
                i = bestEnd
            }
        }
        tokens.append(2)
        return tokens
    }

    private func prompt(_ task: Task, _ text: String) -> String {
        switch task {
        case .phraseGrounding: return "Locate the phrases in the caption: \(text)"
        case .openVocabulary: return "Locate \(text) in the image."
        case .objectDetection: return "Locate the objects with category name in the image."
        case .referringSegmentation: return "Locate \(text) in the image with mask"
        }
    }

    // MARK: Inference

    /// Runs grounding on `img` (whole canvas). Returns labelled boxes in doc coordinates.
    func ground(_ img: SegImage, text: String, task: Task = .phraseGrounding, maxTokens: Int = 80) throws -> [Region] {
        guard isAvailable else { throw ModelError.notInstalled("Florence-2") }
        lock.lock(); defer { lock.unlock() }
        try loadVocab()
        let vis = try SegModels.model(SegModels.florence, SegModels.florenceVision, units: .cpuAndGPU)
        let enc = try SegModels.model(SegModels.florence, SegModels.florenceText, units: .cpuOnly)
        let dec = try SegModels.model(SegModels.florence, SegModels.florenceDecoder, units: .cpuOnly)
        guard let pb = img.pixelBuffer(rect: img.canvas, w: 768, h: 768) else { throw SAMError.failed("image") }
        let feats = try segTime("florence.vision") {
            try vis.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)]))
        }
        guard let imageFeatures = feats.featureValue(for: "image_features")?.multiArrayValue else { throw SAMError.failed("florence vision") }
        // text encoder accepts up to 23 tokens (577 + n ≤ 600)
        var ids = tokenize(prompt(task, text))
        if ids.count > 23 { ids = Array(ids.prefix(22)) + [2] }
        let idArr = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, v) in ids.enumerated() { idArr[i] = NSNumber(value: v) }
        let encOut = try segTime("florence.text") {
            try enc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image_features": imageFeatures, "input_ids": idArr]))
        }
        guard let hs = encOut.featureValue(for: "encoder_hidden_states")?.multiArrayValue else { throw SAMError.failed("florence text") }
        var out: [Int32] = [2]
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<maxTokens {
            let d = try MLMultiArray(shape: [1, NSNumber(value: out.count)], dataType: .int32)
            let dp = d.dataPointer.assumingMemoryBound(to: Int32.self)
            for (i, v) in out.enumerated() { dp[i] = v }
            let r = try dec.prediction(from: MLDictionaryFeatureProvider(dictionary: ["decoder_input_ids": d, "encoder_hidden_states": hs]))
            guard let logits = r.featureValue(for: "logits")?.multiArrayValue else { break }
            let next = argmaxLast(logits)
            if next == 2 { break }
            out.append(next)
        }
        SegLog.record("florence.decode", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        SegLog.record("florence.tokens", Double(out.count))
        if SegLog.enabled || ProcessInfo.processInfo.environment["LUMEN_FLORENCE_DEBUG"] == "1" {
            print("[florence] prompt ids \(ids) → \(out) '\(out.compactMap { vocab[Int($0)] }.joined())'")
        }
        return parse(Array(out.dropFirst()), width: img.width, height: img.height)
    }

    private func argmaxLast(_ a: MLMultiArray) -> Int32 {
        let v = a.shape.last!.intValue
        let off = a.count - v
        var best = 0
        if a.dataType == .float16 {
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            var bv = p[off]
            for i in 1..<v where p[off + i] > bv { bv = p[off + i]; best = i }
        } else {
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            var bv = p[off]
            for i in 1..<v where p[off + i] > bv { bv = p[off + i]; best = i }
        }
        return Int32(best)
    }

    static let locBase: Int32 = 50269

    /// "label<loc_a><loc_b><loc_c><loc_d>…" → regions. Loc bins are 0…999 over the image.
    func parse(_ tokens: [Int32], width: Int, height: Int) -> [Region] {
        var regions: [Region] = []
        var label = ""
        var locs: [Int] = []
        var labelDone = false
        for t in tokens {
            // <loc_0> … <loc_999> are ids 50269…51268 (not in the exported vocabulary)
            if t >= Self.locBase && t < Self.locBase + 1000 {
                locs.append(Int(t - Self.locBase))
                labelDone = true
                if locs.count == 4 {
                    let x0 = (Double(locs[0]) + 0.5) / 1000 * Double(width), y0 = (Double(locs[1]) + 0.5) / 1000 * Double(height)
                    let x1 = (Double(locs[2]) + 0.5) / 1000 * Double(width), y1 = (Double(locs[3]) + 0.5) / 1000 * Double(height)
                    let clean = label.replacingOccurrences(of: "\u{0120}", with: " ").trimmingCharacters(in: .whitespaces)
                    regions.append(Region(label: clean, box: CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))))
                    locs = []
                }
            } else if t > 2, t < Self.locBase, let s = vocab[Int(t)] {
                if labelDone { label = ""; labelDone = false }
                if !s.hasPrefix("<") { label += s }
                locs = []
            }
        }
        return regions
    }

    /// Plain caption (debugging / "describe" features).
    func decodeText(_ tokens: [Int32]) -> String {
        tokens.compactMap { $0 > 2 ? vocab[Int($0)] : nil }.joined().replacingOccurrences(of: "\u{0120}", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
