import AppKit
import CoreText
import Vision
import ImageCratCore

/// Type ▸ Match Font: recognizes the text in an image crop (Vision), renders the recognized string in installed fonts
/// and ranks them by shape similarity of the binarized, size-normalized text (chamfer distance + overlap + aspect +
/// stroke density).
enum MatchFontEngine {
    struct Recognition {
        var text: String
        /// Text box in crop pixel coordinates (y-down).
        var box: CGRect
        var confidence: Float
    }

    struct Candidate: Identifiable, Hashable {
        let fontName: String
        let family: String
        let style: String
        let score: Double
        var id: String { fontName }
    }

    // MARK: Recognition

    static func recognize(_ img: CGImage) -> Recognition? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.02
        let handler = VNImageRequestHandler(cgImage: img, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        let obs = (req.results ?? []).compactMap { o -> (VNRecognizedTextObservation, VNRecognizedText)? in
            guard let c = o.topCandidates(1).first, !c.string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (o, c)
        }
        // the largest line of text
        guard let (o, c) = obs.max(by: { $0.0.boundingBox.width * $0.0.boundingBox.height < $1.0.boundingBox.width * $1.0.boundingBox.height }) else { return nil }
        let W = CGFloat(img.width), H = CGFloat(img.height)
        let b = o.boundingBox
        let box = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
        return Recognition(text: c.string, box: box, confidence: c.confidence)
    }

    // MARK: Normalized ink images

    /// Gray (0 = paper, 1 = ink) image of `W`×`H`.
    struct InkImage {
        var w: Int
        var h: Int
        var v: [Float]
        var aspect: Double
        var density: Double
    }

    static let normH = 40

    /// Grayscale pixels of `img` (0…1, luminance), row-major y-down.
    static func gray(_ img: CGImage) -> (Int, Int, [Float]) {
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 255, count: w * h)
        let ok = data.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return (w, h, []) }
        return (w, h, data.map { Float($0) / 255 })
    }

    /// Otsu threshold → ink mask (ink = the minority class, so light-on-dark text works too).
    static func inkMask(_ w: Int, _ h: Int, _ g: [Float]) -> [Float] {
        var hist = [Int](repeating: 0, count: 256)
        for x in g { hist[min(255, max(0, Int(x * 255)))] += 1 }
        let total = g.count
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * hist[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, thr = 128
        for i in 0..<256 {
            wB += hist[i]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(i * hist[i])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; thr = i }
        }
        let t = Float(thr) / 255
        let dark = g.filter { $0 <= t }.count
        let inkIsDark = dark <= total - dark
        // soft edge around the threshold keeps anti-aliasing information
        return g.map { x in
            let d = inkIsDark ? (t - x) : (x - t)
            return max(0, min(1, 0.5 + d * 6))
        }
    }

    /// Crops the mask to its ink bounds and resamples to `outW`×`normH` (box filter).
    static func normalize(_ w: Int, _ h: Int, _ m: [Float], outW: Int? = nil) -> InkImage? {
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h { for x in 0..<w where m[y * w + x] > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX, maxY >= minY else { return nil }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        let aspect = Double(bw) / Double(bh)
        let H = normH
        let W = outW ?? max(8, min(600, Int((Double(H) * aspect).rounded())))
        var out = [Float](repeating: 0, count: W * H)
        var ink = 0.0
        for y in 0..<bh { for x in 0..<bw { ink += Double(m[(minY + y) * w + minX + x]) } }
        for oy in 0..<H {
            let y0 = Double(oy) * Double(bh) / Double(H), y1 = Double(oy + 1) * Double(bh) / Double(H)
            for ox in 0..<W {
                let x0 = Double(ox) * Double(bw) / Double(W), x1 = Double(ox + 1) * Double(bw) / Double(W)
                var s: Float = 0, n: Float = 0
                var yy = Int(y0)
                while Double(yy) < y1 && yy < bh {
                    var xx = Int(x0)
                    while Double(xx) < x1 && xx < bw {
                        s += m[(minY + yy) * w + minX + xx]; n += 1
                        xx += 1
                    }
                    yy += 1
                }
                out[oy * W + ox] = n > 0 ? s / n : 0
            }
        }
        return InkImage(w: W, h: H, v: out, aspect: aspect, density: ink / Double(bw * bh))
    }

    /// Two-pass chamfer (3-4) distance to the nearest ink pixel, in pixels.
    static func distance(_ a: InkImage) -> [Float] {
        let w = a.w, h = a.h
        let inf: Float = 1e6
        var d = a.v.map { $0 > 0.5 ? 0 : inf }
        for y in 0..<h { for x in 0..<w {
            var v = d[y * w + x]
            if x > 0 { v = min(v, d[y * w + x - 1] + 3) }
            if y > 0 {
                v = min(v, d[(y - 1) * w + x] + 3)
                if x > 0 { v = min(v, d[(y - 1) * w + x - 1] + 4) }
                if x < w - 1 { v = min(v, d[(y - 1) * w + x + 1] + 4) }
            }
            d[y * w + x] = v
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
            var v = d[y * w + x]
            if x < w - 1 { v = min(v, d[y * w + x + 1] + 3) }
            if y < h - 1 {
                v = min(v, d[(y + 1) * w + x] + 3)
                if x < w - 1 { v = min(v, d[(y + 1) * w + x + 1] + 4) }
                if x > 0 { v = min(v, d[(y + 1) * w + x - 1] + 4) }
            }
            d[y * w + x] = v
        } }
        return d.map { $0 / 3 }
    }

    struct Target {
        let ink: InkImage
        let dist: [Float]
    }

    static func target(_ img: CGImage) -> Target? {
        let (w, h, g) = gray(img)
        guard !g.isEmpty, let n = normalize(w, h, inkMask(w, h, g)) else { return nil }
        return Target(ink: n, dist: distance(n))
    }

    /// Ink mask of `text` rendered in `fontName` (black on white, ~64 px).
    static func renderMask(_ text: String, fontName: String, size: CGFloat = 64) -> (Int, Int, [Float])? {
        let f = CTFontCreateWithName(fontName as CFString, size, nil)
        // every character must be supported by this font (no fallback)
        let filtered = Array(text.utf16).filter { $0 != 32 }
        var gf = [CGGlyph](repeating: 0, count: filtered.count)
        guard CTFontGetGlyphsForCharacters(f, filtered, &gf, filtered.count) else { return nil }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: NSColor.black]))
        let ib = CTLineGetImageBounds(line, nil)
        guard ib.width > 1, ib.height > 1, ib.width < 20000 else { return nil }
        let pad: CGFloat = 4
        let w = Int(ceil(ib.width + pad * 2)), h = Int(ceil(ib.height + pad * 2))
        var data = [UInt8](repeating: 255, count: w * h)
        let ok = data.withUnsafeMutableBytes { p -> Bool in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.textPosition = CGPoint(x: pad - ib.minX, y: pad - ib.minY)
            CTLineDraw(line, ctx)
            return true
        }
        guard ok else { return nil }
        // CG bitmap rows are bottom-up relative to our y-down convention only in drawing; memory is top row first.
        return (w, h, data.map { 1 - Float($0) / 255 })
    }

    /// Dissimilarity of a rendered candidate to the target (lower is better).
    static func score(_ t: Target, text: String, fontName: String) -> Double? {
        guard let (w, h, m) = renderMask(text, fontName: fontName), let c = normalize(w, h, m, outW: t.ink.w) else { return nil }
        let dc = distance(c)
        var sumCT: Double = 0, nC: Double = 0, sumTC: Double = 0, nT: Double = 0
        var inter: Double = 0, uni: Double = 0
        for i in 0..<c.v.count {
            let cv = Double(c.v[i]), tv = Double(t.ink.v[i])
            if cv > 0.5 { sumCT += Double(min(t.dist[i], 20)); nC += 1 }
            if tv > 0.5 { sumTC += Double(min(dc[i], 20)); nT += 1 }
            inter += min(cv, tv); uni += max(cv, tv)
        }
        guard nC > 0, nT > 0 else { return nil }
        let chamfer = (sumCT / nC + sumTC / nT) / 2 / Double(normH) * 10
        let iou = uni > 0 ? inter / uni : 0
        let aspect = abs(log(c.aspect / max(0.01, t.ink.aspect)))
        let dens = abs(c.density - t.ink.density) / max(0.02, t.ink.density)
        return chamfer + 2.0 * aspect + 1.2 * dens + 1.5 * (1 - iou)
    }

    // MARK: Candidates

    /// Installed families → (PostScript name, style) members. Call on the main thread (FontCatalog is not thread-safe).
    static func installedMembers() -> [String: [(String, String)]] {
        var out: [String: [(String, String)]] = [:]
        for fam in FontCatalog.families where !fam.contains("Emoji") && !fam.hasPrefix("LastResort") { out[fam] = FontCatalog.members(fam) }
        return out
    }

    /// Regular face of every installed family (symbol / emoji families excluded).
    static func regularFaces(_ all: [String: [(String, String)]]) -> [(String, String, String)] {
        var out: [(String, String, String)] = []
        for fam in all.keys.sorted() {
            let members = all[fam] ?? []
            guard !members.isEmpty else { continue }
            let pref = ["Regular", "Roman", "Book", "Normal", "Plain", "Medium", "W3", "W4"]
            let m = pref.lazy.compactMap { p in members.first { $0.1 == p } }.first ?? members.first { !$0.1.localizedCaseInsensitiveContains("italic") } ?? members[0]
            out.append((m.0, fam, m.1))
        }
        return out
    }

    /// Ranks installed fonts against the target crop. `progress` receives 0…1 (any thread).
    static func rank(target t: Target, text: String, fonts: [String: [(String, String)]], limit: Int = 10, progress: ((Double) -> Void)? = nil) -> [Candidate] {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty else { return [] }
        let faces = regularFaces(fonts)
        // OCR sometimes splits a word ("Handg loves" in monospaced fonts): also try without spaces between lowercase letters.
        var variants = [sample]
        let joined = sample.replacingOccurrences(of: "(?<=\\p{Ll}) (?=\\p{Ll})", with: "", options: .regularExpression)
        if joined != sample { variants.append(joined) }
        func best(_ font: String) -> Double? { variants.compactMap { score(t, text: $0, fontName: font) }.min() }
        var scores = [Double?](repeating: nil, count: faces.count)
        let lock = NSLock()
        var done = 0
        scores.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: faces.count) { i in
                let s = best(faces[i].0)
                (base + i).pointee = s
                lock.lock(); done += 1; let d = done; lock.unlock()
                if d % 20 == 0 { progress?(0.8 * Double(d) / Double(faces.count)) }
            }
        }
        var ranked: [Candidate] = []
        for (i, f) in faces.enumerated() { if let s = scores[i] { ranked.append(Candidate(fontName: f.0, family: f.1, style: f.2, score: s)) } }
        ranked.sort { $0.score < $1.score }
        // Refine: every style of the best families.
        let topFamilies = Array(ranked.prefix(24).map(\.family))
        var extra: [(String, String, String)] = []
        for fam in topFamilies { for m in fonts[fam] ?? [] where !ranked.contains(where: { $0.fontName == m.0 }) { extra.append((m.0, fam, m.1)) } }
        var extraScores = [Double?](repeating: nil, count: extra.count)
        extraScores.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: extra.count) { i in (base + i).pointee = best(extra[i].0) }
        }
        for (i, f) in extra.enumerated() { if let s = extraScores[i] { ranked.append(Candidate(fontName: f.0, family: f.1, style: f.2, score: s)) } }
        ranked.sort { $0.score < $1.score }
        progress?(1)
        return Array(ranked.prefix(limit))
    }

    // MARK: Previews

    private nonisolated(unsafe) static var previewCache: [String: NSImage] = [:]

    static func preview(_ text: String, fontName: String, height: CGFloat, color: NSColor) -> NSImage {
        let key = "\(fontName)|\(text)|\(height)|\(color.description)"
        if let c = previewCache[key] { return c }
        let f = CTFontCreateWithName(fontName as CFString, height * 0.7, nil)
        let astr = NSAttributedString(string: text, attributes: [.font: f, .foregroundColor: color])
        let line = CTLineCreateWithAttributedString(astr)
        let w = min(2000, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 4)
        let img = NSImage(size: NSSize(width: max(4, w), height: height), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.textPosition = CGPoint(x: 2, y: (height - (CTFontGetAscent(f) + CTFontGetDescent(f))) / 2 + CTFontGetDescent(f))
            CTLineDraw(line, ctx)
            return true
        }
        if previewCache.count > 500 { previewCache.removeAll() }
        previewCache[key] = img
        return img
    }

    /// Font size that makes `text` in `fontName` as tall (ink) as `inkHeight` px.
    static func matchingSize(_ text: String, fontName: String, inkHeight: CGFloat) -> Double {
        let f = CTFontCreateWithName(fontName as CFString, 100, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f]))
        let ib = CTLineGetImageBounds(line, nil)
        guard ib.height > 1 else { return 48 }
        return Double(100 * inkHeight / ib.height)
    }
}

// MARK: - Session (dialog model)

@Observable
final class MatchFontSession {
    var crop: CGImage?
    var cropRect: CGRect = .zero        // document coords of the analysed crop
    var text = ""
    var results: [MatchFontEngine.Candidate] = []
    var running = false
    var progress = 0.0
    var message = ""
    var selected: String?
    var inkHeight: CGFloat = 40
    private var target: MatchFontEngine.Target?

    /// Crops the composite to the selection (or the whole canvas) and recognizes the text.
    func load(from d: Document) {
        let sp = AppActions.space(d)
        var r = d.state.canvasRect
        if let sb = d.state.selectionBounds, !sb.isEmpty { r = sb }
        let buf = RenderEngine.renderBuffer(Compositor.shared.composite(d), docRect: r, space: sp)
        load(image: buf.makeCGImage(), docRect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height))
        if d.state.selectionBounds == nil { message = "Tip: draw a rectangular selection around the text for best results." }
    }

    func load(image: CGImage, docRect: CGRect) {
        guard let rec = MatchFontEngine.recognize(image) else {
            crop = image; cropRect = docRect
            message = "No text found. Make a rectangular selection around a line of text."
            return
        }
        // tighten to the recognized line (with a little room for ascenders / descenders)
        let b = rec.box.insetBy(dx: -rec.box.height * 0.08, dy: -rec.box.height * 0.18)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        let c = image.cropping(to: b) ?? image
        crop = c
        cropRect = CGRect(x: docRect.minX + b.minX, y: docRect.minY + b.minY, width: b.width, height: b.height)
        text = rec.text
        target = MatchFontEngine.target(c)
        inkHeight = inkHeightOf(c)
        message = ""
    }

    private func inkHeightOf(_ img: CGImage) -> CGFloat {
        let (w, h, g) = MatchFontEngine.gray(img)
        let m = MatchFontEngine.inkMask(w, h, g)
        var minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where m[y * w + x] > 0.5 { minY = min(minY, y); maxY = max(maxY, y); break } }
        return maxY >= minY ? CGFloat(maxY - minY + 1) : CGFloat(h)
    }

    /// Runs the ranking synchronously (self tests) or in the background (dialog).
    func run(async: Bool = true) {
        guard let t = target, !text.isEmpty else { return }
        let sample = text
        running = true; progress = 0; results = []
        let fonts = MatchFontEngine.installedMembers()
        let work = { [weak self] in
            let res = MatchFontEngine.rank(target: t, text: sample, fonts: fonts) { p in DispatchQueue.main.async { self?.progress = p } }
            let finish = { self?.results = res; self?.running = false; self?.selected = res.first?.fontName }
            if async { DispatchQueue.main.async(execute: finish) } else { finish() }
        }
        if async { DispatchQueue.global(qos: .userInitiated).async(execute: work) } else { work() }
    }

    /// Sets the chosen font on the active type layer, or creates a type layer over the crop.
    func apply(fontName: String) {
        guard let d = AppActions.doc else { return }
        if AppModel.shared.textEditingActive, TextTool.editing != nil {
            TypeEdit.update { $0.fontName = fontName }
            return
        }
        if let id = d.activeLayerID, let t = d.state.layer(id)?.text {
            var n = t
            n.applyLayerWide(CharacterStyle(fontName: fontName))
            d.updateLayer(id) { $0.text = n }
            d.commit("Match Font")
        } else {
            var t = TextContent()
            t.text = text
            t.fontName = fontName
            t.fontSize = MatchFontEngine.matchingSize(text, fontName: fontName, inkHeight: inkHeight)
            t.color = AppModel.shared.foreground
            let f = CTFontCreateWithName(fontName as CFString, CGFloat(t.fontSize), nil)
            let asc = CTFontGetAscent(f)
            // place the baseline roughly at the bottom of the crop's cap height
            t.position = CGPoint(x: cropRect.minX, y: cropRect.midY + inkHeight * 0.5 - asc)
            let l = Layer(name: text, content: .text(t))
            d.addLayer(l)
            d.commit("Match Font")
        }
        d.setNeedsRender()
        TypeEditState.shared.tick += 1
    }
}
