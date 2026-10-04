import AppKit
import CoreImage
import Metal
import ImageCratCore

/// Canvas accuracy at every zoom: what the canvas shows must be the document rendered at 100 % and then resampled.
/// `LUMEN_SELFTEST_ONLY=zoomfx Lumen --selftest <dir>`; `LUMEN_ZOOMFX_FIXTURE=<doc.lumen>` adds that document to the
/// matrix, `LUMEN_ZOOMFX_PERF=1` prints interaction timings (old vs new path), `LUMEN_ZOOMFX_OLD=1` runs the checks
/// against the old (fused) resampling.
enum ZoomFXModule {
    static func register() {
        FeatureModules.selfTests.append(("zoomfx", { out in ZoomFXSelfTest.run(out) }))
    }
}

enum ZoomFXSelfTest {
    static var passes = 0, failures = 0
    static let zooms: [CGFloat] = [1.0 / 16, 1.0 / 8, 0.25, 0.33, 0.37, 0.5, 0.66, 0.75, 1, 2, 4]
    static var useNew: Bool { ProcessInfo.processInfo.environment["LUMEN_ZOOMFX_OLD"] == nil }

    static func check(_ c: Bool, _ msg: @autoclosure () -> String) {
        if c { passes += 1; print("PASS zoomfx: \(msg())") } else { failures += 1; print("FAIL zoomfx: \(msg())") }
    }

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let dir = out.appendingPathComponent("zoomfx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        let saved = CanvasRenderer.exactResampling
        defer { CanvasRenderer.exactResampling = saved }
        if env["LUMEN_ZOOMFX_PERF"] != nil { perf(); print("zoomfx: \(passes) passed, \(failures) failed"); return }
        CanvasRenderer.exactResampling = useNew
        var cases = syntheticCases()
        if let f = env["LUMEN_ZOOMFX_FIXTURE"], let d = try? DocumentIO.load(url: URL(fileURLWithPath: f)) {
            var noAdj = d.state; noAdj.layers.removeAll { $0.isAdjustment }
            cases.insert(("fixture", d.state), at: 0)
            cases.insert(("fixture-noadj", noAdj), at: 1)
            comparisonImages(noAdj, dir)
        }
        accuracy(cases)
        restCache()
        previews()
        perfCheck()
        print("zoomfx: \(passes) passed, \(failures) failed")
    }

    // MARK: Rendering

    /// Renders `img` (output pixel space) into an RGBA8 buffer through the canvas' context.
    static func readback(_ img: CIImage, _ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        RenderEngine.context.render(img.composited(over: CIImage.clearImage.cropped(to: r)), toBitmap: b.data, rowBytes: b.bytesPerRow, bounds: r,
                                    format: .RGBA8, colorSpace: sRGBSpace)
        return b
    }

    static func diff(_ a: PixelBuffer, _ b: PixelBuffer) -> (max: Int, mean: Double) {
        guard a.width == b.width, a.height == b.height else { return (255, 255) }
        var mx = 0, sum = 0
        for y in 0..<a.height {
            let pa = a.data.advanced(by: y * a.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            let pb = b.data.advanced(by: y * b.bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for i in 0..<(a.width * 4) { let d = abs(Int(pa[i]) - Int(pb[i])); sum += d; if d > mx { mx = d } }
        }
        return (mx, Double(sum) / Double(a.width * a.height * 4))
    }

    /// What the canvas shows of `doc` at effective scale `z` (drawable pixels per document pixel), offset by a
    /// fraction of a pixel like a centred canvas usually is.
    static func shown(_ doc: Document, _ z: CGFloat, offset: CGPoint = CGPoint(x: 0.37, y: 0.61)) -> PixelBuffer {
        doc.zoom = Double(z)
        let t = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: offset.x, ty: offset.y)
        let w = Int((CGFloat(doc.state.width) * z).rounded(.up)), h = Int((CGFloat(doc.state.height) * z).rounded(.up))
        return readback(CanvasRenderer.documentImage(doc, transform: t, rotated: false, zoom: z).1, w, h)
    }

    /// The document rendered at 100 %, as a flat bitmap document (shown the same way, so the reference uses the
    /// canvas' own resampling).
    static func flat(_ st: DocumentState) -> Document {
        let sp = CanvasSpace(width: st.width, height: st.height)
        var f = DocumentState(width: st.width, height: st.height)
        f.layers = [Layer.raster(name: "flat", buffer: RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: sp))]
        return Document(state: f, name: "reference")
    }

    // MARK: Accuracy matrix

    static func accuracy(_ cases: [(String, DocumentState)]) {
        var worstNew = 0, worstOld = 0
        print("zoomfx accuracy: max/mean difference (of 255) vs the 100 % render resampled, old fused path → new path")
        print("zoomfx case" + zooms.map { String(format: " | %.4g", $0) }.joined())
        for (name, st) in cases {
            let doc = Document(state: st, name: name), ref = flat(st)
            var row = "", newMax = 0
            for z in zooms {
                let r = shown(ref, z)
                CanvasRenderer.exactResampling = false
                let o = diff(r, shown(doc, z))
                CanvasRenderer.exactResampling = useNew
                let n = diff(r, shown(doc, z))
                row += String(format: " | %d/%.3f→%d/%.3f", o.max, o.mean, n.max, n.mean)
                newMax = max(newMax, n.max); worstNew = max(worstNew, n.max); worstOld = max(worstOld, o.max)
            }
            print("zoomfx \(name)" + row)
            check(newMax <= 3, "\(name): canvas matches the 100 % render at every zoom (max \(newMax)/255)")
            // pixels shown 1:1 at a whole-pixel offset are the composite itself
            let one = diff(shown(ref, 1, offset: .zero), shown(doc, 1, offset: .zero))
            check(one.max <= 2, "\(name): 1:1 view equals the composite (max \(one.max))")
        }
        print("zoomfx accuracy: worst old \(worstOld), worst new \(worstNew)")
        check(worstOld > 10, "the matrix detects the fused-resampling error of the old path (worst \(worstOld))")
    }

    static func shape(_ r: CGRect, _ c: String = "2E86DE", radius: Double = 18, _ fx: (inout LayerEffects) -> Void = { _ in }) -> Layer {
        var l = SelfTest.shapeLayer(r, RGBA(hex: c)!, radius: radius)
        fx(&l.effects)
        return l
    }

    static func doc(_ layers: [Layer], background: Bool = true) -> DocumentState {
        var st = SelfTest.baseState(640, 400)
        if !background { st.layers = [] }
        st.layers += layers
        return st
    }

    static func sharpImage(_ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        for i in 0..<12 {
            b.context.setFillColor((i % 2 == 0 ? RGBA(hex: "1B1F3A")! : RGBA(hex: "F1C40F")!).cgColor)
            b.context.fill(CGRect(x: i * w / 12, y: 0, width: w / 12, height: h))
        }
        b.context.setFillColor(RGBA(hex: "E94F37")!.cgColor)
        b.context.fillEllipse(in: CGRect(x: w / 4, y: h / 4, width: w / 2, height: h / 2))
        b.markDirty()
        return b
    }

    static func smart(_ r: CGRect, _ filters: [FilterInstance] = [], _ fx: (inout LayerEffects) -> Void = { _ in }) -> Layer {
        var so = SmartObjectContent(source: .image(sharpImage(Int(r.width), Int(r.height))), quad: Quad(rect: r))
        so.filters = filters
        var l = Layer(name: "Smart", content: .smartObject(so))
        fx(&l.effects)
        return l
    }

    static func syntheticCases() -> [(String, DocumentState)] {
        let R = CGRect(x: 170, y: 110, width: 300, height: 180)
        var c: [(String, DocumentState)] = []
        func fx(_ name: String, _ f: @escaping (inout LayerEffects) -> Void) { c.append((name, doc([shape(R, "2E86DE", radius: 18, f)]))) }
        fx("stroke-outside-12", { $0.stroke.enabled = true; $0.stroke.size = 12; $0.stroke.paint = .color(.black) })
        fx("stroke-inside-3", { $0.stroke.enabled = true; $0.stroke.size = 3; $0.stroke.position = .inside; $0.stroke.paint = .color(.white) })
        fx("stroke-center-1", { $0.stroke.enabled = true; $0.stroke.size = 1; $0.stroke.position = .center; $0.stroke.paint = .color(.black) })
        fx("stroke-outside-40-gradient", { $0.stroke.enabled = true; $0.stroke.size = 40; $0.stroke.paint = .gradient(GradientFill(gradient: ColorGradient.presets[2])) })
        fx("dropshadow-small", { $0.dropShadow.enabled = true; $0.dropShadow.size = 2; $0.dropShadow.distance = 3 })
        fx("dropshadow-large-spread", { $0.dropShadow.enabled = true; $0.dropShadow.size = 40; $0.dropShadow.spread = 50; $0.dropShadow.distance = 20; $0.dropShadow.opacity = 1 })
        fx("innershadow", { $0.innerShadow.enabled = true; $0.innerShadow.size = 12; $0.innerShadow.distance = 8 })
        fx("outerglow-soft", { $0.outerGlow.enabled = true; $0.outerGlow.size = 30; $0.outerGlow.blendMode = .normal; $0.outerGlow.color = RGBA(hex: "FFEE00")! })
        fx("outerglow-precise-spread", { $0.outerGlow.enabled = true; $0.outerGlow.technique = .precise; $0.outerGlow.size = 8; $0.outerGlow.spread = 60; $0.outerGlow.blendMode = .normal })
        fx("innerglow-center", { $0.innerGlow.enabled = true; $0.innerGlow.size = 25; $0.innerGlow.source = .center; $0.innerGlow.blendMode = .normal; $0.innerGlow.color = .white })
        fx("bevel-inner-chisel", { $0.bevel.enabled = true; $0.bevel.size = 10; $0.bevel.technique = .chiselHard })
        fx("bevel-outer", { $0.bevel.enabled = true; $0.bevel.size = 16; $0.bevel.style = .outerBevel })
        fx("emboss-pillow", { $0.bevel.enabled = true; $0.bevel.size = 6; $0.bevel.style = .pillowEmboss })
        fx("satin", { $0.satin.enabled = true; $0.satin.size = 14 })
        fx("overlays", { $0.colorOverlay.enabled = true; $0.colorOverlay.color = RGBA(hex: "27AE60")!; $0.gradientOverlay.enabled = true; $0.gradientOverlay.opacity = 0.6
            $0.gradientOverlay.blendMode = .overlay; $0.patternOverlay.enabled = true; $0.patternOverlay.patternID = "dots"; $0.patternOverlay.blendMode = .multiply })
        fx("stroke+shadow (fixture-like)", { $0.stroke.enabled = true; $0.stroke.size = 12; $0.stroke.paint = .color(.black); $0.dropShadow.enabled = true })
        fx("all-effects", { f in f.dropShadow.enabled = true; f.innerShadow.enabled = true; f.outerGlow.enabled = true; f.innerGlow.enabled = true
            f.bevel.enabled = true; f.satin.enabled = true; f.stroke.enabled = true; f.stroke.size = 5; f.colorOverlay.enabled = true; f.colorOverlay.opacity = 0.4 })
        // effects on other kinds of layer
        var text = TextContent(); text.text = "Zoom 37%"; text.fontSize = 96; text.position = CGPoint(x: 90, y: 120); text.color = RGBA(hex: "1B1F3A")!
        var tl = Layer(name: "Text", content: .text(text))
        tl.effects.stroke.enabled = true; tl.effects.stroke.size = 4; tl.effects.stroke.paint = .color(.white); tl.effects.dropShadow.enabled = true; tl.effects.dropShadow.size = 6
        c.append(("text-stroke-shadow", doc([tl])))
        c.append(("smart-object-fx", doc([smart(R) { $0.stroke.enabled = true; $0.stroke.size = 8; $0.dropShadow.enabled = true }])))
        var blur = FilterInstance(kind: .gaussianBlur); blur.values["radius"] = 2
        var bigBlur = FilterInstance(kind: .gaussianBlur); bigBlur.values["radius"] = 25
        c.append(("smart-filter-blur-2", doc([smart(R, [blur])])))
        c.append(("smart-filter-blur-25+stroke", doc([smart(R, [bigBlur]) { $0.stroke.enabled = true; $0.stroke.size = 6 }])))
        c.append(("smart-filter-unsharp", doc([smart(R, [FilterInstance(kind: .unsharpMask)])])))
        var g = Layer(name: "Group", content: .group(GroupContent(children: [shape(CGRect(x: 120, y: 90, width: 200, height: 160)), shape(CGRect(x: 320, y: 150, width: 200, height: 160), "E94F37")])))
        g.blendMode = .normal
        g.effects.outerGlow.enabled = true; g.effects.outerGlow.blendMode = .normal; g.effects.stroke.enabled = true; g.effects.stroke.size = 6; g.effects.stroke.paint = .color(.white)
        c.append(("group-fx", doc([g])))
        var clipped = Layer.raster(name: "clip", buffer: sharpImage(640, 400)); clipped.isClipped = true
        c.append(("clipping-on-fx-base", doc([shape(R) { $0.stroke.enabled = true; $0.stroke.size = 6; $0.dropShadow.enabled = true }, clipped])))
        // masks whose edges coincide with the content's
        var masked = Layer.raster(name: "masked", buffer: sharpImage(640, 400))
        let m = PixelBuffer(width: 640, height: 400, gray: 0)
        m.context.setFillColor(CGColor(gray: 1, alpha: 1)); m.context.fill(CGRect(x: 160.5, y: 100.25, width: 320, height: 200)); m.markDirty()
        masked.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0)
        masked.effects.stroke.enabled = true; masked.effects.stroke.size = 3
        c.append(("raster-mask+stroke", doc([masked])))
        var vm = Layer.raster(name: "vmask", buffer: sharpImage(640, 400)); vm.vectorMask = .ellipse(CGRect(x: 150, y: 80, width: 340, height: 240))
        c.append(("vector-mask", doc([vm])))
        // blend modes with coincident edges
        var mult = shape(R, "E94F37"); mult.blendMode = .multiply
        var scr = shape(R.insetBy(dx: 30, dy: 30), "27AE60"); scr.blendMode = .screen
        var ovl = shape(R.offsetBy(dx: 60, dy: 0), "8E44AD"); ovl.blendMode = .overlay; ovl.opacity = 0.7
        c.append(("blend-modes", doc([shape(R), mult, scr, ovl])))
        // an adjustment above effects, fill layers, knockout, a transparent document
        var hue = AdjustmentSettings(kind: .hueSaturation); hue.saturation = -40
        c.append(("adjustment-above-fx", doc([shape(R) { $0.stroke.enabled = true; $0.stroke.size = 12; $0.dropShadow.enabled = true }, Layer(name: "Adj", content: .adjustment(hue))])))
        var fill = Layer(name: "Fill", content: .fill(FillContent(paint: .color(RGBA(hex: "F1C40F")!)))); fill.vectorMask = .rect(R, radius: 30)
        fill.effects.stroke.enabled = true; fill.effects.stroke.size = 10; fill.effects.stroke.paint = .color(.black)
        var gfill = Layer(name: "Gradient Fill", content: .fill(FillContent(paint: .gradient(GradientFill(gradient: ColorGradient.presets[1]))))); gfill.opacity = 0.5; gfill.blendMode = .multiply
        c.append(("fill-layers", doc([gfill, fill])))
        var ko = shape(R.insetBy(dx: 40, dy: 40), "FFFFFF", radius: 40) { $0.stroke.enabled = true; $0.stroke.size = 4; $0.stroke.paint = .color(.white) }
        ko.knockout = .deep; ko.fillOpacity = 0
        c.append(("knockout", doc([shape(R), ko])))
        c.append(("transparent-doc", doc([shape(R) { $0.stroke.enabled = true; $0.stroke.size = 12; $0.dropShadow.enabled = true; $0.dropShadow.size = 20 }], background: false)))
        return c
    }

    // MARK: Rest cache (large documents) and previews

    static func restCache() {
        let prefs = AppModel.shared.prefs
        defer { AppModel.shared.prefs = prefs; CanvasRenderer.forget(nil) }
        AppModel.shared.prefs.cacheLargeDocuments = true
        AppModel.shared.prefs.largeDocumentThreshold = 0.1
        let d = Document(state: doc([shape(CGRect(x: 170, y: 40, width: 300, height: 180)) { $0.stroke.enabled = true; $0.stroke.size = 12; $0.stroke.paint = .color(.black); $0.dropShadow.enabled = true }], background: false), name: "rest")
        for _ in 0..<3 { _ = CanvasRenderer.cachedComposite(d) }
        check(CanvasRenderer.cachedTexture != nil, "a settled large document is kept as a GPU texture")
        let a = diff(shown(flat(d.state), 0.37), shown(d, 0.37))
        check(a.max <= 2, "the settled cache is exact at 0.37× (max \(a.max))")
        d.state.layers[0].effects.stroke.size = 30
        let b = diff(shown(flat(d.state), 0.37), shown(d, 0.37))
        check(b.max <= 2, "an edit bypasses the stale cache (max \(b.max) vs the edited document)")
        for _ in 0..<3 { _ = CanvasRenderer.cachedComposite(d) }
        CanvasRenderer.forget(d.id)
        check(CanvasRenderer.cachedTexture == nil, "closing the document releases the cached texture")
        for _ in 0..<3 { _ = CanvasRenderer.cachedComposite(d) }
        check(CanvasRenderer.cachedTexture != nil, "the cache is rebuilt after release")
        MemoryHygiene.relieve(critical: false)
        check(CanvasRenderer.cachedTexture == nil, "memory pressure releases the cached texture")
        // wider than a GPU texture can be: cached as a tiled CGImage instead
        var wide = SelfTest.baseState(16400, 24)
        wide.layers.append(shape(CGRect(x: 8000, y: 4, width: 300, height: 14), radius: 0) { $0.stroke.enabled = true; $0.stroke.size = 3; $0.stroke.paint = .color(.black) })
        let w = Document(state: wide, name: "wide")
        for _ in 0..<3 { _ = CanvasRenderer.cachedComposite(w) }
        let e = diff(shown(flat(wide), 0.37), shown(w, 0.37))
        check(CanvasRenderer.cachedTexture == nil && CanvasRenderer.cachedComposite(w) === CanvasRenderer.cachedComposite(w) && e.max <= 2, "a document beyond the texture limit is cached and shown exactly (max \(e.max))")
    }

    /// Live previews (content overrides, display overrides, hidden layers) still reach the canvas at reduced zoom.
    static func previews() {
        let st = doc([shape(CGRect(x: 170, y: 110, width: 300, height: 180)) { $0.stroke.enabled = true; $0.stroke.size = 12; $0.dropShadow.enabled = true }])
        let d = Document(state: st, name: "previews")
        let id = st.layers[1].id
        let before = shown(d, 0.37)
        d.contentOverrides[id] = { $0.applyingFilter("CIColorInvert") }
        d.setNeedsRender()
        let o = diff(before, shown(d, 0.37))
        check(o.max > 50, "a content override (filter / brush preview) shows at 0.37× (changed by \(o.max))")
        d.contentOverrides.removeAll(); d.hiddenLayers = [id]; d.setNeedsRender()
        var hidden = st; hidden.layers.remove(at: 1)
        let h = diff(shown(flat(hidden), 0.37), shown(d, 0.37))
        check(h.max <= 2, "hiding a layer for a preview is exact at 0.37× (max \(h.max))")
        d.hiddenLayers = []; d.displayOverride = { $0.applyingFilter("CIColorInvert") }; d.setNeedsRender()
        let v = diff(before, shown(d, 0.37))
        check(v.max > 50, "a display override (Select and Mask view) shows at 0.37× (changed by \(v.max))")
        d.displayOverride = nil
    }

    /// Before / after images of the fixture without its adjustment layer (where the old path was wrong).
    static func comparisonImages(_ st: DocumentState, _ dir: URL) {
        let d = Document(state: st, name: "fixture"), ref = flat(st)
        for z in [0.37, 0.5] as [CGFloat] {
            let r = shown(ref, z)
            CanvasRenderer.exactResampling = false
            let old = shown(d, z)
            CanvasRenderer.exactResampling = true
            let new = shown(d, z)
            for (n, b) in [("reference", r), ("old", old), ("new", new)] {
                var t = DocumentState(width: b.width, height: b.height); t.layers = [Layer.raster(name: n, buffer: b)]
                SelfTest.save(t, "zoomfx/fixture_\(z)_\(n)", dir.deletingLastPathComponent())
            }
            // the rectangle's corner, enlarged 4× (nearest) so the edge pixels are visible
            if let rect = st.layers.first(where: { $0.name == "Rectangle 1" }), let cb = Compositor.shared.contentBounds(rect, state: st) {
                let crop = IRect(x: Int(cb.maxX * z) - 40, y: Int(cb.maxY * z) - 40, width: 80, height: 80)
                for (n, b) in [("reference", r), ("old", old), ("new", new)] {
                    let sub = b.cropped(to: crop)
                    let big = sub.ciImage.samplingNearest().transformed(by: CGAffineTransform(scaleX: 4, y: 4))
                    var t = DocumentState(width: sub.width * 4, height: sub.height * 4)
                    t.layers = [Layer.raster(name: n, buffer: RenderEngine.renderBuffer(big, docRect: t.canvasRect, space: CanvasSpace(width: t.width, height: t.height)))]
                    SelfTest.save(t, "zoomfx/fixture_\(z)_corner_\(n)", dir.deletingLastPathComponent())
                }
            }
        }
        CanvasRenderer.exactResampling = useNew
    }

    // MARK: Performance

    static func paintLayer(_ w: Int, _ h: Int, _ name: String, seed: Int) -> Layer {
        let b = PixelBuffer(width: w, height: h)
        var rng = SeededRandom(seed: UInt64(seed))
        for _ in 0..<12 {
            b.context.setFillColor(RGBA(r: rng.next(), g: rng.next(), b: rng.next(), a: 0.4 + rng.next() * 0.6).cgColor)
            let d = CGFloat(w) * CGFloat(0.03 + rng.next() * 0.12)
            b.context.fillEllipse(in: CGRect(x: CGFloat(rng.next()) * CGFloat(w), y: CGFloat(rng.next()) * CGFloat(h), width: d, height: d * 0.7))
        }
        b.markDirty()
        return Layer.raster(name: name, buffer: b)
    }

    /// A busy document: paint layers, shapes and type with effects, multiply shapes.
    static func bigDoc(_ W: Int, _ H: Int, layers n: Int = 20) -> DocumentState {
        var st = SelfTest.baseState(W, H)
        let u = CGFloat(W) / 100
        var i = 0
        while st.layers.count < n {
            i += 1
            let x = CGFloat((i * 37) % 80) * u, y = CGFloat((i * 53) % 60) * u * CGFloat(H) / CGFloat(W)
            switch i % 5 {
            case 0: st.layers.append(paintLayer(W, H, "Paint \(i)", seed: i))
            case 1:
                var l = SelfTest.shapeLayer(CGRect(x: x, y: y, width: 18 * u, height: 12 * u), RGBA(hex: "2E86DE")!, radius: Double(u))
                l.effects.stroke.enabled = true; l.effects.stroke.size = Double(u) * 0.6; l.effects.stroke.paint = .color(.white)
                l.effects.dropShadow.enabled = true; l.effects.dropShadow.size = Double(u); l.effects.dropShadow.distance = Double(u) * 0.5
                st.layers.append(l)
            case 2:
                var l = SelfTest.shapeLayer(CGRect(x: x, y: y, width: 14 * u, height: 14 * u), RGBA(hex: "E94F37")!, radius: Double(7 * u))
                l.effects.outerGlow.enabled = true; l.effects.outerGlow.size = Double(u) * 1.5
                l.effects.bevel.enabled = true; l.effects.bevel.size = Double(u) * 0.5
                st.layers.append(l)
            case 3:
                var t = TextContent(); t.text = "Lumen \(i)"; t.fontSize = Double(6 * u); t.position = CGPoint(x: x, y: y); t.color = RGBA(hex: "1B1F3A")!
                var l = Layer(name: "Text \(i)", content: .text(t))
                l.effects.stroke.enabled = true; l.effects.stroke.size = Double(u) * 0.3; l.effects.stroke.position = .center; l.effects.stroke.paint = .color(.white)
                st.layers.append(l)
            default:
                var l = SelfTest.shapeLayer(CGRect(x: x, y: y, width: 20 * u, height: 8 * u), RGBA(hex: "27AE60")!, radius: 0)
                l.blendMode = .multiply; l.opacity = 0.8
                st.layers.append(l)
            }
        }
        if st.layers.count > 3 { st.layers.insert(paintLayer(W, H, "Paint 0", seed: 99), at: 2) }
        return st
    }

    /// One canvas frame (2× backing scale, like a Retina display) rendered and waited for; returns milliseconds.
    static func frame(_ d: Document, _ target: MTLTexture, legacy: Bool = false) -> Double {
        let s0 = CFAbsoluteTimeGetCurrent()
        let size = CGSize(width: target.width, height: target.height)
        let z = CGFloat(d.zoom)
        let t = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: d.viewOffset.x, ty: d.viewOffset.y)
        let img = (legacy ? Legacy.frame(d, docToView: t, viewHeight: size.height / 2, scale: 2, size: size) : CanvasRenderer.frame(d, docToView: t, viewHeight: size.height / 2, scale: 2, size: size))
            .composited(over: CIImage(color: CIColor(red: 0.157, green: 0.157, blue: 0.157)).cropped(to: CGRect(origin: .zero, size: size)))
        let cb = RenderEngine.commandQueue.makeCommandBuffer()!
        let dest = CIRenderDestination(mtlTexture: target, commandBuffer: cb)
        dest.colorSpace = sRGBSpace
        _ = try? RenderEngine.context.startTask(toRender: img, from: CGRect(origin: .zero, size: size), to: dest, at: .zero)
        cb.commit(); cb.waitUntilCompleted()
        return (CFAbsoluteTimeGetCurrent() - s0) * 1000
    }

    static func makeTarget() -> MTLTexture {
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2800, height: 1800, mipmapped: false)
        td.usage = [.shaderWrite, .shaderRead, .renderTarget]; td.storageMode = .private
        return RenderEngine.device.makeTexture(descriptor: td)!
    }

    /// Average / worst frame time of each interaction. `step(d, i)` changes the document or view before frame i.
    static func interactions(_ st: DocumentState, zoom: Double, frames n: Int = 30, legacy: Bool = false) -> [(String, Double, Double)] {
        let target = makeTarget()
        var out: [(String, Double, Double)] = []
        func measure(_ name: String, _ setup: (Document) -> Void = { _ in }, _ step: (Document, Int) -> Void) {
            Compositor.shared.clearCaches(); CanvasRenderer.forget(nil); Legacy.cache = nil; Legacy.pending = nil
            let d = Document(state: st, name: name)
            d.zoom = zoom; d.viewOffset = CGPoint(x: 20.37, y: 10.61)
            setup(d)
            for i in 0..<3 { step(d, -1 - i); _ = frame(d, target, legacy: legacy) }   // warm-up (caches, kernels)
            var sum = 0.0, worst = 0.0
            for i in 0..<n { step(d, i); let ms = frame(d, target, legacy: legacy); sum += ms; worst = max(worst, ms) }
            out.append((name, sum / Double(n), worst))
        }
        let fx = st.layers.firstIndex { $0.effects.stroke.enabled } ?? 1
        let paint = st.layers.firstIndex { $0.name.hasPrefix("Paint") }
        measure("idle redraw") { _, _ in }
        measure("pan") { d, i in d.viewOffset.x += 7.3; d.viewOffset.y += i % 2 == 0 ? 3.1 : -3.1 }
        measure("zoom") { d, i in d.zoom = zoom * (1 + 0.15 * sin(Double(i) / 4)) }
        if let p = paint {
            var stroke: PaintStroke?
            let dab = BrushTips.colored(BrushTips.mask(diameter: 40, hardness: 0.5, roundness: 1, angle: 0, tipID: "round")!, color: .red)!
            measure("paint stroke", { d in stroke = PaintStroke(doc: d, layerID: d.state.layers[p].id, target: .content, opacity: 1, blend: .normal) }) { _, i in
                stroke!.dab(dab, at: CGPoint(x: Double(st.width) * (0.2 + 0.01 * Double(i + 4)), y: Double(st.height) / 2), alpha: 1)
                stroke!.flush()
            }
        }
        measure("drag fx layer") { d, _ in d.state.updateLayer(d.state.layers[fx].id) { $0.translate(dx: 3, dy: 1) } }
        measure("scrub fx slider") { d, i in d.state.layers[fx].effects.stroke.size = 4 + Double((i + 10) % 20) }
        return out
    }

    /// Prints old-vs-new frame times for the report (`LUMEN_ZOOMFX_PERF=1`).
    static func perf() {
        for (label, st, zs) in [("typical 1600×1080", bigDoc(1600, 1080, layers: 8), [0.37, 0.25]), ("large 6000×4000, 20 layers", bigDoc(6000, 4000), [0.22, 0.4])] {
            for z in zs {
                let old = interactions(st, zoom: z, legacy: true)
                let new = interactions(st, zoom: z)
                for (o, n) in zip(old, new) {
                    print(String(format: "zoomfx perf %@ zoom %.2f (%.2f× on screen) %@: old %.1f ms (worst %.1f) → new %.1f ms (worst %.1f)", label, z, z * 2, o.0, o.1, o.2, n.1, n.2))
                }
            }
        }
    }

    /// Generous limits: the exact path must stay interactive on a typical document.
    static func perfCheck() {
        let st = bigDoc(1600, 1080, layers: 8)
        let old = interactions(st, zoom: 0.37, frames: 10, legacy: true)
        CanvasRenderer.exactResampling = useNew
        let new = interactions(st, zoom: 0.37, frames: 10)
        for (o, n) in zip(old, new) {
            check(n.1 < 100 && n.1 < o.1 * 2 + 8, String(format: "%@ stays interactive at 0.37× (old %.1f ms, new %.1f ms per frame)", n.0, o.1, n.1))
        }
    }

    /// The canvas as it was before exact resampling (live graph resampled directly; large documents cached as a
    /// CGImage), kept here as the timing baseline.
    enum Legacy {
        static var cache: (docID: UUID, version: Int, image: CIImage)?
        static var pending: (docID: UUID, version: Int, frames: Int)?

        static func cachedComposite(_ doc: Document) -> CIImage {
            let live = Compositor.shared.composite(doc)
            let prefs = AppModel.shared.prefs
            let mp = Double(doc.state.width * doc.state.height) / 1_000_000
            guard prefs.cacheLargeDocuments, mp >= prefs.largeDocumentThreshold else { return live }
            let v = doc.renderVersion
            if let c = cache, c.docID == doc.id, c.version == v { return c.image }
            if let p = pending, p.docID == doc.id, p.version == v {
                if p.frames >= 1 {
                    let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
                    let fmt: CIFormat = doc.state.bitDepth == .eight ? .RGBA8 : .RGBAh
                    if let cg = RenderEngine.context.createCGImage(live, from: space.ciCanvas, format: fmt, colorSpace: sRGBSpace) {
                        let img = CIImage(cgImage: cg)
                        cache = (doc.id, v, img); pending = nil
                        return img
                    }
                }
                pending = (doc.id, v, p.frames + 1)
            } else {
                pending = (doc.id, v, 0)
            }
            return live
        }

        static func frame(_ doc: Document, docToView: CGAffineTransform, viewHeight viewH: CGFloat, scale s: CGFloat, size: CGSize) -> CIImage {
            let full = CGRect(origin: .zero, size: size)
            let z = CGFloat(doc.zoom)
            let H = CGFloat(doc.state.height), W = CGFloat(doc.state.width)
            let ciToDoc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
            let viewToDrawable = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: s * viewH)
            let t = ciToDoc.concatenating(docToView).concatenating(viewToDrawable)
            let ciCanvas = CGRect(x: 0, y: 0, width: W, height: H)
            let rotated = abs(doc.viewRotation) > 0.0001
            let canvasRect = ciCanvas.applying(t)
            let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
                "inputCenter": CIVector(x: canvasRect.minX, y: canvasRect.maxY), "inputColor0": CIColor(red: 1, green: 1, blue: 1),
                "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8), "inputWidth": CGFloat(AppModel.shared.prefs.checkerSize) * s, "inputSharpness": 1,
            ])!.outputImage!.cropped(to: canvasRect)
            var comp = cachedComposite(doc)
            comp = CanvasRenderer.applyViewMode(comp, doc: doc).cropped(to: ciCanvas)
            let scaled = z >= 2 && !rotated ? comp.samplingNearest().transformed(by: t) : comp.transformed(by: t, highQualityDownsample: z < 1)
            let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5)).cropped(to: ciCanvas).transformed(by: t)
                .applyingGaussianBlur(sigma: 5 * s).cropped(to: full)
            return scaled.cropped(to: canvasRect).composited(over: checker).composited(over: shadow)
        }
    }
}
