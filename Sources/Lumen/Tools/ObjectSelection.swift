import AppKit
import Vision
import CoreImage
import ImageCratCore

enum ObjectFinder {
    /// Finds the main object inside `region` (doc coords) of a canvas-size RGBA composite.
    /// Uses Vision foreground instance masks, falling back to saliency + edge-aware refinement.
    static func objectMask(src: PixelBuffer, region: CGRect, lasso: CGPath? = nil) -> PixelBuffer? {
        let W = src.width, H = src.height
        var r = IRect(enclosing: region).intersection(src.bounds)
        guard r.width > 4, r.height > 4 else { return nil }
        // context margin helps Vision
        let m = Int(Double(max(r.width, r.height)) * 0.08)
        r = IRect(x: r.x - m, y: r.y - m, width: r.width + 2 * m, height: r.height + 2 * m).intersection(src.bounds)
        let crop = src.cropped(to: r)
        let cg = crop.makeCGImage()
        var local: CIImage? = nil

        let handler = VNImageRequestHandler(cgImage: cg)
        let req = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([req])) != nil, let obs = req.results?.first {
            // choose instances overlapping the region center area
            var chosen = IndexSet()
            let ref = CGRect(x: region.minX - CGFloat(r.x), y: region.minY - CGFloat(r.y), width: region.width, height: region.height)
            for inst in obs.allInstances {
                if let pb = try? obs.generateScaledMaskForImage(forInstances: IndexSet(integer: inst), from: handler) {
                    let ci = CIImage(cvPixelBuffer: pb)
                    let frac = coverage(ci, crop: r, ref: ref)
                    if frac > 0.25 { chosen.insert(inst) }
                }
            }
            if chosen.isEmpty { chosen = obs.allInstances }
            if let pb = try? obs.generateScaledMaskForImage(forInstances: chosen, from: handler) {
                local = CIImage(cvPixelBuffer: pb)
            }
        }
        if local == nil {
            // Saliency fallback
            let sreq = VNGenerateObjectnessBasedSaliencyImageRequest()
            if (try? handler.perform([sreq])) != nil, let o = sreq.results?.first {
                let sal = CIImage(cvPixelBuffer: o.pixelBuffer)
                let scaled = sal.transformed(by: CGAffineTransform(scaleX: CGFloat(r.width) / sal.extent.width, y: CGFloat(r.height) / sal.extent.height))
                local = scaled.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.35])
            }
        }
        guard var mask = local else { return nil }
        mask = mask.transformed(by: CGAffineTransform(scaleX: CGFloat(r.width) / mask.extent.width, y: CGFloat(r.height) / mask.extent.height))
        // edge-aware refinement with the image as guide
        let guide = CIImage(cgImage: cg)
        mask = mask.applyingFilter("CIGuidedFilter", parameters: ["inputGuideImage": guide, kCIInputRadiusKey: 3, "inputEpsilon": 0.0005])
        let space = CanvasSpace(width: r.width, height: r.height)
        let localBuf = RenderEngine.renderBuffer(mask.cropped(to: space.ciCanvas), docRect: IRect(x: 0, y: 0, width: r.width, height: r.height), space: space, format: .gray)
        let out = PixelBuffer(width: W, height: H, format: .gray)
        out.copyPixels(from: localBuf, at: r.origin)
        // limit to the drawn region (rectangle or lasso), slightly expanded
        let limit = SelectionOps.mask(fromPath: lasso ?? CGPath(rect: region.insetBy(dx: -6, dy: -6), transform: nil), width: W, height: H)
        let limited = SelectionOps.combine(out, SelectionOps.expand(limit, by: 4), mode: .intersect)
        limited.markDirty()
        return limited.opaqueBounds() == nil ? nil : limited
    }

    private static func coverage(_ m: CIImage, crop: IRect, ref: CGRect) -> Double {
        let s = CGAffineTransform(scaleX: CGFloat(crop.width) / m.extent.width, y: CGFloat(crop.height) / m.extent.height)
        let mm = m.transformed(by: s)
        // ref is in top-left coords of the crop → CI coords
        let ciRef = CGRect(x: ref.minX, y: CGFloat(crop.height) - ref.maxY, width: ref.width, height: ref.height).intersection(mm.extent)
        guard !ciRef.isEmpty else { return 0 }
        let avg = mm.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ciRef)])
        var px = [Float](repeating: 0, count: 4)
        RenderEngine.readbackContext.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(origin: avg.extent.origin, size: CGSize(width: 1, height: 1)), format: .RGBAf, colorSpace: nil)
        return Double(px[0])
    }
}

enum ObjectSelectMode: String, CaseIterable { case rectangle = "Rectangle", lasso = "Lasso" }

/// Object Selection tool: SAM 2.1 box / lasso / click prompts with Object Finder hover (falls back to Apple Vision
/// when the SAM model isn't installed). Shift = add, Option = subtract, Shift+Option = intersect.
final class ObjectSelectTool: SelectionToolBase {
    private var start: CGPoint?
    private var current: CGPoint?
    private var lassoPts: [CGPoint] = []
    private var engine: ObjectSelectionEngine { .shared }
    private var settings: ObjectSelectionSettings { .shared }

    override func activate() {
        engine.onChange = { [weak self] in self?.canvas.overlay.needsDisplay = true }
        if let d = doc { engine.prepare(d) }
        if !engine.samAvailable {
            status("Object Selection uses Apple Vision. Download the SAM 2.1 model (94 MB) in the options bar for better results.")
        }
    }

    override func deactivate() {
        engine.clearHover()
        engine.onChange = nil
        super.deactivate()
    }

    override func mouseMoved(_ e: ToolEvent) {
        guard start == nil, let d = doc else { return }
        engine.prepare(d)
        engine.requestHover(at: e.doc)
    }

    override func mouseDown(_ e: ToolEvent) {
        combine = combineMode(e)
        start = e.doc; current = e.doc
        lassoPts = [e.doc]
        engine.clearHover()
    }

    override func mouseDragged(_ e: ToolEvent) {
        current = e.doc
        if app.objectSelectMode == .lasso { lassoPts.append(e.doc) }
    }

    override func mouseUp(_ e: ToolEvent) {
        defer { start = nil; current = nil; lassoPts = [] }
        guard let d = doc, let s = start, let c = current else { return }
        guard settings.busy == nil else { NSSound.beep(); return }
        let mode = combine
        let opts = settings.options
        engine.prepare(d)
        if s.distance(to: c) <= 4 {
            // click: reuse the Object Finder mask under the cursor when available
            let p = c
            let hover = engine.hover
            engine.run("Selecting object…", { img -> PixelBuffer? in
                if let h = hover, h.mask.contains(p), h.mask.emb.key.hasPrefix(img.id) {
                    var m = h.mask
                    m.logits = SAMSegmenter.cleaned(m.logits, w: m.w, h: m.h)
                    return try SegmentationService.finish(m, img: img, options: opts)
                }
                return try SegmentationService.pointSync(img, point: p, options: opts)
            }, done: { [weak self] m in self?.finish(m, mode: mode) })
            return
        }
        if app.objectSelectMode == .lasso, lassoPts.count > 2 {
            let pts = lassoPts
            engine.run("Finding object…", { img in try SegmentationService.lassoSync(img, lasso: pts, options: opts) },
                       done: { [weak self] m in self?.finish(m, mode: mode) })
        } else {
            let r = CGRect(p1: s, p2: c)
            engine.run("Finding object…", { img in try SegmentationService.boxSync(img, box: r, points: [], options: opts) },
                       done: { [weak self] m in self?.finish(m, mode: mode) })
        }
    }

    private func finish(_ m: PixelBuffer?, mode: SelectionCombine) {
        guard let m, m.opaqueBounds(threshold: 20) != nil else {
            status("No object found in the selected area.")
            NSSound.beep()
            return
        }
        combine = mode
        apply(m, name: "Object Selection")
        status("Object selected.")
    }

    override func keyDown(_ e: NSEvent) -> Bool {
        if e.keyCode == 53 { engine.clearHover(); start = nil; lassoPts = []; canvas.overlay.needsDisplay = true; return true }   // Esc
        return false
    }

    override func drawOverlay(_ ctx: CGContext) {
        let t = canvas.docToViewTransform
        // Show All Objects outlines
        if settings.showAllObjects, !engine.allObjects.isEmpty {
            ctx.saveGState()
            ctx.setLineWidth(1.5)
            for (i, o) in engine.allObjects.enumerated() {
                var tt = t
                guard let p = o.outline.copy(using: &tt) else { continue }
                let hue = CGFloat(i) * 0.137
                ctx.addPath(p)
                ctx.setStrokeColor(NSColor(calibratedHue: hue.truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 1, alpha: 0.9).cgColor)
                ctx.strokePath()
            }
            ctx.restoreGState()
        }
        // Object Finder hover
        if start == nil, settings.objectFinder, let h = engine.hover {
            ctx.saveGState()
            ctx.concatenate(t)
            ctx.translateBy(x: h.docRect.minX, y: h.docRect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(h.image, in: CGRect(origin: .zero, size: h.docRect.size))
            ctx.restoreGState()
            var tt = t
            if let p = h.outline.copy(using: &tt) {
                ctx.saveGState()
                ctx.addPath(p)
                ctx.setLineWidth(1.5)
                ctx.setStrokeColor(ObjectSelectionEngine.hoverColor.cgColor)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        if app.objectSelectMode == .lasso, lassoPts.count > 1 {
            let p = CGMutablePath(); p.addLines(between: lassoPts.map { canvas.docToView($0) })
            canvas.overlay.drawAnts(ctx, p, phase: canvas.antsPhase)
        } else if let s = start, let c = current, s.distance(to: c) > 4 {
            canvas.overlay.drawAnts(ctx, canvas.docToViewPath(CGRect(p1: s, p2: c)), phase: canvas.antsPhase)
        }
    }
}
