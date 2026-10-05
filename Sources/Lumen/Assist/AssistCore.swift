import AppKit
import CoreImage
import Vision
import NaturalLanguage
import Observation
import ImageCratCore

/// Shared plumbing for the "smart assists" (auto names, semantic search, crop suggestions, alt text, OCR → text,
/// quality checks, subject helpers). Everything runs on-device: Apple Vision / NaturalLanguage always, plus the
/// optional models installed through `ModelManager` (Florence-2, SAM, LaMa, Depth Anything, NAFNet).
enum Assist {
    static func log(_ s: String) { print("[assist] " + s) }

    /// Runs `body` off the main thread with a status message, then `done` on the main thread.
    static func run<T>(_ status: String, _ body: @escaping () async throws -> T, done: @escaping (T) -> Void) {
        AssistState.shared.busy = status
        AppModel.shared.setStatus(status)
        Task.detached(priority: .userInitiated) {
            do {
                let r = try await body()
                await MainActor.run {
                    AssistState.shared.busy = nil
                    done(r)
                }
            } catch {
                await MainActor.run {
                    AssistState.shared.busy = nil
                    AppModel.shared.setStatus("\(status) failed: \(error.localizedDescription)")
                    Beep.play()
                }
            }
        }
    }

    /// Hops to the main thread (document rendering and mutation live there).
    static func onMain<T>(_ f: @escaping () -> T) async -> T {
        await MainActor.run { f() }
    }

    // MARK: Rendering (main thread)

    /// Flattened composite over `background`, scaled so the long side is at most `maxSide`.
    static func compositeCG(_ st: DocumentState, maxSide: Int? = nil, background: RGBA? = .white) -> CGImage? {
        let sp = CanvasSpace(width: st.width, height: st.height)
        var img = Compositor.shared.composite(st)
        if let bg = background { img = img.composited(over: CIImage.color(bg, sp.ciCanvas)) }
        return scaledCG(img, rect: sp.ciCanvas, maxSide: maxSide)
    }

    /// Canvas-size RGBA buffer of the composite.
    static func compositeBuffer(_ st: DocumentState) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        return RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: sp)
    }

    static func scaledCG(_ img: CIImage, rect: CGRect, maxSide: Int?) -> CGImage? {
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        var i = img.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        var out = CGRect(x: 0, y: 0, width: rect.width.rounded(), height: rect.height.rounded())
        if let m = maxSide, max(rect.width, rect.height) > CGFloat(m) {
            let s = CGFloat(m) / max(rect.width, rect.height)
            i = i.transformed(by: CGAffineTransform(scaleX: s, y: s), highQualityDownsample: true)
            out = CGRect(x: 0, y: 0, width: max(1, (rect.width * s).rounded()), height: max(1, (rect.height * s).rounded()))
        }
        return RenderEngine.readbackContext.createCGImage(i, from: out, format: .RGBA8, colorSpace: sRGBSpace)
    }

    /// A layer's own look (content, mask, effects; full opacity, normal blend) cropped to its visible bounds.
    /// `background` nil keeps transparency.
    static func layerImage(_ layer: Layer, state: DocumentState, maxSide: Int = 768, background: RGBA? = .white) -> (image: CGImage, bounds: CGRect)? {
        let sp = CanvasSpace(width: state.width, height: state.height)
        guard var b = Compositor.shared.contentBounds(layer, state: state) else { return nil }
        let fx = CGFloat(layer.effects.hasAny ? layer.effects.extent : 0)
        b = b.insetBy(dx: -fx, dy: -fx).intersection(state.canvasCGRect).integral
        guard b.width >= 2, b.height >= 2 else { return nil }
        var l = layer
        l.opacity = 1; l.blendMode = l.isGroup ? .passThrough : .normal; l.isVisible = true; l.isClipped = false
        var img = Compositor.shared.layerAppearance(l, state: state)
        let cr = sp.ciRect(b)
        if let bg = background { img = img.composited(over: CIImage.color(bg, cr)) }
        guard let cg = scaledCG(img, rect: cr, maxSide: maxSide) else { return nil }
        return (cg, b)
    }

    static func buffer(_ cg: CGImage) -> PixelBuffer { PixelBuffer(cgImage: cg) }

    static func loadCG(_ url: URL, maxSide: Int? = nil) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        if let m = maxSide {
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: m]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func writePNG(_ cg: CGImage, _ url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// Interleaved RGBA8 (unpremultiplied, row 0 = top) of `cg` resized to w×h.
    static func rgba(_ cg: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGBSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // unpremultiply
        var i = 0
        while i < bytes.count {
            let a = Int(bytes[i + 3])
            if a > 0 && a < 255 {
                bytes[i] = UInt8(min(255, Int(bytes[i]) * 255 / a)); bytes[i + 1] = UInt8(min(255, Int(bytes[i + 1]) * 255 / a))
                bytes[i + 2] = UInt8(min(255, Int(bytes[i + 2]) * 255 / a))
            }
            i += 4
        }
        return bytes
    }

    /// Luminance 0…255 as floats (row 0 = top) of `cg` resized to w×h (opaque: transparent areas read as white).
    static func luma(_ cg: CGImage, _ w: Int, _ h: Int) -> [Float] {
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: graySpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return bytes.map { Float($0) }
    }

    // MARK: Words

    /// "top left", "center", "bottom right" … for a rect inside a canvas; nil when it covers most of the canvas.
    static func position(of r: CGRect, in canvas: CGSize) -> String? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let area = (r.width * r.height) / (canvas.width * canvas.height)
        if area > 0.5 { return nil }
        let cx = r.midX / canvas.width, cy = r.midY / canvas.height
        let h = cx < 0.38 ? "left" : (cx > 0.62 ? "right" : "")
        let v = cy < 0.38 ? "top" : (cy > 0.62 ? "bottom" : "")
        if h.isEmpty && v.isEmpty { return "center" }
        return [v, h].filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { w -> String in
            let str = String(w)
            if str.count > 1, str == str.uppercased() { return str }   // keep acronyms
            return str.prefix(1).uppercased() + str.dropFirst()
        }.joined(separator: " ")
    }

    static func truncate(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count <= n { return t }
        let cut = String(t.prefix(n))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > n / 2 { return String(cut[..<sp]) + "…" }
        return cut + "…"
    }

    static func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
}

/// Observable UI state shared by the assist dialogs and panels.
@Observable
final class AssistState {
    static let shared = AssistState()
    /// Status text while a background analysis runs (nil = idle).
    var busy: String?
    /// Bumped when cached auto names / descriptors change (dialog previews re-read them).
    var revision = 0
}

// MARK: - Colours

enum AssistColor {
    struct Swatch {
        var color: RGBA
        var name: String        // "Dark Blue"
        var base: String        // "blue"
        var fraction: Double
    }

    /// Basic colour word ("red", "gray", …).
    static func base(_ c: RGBA) -> String {
        let (h, s, b) = c.hsb
        let hue = h * 360
        if b < 0.13 { return "black" }
        if s < 0.12 { return b > 0.9 ? "white" : "gray" }
        if s < 0.22 && b < 0.35 { return "gray" }
        switch hue {
        case ..<14: return (s < 0.5 && b > 0.75) ? "pink" : (b < 0.45 && s < 0.75 ? "brown" : "red")
        case ..<42: return (b < 0.62 || (s < 0.55 && b < 0.8)) ? "brown" : (s < 0.35 ? "beige" : "orange")
        case ..<68: return s < 0.35 ? "beige" : (b < 0.5 ? "olive" : "yellow")
        case ..<160: return "green"
        case ..<192: return "teal"
        case ..<255: return "blue"
        case ..<292: return "purple"
        case ..<338: return (b > 0.6) ? "pink" : "purple"
        default: return (s < 0.5 && b > 0.75) ? "pink" : "red"
        }
    }

    /// Display name with a lightness modifier ("Dark Blue", "Light Gray", "Yellow").
    static func name(_ c: RGBA) -> String {
        let n = base(c)
        let (_, s, b) = c.hsb
        var mod = ""
        switch n {
        case "black", "white", "beige", "brown", "olive": break
        case "gray": mod = b > 0.68 ? "Light " : (b < 0.36 ? "Dark " : "")
        default:
            if b < 0.42 { mod = "Dark " } else if s < 0.4 && b > 0.8 { mod = "Light " }
        }
        return mod + n.prefix(1).uppercased() + n.dropFirst()
    }

    /// Dominant colours of the non-transparent pixels (largest first).
    static func dominant(_ cg: CGImage, max n: Int = 5) -> [Swatch] {
        let w = 64, h = 64
        let px = Assist.rgba(cg, w, h)
        var buckets: [String: (r: Double, g: Double, b: Double, n: Double)] = [:]
        var total = 0.0
        for i in 0..<(w * h) {
            let a = Double(px[i * 4 + 3]) / 255
            if a < 0.3 { continue }
            let c = RGBA(r: Double(px[i * 4]) / 255, g: Double(px[i * 4 + 1]) / 255, b: Double(px[i * 4 + 2]) / 255)
            let key = name(c)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.r += c.r * a; e.g += c.g * a; e.b += c.b * a; e.n += a
            buckets[key] = e
            total += a
        }
        guard total > 0 else { return [] }
        return buckets.sorted { $0.value.n > $1.value.n }.prefix(n).compactMap { k, v in
            let c = RGBA(r: v.r / v.n, g: v.g / v.n, b: v.b / v.n)
            let f = v.n / total
            return f < 0.03 ? nil : Swatch(color: c, name: k, base: base(c), fraction: f)
        }
    }

    /// Mean colour and a flatness measure (0 = one flat colour) of the non-transparent pixels, plus coverage (alpha).
    static func stats(_ cg: CGImage) -> (mean: RGBA, spread: Double, coverage: Double, detail: Double) {
        let w = 48, h = 48
        let px = Assist.rgba(cg, w, h)
        var sr = 0.0, sg = 0.0, sb = 0.0, n = 0.0
        for i in 0..<(w * h) {
            let a = Double(px[i * 4 + 3]) / 255
            sr += Double(px[i * 4]) * a; sg += Double(px[i * 4 + 1]) * a; sb += Double(px[i * 4 + 2]) * a; n += a
        }
        guard n > 0 else { return (.white, 0, 0, 0) }
        let mr = sr / n, mg = sg / n, mb = sb / n
        var v = 0.0, detail = 0.0, dn = 0.0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let a = Double(px[i + 3]) / 255
                let dr = Double(px[i]) - mr, dg = Double(px[i + 1]) - mg, db = Double(px[i + 2]) - mb
                v += (dr * dr + dg * dg + db * db) * a
                if x + 1 < w, y + 1 < h, a > 0.9, px[i + 7] > 230, px[i + w * 4 + 3] > 230 {
                    let l0 = Double(px[i]) * 0.3 + Double(px[i + 1]) * 0.59 + Double(px[i + 2]) * 0.11
                    let l1 = Double(px[i + 4]) * 0.3 + Double(px[i + 5]) * 0.59 + Double(px[i + 6]) * 0.11
                    let l2 = Double(px[i + w * 4]) * 0.3 + Double(px[i + w * 4 + 1]) * 0.59 + Double(px[i + w * 4 + 2]) * 0.11
                    detail += abs(l1 - l0) + abs(l2 - l0); dn += 2
                }
            }
        }
        return (RGBA(r: mr / 255, g: mg / 255, b: mb / 255), sqrt(v / n / 3), n / Double(w * h), dn > 0 ? detail / dn : 0)
    }
}

// MARK: - Apple Vision wrappers (call off the main thread)

enum AssistVision {
    struct OCRLine: Identifiable {
        let id = UUID()
        var text: String
        /// Corners in image pixels, y-down.
        var quad: Quad
        var confidence: Float
        var box: CGRect { quad.bounds }
        /// Baseline angle in radians (y-down: positive = clockwise).
        var angle: Double { Double(atan2(quad.tr.y - quad.tl.y, quad.tr.x - quad.tl.x)) }
        var height: CGFloat { (quad.bl - quad.tl).length }
        var width: CGFloat { (quad.tr - quad.tl).length }
    }

    struct Face {
        var box: CGRect             // image pixels, y-down
        var roll: Double?
        /// Eye openness (height / width of the eye contour); < ~0.16 reads as closed.
        var leftEye: Double?
        var rightEye: Double?
        var captureQuality: Float?
        var eyesClosed: Bool {
            guard let l = leftEye, let r = rightEye else { return false }
            return max(l, r) < 0.17
        }
    }

    struct Saliency {
        var map: [Float]            // row 0 = top
        var w: Int
        var h: Int
        var boxes: [CGRect]         // normalized, y-down
    }

    /// Runs Vision requests. Vision occasionally refuses work while the machine is saturated; a short retry
    /// gets past brief hiccups (callers treat `false` as "nothing found").
    private static func perform(_ cg: CGImage, _ reqs: [VNRequest]) -> Bool {
        for attempt in 0..<3 {
            let h = VNImageRequestHandler(cgImage: cg, options: [:])
            do { try h.perform(reqs); return true } catch { if attempt < 2 { Thread.sleep(forTimeInterval: 0.3) } }
        }
        return false
    }

    /// True when Vision answers at all right now (a request on a blank image completes without an error).
    static func isResponsive() -> Bool {
        let b = PixelBuffer(width: 320, height: 96)
        b.context.setFillColor(gray: 1, alpha: 1)
        b.context.fill(CGRect(x: 0, y: 0, width: 320, height: 96))
        b.markDirty()
        // the neural requests are the ones that stall under load
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        let cls = VNClassifyImageRequest()
        let h = VNImageRequestHandler(cgImage: b.makeCGImage(), options: [:])
        do { try h.perform([req, cls]); return true } catch { return false }
    }

    static func humanize(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
    }

    /// Too-generic classifier labels that make poor names.
    static let genericLabels: Set<String> = ["outdoor", "indoor", "structure", "material", "textile", "art", "design", "illustrations", "graphics",
                                             "screenshot", "document", "people", "adult", "land", "liquid", "plant", "machine", "conveyance",
                                             "consumer electronics", "food", "animal", "mammal", "tool", "clothing", "decoration", "rectangle", "circle",
                                             "blue sky", "daytime", "night sky", "light", "pattern", "abstract", "colorfulness", "diagram", "text", "font", "mammal", "underwater"]

    /// Scene / object labels, best first.
    static func classify(_ cg: CGImage, max n: Int = 8, minConfidence: Float = 0.12) -> [(label: String, confidence: Float)] {
        let req = VNClassifyImageRequest()
        guard perform(cg, [req]) else { return [] }
        let obs = (req.results ?? []).filter { $0.confidence >= minConfidence }.sorted { $0.confidence > $1.confidence }
        return obs.prefix(n).map { (humanize($0.identifier), $0.confidence) }
    }

    /// Category labels: better than nothing, worse than a specific label ("bird" vs "parrot").
    static let categoryLabels: Set<String> = ["bird", "raptor", "ungulates", "flower", "tree", "sport", "recreation", "sports equipment", "ballgames", "ball",
                                              "arthropods", "insect", "fish", "reptile", "fruit", "vegetable", "vehicle", "automobile", "building", "furniture",
                                              "sky", "water", "water body", "rocks", "canine", "feline", "musical instrument", "frozen"]

    /// The most specific confident labels. Vision reports a whole taxonomy path with one confidence
    /// ("animal, bird, parrot"), so generic parents are skipped when a more specific label ties with them.
    static func bestLabels(_ labels: [(label: String, confidence: Float)], max n: Int = 1) -> [String] {
        guard let top = labels.first else { return [] }
        let tier = labels.filter { $0.confidence >= top.confidence * 0.82 }
        var picked = tier.filter { !genericLabels.contains($0.label) && !categoryLabels.contains($0.label) }.map(\.label)
        if picked.isEmpty { picked = tier.filter { !genericLabels.contains($0.label) }.map(\.label) }
        if picked.isEmpty { picked = [top.label] }
        // "blue sky" next to "sky" etc.: drop labels contained in another pick
        var out: [String] = []
        for p in picked where !out.contains(where: { $0.contains(p) || p.contains($0) }) { out.append(p) }
        return Array(out.prefix(n))
    }

    static func bestLabel(_ labels: [(label: String, confidence: Float)]) -> String? { bestLabels(labels).first }

    static func ocr(_ cg: CGImage, fast: Bool = false, languageCorrection: Bool = true) -> [OCRLine] {
        var req = VNRecognizeTextRequest()
        req.recognitionLevel = fast ? .fast : .accurate
        req.usesLanguageCorrection = languageCorrection
        req.minimumTextHeight = 0.012
        if !perform(cg, [req]) {
            // the accurate (neural) recogniser can be unavailable while the fast one still works
            guard !fast else { return [] }
            req = VNRecognizeTextRequest()
            req.recognitionLevel = .fast
            req.usesLanguageCorrection = languageCorrection
            guard perform(cg, [req]) else { return [] }
        }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        func p(_ v: CGPoint) -> CGPoint { CGPoint(x: v.x * W, y: (1 - v.y) * H) }
        var out: [OCRLine] = []
        for o in req.results ?? [] {
            guard let c = o.topCandidates(1).first else { continue }
            let s = c.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            // the candidate's box follows the baseline (the observation's own corners are often axis-aligned)
            let box: VNRectangleObservation = (try? c.boundingBox(for: c.string.startIndex..<c.string.endIndex)) ?? o
            out.append(OCRLine(text: s, quad: Quad(tl: p(box.topLeft), tr: p(box.topRight), br: p(box.bottomRight), bl: p(box.bottomLeft)), confidence: c.confidence))
        }
        // reading order: top to bottom, then left to right
        return out.sorted { a, b in abs(a.box.midY - b.box.midY) > min(a.box.height, b.box.height) * 0.6 ? a.box.midY < b.box.midY : a.box.minX < b.box.minX }
    }

    static func faces(_ cg: CGImage) -> [Face] {
        let lm = VNDetectFaceLandmarksRequest()
        let q = VNDetectFaceCaptureQualityRequest()
        guard perform(cg, [lm, q]) else { return [] }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let quality = q.results ?? []
        func openness(_ r: VNFaceLandmarkRegion2D?) -> Double? {
            guard let r, r.pointCount >= 4 else { return nil }
            let pts = r.pointsInImage(imageSize: CGSize(width: W, height: H))
            let b = CGRect.bounding(pts)
            guard b.width > 1 else { return nil }
            // use the principal axis so rolled faces still measure correctly
            let c = b.center
            var sxx = 0.0, syy = 0.0, sxy = 0.0
            for p in pts { let dx = Double(p.x - c.x), dy = Double(p.y - c.y); sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
            let tr = sxx + syy, det = sxx * syy - sxy * sxy
            let disc = (tr * tr / 4 - det).squareRoot()
            let l1 = tr / 2 + disc, l2 = Swift.max(0, tr / 2 - disc)
            return l1 > 0 ? (l2 / l1).squareRoot() : nil
        }
        return (lm.results ?? []).map { f in
            let b = f.boundingBox
            let box = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
            let cq = quality.first { abs($0.boundingBox.midX - b.midX) < 0.02 && abs($0.boundingBox.midY - b.midY) < 0.02 }?.faceCaptureQuality
            return Face(box: box, roll: f.roll?.doubleValue, leftEye: openness(f.landmarks?.leftEye), rightEye: openness(f.landmarks?.rightEye), captureQuality: cq)
        }
    }

    /// Attention saliency heat map plus salient-object boxes.
    static func saliency(_ cg: CGImage) -> Saliency? {
        let att = VNGenerateAttentionBasedSaliencyImageRequest()
        let obj = VNGenerateObjectnessBasedSaliencyImageRequest()
        guard perform(cg, [att, obj]), let o = att.results?.first else { return nil }
        let pb = o.pixelBuffer
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rb = CVPixelBufferGetBytesPerRow(pb)
        var map = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + y * rb).assumingMemoryBound(to: Float32.self)
            for x in 0..<w { map[y * w + x] = row[x] }
        }
        var boxes: [CGRect] = []
        for r in (obj.results?.first?.salientObjects ?? []) + (o.salientObjects ?? []) {
            let b = r.boundingBox
            boxes.append(CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
        return Saliency(map: map, w: w, h: h, boxes: boxes)
    }

    /// Horizon tilt in radians (Vision convention: counter-clockwise, y-up) or nil.
    static func horizon(_ cg: CGImage) -> Double? {
        let req = VNDetectHorizonRequest()
        guard perform(cg, [req]), let o = req.results?.first else { return nil }
        return Double(o.angle)
    }

    static func featurePrint(_ cg: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        guard perform(cg, [req]) else { return nil }
        return req.results?.first
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float? {
        var d: Float = 0
        do { try a.computeDistance(&d, to: b); return d } catch { return nil }
    }

    /// Vision aesthetics score (−1…1) and whether the image is a "utility" picture (screenshot, document).
    static func aesthetics(_ cg: CGImage) async -> (score: Float, utility: Bool)? {
        let req = CalculateImageAestheticsScoresRequest()
        guard let o = try? await req.perform(on: cg) else { return nil }
        return (o.overallScore, o.isUtility)
    }

    static func animals(_ cg: CGImage) -> [(label: String, box: CGRect)] {
        let req = VNRecognizeAnimalsRequest()
        guard perform(cg, [req]) else { return [] }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        return (req.results ?? []).compactMap { o in
            guard let l = o.labels.first else { return nil }
            let b = o.boundingBox
            return (l.identifier.lowercased(), CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H))
        }
    }

    static func humans(_ cg: CGImage) -> [CGRect] {
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        guard perform(cg, [req]) else { return [] }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        return (req.results ?? []).map { o in
            let b = o.boundingBox
            return CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H)
        }
    }
}

// MARK: - Text embeddings (NaturalLanguage)

enum AssistEmbedding {
    static let sentence: NLEmbedding? = NLEmbedding.sentenceEmbedding(for: .english)
    static let word: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)
    static var engine: String { sentence != nil ? "sentence embedding" : (word != nil ? "word embedding" : "keywords only") }

    static func vector(_ s: String) -> [Double]? {
        let t = s.lowercased()
        if let e = sentence, let v = e.vector(for: t) { return v }
        guard let w = word else { return nil }
        var sum: [Double] = []
        var n = 0
        for tok in words(t) {
            guard let v = w.vector(for: tok) else { continue }
            if sum.isEmpty { sum = v } else { for i in v.indices { sum[i] += v[i] } }
            n += 1
        }
        return n > 0 ? sum.map { $0 / Double(n) } : nil
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? d / (na.squareRoot() * nb.squareRoot()) : 0
    }

    /// Word-level similarity (0…1) used for synonym matching ("automobile" ≈ "car").
    static func wordSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard let w = word, w.contains(a), w.contains(b) else { return 0 }
        // NLEmbedding cosine distances: ≈ 0.75–0.9 for related words (car / vehicle, bird / parrot), ≥ 1.15 for unrelated ones
        let d = w.distance(between: a, and: b, distanceType: .cosine)
        return Swift.max(0, Swift.min(1, (1.15 - d) / 0.4))
    }

    static let stopWords: Set<String> = ["the", "a", "an", "of", "in", "on", "at", "with", "and", "or", "that", "this", "is", "are", "to", "for", "by",
                                         "layer", "layers", "all", "any", "my", "me", "find", "show", "select", "which", "it", "its", "there", "one", "ones"]

    static func words(_ s: String) -> [String] {
        s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    /// Lemmatized content words ("cars" → "car", "running" → "run").
    static func lemmas(_ s: String) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = s.lowercased()
        var out: [String] = []
        let lower = s.lowercased()
        tagger.enumerateTags(in: lower.startIndex..<lower.endIndex, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let raw = String(lower[range])
            let lemma = tag?.rawValue.lowercased() ?? raw
            out.append(lemma.isEmpty ? raw : lemma)
            return true
        }
        return out
    }
}
