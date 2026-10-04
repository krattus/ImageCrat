import Foundation
import CoreImage
import Vision
import ImageCratCore

/// Public segmentation API shared by Object Selection, Select Subject/People/Sky, Mask All Objects and other
/// features (Sky Replacement, generative background, Remove tool …).
///
/// All masks are canvas-size gray `PixelBuffer`s (255 = selected) in doc coordinates. Inputs are canvas-size RGBA
/// buffers such as `AppActions.sampleSource(allLayers:)`. Every call degrades gracefully: SAM 2.1 → Apple Vision
/// when the SAM model isn't installed; SAM 3.1 → Florence-2 + SAM 2.1 for text prompts.
enum SegmentationService {
    enum TextEngine: String, CaseIterable, Identifiable {
        case automatic = "Automatic", fast = "Fast (Florence-2 + SAM 2.1)", highQuality = "High Quality (SAM 3.1)"
        var id: String { rawValue }
    }

    struct Options {
        var hardEdge = false
        /// Edge-aware (guided filter) refinement of the upsampled SAM mask.
        var refineEdges = true
        /// Hair/fine-edge matting with BiRefNet in a band around the edge.
        var hair = false
        var hairQuality: SegMatting.Quality = .fast
        /// Re-encode a crop around small boxes for more detail.
        var cropSmallObjects = true
    }

    struct TextMatch {
        var label: String
        var box: CGRect
        var score: Float
        var mask: PixelBuffer
    }

    // MARK: - Public async API

    /// Mask of everything matching a text prompt ("sky", "the red car", "person on the left"), or nil if nothing matched.
    static func mask(forPrompt prompt: String, in image: PixelBuffer, engine: TextEngine = .automatic, options: Options = Options()) async throws -> PixelBuffer? {
        let matches = try await textMatches(prompt, in: SegImage(buffer: image), engine: engine, options: options)
        return SegMask.union(matches.map(\.mask))
    }

    /// Main subject(s) of the image.
    static func subjectMask(in image: PixelBuffer, quality: SegMatting.Quality = .fast, hair: Bool = false) async throws -> PixelBuffer? {
        try await detached { try subjectSync(SegImage(buffer: image), quality: quality, hair: hair) }
    }

    /// Sky region.
    static func skyMask(in image: PixelBuffer) async throws -> PixelBuffer? {
        try await detached { try skySync(SegImage(buffer: image)) }
    }

    /// One mask per person (Vision person instances refined with SAM, optional hair matting).
    static func peopleMasks(in image: PixelBuffer, hair: Bool = true) async throws -> [PixelBuffer] {
        try await detached { try peopleSync(SegImage(buffer: image), hair: hair) }
    }

    /// Object inside a doc-space box (Object Selection rectangle mode).
    static func objectMask(in image: PixelBuffer, box: CGRect, options: Options = Options()) async throws -> PixelBuffer? {
        try await detached { try boxSync(SegImage(buffer: image), box: box, points: [], options: options) }
    }

    /// Automatic "everything" masks (Mask All Objects), largest first.
    static func allObjectMasks(in image: PixelBuffer, grid: Int = 32) async throws -> [PixelBuffer] {
        try await detached { try allObjectsSync(SegImage(buffer: image), grid: grid).map(\.1) }
    }

    static func detached<T>(_ f: @escaping () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try f() }.value
    }

    // MARK: - Synchronous core (call off the main thread)

    static func finish(_ m: SAMMask, img: SegImage, options: Options) throws -> PixelBuffer {
        let guide: CIImage? = options.refineEdges && !options.hardEdge ? img.image : nil
        var buf = segTime("mask.fullres") { m.buffer(guide: guide, hard: options.hardEdge) }
        if options.hair, !options.hardEdge, SegMatting.isAvailable {
            buf = try segTime("mask.hair") { try SegMatting.refine(mask: buf, image: img, quality: options.hairQuality) }
        }
        return buf
    }

    /// Whether a box is small enough to deserve its own crop encoding.
    static func cropRect(for box: CGRect, img: SegImage) -> CGRect? {
        let big = CGFloat(max(img.width, img.height))
        guard max(box.width, box.height) < big * 0.4, big > 700 else { return nil }
        let side = max(max(box.width, box.height) * 1.6, min(big, 384))
        var r = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        r = r.intersection(img.canvas)
        return r.width >= 32 && r.height >= 32 ? r : nil
    }

    /// SAM mask for a box (+ optional labelled points).
    static func boxSAM(_ img: SegImage, box: CGRect, points: [(CGPoint, SAMPrompt.Label)], options: Options) throws -> SAMMask {
        let sam = SAMSegmenter.shared
        var emb = try sam.embedding(img)
        if options.cropSmallObjects, let c = cropRect(for: box, img: img) { emb = try sam.embedding(img, crop: c) }
        return try sam.predict(SAMPrompt(points: points, box: box), emb: emb)
    }

    static func boxSync(_ img: SegImage, box: CGRect, points: [(CGPoint, SAMPrompt.Label)], options: Options) throws -> PixelBuffer? {
        guard SAMSegmenter.shared.isAvailable else { return visionObject(img, region: box) }
        let m = try boxSAM(img, box: box, points: points, options: options)
        guard m.coverage > 0 else { return nil }
        return try finish(m, img: img, options: options)
    }

    static func pointSync(_ img: SegImage, point: CGPoint, options: Options) throws -> PixelBuffer? {
        guard SAMSegmenter.shared.isAvailable else { return visionInstance(img, at: point) }
        let emb = try SAMSegmenter.shared.embedding(img)
        let m = try SAMSegmenter.shared.predict(.point(point), emb: emb)
        guard m.coverage > 0 else { return nil }
        return try finish(m, img: img, options: options)
    }

    /// Lasso: bbox + deepest interior point (positive) + exterior points inside the bbox (negative); clipped to the lasso.
    static func lassoSync(_ img: SegImage, lasso: [CGPoint], options: Options) throws -> PixelBuffer? {
        let path = CGMutablePath(); path.addLines(between: lasso); path.closeSubpath()
        let box = path.boundingBoxOfPath.intersection(img.canvas)
        guard box.width > 2, box.height > 2 else { return nil }
        let limit = SelectionOps.expand(SelectionOps.mask(fromPath: path, width: img.width, height: img.height), by: max(4, Double(max(box.width, box.height)) * 0.02))
        guard SAMSegmenter.shared.isAvailable else {
            guard let v = visionObject(img, region: box) else { return nil }
            return SelectionOps.combine(v, limit, mode: .intersect)
        }
        let (inside, outside) = lassoPoints(path, box: box)
        let sam = SAMSegmenter.shared
        var emb = try sam.embedding(img)
        if options.cropSmallObjects, let c = cropRect(for: box, img: img) { emb = try sam.embedding(img, crop: c) }
        let negs = outside.prefix(4).map { ($0, SAMPrompt.Label.negative) }
        var best = try sam.predict(SAMPrompt(points: Array(negs), box: box), emb: emb)
        if let p = inside {
            let withPos = try sam.predict(SAMPrompt(points: [(p, .positive)] + negs, box: box), emb: emb)
            if withPos.score > best.score + 0.02 { best = withPos }
        }
        guard best.coverage > 0 else { return nil }
        let full = try finish(best, img: img, options: options)
        let r = SelectionOps.combine(full, limit, mode: .intersect)
        return r.opaqueBounds() == nil ? nil : r
    }

    /// Deepest point inside the lasso and a few points in the bbox outside it (far from the stroke).
    static func lassoPoints(_ path: CGPath, box: CGRect) -> (CGPoint?, [CGPoint]) {
        let n = 64
        var inside = [Bool](repeating: false, count: n * n)
        func center(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: box.minX + (CGFloat(x) + 0.5) / CGFloat(n) * box.width, y: box.minY + (CGFloat(y) + 0.5) / CGFloat(n) * box.height)
        }
        for y in 0..<n { for x in 0..<n { inside[y * n + x] = path.contains(center(x, y)) } }
        // chamfer distance (in cells) to the other region, for both regions
        func distance(to target: Bool) -> [Float] {
            let big: Float = 1e6
            var d = [Float](repeating: big, count: n * n)
            for i in 0..<(n * n) where inside[i] == target { d[i] = 0 }
            for y in 0..<n { for x in 0..<n {
                let i = y * n + x
                if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }
                if y > 0 { d[i] = min(d[i], d[i - n] + 1) }
                if x > 0 && y > 0 { d[i] = min(d[i], d[i - n - 1] + 1.414) }
                if x < n - 1 && y > 0 { d[i] = min(d[i], d[i - n + 1] + 1.414) }
            } }
            for y in stride(from: n - 1, through: 0, by: -1) { for x in stride(from: n - 1, through: 0, by: -1) {
                let i = y * n + x
                if x < n - 1 { d[i] = min(d[i], d[i + 1] + 1) }
                if y < n - 1 { d[i] = min(d[i], d[i + n] + 1) }
                if x < n - 1 && y < n - 1 { d[i] = min(d[i], d[i + n + 1] + 1.414) }
                if x > 0 && y < n - 1 { d[i] = min(d[i], d[i + n - 1] + 1.414) }
            } }
            return d
        }
        let dIn = distance(to: false)     // for inside cells: distance to the outside
        let dOut = distance(to: true)     // for outside cells: distance to the inside
        var deepest: CGPoint?
        var best: Float = 0
        for i in 0..<(n * n) where inside[i] && dIn[i] > best { best = dIn[i]; deepest = center(i % n, i / n) }
        var outs: [CGPoint] = []
        let order = (0..<(n * n)).filter { !inside[$0] && dOut[$0] > Float(n) * 0.06 }.sorted { dOut[$0] > dOut[$1] }
        let minSep = max(box.width, box.height) * 0.2
        for i in order {
            let p = center(i % n, i / n)
            if outs.allSatisfy({ $0.distance(to: p) > minSep }) { outs.append(p) }
            if outs.count >= 4 { break }
        }
        return (deepest, outs)
    }

    // MARK: Subject

    /// Candidate subject boxes from Apple Vision (foreground instances, then saliency).
    static func subjectBoxes(_ img: SegImage) -> [(CGRect, PixelBuffer?)] {
        let scale = min(1, 1536 / CGFloat(max(img.width, img.height)))
        let w = max(8, Int(CGFloat(img.width) * scale)), h = max(8, Int(CGFloat(img.height) * scale))
        guard let pb = img.pixelBuffer(rect: img.canvas, w: w, h: h) else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pb)
        let req = VNGenerateForegroundInstanceMaskRequest()
        var out: [(CGRect, PixelBuffer?)] = []
        if (try? handler.perform([req])) != nil, let obs = req.results?.first {
            for inst in obs.allInstances {
                guard let mpb = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: inst), from: handler) else { continue }
                let m = visionMaskBuffer(mpb, img: img)
                if let b = m.opaqueBounds(threshold: 127)?.cgRect { out.append((b, m)) }
            }
        }
        if out.isEmpty {
            let sreq = VNGenerateObjectnessBasedSaliencyImageRequest()
            if (try? handler.perform([sreq])) != nil, let o = sreq.results?.first {
                for s in o.salientObjects ?? [] where s.confidence > 0.3 {
                    let bb = s.boundingBox // normalized, y-up
                    out.append((CGRect(x: bb.minX * CGFloat(img.width), y: (1 - bb.maxY) * CGFloat(img.height), width: bb.width * CGFloat(img.width), height: bb.height * CGFloat(img.height)), nil))
                }
            }
        }
        return out
    }

    /// Vision mask pixel buffer (any size) → canvas-size gray PixelBuffer.
    static func visionMaskBuffer(_ pb: CVPixelBuffer, img: SegImage) -> PixelBuffer {
        let ci = CIImage(cvPixelBuffer: pb)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: CGFloat(img.width) / ci.extent.width, y: CGFloat(img.height) / ci.extent.height))
        return SegMask.buffer(scaled.cropped(to: img.canvas), width: img.width, height: img.height)
    }

    static func subjectSync(_ img: SegImage, quality: SegMatting.Quality, hair: Bool) throws -> PixelBuffer? {
        // High Quality: dichotomous segmentation (BiRefNet) of the whole image — excellent on hair, fur and fuzzy objects.
        if quality == .high, SegMatting.engine(.high) != nil {
            if let m = try segTime("subject.birefnet") { try SegMatting.subjectMatte(img, quality: .high) } { return m }
        }
        let boxes = segTime("subject.vision") { subjectBoxes(img) }
        guard !boxes.isEmpty else { return nil }
        guard SAMSegmenter.shared.isAvailable else {
            // Vision-only fallback: union of instance masks with an edge-aware pass
            guard let u = SegMask.union(boxes.compactMap(\.1)) else { return nil }
            return SegMask.buffer(SegMask.refineEdges(u.ciImage, guide: img.image, canvas: img.canvas, radius: 3), width: img.width, height: img.height)
        }
        var opts = Options()
        opts.hair = false
        var masks: [PixelBuffer] = []
        for (b, vm) in boxes {
            var pts: [(CGPoint, SAMPrompt.Label)] = []
            if let vm, let c = centroid(vm) { pts.append((c, .positive)) }
            let m = try boxSAM(img, box: b, points: pts, options: opts)
            var buf = try finish(m, img: img, options: opts)
            // SAM picked a part only → trust the Vision instance
            if let vm, SegMask.area(buf) < SegMask.area(vm) * 0.5 { buf = vm }
            masks.append(buf)
        }
        guard var u = SegMask.union(masks) else { return nil }
        if (hair || quality == .high), SegMatting.isAvailable {
            u = try segTime("subject.matting") { try SegMatting.refine(mask: u, image: img, quality: quality) }
        }
        return u
    }

    static func centroid(_ m: PixelBuffer) -> CGPoint? {
        // deepest-ish point: centroid of the eroded mask if it lies inside, else any inside point near the centroid
        let w = 64, h = 64
        let f = SegMask.floats(m, w: w, h: h)
        var sx: Float = 0, sy: Float = 0, s: Float = 0
        for y in 0..<h { for x in 0..<w { let v = f[y * w + x]; if v > 0.5 { sx += Float(x) * v; sy += Float(y) * v; s += v } } }
        guard s > 0 else { return nil }
        var cx = Int(sx / s), cy = Int(sy / s)
        if f[cy * w + cx] < 0.5 {
            var best = Int.max
            for y in 0..<h { for x in 0..<w where f[y * w + x] > 0.5 {
                let d = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if d < best { best = d; cx = x; cy = y }
            } }
        }
        return CGPoint(x: (CGFloat(cx) + 0.5) / CGFloat(w) * CGFloat(m.width), y: (CGFloat(cy) + 0.5) / CGFloat(h) * CGFloat(m.height))
    }

    // MARK: People

    static func personInstances(_ img: SegImage) -> [PixelBuffer] {
        let scale = min(1, 2048 / CGFloat(max(img.width, img.height)))
        let w = max(8, Int(CGFloat(img.width) * scale)), h = max(8, Int(CGFloat(img.height) * scale))
        guard let pb = img.pixelBuffer(rect: img.canvas, w: w, h: h) else { return [] }
        let handler = VNImageRequestHandler(cvPixelBuffer: pb)
        let req = VNGeneratePersonInstanceMaskRequest()
        guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return [] }
        var out: [PixelBuffer] = []
        for inst in obs.allInstances.sorted() {
            if let m = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: inst), from: handler) {
                let buf = visionMaskBuffer(m, img: img)
                if buf.opaqueBounds(threshold: 127) != nil { out.append(buf) }
            }
        }
        // left-to-right order ("Person 1" is the leftmost)
        return out.sorted { ($0.opaqueBounds()?.x ?? 0) < ($1.opaqueBounds()?.x ?? 0) }
    }

    /// Human bounding boxes (doc coords) from Vision's human detector — used to reject non-human "person" instances.
    static func humanBoxes(_ img: SegImage) -> [CGRect] {
        let scale = min(1, 2048 / CGFloat(max(img.width, img.height)))
        let w = max(8, Int(CGFloat(img.width) * scale)), h = max(8, Int(CGFloat(img.height) * scale))
        guard let pb = img.pixelBuffer(rect: img.canvas, w: w, h: h) else { return [] }
        let req = VNDetectHumanRectanglesRequest()
        req.upperBodyOnly = false
        let face = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cvPixelBuffer: pb).perform([req, face])) != nil else { return [] }
        let obs: [VNDetectedObjectObservation] = (req.results ?? []) + (face.results ?? [])
        return obs.filter { $0.confidence > 0.3 }.map { o in
            let b = o.boundingBox
            return CGRect(x: b.minX * CGFloat(img.width), y: (1 - b.maxY) * CGFloat(img.height), width: b.width * CGFloat(img.width), height: b.height * CGFloat(img.height))
        }
    }

    /// Face bounding boxes (doc coords), slightly expanded to include hair.
    static func faceBoxes(_ img: SegImage) -> [CGRect] {
        guard let pb = img.pixelBuffer(rect: img.canvas, w: min(img.width, 2048), h: min(img.height, Int(2048 * CGFloat(img.height) / CGFloat(max(1, img.width))))) else { return [] }
        let face = VNDetectFaceRectanglesRequest()
        guard (try? VNImageRequestHandler(cvPixelBuffer: pb).perform([face])) != nil else { return [] }
        return (face.results ?? []).map { o in
            let b = o.boundingBox
            let r = CGRect(x: b.minX * CGFloat(img.width), y: (1 - b.maxY) * CGFloat(img.height), width: b.width * CGFloat(img.width), height: b.height * CGFloat(img.height))
            return r.insetBy(dx: -r.width * 0.12, dy: -r.height * 0.25).offsetBy(dx: 0, dy: -r.height * 0.1).intersection(img.canvas)
        }
    }

    static func peopleSync(_ img: SegImage, hair: Bool) throws -> [PixelBuffer] {
        var people = segTime("people.vision") { personInstances(img) }
        // keep only instances confirmed by the human / face detector
        let humans = humanBoxes(img)
        people = people.filter { m in
            guard let b = m.opaqueBounds(threshold: 127)?.cgRect else { return false }
            return humans.contains { h in let i = h.intersection(b); return !i.isNull && i.width * i.height > 0.3 * min(h.width * h.height, b.width * b.height) }
        }
        var out: [PixelBuffer] = []
        for vm in people {
            guard let b = vm.opaqueBounds(threshold: 127)?.cgRect else { continue }
            var result = vm
            if SAMSegmenter.shared.isAvailable {
                var pts: [(CGPoint, SAMPrompt.Label)] = []
                if let c = centroid(vm) { pts.append((c, .positive)) }
                let m = try boxSAM(img, box: b.insetBy(dx: -4, dy: -4), points: pts, options: Options())
                let s = try finish(m, img: img, options: Options())
                // accept SAM when it agrees with Vision's person silhouette
                let va = SegMask.area(vm), sa = SegMask.area(s)
                if sa > va * 0.6 && sa < va * 1.6 { result = s }
                else { result = SegMask.buffer(SegMask.refineEdges(vm.ciImage, guide: img.image, canvas: img.canvas, radius: 4), width: img.width, height: img.height) }
            }
            if hair, SegMatting.isAvailable { result = try SegMatting.refine(mask: result, image: img, quality: .fast) }
            out.append(result)
        }
        return out
    }

    // MARK: Text prompts

    static func resolvedEngine(_ e: TextEngine) -> TextEngine {
        switch e {
        case .automatic: return SAM3Engine.isAvailable ? .highQuality : .fast
        case .highQuality: return SAM3Engine.isAvailable ? .highQuality : .fast
        case .fast: return .fast
        }
    }

    static func textMatches(_ prompt: String, in img: SegImage, engine: TextEngine = .automatic, options: Options = Options()) async throws -> [TextMatch] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if resolvedEngine(engine) == .highQuality {
            let dets = try await SAM3Engine.detect(img, text: text)
            let guide: CIImage? = options.hardEdge ? nil : img.image
            var out: [TextMatch] = []
            for d in dets {
                var m = SegMask.buffer(d.ciMask(canvasW: img.width, canvasH: img.height, guide: guide, hard: options.hardEdge), width: img.width, height: img.height)
                if options.hair, SegMatting.isAvailable { m = try SegMatting.refine(mask: m, image: img, quality: options.hairQuality) }
                out.append(TextMatch(label: text, box: d.box, score: d.score, mask: m))
            }
            return out
        }
        return try await detached { try florenceMatches(text, img: img, options: options) }
    }

    static func florenceMatches(_ text: String, img: SegImage, options: Options) throws -> [TextMatch] {
        guard Florence2Grounder.shared.isAvailable else { throw ModelError.notInstalled("Florence-2 Base (Core ML)") }
        var regions = try Florence2Grounder.shared.ground(img, text: text, task: .phraseGrounding)
        if regions.isEmpty { regions = try Florence2Grounder.shared.ground(img, text: text, task: .openVocabulary) }
        // drop degenerate and duplicate boxes
        var boxes: [Florence2Grounder.Region] = []
        for r in regions where r.box.width > 2 && r.box.height > 2 {
            if !boxes.contains(where: { iou($0.box, r.box) > 0.85 }) { boxes.append(r) }
        }
        var out: [TextMatch] = []
        for r in boxes.prefix(12) {
            if SAMSegmenter.shared.isAvailable {
                let m = try boxSAM(img, box: r.box, points: [], options: options)
                let buf = try finish(m, img: img, options: options)
                out.append(TextMatch(label: r.label.isEmpty ? text : r.label, box: r.box, score: m.score, mask: buf))
            } else {
                out.append(TextMatch(label: r.label, box: r.box, score: 0.5, mask: SelectionOps.rectMask(r.box, width: img.width, height: img.height)))
            }
        }
        return out
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        if i.isNull { return 0 }
        let ia = i.width * i.height
        return ia / (a.width * a.height + b.width * b.height - ia)
    }

    // MARK: Sky

    /// Low-res (n×n) sky prior: sky-coloured, low-texture pixels flood-filled from the top edge, optionally limited to boxes.
    static func skyPrior(_ img: SegImage, n: Int = 256, limit: [CGRect]? = nil) -> [Float]? {
        let px = img.rgba(rect: img.canvas, w: n, h: n)
        func c(_ x: Int, _ y: Int) -> (Float, Float, Float) {
            let i = (y * n + x) * 4
            return (Float(px[i]) / 255, Float(px[i + 1]) / 255, Float(px[i + 2]) / 255)
        }
        var grad = [Float](repeating: 0, count: n * n)
        for y in 1..<(n - 1) { for x in 1..<(n - 1) {
            let a = c(x - 1, y), b = c(x + 1, y), u = c(x, y - 1), d = c(x, y + 1)
            grad[y * n + x] = abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2) + abs(u.0 - d.0) + abs(u.1 - d.1) + abs(u.2 - d.2)
        } }
        var allowed = [Bool](repeating: true, count: n * n)
        if let boxes = limit, !boxes.isEmpty {
            for y in 0..<n { for x in 0..<n {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(n) * CGFloat(img.width), y: (CGFloat(y) + 0.5) / CGFloat(n) * CGFloat(img.height))
                allowed[y * n + x] = boxes.contains { $0.insetBy(dx: -CGFloat(img.width) * 0.02, dy: -CGFloat(img.height) * 0.02).contains(p) }
            } }
        }
        // sky colour model from the top rows
        var sr: Float = 0, sg: Float = 0, sb: Float = 0, cnt: Float = 0
        for y in 0..<max(1, n / 40) { for x in 0..<n where allowed[y * n + x] { let v = c(x, y); sr += v.0; sg += v.1; sb += v.2; cnt += 1 } }
        guard cnt > 0 else { return nil }
        sr /= cnt; sg /= cnt; sb /= cnt
        guard sb >= sr * 0.85 || (sr + sg + sb) / 3 > 0.55 || limit != nil else { return nil }
        var mask = [Float](repeating: -1, count: n * n)
        var queue: [Int] = (0..<n).filter { allowed[$0] }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            if mask[i] > 0 { continue }
            let x = i % n, y = i / n
            let v = c(x, y)
            let ref = y > 0 ? c(x, y - 1) : (sr, sg, sb)
            let dLocal = abs(v.0 - ref.0) + abs(v.1 - ref.1) + abs(v.2 - ref.2)
            let dGlobal = abs(v.0 - sr) + abs(v.1 - sg) + abs(v.2 - sb)
            if grad[i] > 0.3 || dLocal > 0.1 || dGlobal > 0.8 || !allowed[i] { continue }
            mask[i] = 1
            if x > 0 { queue.append(i - 1) }
            if x < n - 1 { queue.append(i + 1) }
            if y < n - 1 { queue.append(i + n) }
            if y > 0 { queue.append(i - n) }
        }
        return SegMask.count(mask, above: 0) > n * n / 200 ? mask : nil
    }

    /// Up to `k` well-separated deep points of a low-res n×n region (value > 0 when `positive`).
    static func deepPoints(_ m: [Float], n: Int, positive: Bool, k: Int, img: SegImage) -> [CGPoint] {
        // distance transform (city-block, two passes) to the region boundary
        var d = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) { d[i] = ((m[i] > 0) == positive) ? 1e6 : 0 }
        for y in 0..<n { for x in 0..<n { let i = y * n + x
            if x > 0 { d[i] = min(d[i], d[i - 1] + 1) }; if y > 0 { d[i] = min(d[i], d[i - n] + 1) } } }
        for y in stride(from: n - 1, through: 0, by: -1) { for x in stride(from: n - 1, through: 0, by: -1) { let i = y * n + x
            if x < n - 1 { d[i] = min(d[i], d[i + 1] + 1) }; if y < n - 1 { d[i] = min(d[i], d[i + n] + 1) } } }
        // borders of the image count as inside (sky touches the top)
        var pts: [CGPoint] = []
        let order = (0..<(n * n)).filter { d[$0] >= 3 }.sorted { d[$0] > d[$1] }
        for i in order {
            let p = CGPoint(x: (CGFloat(i % n) + 0.5) / CGFloat(n) * CGFloat(img.width), y: (CGFloat(i / n) + 0.5) / CGFloat(n) * CGFloat(img.height))
            if pts.allSatisfy({ $0.distance(to: p) > CGFloat(max(img.width, img.height)) * 0.18 }) { pts.append(p) }
            if pts.count >= k { break }
        }
        return pts
    }

    static func skySync(_ img: SegImage) throws -> PixelBuffer? {
        var boxes: [CGRect]? = nil
        if Florence2Grounder.shared.isAvailable {
            let r = try Florence2Grounder.shared.ground(img, text: "sky", task: .phraseGrounding).map(\.box).filter { $0.width > 4 && $0.height > 4 }
            if r.isEmpty { return nil }
            boxes = r
        }
        let n = 256
        let priorOpt = segTime("sky.prior") { skyPrior(img, n: n, limit: boxes) }
        guard let prior = priorOpt else { return nil }
        let priorBin = SegMask.binary(prior)
        let priorCI = SegMask.fullMask(prior, w: n, h: n, rect: img.canvas, canvasW: img.width, canvasH: img.height, guide: nil, hard: false)
        let fallback = { SegMask.buffer(SegMask.refineEdges(priorCI.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: img.canvas), guide: img.image, canvas: img.canvas, radius: 6), width: img.width, height: img.height) }
        guard SAMSegmenter.shared.isAvailable else { return fallback() }
        let pos = deepPoints(prior, n: n, positive: true, k: 3, img: img)
        let neg = deepPoints(prior, n: n, positive: false, k: 3, img: img)
        guard !pos.isEmpty else { return fallback() }
        let emb = try SAMSegmenter.shared.embedding(img)
        let prompt = SAMPrompt(points: pos.map { ($0, SAMPrompt.Label.positive) } + neg.map { ($0, SAMPrompt.Label.negative) })
        let cands = try SAMSegmenter.shared.candidates(prompt, emb: emb)
        // pick the candidate that agrees best with the colour prior
        var best: (SAMMask, Float)? = nil
        for c in cands {
            let v = SegMask.iou(SegMask.binary(c.logits), priorBin)
            if best == nil || v > best!.1 { best = (c, v) }
        }
        guard var m = best?.0, (best?.1 ?? 0) > 0.5 else { return fallback() }
        m.logits = SAMSegmenter.cleaned(m.logits, w: m.w, h: m.h, maxArea: 200)
        return try finish(m, img: img, options: Options())
    }

    // MARK: Mask All Objects

    static func allObjectsSync(_ img: SegImage, grid: Int = 32, progress: ((Double) -> Void)? = nil) throws -> [(SAMObject, PixelBuffer)] {
        guard SAMSegmenter.shared.isAvailable else { throw SAMError.notInstalled }
        let emb = try SAMSegmenter.shared.embedding(img)
        let objs = try segTime("amg.decode") { try SAMSegmenter.shared.automaticMasks(emb: emb, grid: grid, progress: { progress?($0 * 0.8) }) }
        var out: [(SAMObject, PixelBuffer)] = []
        for (i, o) in objs.enumerated() {
            out.append((o, try finish(o.mask, img: img, options: Options())))
            progress?(0.8 + 0.2 * Double(i + 1) / Double(max(1, objs.count)))
        }
        return out
    }

    // MARK: Vision fallbacks (no SAM model)

    static func visionObject(_ img: SegImage, region: CGRect) -> PixelBuffer? {
        let W = img.width, H = img.height
        let buf = RenderEngine.renderBuffer(img.image, docRect: IRect(x: 0, y: 0, width: W, height: H), space: img.space)
        return ObjectFinder.objectMask(src: buf, region: region)
    }

    static func visionInstance(_ img: SegImage, at p: CGPoint) -> PixelBuffer? {
        let boxes = subjectBoxes(img)
        for (_, m) in boxes {
            if let m, m.alpha(Int(p.x), Int(p.y)) > 127 { return m }
        }
        return nil
    }
}
