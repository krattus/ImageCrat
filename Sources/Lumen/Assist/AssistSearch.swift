import AppKit
import SwiftUI
import Vision
import Observation
import ImageCratCore

/// Semantic layer search ("Find Layers" panel): finds layers by what they show, say and are —
/// "the red car", "text that says sale", "blurry layers", "layers with drop shadow", "big images".
/// Each layer gets a cached descriptor (caption, labels, OCR text, colours, sharpness, feature print) that is
/// combined with live metadata (kind, effects, size, state) and scored with keyword rules + word / sentence
/// embeddings from NaturalLanguage.
struct AssistVisual {
    var caption = ""
    var labels: [String] = []
    var ocrText = ""
    var colors: [String] = []          // base colour words, dominant first
    var blur: Double? = nil            // 0 sharp … 1 blurry
    var brightness: Double? = nil      // 0…1
    var print: VNFeaturePrintObservation? = nil
    var bounds: CGRect = .zero
}

struct AssistDescriptor {
    var id: UUID
    var name: String
    var kind: String                   // text, shape, image, smart object, adjustment, fill, group, artboard
    var text: String
    var effects: [String]
    var areaFraction: Double
    var position: String?
    var opacity: Double
    var visible: Bool
    var hasMask: Bool
    var clipped: Bool
    var locked: Bool
    var blend: String
    var detail: String                 // shape kind / adjustment kind / font
    var visual: AssistVisual

    /// One-sentence description used for the sentence embedding and shown as the result subtitle.
    var summary: String {
        var parts: [String] = []
        if !visual.caption.isEmpty { parts.append(visual.caption) }
        if !text.isEmpty { parts.append("\(kind == "text" ? "text" : "with text") “\(Assist.truncate(text, 40))”") }
        if !detail.isEmpty, visual.caption.isEmpty { parts.append(detail.lowercased()) }
        if parts.isEmpty, let l = visual.labels.first { parts.append(l) }
        if parts.isEmpty { parts.append(kind) }
        return parts.joined(separator: ", ")
    }

    /// Words a query term can match.
    var terms: Set<String> {
        var t = Set<String>()
        for s in [name, visual.caption, text, visual.ocrText, detail] { for w in AssistEmbedding.lemmas(s) where w.count > 1 { t.insert(w) } }
        for l in visual.labels { for w in AssistEmbedding.words(l) { t.insert(w) } }
        return t.subtracting(AssistEmbedding.stopWords)
    }
}

final class AssistIndex {
    static let shared = AssistIndex()
    private var visuals: [String: AssistVisual] = [:]
    private var embeddings: [String: [Double]] = [:]
    private var termCache: [String: Set<String>] = [:]
    private let lock = NSLock()

    static func visualKey(_ l: Layer) -> String {
        func bid(_ b: PixelBuffer) -> String { "\(UInt(bitPattern: ObjectIdentifier(b).hashValue))v\(b.version)" }
        var k: String
        switch l.content {
        case .raster(let r): k = "r\(bid(r.buffer))@\(r.origin.x),\(r.origin.y)"
        case .smartObject(let s):
            var src = "doc"
            if case .image(let b) = s.source { src = bid(b) }
            k = "so\(src)r\(s.sourceRevision)q\(s.quad.bounds)f\(s.filters.count)"
        case .text(let t): k = "t\(String(describing: t).hashValue)"
        case .shape(let s): k = "s\(String(describing: s).hashValue)"
        case .fill(let f): k = "f\(String(describing: f).hashValue)"
        case .adjustment: k = "a"
        case .group(let g): k = "g[" + g.children.map { visualKey($0) }.joined(separator: "|") + "]"
        }
        if let m = l.mask { k += "m\(bid(m.buffer))" }
        return "\(l.id)-\(k)"
    }

    func visual(_ key: String) -> AssistVisual? { lock.lock(); defer { lock.unlock() }; return visuals[key] }
    func store(_ key: String, _ v: AssistVisual) { lock.lock(); visuals[key] = v; lock.unlock() }

    func embedding(_ s: String) -> [Double]? {
        lock.lock()
        if let e = embeddings[s] { lock.unlock(); return e }
        lock.unlock()
        guard let v = AssistEmbedding.vector(s) else { return nil }
        lock.lock(); embeddings[s] = v; if embeddings.count > 4000 { embeddings.removeAll() }; lock.unlock()
        return v
    }

    func terms(_ d: AssistDescriptor, key: String) -> Set<String> {
        let k = key + "|" + d.name
        lock.lock()
        if let t = termCache[k] { lock.unlock(); return t }
        lock.unlock()
        let t = d.terms
        lock.lock(); termCache[k] = t; if termCache.count > 4000 { termCache.removeAll() }; lock.unlock()
        return t
    }

    struct Input {
        var key: String
        var layerID: UUID
        var image: CGImage?
        var alpha: CGImage?
        var sharpCrop: CGImage?
        var bounds: CGRect
        var wantsCaption: Bool
        var wantsOCR: Bool
        var paintColors: [String]
    }

    /// Analyses one layer's pixels (off the main thread).
    static func analyze(_ i: Input, useFlorence: Bool) -> AssistVisual {
        var v = AssistVisual()
        v.bounds = i.bounds
        v.colors = i.paintColors
        guard let img = i.image else { return v }
        if let a = i.alpha {
            let sw = AssistColor.dominant(a, max: 4)
            if v.colors.isEmpty { v.colors = sw.map(\.base).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } } }
            let st = AssistColor.stats(a)
            v.brightness = st.mean.luminance
        }
        v.print = AssistVision.featurePrint(img)
        var flat = false
        if let a = i.alpha {
            let st = AssistColor.stats(a)
            flat = st.detail < 1.2 && st.spread < 7 && st.coverage > 0.85
            if flat { v.caption = "Solid \(AssistColor.name(st.mean).lowercased()) area" }
        }
        if i.wantsCaption, !flat {
            v.labels = AssistVision.classify(img, max: 8, minConfidence: 0.1).map(\.label)
            if useFlorence, AssistCaptioner.shared.isAvailable, let c = try? AssistCaptioner.shared.generate(img, task: .caption) {
                v.caption = AssistText.cleanCaption(c).trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            if let crop = i.sharpCrop { v.blur = AssistQuality.blurMetric(crop) }
        }
        if i.wantsOCR, !flat {
            v.ocrText = AssistVision.ocr(img, fast: true)
                .filter { l in l.confidence >= 0.5 && l.text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count >= 3 }
                .map(\.text).joined(separator: " ")
        }
        return v
    }

    /// Makes sure every layer of `state` has a cached visual descriptor. Returns the number analysed.
    @discardableResult
    func ensure(_ state: DocumentState, useFlorence: Bool = true, progress: ((Int, Int) -> Void)? = nil) async -> Int {
        let inputs: [Input] = await Assist.onMain {
            var out: [Input] = []
            for l in state.allLayers {
                let key = AssistIndex.visualKey(l)
                if self.visual(key) != nil { continue }
                var inp = Input(key: key, layerID: l.id, image: nil, alpha: nil, sharpCrop: nil, bounds: .zero, wantsCaption: false, wantsOCR: false, paintColors: [])
                switch l.content {
                case .text(let t): inp.paintColors = [AssistColor.base(t.color)]
                case .shape(let s): if let c = s.fill.solidColor ?? s.stroke.paint.solidColor { inp.paintColors = [AssistColor.base(c)] }
                case .fill(let f): if let c = f.paint.solidColor { inp.paintColors = [AssistColor.base(c)] }
                default: break
                }
                if !l.isAdjustment, let (img, b) = Assist.layerImage(l, state: state, maxSide: 512, background: .white) {
                    inp.image = img
                    inp.bounds = b
                    inp.alpha = Assist.layerImage(l, state: state, maxSide: 128, background: nil)?.image
                    if l.isRaster || l.isSmartObject {
                        inp.wantsCaption = true
                        inp.wantsOCR = true
                        // native-resolution centre crop for the sharpness estimate
                        let side = min(512, b.width, b.height)
                        let cr = CGRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side).integral
                        let sp = CanvasSpace(width: state.width, height: state.height)
                        if side >= 48, let content = Compositor.shared.contentImage(l, space: sp) {
                            inp.sharpCrop = Assist.scaledCG(content.composited(over: CIImage.color(.white, sp.ciRect(cr))), rect: sp.ciRect(cr), maxSide: nil)
                        }
                    } else if l.isGroup {
                        inp.wantsOCR = false
                    }
                } else if let b = Compositor.shared.contentBounds(l, state: state) {
                    inp.bounds = b
                }
                out.append(inp)
            }
            return out
        }
        for (n, i) in inputs.enumerated() {
            store(i.key, AssistIndex.analyze(i, useFlorence: useFlorence))
            progress?(n + 1, inputs.count)
        }
        return inputs.count
    }

    /// Descriptors for all layers (cheap metadata + cached visuals). Layers not analysed yet get an empty visual.
    func descriptors(_ state: DocumentState) -> [(AssistDescriptor, String)] {
        let canvasArea = Double(max(1, state.width * state.height))
        return state.allLayers.map { l in
            let key = AssistIndex.visualKey(l)
            let v = visual(key) ?? AssistVisual()
            var kind = "image", text = "", detail = ""
            switch l.content {
            case .raster: kind = "image"
            case .text(let t): kind = "text"; text = t.text; detail = t.fontName
            case .shape(let s): kind = "shape"; detail = AssistNaming.shapeName(s)
            case .smartObject(let s): kind = "smart object"; detail = s.filters.map { $0.kind.displayName }.joined(separator: ", ")
            case .adjustment(let a): kind = "adjustment"; detail = AssistNaming.adjustmentName(a)
            case .fill(let f): kind = "fill"; detail = AssistNaming.fillName(f)
            case .group: kind = l.isArtboard ? "artboard" : "group"
            }
            var fx = l.effects.enabled ? l.effects.activeNames.map { $0.lowercased() } : []
            if case .smartObject(let s) = l.content, !s.filters.isEmpty { fx.append("smart filter"); fx += s.filters.map { $0.kind.displayName.lowercased() } }
            if case .shape(let s) = l.content, !s.stroke.paint.isNone { fx.append("shape stroke") }
            let area = Double(v.bounds.width * v.bounds.height) / canvasArea
            let d = AssistDescriptor(id: l.id, name: l.name, kind: kind, text: text.isEmpty ? v.ocrText : text, effects: fx, areaFraction: area,
                                     position: v.bounds.isEmpty ? nil : Assist.position(of: v.bounds, in: CGSize(width: state.width, height: state.height)),
                                     opacity: l.opacity, visible: l.isVisible, hasMask: l.mask != nil || l.vectorMask != nil, clipped: l.isClipped,
                                     locked: l.locks.anyLocked, blend: l.blendMode.rawValue.lowercased(), detail: detail, visual: v)
            return (d, key)
        }
    }
}

// MARK: - Query scoring

enum AssistSearch {
    struct Hit: Identifiable {
        var id: UUID
        var score: Double
        var reasons: [String]
        var summary: String
    }

    private static func smooth(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    private struct Rule {
        var phrases: [String]
        var label: String
        var score: (AssistDescriptor) -> Double
    }

    private static let colourSynonyms: [String: String] = ["grey": "gray", "violet": "purple", "cyan": "teal", "turquoise": "teal", "magenta": "pink",
                                                           "navy": "blue", "golden": "yellow", "gold": "yellow", "crimson": "red", "scarlet": "red",
                                                           "lime": "green", "tan": "beige", "cream": "beige", "silver": "gray", "aqua": "teal"]
    private static let colourWords = ["red", "orange", "yellow", "green", "teal", "blue", "purple", "pink", "brown", "beige", "olive", "black", "white", "gray"]

    private static let rules: [Rule] = {
        var r: [Rule] = []
        func fx(_ phrases: [String], _ label: String, _ match: @escaping (String) -> Bool) {
            r.append(Rule(phrases: phrases, label: label) { d in d.effects.contains(where: match) ? 1 : 0 })
        }
        fx(["drop shadow", "drop shadows", "dropshadow"], "drop shadow") { $0 == "drop shadow" }
        fx(["inner shadow"], "inner shadow") { $0 == "inner shadow" }
        fx(["shadow", "shadows"], "shadow") { $0.contains("shadow") }
        fx(["stroke", "strokes", "outline", "outlined", "border"], "stroke") { $0.contains("stroke") }
        fx(["glow", "glowing"], "glow") { $0.contains("glow") }
        fx(["bevel", "emboss", "embossed"], "bevel") { $0.contains("bevel") }
        fx(["gradient overlay"], "gradient overlay") { $0 == "gradient overlay" }
        fx(["color overlay", "colour overlay"], "colour overlay") { $0 == "color overlay" }
        fx(["smart filter", "smart filters", "filter", "filters", "filtered"], "smart filter") { $0 == "smart filter" }
        r.append(Rule(phrases: ["layer style", "layer styles", "effects", "effect", "styles", "fx"], label: "effects") { d in
            d.effects.contains { $0 != "smart filter" && $0 != "shape stroke" } ? 1 : 0 })
        r.append(Rule(phrases: ["blurry", "blurred", "blur", "out of focus", "unsharp", "fuzzy", "soft focus", "not sharp"], label: "blurry") { d in
            guard let b = d.visual.blur else { return 0 }
            return smooth(b, 0.42, 0.62) })
        r.append(Rule(phrases: ["sharp", "crisp", "in focus"], label: "sharp") { d in
            guard let b = d.visual.blur else { return 0 }
            return 1 - smooth(b, 0.3, 0.5) })
        r.append(Rule(phrases: ["big", "large", "huge", "biggest", "largest", "full size", "full-size"], label: "big") { d in smooth(d.areaFraction, 0.2, 0.55) })
        r.append(Rule(phrases: ["small", "tiny", "little", "smallest"], label: "small") { d in d.areaFraction <= 0 ? 0 : 1 - smooth(d.areaFraction, 0.03, 0.15) })
        func kind(_ phrases: [String], _ label: String, _ f: @escaping (AssistDescriptor) -> Double) { r.append(Rule(phrases: phrases, label: label, score: f)) }
        kind(["text layers", "text layer", "type layers", "type layer", "text", "type", "typography", "headline", "headlines", "caption", "captions", "label", "labels", "words", "lettering", "title", "titles"], "text") { d in
            d.kind == "text" ? 1 : (d.text.isEmpty ? 0 : 0.6) }
        kind(["images", "image", "photos", "photo", "pictures", "picture", "pixel layers", "pixel layer", "raster", "bitmap", "bitmaps", "photograph", "photographs"], "image") { d in
            d.kind == "image" || d.kind == "smart object" ? 1 : 0 }
        kind(["smart objects", "smart object"], "smart object") { $0.kind == "smart object" ? 1 : 0 }
        kind(["shapes", "shape", "vector", "vectors", "vector shapes"], "shape") { $0.kind == "shape" ? 1 : 0 }
        kind(["adjustment layers", "adjustment layer", "adjustments", "adjustment"], "adjustment") { $0.kind == "adjustment" ? 1 : 0 }
        kind(["groups", "group", "folders", "folder"], "group") { $0.kind == "group" || $0.kind == "artboard" ? 1 : 0 }
        kind(["artboards", "artboard"], "artboard") { $0.kind == "artboard" ? 1 : 0 }
        kind(["fill layers", "fill layer", "fills"], "fill") { $0.kind == "fill" ? 1 : 0 }
        kind(["hidden", "invisible", "turned off"], "hidden") { $0.visible ? 0 : 1 }
        kind(["visible"], "visible") { $0.visible ? 1 : 0 }
        kind(["locked"], "locked") { $0.locked ? 1 : 0 }
        kind(["masked", "with mask", "with a mask", "with masks", "has mask", "layer mask", "mask", "masks"], "mask") { $0.hasMask ? 1 : 0 }
        kind(["clipped", "clipping", "clipping mask"], "clipped") { $0.clipped ? 1 : 0 }
        kind(["semi-transparent", "semitransparent", "transparent", "see-through", "faded", "translucent", "low opacity"], "transparent") { $0.opacity < 0.999 ? 1 : 0 }
        kind(["dark"], "dark") { d in d.visual.brightness.map { 1 - smooth($0, 0.2, 0.45) } ?? 0 }
        kind(["bright", "light"], "bright") { d in d.visual.brightness.map { smooth($0, 0.55, 0.8) } ?? 0 }
        for (p, label) in [("top left", "top left"), ("top right", "top right"), ("bottom left", "bottom left"), ("bottom right", "bottom right"),
                           ("top", "top"), ("bottom", "bottom"), ("left", "left"), ("right", "right"), ("center", "center"), ("centre", "center"), ("middle", "center")] {
            let variants = [p, "on the \(p)", "at the \(p)", "in the \(p)"]
            kind(variants, label) { d in
                guard let pos = d.position else { return 0 }
                return pos == label ? 1 : (pos.contains(label) ? 0.8 : 0) }
        }
        for m in BlendMode.allCases where m != .normal && m != .passThrough {
            let n = m.rawValue.lowercased()
            kind([n, n.replacingOccurrences(of: " ", with: "")], n) { $0.blend == n ? 1 : 0 }
        }
        for c in colourWords {
            let syn = [c] + colourSynonyms.filter { $0.value == c }.map(\.key)
            kind(syn, c) { d in
                guard let i = d.visual.colors.firstIndex(of: c) else { return 0 }
                return i == 0 ? 1 : 0.7 }
        }
        return r
    }()

    /// "text that says sale", "saying “50% off”", quoted strings → the literal text to look for.
    static func saysClause(_ q: String) -> (text: String, rest: String)? {
        let patterns = [#"(?:that\s+)?(?:says|saying|reads|reading|contains|containing|with\s+the\s+text|with\s+text|labell?ed|spelling)\s+["“'‘]?(.+?)["”'’]?\s*$"#,
                        #"["“](.+?)["”]"#]
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let ns = q as NSString
            if let m = re.firstMatch(in: q, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 {
                let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let rest = ns.replacingCharacters(in: m.range, with: " ")
                if !t.isEmpty { return (t, rest) }
            }
        }
        return nil
    }

    static func search(_ query: String, in state: DocumentState, limit: Int = 50) -> [Hit] {
        let q0 = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q0.isEmpty else { return [] }
        var q = " " + q0.replacingOccurrences(of: "?", with: " ").replacingOccurrences(of: ",", with: " ") + " "
        var says: String?
        if let s = saysClause(q0) { says = s.text.lowercased(); q = " " + s.rest + " " }
        // rules: longest phrases first, each consumes its words
        var active: [Rule] = []
        let ordered = rules.flatMap { r in r.phrases.map { ($0, r) } }.sorted { $0.0.count > $1.0.count }
        var usedLabels = Set<String>()
        for (phrase, rule) in ordered {
            guard let range = q.range(of: " \(phrase) ") else { continue }
            q.replaceSubrange(range, with: "  ")
            if usedLabels.insert(rule.label).inserted { active.append(rule) }
        }
        if says != nil, !usedLabels.contains("text") { /* "says" implies text-bearing layers; handled by the text match itself */ }
        let content = AssistEmbedding.lemmas(q).filter { !AssistEmbedding.stopWords.contains($0) && $0.count > 1 }
        let index = AssistIndex.shared
        let qVec = index.embedding(q0)
        var hits: [Hit] = []
        for (d, key) in index.descriptors(state) {
            var reasons: [String] = []
            // literal text
            var textScore: Double? = nil
            if let s = says {
                let hay = d.text.lowercased()
                if hay.contains(s) { textScore = d.kind == "text" ? 1 : 0.9 }
                else {
                    let words = AssistEmbedding.words(s), hw = Set(AssistEmbedding.words(hay))
                    let found = words.filter { hw.contains($0) }.count
                    textScore = words.isEmpty ? 0 : (found == words.count ? 0.8 : 0)
                }
                if textScore! <= 0 { continue }
                reasons.append("says “\(Assist.truncate(d.text, 18))”")
            }
            // rules
            var ruleScore: Double? = nil
            if !active.isEmpty {
                var sum = 0.0, minV = 1.0
                for r in active {
                    let v = r.score(d)
                    sum += v; minV = min(minV, v)
                    if v >= 0.5 { reasons.append(r.label) }
                }
                ruleScore = 0.5 * (sum / Double(active.count)) + 0.5 * minV
            }
            // content words
            var lexical: Double? = nil
            if !content.isEmpty {
                let terms = index.terms(d, key: key)
                var sum = 0.0
                for w in content {
                    var best = terms.contains(w) ? 1.0 : 0.0
                    if best < 1 {
                        for t in terms {
                            let s = AssistEmbedding.wordSimilarity(w, t)
                            if s >= 0.45 { best = max(best, s * 0.9) }
                        }
                    }
                    if best >= 0.6 { reasons.append(w) }
                    sum += best
                }
                lexical = sum / Double(content.count)
            }
            var emb = 0.0
            if let qv = qVec, let dv = index.embedding(d.summary.lowercased()) { emb = min(1, max(0, (AssistEmbedding.cosine(qv, dv) - 0.3) / 0.3)) }
            var score: Double
            switch (ruleScore, lexical) {
            case (let r?, let l?): score = 0.45 * r + 0.43 * l + 0.12 * emb
            case (let r?, nil): score = 0.9 * r + 0.1 * emb
            case (nil, let l?): score = 0.75 * l + 0.25 * emb
            case (nil, nil): score = says != nil ? 1 : emb
            }
            if let t = textScore { score = 0.5 * t + 0.5 * score }
            if score < 0.3 { continue }
            hits.append(Hit(id: d.id, score: score, reasons: reasons.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }, summary: d.summary))
        }
        hits.sort { $0.score > $1.score }
        guard let top = hits.first else { return [] }
        return Array(hits.filter { $0.score >= top.score * 0.6 }.prefix(limit))
    }

    // MARK: Similar-looking layers (Vision feature prints)

    /// Layers that look like `id`, nearest first, with their feature-print distance.
    static func similar(to id: UUID, in state: DocumentState, threshold: Float = 0.55) -> [(id: UUID, distance: Float)] {
        let index = AssistIndex.shared
        guard let ref = state.layer(id), let rp = index.visual(AssistIndex.visualKey(ref))?.print else { return [] }
        var out: [(UUID, Float)] = []
        for l in state.allLayers where l.id != id {
            guard let p = index.visual(AssistIndex.visualKey(l))?.print, let d = AssistVision.distance(rp, p) else { continue }
            if d <= threshold { out.append((l.id, d)) }
        }
        return out.sorted { $0.1 < $1.1 }
    }

    static func selectSimilarAction() {
        guard let d = AppActions.doc, let id = d.activeLayerID else { return }
        let st = d.state
        Assist.run("Comparing layers…", { await AssistIndex.shared.ensure(st, useFlorence: false) }) { _ in
            let sim = similar(to: id, in: d.state)
            guard !sim.isEmpty else { AppModel.shared.setStatus("No similar looking layers found."); NSSound.beep(); return }
            d.selectedLayerIDs = Set(sim.map(\.id) + [id])
            d.activeLayerID = id
            reveal(d, ids: sim.map(\.id))
            d.setNeedsOverlay()
            AppModel.shared.setStatus("Selected \(sim.count + 1) similar looking layers.")
        }
    }

    /// Expands the groups that contain `ids` so they show in the Layers panel.
    static func reveal(_ d: Document, ids: [UUID]) {
        for id in ids {
            var p = d.state.parentID(of: id)
            while let pid = p {
                if d.state.layer(pid)?.isExpanded == false { d.state.updateLayer(pid) { $0.isExpanded = true } }
                p = d.state.parentID(of: pid)
            }
        }
    }
}

// MARK: - Panel

@Observable
final class AssistSearchModel {
    static let shared = AssistSearchModel()
    var query = ""
    var hits: [AssistSearch.Hit] = []
    var indexing = false
    var progress = ""
    var deep = UserDefaults.standard.object(forKey: "Lumen.Assist.SearchCaptions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(deep, forKey: "Lumen.Assist.SearchCaptions") }
    }
    @ObservationIgnored private var generation = 0

    func run() {
        guard let d = AppActions.doc else { hits = []; return }
        let q = query
        generation += 1
        let gen = generation
        hits = AssistSearch.search(q, in: d.state)      // instant pass on what is cached
        let st = d.state
        let deep = self.deep
        indexing = true
        Task.detached(priority: .userInitiated) {
            let n = await AssistIndex.shared.ensure(st, useFlorence: deep) { done, total in
                Task { @MainActor in AssistSearchModel.shared.progress = "Describing layers \(done)/\(total)…" }
            }
            await MainActor.run {
                let m = AssistSearchModel.shared
                m.indexing = false
                m.progress = ""
                guard gen == m.generation else { return }
                if n > 0, let cur = AppActions.doc { m.hits = AssistSearch.search(q, in: cur.state) }
            }
        }
    }
}

struct AssistFindLayersPanel: View {
    @Bindable var m = AssistSearchModel.shared
    @Bindable var app = AppModel.shared
    private let examples = ["the red car", "text that says sale", "blurry layers", "layers with drop shadow", "big images", "hidden layers"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Theme.textDim)
                TextField("Find layers: “red car”, “blurry”, “says sale”…", text: $m.query)
                    .textFieldStyle(.plain).font(Theme.font)
                    .onSubmit { m.run() }
                if !m.query.isEmpty {
                    Button { m.query = ""; m.hits = [] } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.fieldBG))
            if let d = app.activeDocument {
                if m.hits.isEmpty {
                    if m.query.isEmpty {
                        Text("Describe what you are looking for:").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
                        ForEach(examples, id: \.self) { e in
                            Button(e) { m.query = e; m.run() }.buttonStyle(.plain).font(Theme.font).foregroundStyle(Theme.accent)
                        }
                    } else if !m.indexing {
                        Text("No matching layers.").font(Theme.font).foregroundStyle(Theme.textFaint)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(m.hits) { h in
                                if let l = d.state.layer(h.id) { row(d, l, h) }
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
                HStack(spacing: 6) {
                    if m.indexing { ProgressView().controlSize(.mini); Text(m.progress.isEmpty ? "Indexing…" : m.progress).font(Theme.fontSmall).foregroundStyle(Theme.textFaint) }
                    Spacer()
                    if !m.hits.isEmpty {
                        Button("Select All") {
                            d.selectedLayerIDs = Set(m.hits.map(\.id)); d.activeLayerID = m.hits.first?.id
                            AssistSearch.reveal(d, ids: m.hits.map(\.id)); d.setNeedsOverlay()
                        }.buttonStyle(PanelButtonStyle())
                    }
                    Button("Similar") { AssistSearch.selectSimilarAction() }.buttonStyle(PanelButtonStyle())
                        .help("Select layers that look like the active layer (Vision feature prints)")
                }
                Toggle2(label: "Describe pixels with Florence-2 (slower, better)", on: $m.deep)
                    .disabled(!AssistCaptioner.shared.isAvailable)
                    .help(AssistCaptioner.shared.isAvailable ? "Captions each image layer on-device" : "Florence-2 is not installed: using Vision labels")
            } else {
                Text("Open a document to search its layers.").font(Theme.font).foregroundStyle(Theme.textFaint)
            }
        }
        .padding(8)
        .panelText()
    }

    @ViewBuilder func row(_ d: Document, _ l: Layer, _ h: AssistSearch.Hit) -> some View {
        let selected = d.selectedLayerIDs.contains(l.id)
        HStack(spacing: 6) {
            ZStack {
                CheckerBackground()
                if let cg = Thumbnails.shared.layer(l, doc: d, size: 28) { Image(decorative: cg, scale: 2).resizable().aspectRatio(contentMode: .fit) }
            }
            .frame(width: 30, height: 30).clipShape(RoundedRectangle(cornerRadius: 2))
            VStack(alignment: .leading, spacing: 1) {
                Text(l.name).font(Theme.font).lineLimit(1)
                Text(h.reasons.isEmpty ? h.summary : h.reasons.joined(separator: " · ")).font(Theme.fontSmall).foregroundStyle(Theme.textFaint).lineLimit(1)
            }
            Spacer()
            Text("\(Int((h.score * 100).rounded()))%").font(Theme.fontSmall).foregroundStyle(Theme.textFaint)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(selected ? Theme.selection : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            let ext = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            d.selectLayer(l.id, extend: ext)
            AssistSearch.reveal(d, ids: [l.id])
        }
        .help(h.summary)
    }
}
