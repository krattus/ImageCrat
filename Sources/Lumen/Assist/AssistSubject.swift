import AppKit
import SwiftUI
import CoreImage
import Observation
import ImageCratCore

/// Subject-aware one-click helpers, all editable afterwards:
/// Text Behind Subject, Pop Subject, Depth Parallax Layers (+ animation / video) and batch background removal.
enum AssistSubject {
    enum SubjectError: LocalizedError {
        case noSubject, noText, noImage
        var errorDescription: String? {
            switch self {
            case .noSubject: return "No clear subject was found in the image."
            case .noText: return "Select the type layer that should go behind the subject."
            case .noImage: return "There is nothing to analyse."
            }
        }
    }

    /// Subject mask (canvas-size gray) of a canvas-size RGBA buffer: SAM / BiRefNet through `SegmentationService`
    /// when installed, Apple Vision otherwise.
    static func subjectMask(_ image: PixelBuffer, hair: Bool = true) async throws -> PixelBuffer {
        guard let m = try await SegmentationService.subjectMask(in: image, quality: .fast, hair: hair), m.opaqueBounds(threshold: 32) != nil else { throw SubjectError.noSubject }
        return m
    }

    // MARK: Text Behind Subject

    struct TextBehindResult {
        var subjectLayerID: UUID
        var overlap: Double         // fraction of the text box covered by the subject
        var duplicatedLayer: Bool
        var seconds: Double
    }

    /// Puts `textID` behind the main subject: a masked copy of the picture under the text is placed right above
    /// the text layer. The text stays live; the mask on the copy can be refined with any brush.
    static func textBehindSubject(_ d: Document, textID: UUID) async throws -> TextBehindResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        struct Prep { var below: PixelBuffer; var source: Layer?; var textBounds: CGRect }
        let prep: Prep? = await Assist.onMain {
            guard let text = d.state.layer(textID), text.isText else { return nil }
            // the picture the text sits on: everything below it in the stack
            var st = d.state
            let order = st.allLayers.map(\.id)
            guard let idx = order.firstIndex(of: textID) else { return nil }
            let above = Set(order[idx...])
            for id in above { st.updateLayer(id) { $0.isVisible = false } }
            // groups that contain the text must stay visible for the layers under it
            var p = d.state.parentID(of: textID)
            while let pid = p { st.updateLayer(pid) { $0.isVisible = true }; p = d.state.parentID(of: pid) }
            let buf = Assist.compositeBuffer(st)
            let sib = d.state.siblings(of: textID)
            let me = sib.firstIndex { $0.id == textID } ?? 0
            let under = sib[..<me].filter { $0.isVisible && ($0.isRaster || $0.isSmartObject) }
            let others = sib[..<me].filter { $0.isVisible && !$0.isRaster && !$0.isSmartObject }
            let single = (under.count == 1 && others.isEmpty && d.state.parentID(of: textID) == nil) ? under.first : nil
            return Prep(below: buf, source: single, textBounds: Compositor.shared.contentBounds(text, state: d.state) ?? .zero)
        }
        guard let p = prep else { throw SubjectError.noText }
        let mask = try await subjectMask(p.below)
        // how much of the text the subject covers
        var overlap = 0.0
        let tb = IRect(enclosing: p.textBounds).intersection(mask.bounds)
        if !tb.isEmpty {
            var s = 0.0
            let mp = mask.data.assumingMemoryBound(to: UInt8.self)
            for y in tb.minY..<tb.maxY { for x in tb.minX..<tb.maxX { s += Double(mp[y * mask.bytesPerRow + x]) } }
            overlap = s / 255 / Double(tb.width * tb.height)
        }
        let id: UUID = await Assist.onMain {
            var layer: Layer
            if let src = p.source {
                layer = src.duplicated(newName: "Subject (in front of text)")
                layer.effects = LayerEffects()
            } else {
                layer = Layer.raster(name: "Subject (in front of text)", buffer: p.below)
            }
            layer.mask = LayerMask(buffer: mask, origin: .zero, outsideValue: 0)
            layer.isClipped = false
            layer.opacity = 1; layer.blendMode = .normal
            d.state.insertLayer(layer, above: textID)
            d.activeLayerID = textID; d.selectedLayerIDs = [textID]
            d.commit("Text Behind Subject")
            d.setNeedsRender()
            return layer.id
        }
        return TextBehindResult(subjectLayerID: id, overlap: overlap, duplicatedLayer: p.source != nil, seconds: CFAbsoluteTimeGetCurrent() - t0)
    }

    static func textBehindSubjectAction() {
        guard let d = AppActions.doc else { return }
        guard let id = d.activeLayer?.isText == true ? d.activeLayerID : d.state.allLayers.last(where: { $0.isText && $0.isVisible })?.id else {
            AppActions.alert("Text Behind Subject", SubjectError.noText.localizedDescription)
            return
        }
        Assist.run("Text Behind Subject: finding the subject…", { try await textBehindSubject(d, textID: id) }) { r in
            AppModel.shared.setStatus(r.overlap < 0.02
                ? "Text Behind Subject: done — the subject does not overlap the text yet; move the text behind it."
                : String(format: "Text Behind Subject: done (%.1f s). Move or edit the text freely; paint on the Subject mask to refine.", r.seconds))
        }
    }

    // MARK: Pop Subject

    struct PopOptions {
        var blur: Double = 10          // px at 2000 px wide (scaled with the document)
        var desaturate: Double = 55
        var darken: Double = 28
    }

    static let fillKernel = CIColorKernel(source: """
    kernel vec4 assistFill(__sample s) {
        float a = max(s.a, 0.0001);
        return vec4(clamp(s.rgb / a, 0.0, 1.0), 1.0);
    }
    """)

    /// The picture with the subject replaced by a smooth extrapolation of the background, so blurring it later
    /// does not smear subject colours into the backdrop.
    static func backgroundPlate(_ image: PixelBuffer, subject: PixelBuffer, radius: Double) -> PixelBuffer {
        let sp = CanvasSpace(width: image.width, height: image.height)
        let img = image.ciImage
        let bg = SelectionOps.invert(SelectionOps.expand(subject, by: 2))
        let cut = img.masked(byGray: bg.ciImage)
        var fill = cut.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: sp.ciCanvas)
        // a second, wider pass fills the middle of large subjects
        let wide = cut.clampedToExtent().applyingGaussianBlur(sigma: radius * 4).cropped(to: sp.ciCanvas)
        fill = fill.composited(over: wide)
        if let k = fillKernel, let f = k.apply(extent: sp.ciCanvas, arguments: [fill]) { fill = f }
        return RenderEngine.renderBuffer(cut.composited(over: fill), docRect: image.bounds, space: sp)
    }

    /// Background blur / desaturate / darken, each masked by the inverse of the subject, in a "Pop Subject" group.
    @discardableResult
    static func popSubject(_ d: Document, options o: PopOptions = PopOptions()) async throws -> UUID {
        let image: PixelBuffer = await Assist.onMain { Assist.compositeBuffer(d.state) }
        let subject = try await subjectMask(image)
        let W = image.width, H = image.height
        let scale = Double(max(W, H)) / 2000
        let bgMask = SelectionOps.feather(SelectionOps.invert(subject), radius: max(0.8, 1.5 * scale))
        let plate = o.blur > 0 ? backgroundPlate(image, subject: subject, radius: max(6, o.blur * scale * 2.5)) : nil
        return await Assist.onMain {
            var kids: [Layer] = []
            func mask() -> LayerMask { LayerMask(buffer: bgMask.copy(), origin: .zero, outsideValue: 255) }
            if let plate {
                var f = FilterInstance(kind: .gaussianBlur)
                f.values["radius"] = max(1, (o.blur * scale).rounded())
                var so = SmartObjectContent(source: .image(plate), quad: Quad(rect: CGRect(x: 0, y: 0, width: W, height: H)), sourceName: "Background Plate")
                so.filters = [f]
                var l = Layer(name: "Background Blur", content: .smartObject(so))
                l.mask = mask()
                kids.append(l)
            }
            if o.desaturate > 0 {
                var s = AdjustmentSettings(kind: .hueSaturation)
                s.hsSaturation = -o.desaturate
                var l = Layer(name: "Background Desaturate", content: .adjustment(s))
                l.mask = mask()
                kids.append(l)
            }
            if o.darken > 0 {
                var s = AdjustmentSettings(kind: .brightnessContrast)
                s.brightness = -o.darken
                var l = Layer(name: "Background Darken", content: .adjustment(s))
                l.mask = mask()
                kids.append(l)
            }
            var g = Layer(name: "Pop Subject", content: .group(GroupContent(children: kids, isExpanded: true)))
            g.blendMode = .passThrough
            d.state.layers.append(g)
            d.activeLayerID = g.id; d.selectedLayerIDs = [g.id]
            d.commit("Pop Subject")
            d.setNeedsRender()
            return g.id
        }
    }

    static func popSubjectAction() {
        guard let d = AppActions.doc else { return }
        Assist.run("Pop Subject: finding the subject…", { try await popSubject(d) }) { _ in
            AppModel.shared.showPanels = true
            AppModel.shared.setStatus("Pop Subject: added background blur, desaturate and darken layers (tweak or hide each in the group).")
        }
    }

    // MARK: Batch background removal

    /// Adds a subject mask to every selected pixel / smart-object layer. One undo step. Returns the masked layer ids.
    @discardableResult
    static func removeBackgrounds(_ d: Document, ids: [UUID]) async -> [UUID] {
        let inputs: [(UUID, PixelBuffer)] = await Assist.onMain {
            let sp = CanvasSpace(width: d.state.width, height: d.state.height)
            return ids.compactMap { id in
                guard let l = d.state.layer(id), l.isRaster || l.isSmartObject, let img = Compositor.shared.contentImage(l, space: sp) else { return nil }
                return (id, RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: d.state.canvasRect, space: sp))
            }
        }
        var masks: [(UUID, PixelBuffer)] = []
        for (id, buf) in inputs {
            if let m = try? await subjectMask(buf) { masks.append((id, m)) }
        }
        guard !masks.isEmpty else { return [] }
        return await Assist.onMain {
            for (id, m) in masks { d.updateLayer(id) { $0.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0) } }
            d.commit(masks.count == 1 ? "Remove Background" : "Remove \(masks.count) Backgrounds")
            d.setNeedsRender()
            return masks.map(\.0)
        }
    }

    static func removeBackgroundsAction() {
        guard let d = AppActions.doc else { return }
        let ids = d.orderedSelection.flatMap { d.state.layer($0)?.allIDs ?? [] }.filter { d.state.layer($0).map { $0.isRaster || $0.isSmartObject } ?? false }
        guard !ids.isEmpty else { NSSound.beep(); AppModel.shared.setStatus("Select one or more image layers."); return }
        Assist.run("Removing the background of \(ids.count) layer\(ids.count == 1 ? "" : "s")…", { await removeBackgrounds(d, ids: ids) }) { done in
            AppModel.shared.setStatus(done.isEmpty ? "No subject found in the selected layers." :
                "Masked \(done.count) of \(ids.count) layer\(ids.count == 1 ? "" : "s") (non-destructive layer masks).")
        }
    }

    // MARK: Depth parallax

    struct ParallaxOptions {
        var layers = 3
        var amount = 2.2           // % of the width the nearest layer travels each way
        var seconds = 3.0
        var fps = 24.0
        var vertical = 0.35        // vertical share of the orbit
    }

    struct ParallaxLayer {
        var name: String
        var buffer: PixelBuffer
        var origin: IPoint
        var depth: Double          // 0 far … 1 near (band centre)
    }

    struct ParallaxBuild {
        var layers: [ParallaxLayer]     // far → near
        var engine: String
        var depthMap: CGImage?
        var seconds: Double
    }

    /// 1-D k-means on depth values → N−1 thresholds (ascending).
    static func depthThresholds(_ depth: [Float], count n: Int) -> [Float] {
        var hist = [Double](repeating: 0, count: 256)
        for v in depth { hist[min(255, max(0, Int(v * 255)))] += 1 }
        var centers = (0..<n).map { (Double($0) + 0.5) / Double(n) * 255 }
        for _ in 0..<40 {
            var sum = [Double](repeating: 0, count: n), cnt = [Double](repeating: 0, count: n)
            for i in 0..<256 where hist[i] > 0 {
                var best = 0, bd = Double.infinity
                for k in 0..<n { let dd = abs(Double(i) - centers[k]); if dd < bd { bd = dd; best = k } }
                sum[best] += Double(i) * hist[i]; cnt[best] += hist[i]
            }
            var moved = 0.0
            for k in 0..<n where cnt[k] > 0 { let c = sum[k] / cnt[k]; moved += abs(c - centers[k]); centers[k] = c }
            if moved < 0.01 { break }
        }
        centers.sort()
        return (0..<(n - 1)).map { Float((centers[$0] + centers[$0 + 1]) / 2 / 255) }
    }

    /// Splits `image` into `count` depth-ordered layers. Every layer except the nearest has the nearer content
    /// painted out (LaMa, else PatchMatch) so nothing is missing when the layers slide apart.
    static func buildParallax(_ image: CGImage, count: Int, reach: Int, progress: ((String) -> Void)? = nil) async throws -> ParallaxBuild {
        let t0 = CFAbsoluteTimeGetCurrent()
        let W = image.width, H = image.height
        let n = max(2, min(6, count))
        var engine = ""
        // depth: 0 far … 1 near
        var depth: PlanarImage
        if DepthEstimator.isAvailable, let dmap = try? await DepthEstimator.depth(image) {
            depth = dmap
            engine = "Depth Anything V2"
        } else {
            // no depth model: subject in front, ground nearer than sky
            depth = PlanarImage(width: W, height: H, channels: 1)
            let subj = try? await subjectMask(PixelBuffer(cgImage: image), hair: false)
            let sp = subj.map { PlanarImage.gray($0.makeCGImage()) }
            for y in 0..<H { for x in 0..<W { depth.data[y * W + x] = 0.3 * Float(y) / Float(H) + 0.7 * (sp?.data[y * W + x] ?? 0) } }
            engine = "Vision subject + ground plane"
        }
        // smooth a little so bands have clean outlines
        let blurR = max(1, Int(Double(max(W, H)) / 600))
        depth = MaskMath.boxBlur(depth, blurR)
        let th = depthThresholds(depth.data, count: n)
        progress?("Depth map ready (\(engine)); separating \(n) layers…")
        let inpaintEngine = LamaInpainter.isAvailable ? "LaMa" : "PatchMatch"
        engine += " + " + inpaintEngine
        let original = PixelBuffer(cgImage: image)
        var layers: [ParallaxLayer] = []
        for k in 0..<n {
            let lo: Float = k == 0 ? -1 : th[k - 1]
            let hi: Float = k == n - 1 ? 2 : th[k]
            // band k and everything nearer
            let band = PixelBuffer(width: W, height: H, format: .gray)
            let nearer = PixelBuffer(width: W, height: H, format: .gray)
            let bp = band.data.assumingMemoryBound(to: UInt8.self), np = nearer.data.assumingMemoryBound(to: UInt8.self)
            var hasNearer = false
            for y in 0..<H {
                for x in 0..<W {
                    let v = depth.data[y * W + x]
                    if v >= lo && v < hi { bp[y * band.bytesPerRow + x] = 255 }
                    if v >= hi { np[y * nearer.bytesPerRow + x] = 255; hasNearer = true }
                }
            }
            band.markDirty(); nearer.markDirty()
            var content = original
            if hasNearer {
                // remove the nearer layers (with a margin for their soft edges) from this one
                let hole = SelectionOps.expand(nearer, by: max(3, Double(max(W, H)) / 250))
                progress?("Filling behind layer \(k + 2) of \(n) (\(inpaintEngine))…")
                if LamaInpainter.isAvailable, let out = try? await LamaInpainter.inpaint(image, hole: PlanarImage.gray(hole.makeCGImage())) {
                    content = PixelBuffer(cgImage: out)
                } else {
                    // PatchMatch is slow on large holes: work at reduced size
                    let s = min(1, 700.0 / Double(max(W, H)))
                    if s < 1 {
                        let sw = max(8, Int(Double(W) * s)), sh = max(8, Int(Double(H) * s))
                        let small = PixelBuffer(cgImage: NImg.resized(image, sw, sh))
                        let smallHole = PixelBuffer(cgImage: NImg.resized(hole.makeCGImage(), sw, sh), format: .gray)
                        let filled = Inpainter.inpaint(small, hole: smallHole)
                        let up = PixelBuffer(cgImage: NImg.resized(filled.makeCGImage(), W, H))
                        let merged = original.copy()
                        merged.context.saveGState()
                        merged.clip(toMask: SelectionOps.feather(hole, radius: 2).makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
                        merged.drawImage(up.makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
                        merged.context.restoreGState()
                        merged.markDirty()
                        content = merged
                    } else {
                        content = Inpainter.inpaint(original, hole: hole)
                    }
                }
            }
            let name = k == 0 ? "Depth 1 (far)" : (k == n - 1 ? "Depth \(n) (near)" : "Depth \(k + 1)")
            let centre = Double((max(0, lo) + min(1, hi)) / 2)
            if k == 0 {
                layers.append(ParallaxLayer(name: name, buffer: content, origin: .zero, depth: centre))
                continue
            }
            // alpha: the band, extended `reach` px underneath nearer layers, soft edge
            var alpha = band
            if hasNearer {
                let grown = SelectionOps.expand(band, by: Double(reach))
                let under = SelectionOps.combine(grown, nearer, mode: .intersect)
                alpha = SelectionOps.combine(band, under, mode: .add)
            }
            alpha = SelectionOps.feather(alpha, radius: max(0.8, Double(max(W, H)) / 1400))
            let out = PixelBuffer(width: W, height: H)
            out.context.saveGState()
            out.clip(toMask: alpha.makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
            out.drawImage(content.makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
            out.context.restoreGState()
            out.markDirty()
            if let b = out.opaqueBounds() {
                layers.append(ParallaxLayer(name: name, buffer: out.cropped(to: b), origin: b.origin, depth: centre))
            }
        }
        return ParallaxBuild(layers: layers, engine: engine, depthMap: depth.cgImage(), seconds: CFAbsoluteTimeGetCurrent() - t0)
    }

    /// Animation frames for a gentle orbiting camera: near layers travel further than far ones.
    static func parallaxFrames(_ st: DocumentState, ids: [UUID], options o: ParallaxOptions) -> [AnimationFrame] {
        let count = max(2, Int((o.seconds * o.fps).rounded()))
        let base = Animation.capture(st)
        let amp = Double(st.width) * o.amount / 100
        var frames: [AnimationFrame] = []
        for i in 0..<count {
            var f = AnimationFrame(delay: 1 / o.fps)
            f.visibility = base.visibility; f.opacities = base.opacities; f.positions = base.positions
            let phase = 2 * Double.pi * Double(i) / Double(count)
            for (k, id) in ids.enumerated() {
                guard let l = st.layer(id), let a = Animation.anchor(l) else { continue }
                let w = ids.count > 1 ? Double(k) / Double(ids.count - 1) : 0      // far layer stays put
                f.positions[id] = CGPoint(x: a.x + CGFloat((amp * w * sin(phase)).rounded()), y: a.y + CGFloat((amp * o.vertical * w * cos(phase)).rounded()))
            }
            frames.append(f)
        }
        return frames
    }

    struct ParallaxResult {
        var groupID: UUID
        var layerIDs: [UUID]       // far → near
        var engine: String
        var seconds: Double
        var frames: Int
    }

    /// Adds the depth layers (in a "Parallax Layers" group) and optionally the orbit animation. One undo step.
    static func addParallax(_ d: Document, build: ParallaxBuild, animate: Bool, options o: ParallaxOptions) -> ParallaxResult {
        let kids = build.layers.map { Layer.raster(name: $0.name, buffer: $0.buffer, origin: $0.origin) }
        var g = Layer(name: "Parallax Layers", content: .group(GroupContent(children: kids, isExpanded: true)))
        g.blendMode = .passThrough
        d.state.layers.append(g)
        d.activeLayerID = g.id; d.selectedLayerIDs = [g.id]
        var frames = 0
        if animate {
            d.state.frames = parallaxFrames(d.state, ids: kids.map(\.id), options: o)
            d.state.animationLoop = .forever
            frames = d.state.frames.count
        }
        d.commit(animate ? "Depth Parallax Layers + Animation" : "Depth Parallax Layers")
        d.setNeedsRender()
        return ParallaxResult(groupID: g.id, layerIDs: kids.map(\.id), engine: build.engine, seconds: build.seconds, frames: frames)
    }

    static func parallax(_ d: Document, options o: ParallaxOptions, animate: Bool, progress: ((String) -> Void)? = nil) async throws -> ParallaxResult {
        let cg: CGImage? = await Assist.onMain { Assist.compositeCG(d.state) }
        guard let image = cg else { throw SubjectError.noImage }
        let reach = Int((Double(image.width) * o.amount / 100).rounded(.up)) * 2 + 8
        let build = try await buildParallax(image, count: o.layers, reach: reach, progress: progress)
        return await Assist.onMain { addParallax(d, build: build, animate: animate, options: o) }
    }

    /// Ids (far → near) of an existing "Parallax Layers" group.
    static func existingParallax(_ st: DocumentState) -> [UUID]? {
        guard let g = st.layers.last(where: { $0.isGroup && $0.name == "Parallax Layers" }), g.children.count >= 2 else { return nil }
        return g.children.map(\.id)
    }

    /// Renders the orbit to an MP4 / MOV / GIF with the app's animation exporters (does not change the document).
    static func exportParallax(_ st: DocumentState, ids: [UUID], to url: URL, options o: ParallaxOptions) throws -> Int {
        var s = st
        s.frames = parallaxFrames(st, ids: ids, options: o)
        s.animationLoop = .forever
        if url.pathExtension.lowercased() == "gif" { try AnimationExport.writeGIF(s, to: url, background: .white) }
        else { try AnimationExport.writeVideo(s, to: url) }
        return s.frames.count
    }
}

// MARK: - Parallax dialog

@Observable
final class AssistParallaxModel {
    var o = AssistSubject.ParallaxOptions()
    var running = false
    var message = ""

    var layersD: Double { get { Double(o.layers) } set { o.layers = Int(newValue.rounded()) } }

    func create(animate: Bool, then: ((Document, [UUID]) -> Void)? = nil) {
        guard let d = AppActions.doc else { return }
        running = true
        message = "Estimating depth…"
        let opts = o
        Task.detached(priority: .userInitiated) {
            do {
                let r = try await AssistSubject.parallax(d, options: opts, animate: animate) { s in Task { @MainActor in self.message = s } }
                await MainActor.run {
                    self.running = false
                    self.message = String(format: "%d layers with %@ in %.1f s%@.", r.layerIDs.count, r.engine, r.seconds, r.frames > 0 ? " · \(r.frames) animation frames (Window ▸ Timeline)" : "")
                    AppModel.shared.setStatus("Depth Parallax: " + self.message)
                    then?(d, r.layerIDs)
                }
            } catch {
                await MainActor.run { self.running = false; self.message = error.localizedDescription }
            }
        }
    }

    func export(gif: Bool) {
        guard let d = AppActions.doc else { return }
        let run: (Document, [UUID]) -> Void = { d, ids in
            let p = NSSavePanel()
            p.allowedContentTypes = gif ? [.gif] : [.mpeg4Movie, .quickTimeMovie]
            p.nameFieldStringValue = (d.name as NSString).deletingPathExtension + " parallax." + (gif ? "gif" : "mp4")
            let opts = self.o
            p.begin { r in
                guard r == .OK, let url = p.url else { return }
                AppModel.shared.setStatus("Rendering parallax…")
                do {
                    let n = try AssistSubject.exportParallax(d.state, ids: ids, to: url, options: opts)
                    self.message = "Exported \(url.lastPathComponent) (\(n) frames)."
                    AppModel.shared.setStatus(self.message)
                } catch { AppActions.alert("Export failed.", error.localizedDescription) }
            }
        }
        if let ids = AssistSubject.existingParallax(d.state) { run(d, ids) } else { create(animate: false, then: run) }
    }
}

struct AssistParallaxDialog: View {
    @State private var m: AssistParallaxModel
    init(model: AssistParallaxModel = AssistParallaxModel()) { _m = State(initialValue: model) }

    var body: some View {
        DialogFrame(title: "Depth Parallax", width: 400, okTitle: "Done", onOK: {}) {
            ValueSlider(label: "Layers", value: $m.layersD, range: 2...5, step: 1)
            ValueSlider(label: "Camera move", value: $m.o.amount, range: 0.5...6, step: 0.1, unit: "%", format: "%.1f")
            ValueSlider(label: "Duration", value: $m.o.seconds, range: 1...8, step: 0.5, unit: "s", format: "%.1f")
            HStack(spacing: 6) {
                Button("Create Layers") { m.create(animate: false) }.buttonStyle(PanelButtonStyle()).disabled(m.running)
                Button("Layers + Animation") { m.create(animate: true) }.buttonStyle(PanelButtonStyle(prominent: true)).disabled(m.running)
                    .help("Adds the depth layers and a looping frame animation you can play in the Timeline")
            }
            HStack(spacing: 6) {
                Button("Export MP4…") { m.export(gif: false) }.buttonStyle(PanelButtonStyle()).disabled(m.running)
                Button("Export GIF…") { m.export(gif: true) }.buttonStyle(PanelButtonStyle()).disabled(m.running)
                if m.running { ProgressView().controlSize(.small) }
            }
            if !m.message.isEmpty { Text(m.message).font(Theme.fontSmall).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true) }
            Text("Splits the picture into depth-ordered layers (\(DepthEstimator.isAvailable ? "Depth Anything V2" : "subject + ground plane — install Depth Anything for true depth")) and paints in what each layer hides (\(LamaInpainter.isAvailable ? "LaMa" : "PatchMatch")).")
                .font(Theme.fontSmall).foregroundStyle(Theme.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}
