import AppKit
import CoreImage
import Observation
import ImageCratCore

/// User settings of the Object Selection tool and the AI selection commands (persisted).
@Observable
final class ObjectSelectionSettings {
    static let shared = ObjectSelectionSettings()
    private static let d = UserDefaults.standard

    var objectFinder = d.object(forKey: "objsel.finder") as? Bool ?? true { didSet { Self.d.set(objectFinder, forKey: "objsel.finder"); ObjectSelectionEngine.shared.settingsChanged() } }
    var showAllObjects = false { didSet { ObjectSelectionEngine.shared.settingsChanged() } }
    var sampleAllLayers = d.object(forKey: "objsel.sampleAll") as? Bool ?? true { didSet { Self.d.set(sampleAllLayers, forKey: "objsel.sampleAll"); ObjectSelectionEngine.shared.settingsChanged() } }
    var hardEdge = d.bool(forKey: "objsel.hardEdge") { didSet { Self.d.set(hardEdge, forKey: "objsel.hardEdge") } }
    /// Automatic hair-quality edges (BiRefNet matting in the edge band) for Object Selection / Select Subject.
    var hairEdges = d.bool(forKey: "objsel.hair") { didSet { Self.d.set(hairEdges, forKey: "objsel.hair") } }
    var hairQuality = SegMatting.Quality(rawValue: d.string(forKey: "objsel.hairQ") ?? "") ?? .fast { didSet { Self.d.set(hairQuality.rawValue, forKey: "objsel.hairQ") } }
    var subjectQuality = SegMatting.Quality(rawValue: d.string(forKey: "objsel.subjectQ") ?? "") ?? .fast { didSet { Self.d.set(subjectQuality.rawValue, forKey: "objsel.subjectQ") } }
    var textEngine = SegmentationService.TextEngine(rawValue: d.string(forKey: "objsel.textEngine") ?? "") ?? .automatic { didSet { Self.d.set(textEngine.rawValue, forKey: "objsel.textEngine") } }
    var findText = ""

    // Runtime state (not persisted)
    var busy: String? = nil
    var analyzing = false
    var objectCount: Int? = nil

    var options: SegmentationService.Options {
        var o = SegmentationService.Options()
        o.hardEdge = hardEdge
        o.hair = hairEdges
        o.hairQuality = hairQuality
        return o
    }
}

/// Object Finder hover result.
struct HoverMask {
    let image: CGImage        // tinted RGBA over `docRect`
    let outline: CGPath       // doc coords
    let docRect: CGRect
    let mask: SAMMask
    let point: CGPoint
}

/// Per-document analysis state for the Object Selection tool: the source image, its SAM embedding (computed in the
/// background when the tool is activated / the document changes), Object Finder hover and "Show All Objects".
final class ObjectSelectionEngine: @unchecked Sendable {
    static let shared = ObjectSelectionEngine()
    let queue = DispatchQueue(label: "lumen.objsel", qos: .userInitiated)
    private let hoverQueue = DispatchQueue(label: "lumen.objsel.hover", qos: .userInteractive)
    var settings: ObjectSelectionSettings { .shared }

    // main-thread state
    private(set) var image: SegImage?
    private var sourceKey = ""
    private(set) var embeddingReady = false
    private(set) var hover: HoverMask?
    private(set) var allObjects: [(outline: CGPath, box: CGRect)] = []
    private var allObjectsFor = ""
    var onChange: (() -> Void)?

    // hover throttling
    private var hoverInFlight = false
    private var pendingHover: CGPoint?
    private var lastHoverStart: CFAbsoluteTime = 0

    var samAvailable: Bool { SAMSegmenter.shared.isAvailable }

    // MARK: Source image

    /// CI composite (or active layer) of a document, over white, canvas extent.
    static func sourceImage(_ d: Document, sampleAll: Bool) -> CIImage {
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        var img: CIImage
        if sampleAll {
            img = Compositor.shared.composite(d)
        } else if let l = d.activeLayer {
            img = Compositor.shared.contentImage(l, space: sp) ?? CIImage.clearImage
        } else {
            img = Compositor.shared.composite(d)
        }
        return img.cropped(to: sp.ciCanvas)
    }

    /// Ensures `image` matches the document's current content; starts the SAM encoder in the background if needed.
    @discardableResult
    func prepare(_ d: Document, force: Bool = false) -> SegImage? {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = "\(d.id)-\(d.revision)-\(settings.sampleAllLayers)-\(d.activeLayerID?.uuidString ?? "")-\(d.state.width)x\(d.state.height)"
        if key == sourceKey, !force, let img = image { return img }
        sourceKey = key
        let ci = Self.sourceImage(d, sampleAll: settings.sampleAllLayers)
        let fp = "\(d.id.uuidString.prefix(8))-" + SegImage.fingerprint(ci.composited(over: CIImage(color: .white).cropped(to: ci.extent)), width: d.state.width, height: d.state.height)
        if !force, let img = image, img.id == fp { return img }
        // content changed: render a stable full-res copy (the composite graph references live buffers)
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        let buf = RenderEngine.renderBuffer(ci, docRect: d.state.canvasRect, space: sp)
        let img = SegImage(buffer: buf, id: fp)
        image = img
        embeddingReady = false
        hover = nil
        allObjects = []
        allObjectsFor = ""
        settings.objectCount = nil
        if force { SAMSegmenter.shared.clearCache() }
        guard samAvailable else { return img }
        settings.analyzing = true
        queue.async { [weak self] in
            let ok = (try? SAMSegmenter.shared.embedding(img)) != nil
            DispatchQueue.main.async {
                guard let self, self.image?.id == img.id else { return }
                self.embeddingReady = ok
                self.settings.analyzing = false
                if ok && self.settings.showAllObjects { self.computeAllObjects() }
                self.onChange?()
            }
        }
        return img
    }

    func settingsChanged() {
        DispatchQueue.main.async { [self] in
            if !settings.objectFinder { hover = nil }
            if settings.showAllObjects, embeddingReady { computeAllObjects() }
            if let d = AppActions.doc, AppModel.shared.tool == .objectSelect { prepare(d) }
            onChange?()
        }
    }

    func clearHover() { hover = nil; pendingHover = nil }

    // MARK: Object Finder hover

    /// Requests the object mask under `p` (doc coords); throttled to ~30 Hz, latest request wins.
    func requestHover(at p: CGPoint) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard settings.objectFinder, embeddingReady, let img = image, settings.busy == nil else { return }
        guard p.x >= 0, p.y >= 0, p.x < CGFloat(img.width), p.y < CGFloat(img.height) else { hover = nil; onChange?(); return }
        if let h = hover, h.mask.contains(p), h.point.distance(to: p) < CGFloat(max(img.width, img.height)) * 0.08 { return }
        if hoverInFlight || CFAbsoluteTimeGetCurrent() - lastHoverStart < 1.0 / 30 {
            pendingHover = p
            if !hoverInFlight { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in self?.flushHover() } }
            return
        }
        startHover(p, img: img)
    }

    private func flushHover() {
        guard !hoverInFlight, let p = pendingHover, let img = image else { return }
        pendingHover = nil
        startHover(p, img: img)
    }

    private func startHover(_ p: CGPoint, img: SegImage) {
        hoverInFlight = true
        lastHoverStart = CFAbsoluteTimeGetCurrent()
        hoverQueue.async { [weak self] in
            let h = try? ObjectSelectionEngine.hoverMask(img, at: p)
            DispatchQueue.main.async {
                guard let self else { return }
                self.hoverInFlight = false
                if self.image?.id == img.id { self.hover = h; self.onChange?() }
                if self.pendingHover != nil { self.flushHover() }
            }
        }
    }

    static let hoverColor = NSColor(calibratedRed: 0.2, green: 0.5, blue: 1, alpha: 1)

    /// Computes the hover mask (point prompt on the cached embedding) and renders its tinted preview.
    static func hoverMask(_ img: SegImage, at p: CGPoint) throws -> HoverMask? {
        guard let emb = SAMSegmenter.shared.cachedEmbedding(img) else { return nil }
        let t0 = CFAbsoluteTimeGetCurrent()
        let m = try segTime("hover.decode", false) { try SAMSegmenter.shared.predictRaw(.point(p), emb: emb) }
        guard m.coverage > 0, m.coverage < 0.97, m.score > 0.5 else { return nil }
        let (image, outline) = segTime("hover.preview", false) { preview(m) }
        SegLog.record("hover", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
        return HoverMask(image: image, outline: outline, docRect: emb.rect, mask: m, point: p)
    }

    /// Tinted RGBA preview (512² over the embedding rect) and a doc-space outline of a low-res mask.
    static func preview(_ m: SAMMask, color: NSColor = hoverColor, alpha: CGFloat = 0.38) -> (CGImage, CGPath) {
        let n = SAMSegmenter.maskSize
        let S = 512
        let logits = SegMask.floatImage(m.logits, w: n, h: n)
        let up = logits.clampedToExtent().transformed(by: CGAffineTransform(scaleX: CGFloat(S) / CGFloat(n), y: CGFloat(S) / CGFloat(n)))
            .cropped(to: CGRect(x: 0, y: 0, width: S, height: S))
        let a = SegMask.sigmoidKernel!.apply(extent: up.extent, arguments: [up, Float(1.5)])!.cropped(to: up.extent)
        let c = CIImage(color: CIColor(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent, alpha: alpha)).cropped(to: up.extent)
        let tinted = c.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.clearImage.cropped(to: up.extent), kCIInputMaskImageKey: a])
        let cg = SegImage.ctx.createCGImage(tinted, from: up.extent, format: .RGBA8, colorSpace: sRGBSpace)!
        // outline from a 256² binary buffer
        let bin = PixelBuffer(width: n, height: n, format: .gray)
        let bp = bin.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<n { for x in 0..<n { bp[y * bin.bytesPerRow + x] = m.logits[y * n + x] > 0 ? 255 : 0 } }
        bin.markDirty()
        let r = m.emb.rect
        var t = CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: r.width / CGFloat(n), y: r.height / CGFloat(n))
        let path = SelectionOps.outline(bin).copy(using: &t) ?? CGMutablePath()
        return (cg, path)
    }

    // MARK: Show All Objects

    func computeAllObjects() {
        guard let img = image, embeddingReady, allObjectsFor != img.id else { return }
        allObjectsFor = img.id
        settings.busy = "Finding objects…"
        queue.async { [weak self] in
            var out: [(CGPath, CGRect)] = []
            if let emb = SAMSegmenter.shared.cachedEmbedding(img), let objs = try? SAMSegmenter.shared.automaticMasks(emb: emb, grid: 16) {
                let n = SAMSegmenter.maskSize
                for o in objs {
                    let bin = PixelBuffer(width: n, height: n, format: .gray)
                    let bp = bin.data.assumingMemoryBound(to: UInt8.self)
                    for y in 0..<n { for x in 0..<n { bp[y * bin.bytesPerRow + x] = o.bin[y * n + x] > 0 ? 255 : 0 } }
                    bin.markDirty()
                    var t = CGAffineTransform(translationX: emb.rect.minX, y: emb.rect.minY).scaledBy(x: emb.rect.width / CGFloat(n), y: emb.rect.height / CGFloat(n))
                    out.append((SelectionOps.outline(bin).copy(using: &t) ?? CGMutablePath(), emb.lowResToDoc(o.box)))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.image?.id == img.id else { return }
                self.allObjects = out.map { (outline: $0.0, box: $0.1) }
                self.settings.busy = nil
                self.settings.objectCount = out.count
                self.onChange?()
            }
        }
    }

    // MARK: Background jobs

    /// Runs segmentation work off the main thread with a status message; `done` runs on the main thread.
    func run<T>(_ message: String, _ work: @escaping (SegImage) throws -> T?, done: @escaping (T?) -> Void) {
        guard let d = AppActions.doc, let img = prepare(d) else { done(nil); return }
        settings.busy = message
        AppModel.shared.setStatus(message)
        hover = nil
        onChange?()
        queue.async {
            let t0 = CFAbsoluteTimeGetCurrent()
            var result: T?
            var err: Error?
            do { result = try work(img) } catch { err = error }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            DispatchQueue.main.async {
                self.settings.busy = nil
                if let e = err {
                    AppModel.shared.setStatus(e.localizedDescription)
                    Beep.play()
                } else {
                    AppModel.shared.setStatus(String(format: "%@ done (%.0f ms).", message.replacingOccurrences(of: "…", with: ""), ms))
                }
                done(result)
                self.onChange?()
            }
        }
    }
}
