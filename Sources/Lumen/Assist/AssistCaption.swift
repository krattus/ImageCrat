import Foundation
import CoreML
import CoreImage
import NaturalLanguage

/// Florence-2 text generation (captions, OCR) for the assists. Uses the same three Core ML packages and model cache
/// as `Florence2Grounder` (which only parses region tokens) with its own tokenizer / greedy decoder, so nothing in the
/// segmentation stack had to change. Read-only use of the installed model; throws `ModelError.notInstalled` otherwise.
final class AssistCaptioner: @unchecked Sendable {
    static let shared = AssistCaptioner()

    enum Task: String {
        case caption = "What does the image describe?"
        case detailed = "Describe in detail what is shown in the image."
        case moreDetailed = "Describe with a paragraph what is shown in the image."
        case ocr = "What is the text in the image?"

        var maxTokens: Int {
            switch self {
            case .caption: return 28
            case .detailed: return 72
            case .moreDetailed: return 120
            case .ocr: return 96
            }
        }
    }

    /// Compute units of the text encoder / decoder. The conversion is verified for CPU only (fp16 attention can
    /// overflow on GPU / Neural Engine); LUMEN_ASSIST_FLORENCE_UNITS=gpu|all overrides for experiments.
    static let textUnits: MLComputeUnits = {
        switch ProcessInfo.processInfo.environment["LUMEN_ASSIST_FLORENCE_UNITS"] {
        case "gpu": return .cpuAndGPU
        case "all": return .all
        case "ane": return .cpuAndNeuralEngine
        default: return .cpuOnly
        }
    }()

    private let lock = NSLock()
    private var vocab: [Int: String] = [:]
    private var reverse: [String: Int] = [:]
    private var loaded = false
    /// Milliseconds of the last call: vision encoder, text encoder, decoder, and generated token count.
    private(set) var lastTiming: (vision: Double, text: Double, decode: Double, tokens: Int) = (0, 0, 0, 0)
    /// Seconds the one-time model load took in this session.
    private(set) var loadSeconds = 0.0

    var isAvailable: Bool { SegModels.florenceInstalled }

    private func loadVocab() throws {
        if loaded { return }
        let url = try ModelManager.shared.file(SegModels.florence, "florence2_vocab.json")
        guard let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String] else { throw ModelError.compile("Florence vocabulary") }
        for (k, v) in dict { if let id = Int(k) { vocab[id] = v; reverse[v] = id } }
        loaded = true
    }

    // Byte-level BPE alphabet (GPT-2 / BART): printable bytes map to themselves, the rest to U+0100….
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
    private static let byteDecoder: [Character: UInt8] = {
        var d: [Character: UInt8] = [:]
        for (k, v) in byteEncoder { d[v] = k }
        return d
    }()

    private func tokenize(_ text: String) -> [Int32] {
        var tokens: [Int32] = [0]
        let regex = try! NSRegularExpression(pattern: "'s|'t|'re|'ve|'m|'ll|'d| ?\\p{L}+| ?\\p{N}+| ?[^\\s\\p{L}\\p{N}]+|\\s+(?!\\S)|\\s+")
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

    private func decode(_ tokens: [Int32]) -> String {
        var bytes: [UInt8] = []
        for t in tokens where t > 2 && t < Florence2Grounder.locBase {
            guard let s = vocab[Int(t)], !(s.hasPrefix("<") && s.hasSuffix(">") && s.count > 2) else { continue }
            for ch in s { if let b = Self.byteDecoder[ch] { bytes.append(b) } else { bytes.append(contentsOf: Array(String(ch).utf8)) } }
        }
        return (String(bytes: bytes, encoding: .utf8) ?? String(decoding: bytes, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generates text for `task` from an image (any size; resampled to 768×768 like the reference processor).
    func generate(_ cg: CGImage, task: Task, maxTokens: Int? = nil) throws -> String {
        guard isAvailable else { throw ModelError.notInstalled("Florence-2") }
        lock.lock(); defer { lock.unlock() }
        try loadVocab()
        let img = SegImage(image: CIImage(cgImage: cg), width: cg.width, height: cg.height, id: "assist-caption")
        let tl = CFAbsoluteTimeGetCurrent()
        let vis = try SegModels.model(SegModels.florence, SegModels.florenceVision, units: .cpuAndGPU)
        let enc = try SegModels.model(SegModels.florence, SegModels.florenceText, units: Self.textUnits)
        let dec = try SegModels.model(SegModels.florence, SegModels.florenceDecoder, units: Self.textUnits)
        let tLoad = CFAbsoluteTimeGetCurrent() - tl
        if tLoad > 0.05 { loadSeconds = tLoad }
        guard let pb = img.pixelBuffer(rect: img.canvas, w: 768, h: 768) else { throw ModelError.compile("Florence input") }
        var t0 = CFAbsoluteTimeGetCurrent()
        let feats = try vis.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: pb)]))
        guard let imageFeatures = feats.featureValue(for: "image_features")?.multiArrayValue else { throw ModelError.compile("Florence vision") }
        let tVision = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        var ids = tokenize(task.rawValue)
        if ids.count > 23 { ids = Array(ids.prefix(22)) + [2] }
        let idArr = try MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32)
        for (i, v) in ids.enumerated() { idArr[i] = NSNumber(value: v) }
        t0 = CFAbsoluteTimeGetCurrent()
        let encOut = try enc.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image_features": imageFeatures, "input_ids": idArr]))
        guard let hs = encOut.featureValue(for: "encoder_hidden_states")?.multiArrayValue else { throw ModelError.compile("Florence text") }
        let tText = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        t0 = CFAbsoluteTimeGetCurrent()
        var out: [Int32] = [2]
        let limit = maxTokens ?? task.maxTokens
        for _ in 0..<limit {
            let d = try MLMultiArray(shape: [1, NSNumber(value: out.count)], dataType: .int32)
            let dp = d.dataPointer.assumingMemoryBound(to: Int32.self)
            for (i, v) in out.enumerated() { dp[i] = v }
            let r = try dec.prediction(from: MLDictionaryFeatureProvider(dictionary: ["decoder_input_ids": d, "encoder_hidden_states": hs]))
            guard let logits = r.featureValue(for: "logits")?.multiArrayValue else { break }
            let next = Self.argmaxLast(logits, banned: Self.bannedTokens(out))
            if next == 2 { break }
            out.append(next)
        }
        lastTiming = (tVision, tText, (CFAbsoluteTimeGetCurrent() - t0) * 1000, out.count - 1)
        return decode(Array(out.dropFirst()))
    }

    /// no_repeat_ngram_size = 3 (the reference generation config): tokens that would repeat an earlier trigram.
    private static func bannedTokens(_ seq: [Int32]) -> Set<Int32> {
        guard seq.count >= 3 else { return [] }
        let a = seq[seq.count - 2], b = seq[seq.count - 1]
        var banned = Set<Int32>()
        for i in 0..<(seq.count - 2) where seq[i] == a && seq[i + 1] == b { banned.insert(seq[i + 2]) }
        return banned
    }

    private static func argmaxLast(_ a: MLMultiArray, banned: Set<Int32>) -> Int32 {
        let v = a.shape.last!.intValue
        let off = a.count - v
        var best = -1
        if a.dataType == .float16 {
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            var bv = -Float16.infinity
            for i in 0..<v where p[off + i] > bv && !banned.contains(Int32(i)) { bv = p[off + i]; best = i }
        } else {
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            var bv = -Float.infinity
            for i in 0..<v where p[off + i] > bv && !banned.contains(Int32(i)) { bv = p[off + i]; best = i }
        }
        return Int32(max(0, best))
    }
}

// MARK: - Caption clean-up

enum AssistText {
    private static let leadIns = ["the image shows ", "the image is of ", "the image is ", "the image features ", "the image depicts ", "this image shows ",
                                  "this is ", "there is ", "there are ", "in this image we can see ", "in this image, we can see ", "in this image ",
                                  "a picture of ", "an image of ", "a photo of ", "a photograph of ", "a close up of ", "a close-up of ", "a close up view of ",
                                  "a view of ", "a drawing of ", "an illustration of ", "a cartoon of ", "a painting of ", "a screenshot of ", "a black and white photo of "]

    /// Removes model boilerplate ("The image shows …") and tidies capitalisation / punctuation.
    static func cleanCaption(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        var changed = true
        while changed {
            changed = false
            let lower = t.lowercased()
            for p in leadIns where lower.hasPrefix(p) { t = String(t.dropFirst(p.count)); changed = true; break }
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let f = t.first else { return t }
        t = f.uppercased() + t.dropFirst()
        if let l = t.last, !".!?".contains(l) { t += "." }
        return t
    }

    private static let weakNouns: Set<String> = ["image", "picture", "photo", "photograph", "view", "background", "close", "closeup", "front", "side", "top",
                                                 "middle", "center", "lot", "bunch", "group", "pair", "couple", "kind", "type", "piece", "body", "row", "set",
                                                 "collection", "variety", "series", "number", "pile", "stack"]
    private static let numberWords: Set<String> = ["two", "three", "four", "five", "six", "several", "many"]

    /// Condenses a caption to its head noun phrase in 2–4 words: "A yellow sun in a blue sky." → "Yellow Sun".
    static func headPhrase(_ caption: String, maxWords: Int = 4) -> String? {
        var t = cleanCaption(caption).lowercased()
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: ".!? "))
        guard !t.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = t
        var toks: [(String, NLTag?)] = []
        tagger.enumerateTags(in: t.startIndex..<t.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace]) { tag, r in
            toks.append((String(t[r]), tag)); return true
        }
        var words: [String] = []
        var haveNoun = false
        var i = 0
        while i < toks.count {
            let (w, tag) = toks[i]
            i += 1
            if tag == .determiner || ["a", "an", "the", "some"].contains(w) { if haveNoun { break }; continue }
            if tag == .punctuation || tag == .otherPunctuation || tag == .sentenceTerminator || w == "," { if haveNoun { break }; continue }
            if w == "of", haveNoun, let last = words.last, weakNouns.contains(last) {
                // "a group of people", "a large body of water": drop the weak head (and its adjectives), continue with the real one
                words.removeAll(); haveNoun = false
                continue
            }
            if tag == .noun || (tag == .otherWord && !haveNoun) {
                words.append(w); haveNoun = true
            } else if tag == .adjective || tag == .number || numberWords.contains(w) {
                if haveNoun { break }
                words.append(w)
            } else if tag == .verb, !haveNoun, w.hasSuffix("ing") || w.hasSuffix("ed") {
                words.append(w)   // participle used as an adjective ("smiling woman")
            } else {
                if haveNoun { break }
                if tag == .preposition || tag == .conjunction || tag == .verb { continue }
            }
            if words.count >= maxWords { break }
        }
        while let l = words.last, weakNouns.contains(l), words.count > 1 { words.removeLast() }
        guard haveNoun, !words.isEmpty else { return nil }
        return Assist.titleCase(words.joined(separator: " "))
    }

    /// A 2–4 word name from a caption: the head phrase, plus the next thing mentioned when the head is a single
    /// word ("A large body of water surrounded by rocks and trees." → "Water and Rocks").
    static func namePhrase(_ caption: String) -> String? {
        guard let head = headPhrase(caption) else { return nil }
        if head.split(separator: " ").count >= 2 { return head }
        let lower = cleanCaption(caption).lowercased()
        guard let r = lower.range(of: head.lowercased()) else { return head }
        var rest = String(lower[r.upperBound...])
        for lead in [" surrounded by ", " next to ", " in front of ", " on top of ", " with ", " and ", " on ", " in ", " near ", " under ", " by "] where rest.hasPrefix(lead) {
            rest = String(rest.dropFirst(lead.count))
            if let second = headPhrase(rest, maxWords: 2), !second.lowercased().contains("background"), second.lowercased() != head.lowercased() {
                return "\(head) and \(second)"
            }
            break
        }
        return head
    }
}
