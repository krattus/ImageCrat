import AppKit
import Metal
import CoreImage
import ImageCratCore

/// Headless render tests: `Lumen --selftest <outdir>` writes PNGs of feature samples and exits.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: args[i + 1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        FeatureModules.registerAll()
        run(out)
        print("beeps silenced during this run: \(Beep.suppressedCount)")   // App/Beep.swift: none reached the speakers
        print("SELFTEST COMPLETE")   // a log without this line ended early (crash, or the app quit mid-run)
        exit(0)
    }

    static func baseState(_ w: Int = 480, _ h: Int = 300) -> DocumentState {
        var st = DocumentState(width: w, height: h)
        let bg = PixelBuffer(width: w, height: h)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "8EC5FC")!.cgColor, RGBA(hex: "E0C3FC")!.cgColor] as CFArray, locations: [0, 1])!
        bg.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        bg.markDirty()
        st.layers = [Layer.raster(name: "Background", buffer: bg)]
        return st
    }

    static func shapeLayer(_ r: CGRect, _ color: RGBA = RGBA(hex: "E94F37")!, radius: Double = 24) -> Layer {
        Layer(name: "Shape", content: .shape(ShapeContent(geometry: .rectangle(r, cornerRadius: radius), fill: .color(color))))
    }

    static func save(_ st: DocumentState, _ name: String, _ out: URL) {
        let url = out.appendingPathComponent(name + ".png")
        do { try DocumentIO.export(st, to: url, format: .png, quality: 1, scale: 1) } catch { print("FAIL \(name): \(error)") }
        print("wrote \(name)")
    }

    static func run(_ out: URL) {
        // Every suite runs inside `SelfTestSuites.run`, which tears down what the suite left behind (robot canvases,
        // offscreen windows, hosting views, open documents) so memory and SwiftUI graph state stay bounded over the run.
        SelfTestSuites.run("type") { runTypeTests(out) }
        SelfTestSuites.run("core") { runCoreRenders(out) }
        SelfTestSuites.run("workflow") { runWorkflowTests(out) }
        SelfTestSuites.run("animation") { runAnimationTests(out) }
        SelfTestSuites.run("adjust") { AdjustSelfTest.run(out) }
        SelfTestSuites.run("brush") { BrushSelfTest.run(out) }
        for (name, t) in FeatureModules.selfTests where ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"].map({ name.hasPrefix($0) }) ?? true {
            SelfTestSuites.run(name) { t(out) }
        }
        SelfTestSuites.summary()
        print("done")
    }

    /// Effects, blending, text, blend modes, adjustments, filters, smart objects, selections, warps, Liquify, Camera Raw renders.
    static func runCoreRenders(_ out: URL) {
        // Effects
        var effects: [(String, (inout LayerEffects) -> Void)] = [
            ("fx_dropshadow", { $0.dropShadow.enabled = true; $0.dropShadow.distance = 12; $0.dropShadow.size = 14 }),
            ("fx_innershadow", { $0.innerShadow.enabled = true; $0.innerShadow.distance = 8; $0.innerShadow.size = 10 }),
            ("fx_outerglow", { $0.outerGlow.enabled = true; $0.outerGlow.size = 24; $0.outerGlow.color = RGBA(hex: "FFEE00")!; $0.outerGlow.blendMode = .normal }),
            ("fx_innerglow", { $0.innerGlow.enabled = true; $0.innerGlow.size = 20; $0.innerGlow.color = .white; $0.innerGlow.blendMode = .normal }),
            ("fx_bevel", { $0.bevel.enabled = true; $0.bevel.size = 12 }),
            ("fx_emboss", { $0.bevel.enabled = true; $0.bevel.size = 10; $0.bevel.style = .pillowEmboss }),
            ("fx_satin", { $0.satin.enabled = true }),
            ("fx_gradient", { $0.gradientOverlay.enabled = true; $0.gradientOverlay.fill.gradient = ColorGradient.presets[2] }),
            ("fx_pattern", { $0.patternOverlay.enabled = true; $0.patternOverlay.patternID = "dots"; $0.patternOverlay.blendMode = .multiply }),
            ("fx_stroke", { $0.stroke.enabled = true; $0.stroke.size = 6; $0.stroke.paint = .color(.white) }),
        ]
        effects.append(("fx_stack_overlay_innershadow", { fx in
            fx.colorOverlay.enabled = true; fx.colorOverlay.color = RGBA(hex: "2E86DE")!
            fx.innerShadow.enabled = true; fx.innerShadow.distance = 10; fx.innerShadow.size = 12
        }))
        effects.append(("fx_stack_full", { fx in
            fx.colorOverlay.enabled = true; fx.colorOverlay.color = RGBA(hex: "27AE60")!
            fx.innerShadow.enabled = true; fx.innerGlow.enabled = true; fx.innerGlow.color = .white; fx.innerGlow.blendMode = .screen
            fx.satin.enabled = true; fx.satin.opacity = 0.3
            fx.bevel.enabled = true; fx.stroke.enabled = true; fx.stroke.size = 4; fx.dropShadow.enabled = true; fx.outerGlow.enabled = true
        }))
        effects.append(("fx_multi_instances", { fx in
            fx.stroke.enabled = true; fx.stroke.size = 4; fx.stroke.paint = .color(.white)
            var s2 = fx.stroke; s2.size = 10; s2.paint = .color(RGBA(hex: "1B1F3A")!); fx.extraStrokes = [s2]
            fx.dropShadow.enabled = true; fx.dropShadow.distance = 8; fx.dropShadow.size = 4
            var d2 = fx.dropShadow; d2.distance = 25; d2.size = 20; d2.color = RGBA(hex: "8E44AD")!; d2.opacity = 0.6; fx.extraDropShadows = [d2]
            fx.colorOverlay.enabled = true; fx.colorOverlay.color = RGBA(hex: "F1C40F")!
            var c2 = fx.colorOverlay; c2.color = RGBA(hex: "E74C3C")!; c2.blendMode = .multiply; c2.opacity = 0.5; fx.extraColorOverlays = [c2]
        }))
        effects.append(("fx2_ring_contour_glow", { fx in
            fx.outerGlow.enabled = true; fx.outerGlow.size = 40; fx.outerGlow.contour = Contour(preset: .ringDouble); fx.outerGlow.blendMode = .normal; fx.outerGlow.opacity = 1
        }))
        effects.append(("fx2_gradient_glow_noise", { fx in
            fx.outerGlow.enabled = true; fx.outerGlow.size = 45; fx.outerGlow.useGradient = true; fx.outerGlow.blendMode = .normal; fx.outerGlow.opacity = 1
            fx.outerGlow.gradient = ColorGradient(name: "g", stops: [GradientStop(location: 0, color: RGBA(hex: "FFEB3B")!), GradientStop(location: 0.5, color: RGBA(hex: "FF5722")!), GradientStop(location: 1, color: RGBA(hex: "9C27B0")!.withAlpha(0))])
            fx.dropShadow.enabled = true; fx.dropShadow.noise = 40; fx.dropShadow.size = 20
        }))
        effects.append(("fx2_precise_glow_cone", { fx in
            fx.outerGlow.enabled = true; fx.outerGlow.technique = .precise; fx.outerGlow.size = 30; fx.outerGlow.contour = Contour(preset: .cone); fx.outerGlow.blendMode = .normal; fx.outerGlow.opacity = 1; fx.outerGlow.color = .white
            fx.innerGlow.enabled = true; fx.innerGlow.technique = .precise; fx.innerGlow.size = 25; fx.innerGlow.color = .white; fx.innerGlow.blendMode = .normal
        }))
        effects.append(("fx2_bevel_texture_gloss", { fx in
            fx.bevel.enabled = true; fx.bevel.size = 14; fx.bevel.textureEnabled = true; fx.bevel.texturePatternID = "bricks"; fx.bevel.textureDepth = 200
            fx.bevel.glossContour = Contour(preset: .ring); fx.bevel.contourEnabled = true; fx.bevel.contour = Contour(preset: .cove)
        }))
        effects.append(("fx_all", { fx in
            fx.dropShadow.enabled = true; fx.bevel.enabled = true; fx.stroke.enabled = true; fx.gradientOverlay.enabled = true; fx.gradientOverlay.opacity = 0.6; fx.gradientOverlay.blendMode = .overlay
        }))
        for (name, f) in effects {
            var st = baseState()
            var l = shapeLayer(CGRect(x: 120, y: 70, width: 240, height: 160))
            f(&l.effects)
            st.layers.append(l)
            save(st, name, out)
        }

        // Advanced blending: Blend If, knockout, global light
        do {
            var st = baseState()
            var dark = shapeLayer(CGRect(x: 30, y: 30, width: 200, height: 240), RGBA(hex: "111111")!, radius: 0)
            dark.name = "dark"
            st.layers.append(dark)
            var top = shapeLayer(CGRect(x: 120, y: 60, width: 320, height: 180), RGBA(hex: "E94F37")!)
            top.blendIf.underLow = [60, 120]   // hide where the underlying layer is dark
            st.layers.append(top)
            save(st, "blendif_under", out)
            // knockout
            var st2 = baseState()
            st2.layers.append(shapeLayer(CGRect(x: 40, y: 40, width: 400, height: 220), RGBA(hex: "2E86DE")!, radius: 10))
            var ko = shapeLayer(CGRect(x: 140, y: 90, width: 200, height: 120), .white, radius: 60)
            ko.knockout = .deep; ko.fillOpacity = 0; ko.effects.stroke.enabled = true; ko.effects.stroke.size = 4; ko.effects.stroke.paint = .color(.white)
            st2.layers.append(ko)
            save(st2, "knockout_deep", out)
            // global light: two shadows that follow the document light
            var st3 = baseState()
            st3.globalLight = GlobalLight(angle: 45, altitude: 30)
            var a = shapeLayer(CGRect(x: 60, y: 80, width: 140, height: 140)); a.effects.dropShadow.enabled = true; a.effects.dropShadow.distance = 16
            var b = shapeLayer(CGRect(x: 280, y: 80, width: 140, height: 140), RGBA(hex: "27AE60")!); b.effects.bevel.enabled = true; b.effects.bevel.size = 12
            st3.layers += [a, b]
            save(st3, "global_light_45", out)
        }

        // Text
        do {
            var st = baseState()
            var t = TextContent()
            t.text = "Lumen Type\nSecond line"
            t.fontName = "Helvetica-Bold"; t.fontSize = 56; t.color = RGBA(hex: "1B1F3A")!
            t.position = CGPoint(x: 40, y: 60)
            var l = Layer(name: "Text", content: .text(t))
            l.effects.dropShadow.enabled = true
            st.layers.append(l)
            var t2 = t
            t2.text = "Rotated"; t2.fontSize = 30; t2.color = .white; t2.position = CGPoint(x: 300, y: 200)
            t2.transform = CGAffineTransform(translationX: 330, y: 215).rotated(by: -0.4).translatedBy(x: -330, y: -215)
            st.layers.append(Layer(name: "T2", content: .text(t2)))
            save(st, "text", out)
        }

        // Blend modes
        for m in [BlendMode.multiply, .screen, .overlay, .difference, .color, .hardMix, .dissolve] {
            var st = baseState()
            var l = shapeLayer(CGRect(x: 60, y: 40, width: 360, height: 220), RGBA(hex: "2E86DE")!)
            l.blendMode = m
            l.opacity = m == .dissolve ? 0.5 : 1
            st.layers.append(l)
            save(st, "blend_\(m.rawValue)", out)
        }

        // Adjustments
        for k in [AdjustmentKind.hueSaturation, .curves, .blackWhite, .gradientMap, .colorBalance, .invert, .threshold, .colorLookup] {
            var st = baseState()
            st.layers.append(shapeLayer(CGRect(x: 60, y: 60, width: 160, height: 160), RGBA(hex: "27AE60")!))
            var s = AdjustmentSettings(kind: k)
            s.hue = 120; s.hsSaturation = 40
            s.curves[0].points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.15), CGPoint(x: 0.7, y: 0.9), CGPoint(x: 1, y: 1)]
            s.midtones.cyanRed = 60
            s.gradient = ColorGradient.presets[3]
            var l = Layer(name: "Adj", content: .adjustment(s))
            // mask: right half only
            let m = PixelBuffer(width: st.width, height: st.height, format: .gray)
            m.context.setFillColor(gray: 1, alpha: 1); m.context.fill(CGRect(x: 140, y: 0, width: 400, height: 300)); m.markDirty()
            l.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0)
            st.layers.append(l)
            save(st, "adj_\(k.rawValue)", out)
        }

        // Filters on a photo-like background
        for k in [FilterKind.gaussianBlur, .motionBlur, .radialBlur, .twirl, .ripple, .polarCoordinates, .mosaic, .crystallize, .emboss, .findEdges, .oilPaint, .clouds, .lensFlare, .addNoise, .highPass, .unsharpMask, .spinBlur, .tiltShift, .wind, .kaleidoscope, .colorHalftone] {
            var st = baseState()
            st.layers.append(shapeLayer(CGRect(x: 140, y: 80, width: 200, height: 140), RGBA(hex: "F6AE2D")!))
            let sp = CanvasSpace(width: st.width, height: st.height)
            let img = Compositor.shared.composite(st)
            let f = FilterInstance(kind: k, colors: [.black, .white])
            let res = f.apply(img, canvas: sp.ciCanvas)
            let buf = RenderEngine.renderBuffer(res, docRect: st.canvasRect, space: sp)
            var s2 = DocumentState(width: st.width, height: st.height)
            s2.layers = [Layer.raster(name: "F", buffer: buf)]
            save(s2, "filter_\(k.rawValue)", out)
        }

        // Smart object with transform + smart filter + clipping + group
        do {
            var st = baseState()
            var inner = DocumentState(width: 200, height: 200)
            inner.layers = [shapeLayer(CGRect(x: 10, y: 10, width: 180, height: 180), RGBA(hex: "8E44AD")!, radius: 90)]
            var so = SmartObjectContent(source: .document(inner), quad: Quad(tl: CGPoint(x: 60, y: 40), tr: CGPoint(x: 260, y: 70), br: CGPoint(x: 240, y: 260), bl: CGPoint(x: 40, y: 230)))
            so.filters = [FilterInstance(kind: .gaussianBlur)]
            st.layers.append(Layer(name: "SO", content: .smartObject(so)))
            // group with clipped layer
            var base = shapeLayer(CGRect(x: 290, y: 60, width: 160, height: 180), RGBA(hex: "FFFFFF")!, radius: 80)
            base.name = "Base"
            var clipped = Layer(name: "Clip", content: .fill(FillContent(paint: .gradient(GradientFill(gradient: ColorGradient.presets[2], angle: 45)))))
            clipped.isClipped = true
            var g = Layer(name: "Group", content: .group(GroupContent(children: [base, clipped])))
            g.blendMode = .normal
            g.effects.dropShadow.enabled = true
            _ = g
            st.layers.append(g)
            save(st, "smart_group_clip", out)

            // PSD roundtrip
            let psd = out.appendingPathComponent("roundtrip.psd")
            do {
                try PSDWriter.write(st, to: psd)
                let back = try PSDReader.read(url: psd)
                print("PSD layers read back: \(back.layers.count) top-level, names: \(back.layers.map(\.name))")
                save(back, "psd_roundtrip", out)
            } catch { print("PSD FAIL \(error)") }
            // Native roundtrip
            let nat = out.appendingPathComponent("roundtrip.imagecrat")
            do {
                let d = Document(state: st, name: "t")
                try DocumentIO.saveNative(d, to: nat)
                let back = try DocumentIO.load(url: nat)
                save(back.state, "native_roundtrip", out)
            } catch { print("NATIVE FAIL \(error)") }
        }

        // Selection ops + transforms
        do {
            var st = baseState()
            let sel = SelectionOps.mask(fromPath: CGPath(ellipseIn: CGRect(x: 100, y: 50, width: 280, height: 200), transform: nil), width: st.width, height: st.height)
            let outline = SelectionOps.outline(sel)
            print("outline bbox \(outline.boundingBoxOfPath)")
            let sp = CanvasSpace(width: st.width, height: st.height)
            var l = shapeLayer(CGRect(x: 100, y: 80, width: 200, height: 120), RGBA(hex: "16A085")!)
            let h = Homography(from: Quad(rect: CGRect(x: 100, y: 80, width: 200, height: 120)),
                               to: Quad(tl: CGPoint(x: 150, y: 60), tr: CGPoint(x: 330, y: 90), br: CGPoint(x: 380, y: 250), bl: CGPoint(x: 80, y: 220)))!
            l = LayerTransformer.apply(h, to: l, space: sp)
            var r = Compositor.shared.rasterize(shapeLayer(CGRect(x: 20, y: 20, width: 80, height: 80), .black), state: st)
            let (wb, wo) = LayerTransformer.warpBuffer(r.buffer, origin: r.origin, h: Homography(affine: CGAffineTransform(rotationAngle: 0.3)), space: sp)
            r.buffer = wb; r.origin = wo
            st.layers.append(l)
            st.layers.append(Layer(name: "R", content: .raster(r)))
            save(st, "transforms", out)
        }
        // Warps (sessions) on a checker-ish raster
        do {
            func makeDoc() -> (Document, UUID) {
                var st = baseState()
                let b = PixelBuffer(width: 240, height: 160)
                for y in 0..<8 { for x in 0..<12 {
                    b.context.setFillColor(((x + y) % 2 == 0 ? RGBA(hex: "2C3E50")! : RGBA(hex: "F39C12")!).cgColor)
                    b.context.fill(CGRect(x: x * 20, y: y * 20, width: 20, height: 20))
                } }
                b.markDirty()
                let l = Layer.raster(name: "Checker", buffer: b, origin: IPoint(x: 120, y: 70))
                st.layers.append(l)
                return (Document(state: st, name: "w"), l.id)
            }
            var (d, id) = makeDoc()
            if let w = WarpSession(doc: d, layerID: id) { w.style = .arc; w.bend = 0.6; w.commit() }
            save(d.state, "warp_arc", out)
            (d, id) = makeDoc()
            if let w = WarpSession(doc: d, layerID: id) { w.style = .flag; w.bend = 0.8; w.commit() }
            save(d.state, "warp_flag", out)
            (d, id) = makeDoc()
            if let p = PuppetWarpSession(doc: d, layerID: id) {
                p.pins = [(CGPoint(x: 130, y: 150), CGPoint(x: 130, y: 150)), (CGPoint(x: 350, y: 150), CGPoint(x: 330, y: 240)), (CGPoint(x: 240, y: 90), CGPoint(x: 240, y: 60))]
                p.commit()
            }
            save(d.state, "warp_puppet", out)
            (d, id) = makeDoc()
            if let pw = PerspectiveWarpSession(doc: d, layerID: id) {
                pw.split(horizontal: true)
                pw.mode = .warp
                pw.warped[0].y += 30; pw.warped[3].y -= 30; pw.warped[2].x -= 20; pw.warped[5].x -= 20
                pw.commit()
            }
            save(d.state, "warp_perspective", out)
            (d, id) = makeDoc()
            if let c = ContentAwareScaleSession(doc: d, layerID: id) { c.target = CGRect(x: 120, y: 70, width: 150, height: 160); c.commit() }
            save(d.state, "content_aware_scale", out)
            // new filters
            var fs = baseState()
            fs.layers.append(shapeLayer(CGRect(x: 140, y: 80, width: 200, height: 140), RGBA(hex: "F6AE2D")!))
            let sp = CanvasSpace(width: fs.width, height: fs.height)
            let img = Compositor.shared.composite(fs)
            var instances: [(String, FilterInstance)] = []
            var lc = FilterInstance(kind: .lensCorrection); lc.values["distortion"] = -60; lc.values["vignette"] = -60; instances.append(("lens", lc))
            instances.append(("smartsharpen", FilterInstance(kind: .smartSharpen)))
            var sb = FilterInstance(kind: .surfaceBlur); sb.values["radius"] = 20; instances.append(("surfaceblur", sb))
            var fb = FilterInstance(kind: .fieldBlur); fb.points = [FilterPin(x: 0.2, y: 0.5, value: 0), FilterPin(x: 0.8, y: 0.5, value: 25)]; instances.append(("fieldblur", fb))
            var ib = FilterInstance(kind: .irisBlur); ib.points = [FilterPin(x: 0.5, y: 0.5, value: 0)]; ib.values["blur"] = 20; instances.append(("irisblur", ib))
            var pb = FilterInstance(kind: .pathBlur); pb.points = [FilterPin(x: 0.2, y: 0.8, value: 0), FilterPin(x: 0.8, y: 0.2, value: 0)]; instances.append(("pathblur", pb))
            var gal = FilterInstance(kind: .filterGallery); gal.gallery = [GalleryEntry(.watercolor), GalleryEntry(.texturizer)]; instances.append(("gallery_stack", gal))
            for (n, f) in instances {
                var s2 = DocumentState(width: fs.width, height: fs.height)
                s2.layers = [Layer.raster(name: "F", buffer: RenderEngine.renderBuffer(f.apply(img, canvas: sp.ciCanvas), docRect: fs.canvasRect, space: sp))]
                save(s2, "filter2_\(n)", out)
            }
        }

        // Liquify: push right at the top-left region only
        do {
            var st = baseState()
            st.layers.append(shapeLayer(CGRect(x: 60, y: 40, width: 360, height: 60), RGBA(hex: "2C3E50")!, radius: 0))
            st.layers.append(shapeLayer(CGRect(x: 60, y: 200, width: 360, height: 60), RGBA(hex: "C0392B")!, radius: 0))
            let sp = CanvasSpace(width: st.width, height: st.height)
            let f = DisplacementField(width: st.width, height: st.height)
            for i in 0..<20 { f.apply(mode: .forward, center: CGPoint(x: 150 + i * 4, y: 70), delta: CGPoint(x: 4, y: 0), radius: 60, pressure: 1) }
            f.apply(mode: .twirlCW, center: CGPoint(x: 300, y: 230), delta: .zero, radius: 80, pressure: 1)
            for _ in 0..<15 { f.apply(mode: .twirlCW, center: CGPoint(x: 300, y: 230), delta: .zero, radius: 80, pressure: 1) }
            let warped = f.warp(Compositor.shared.composite(st), space: sp)
            var s2 = DocumentState(width: st.width, height: st.height)
            s2.layers = [Layer.raster(name: "L", buffer: RenderEngine.renderBuffer(warped, docRect: st.canvasRect, space: sp))]
            save(s2, "liquify", out)
            let raw = FilterInstance(kind: .cameraRaw)
            var r2 = raw
            r2.values["temp"] = 60; r2.values["clarity"] = 60; r2.values["vignette"] = 60; r2.values["dehaze"] = 40
            let res = r2.apply(Compositor.shared.composite(st), canvas: sp.ciCanvas)
            s2.layers = [Layer.raster(name: "L", buffer: RenderEngine.renderBuffer(res, docRect: st.canvasRect, space: sp))]
            save(s2, "camera_raw", out)
        }
    }
}

enum PerfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--perftest") else { return }
        let W = 6000, H = 4000
        var st = SelfTest.baseState(W, H)
        st.layers.append(Layer.raster(name: "Paint", width: W, height: H))
        var fxl = SelfTest.shapeLayer(CGRect(x: 1000, y: 1000, width: 3000, height: 1500))
        fxl.effects.dropShadow.enabled = true; fxl.effects.bevel.enabled = true; fxl.effects.stroke.enabled = true
        st.layers.append(fxl)
        let d = Document(state: st, name: "perf")
        let paintID = st.layers[1].id
        func t(_ label: String, _ f: () -> Void) {
            let s = CFAbsoluteTimeGetCurrent(); f(); print(label, String(format: "%.1f ms", (CFAbsoluteTimeGetCurrent() - s) * 1000))
        }
        func renderView() {
            let comp = Compositor.shared.composite(d)
            let z: CGFloat = 0.25
            let img = comp.transformed(by: CGAffineTransform(scaleX: z, y: z), highQualityDownsample: true)
            let tex = RenderEngine.device.makeTexture(descriptor: {
                let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1500, height: 1000, mipmapped: false)
                td.usage = [.shaderWrite, .shaderRead, .renderTarget]; return td }())!
            let cb = RenderEngine.commandQueue.makeCommandBuffer()!
            RenderEngine.context.render(img, to: tex, commandBuffer: cb, bounds: CGRect(x: 0, y: 0, width: 1500, height: 1000), colorSpace: sRGBSpace)
            cb.commit(); cb.waitUntilCompleted()
        }
        t("first render", renderView)
        t("second render", renderView)
        var stroke: PaintStroke?
        t("begin stroke (clone 96MB)") { stroke = PaintStroke(doc: d, layerID: paintID, target: .content, opacity: 1, blend: .normal) }
        let m = BrushTips.mask(diameter: 60, hardness: 0.5, roundness: 1, angle: 0, tipID: "round")!
        let dab = BrushTips.colored(m, color: .red)!
        t("60 dab+flush+render frames") {
            for i in 0..<60 {
                stroke!.dab(dab, at: CGPoint(x: 500 + i * 40, y: 2000), alpha: 1)
                stroke!.flush()
                renderView()
            }
        }
        t("60 renders, no change") { for _ in 0..<60 { renderView() } }
        t("60 dabs+flush only") { for i in 0..<60 { stroke!.dab(dab, at: CGPoint(x: 500 + i * 40, y: 2100), alpha: 1); stroke!.flush() } }
        t("60 renders w/ new override each") { for _ in 0..<60 { stroke!.dab(dab, at: CGPoint(x: 500, y: 2200), alpha: 1); stroke!.flush(); renderView() } }
        d.state.layers[2].effects = LayerEffects()
        t("60 frames no fx layer") { for _ in 0..<60 { stroke!.dab(dab, at: CGPoint(x: 500, y: 2200), alpha: 1); stroke!.flush(); renderView() } }
        t("finish") { stroke!.finish(name: "Brush") }
        t("thumbnail") { _ = Thumbnails.shared.layer(d.state.layers[1], doc: d, size: 30) }
        BrushSelfTest.perf()
        TabletSelfTest.perf(quick: false)   // 300 px soft brush, tablet reports through the canvas event path
        exit(0)
    }
}
