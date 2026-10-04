import AppKit
import SwiftUI
import CoreImage
import ImageCratCore

/// Headless tests for the Edits module (`LUMEN_SELFTEST_ONLY=edits`).
enum EditsSelfTests {
    static func register() {
        FeatureModules.selfTests.append(("edits_adjust", adjustments))
        FeatureModules.selfTests.append(("edits_matting", matting))
        FeatureModules.selfTests.append(("edits_colorrange", colorRange))
        FeatureModules.selfTests.append(("edits_caf", contentAwareFill))
        FeatureModules.selfTests.append(("edits_clonesource", cloneSource))
        FeatureModules.selfTests.append(("edits_vp", vanishingPoint))
        FeatureModules.selfTests.append(("edits_warp", splitWarp))
        FeatureModules.selfTests.append(("edits_resample", resample))
        FeatureModules.selfTests.append(("edits_lens", lensProfiles))
        FeatureModules.selfTests.append(("edits_awa", adaptiveWideAngle))
        FeatureModules.selfTests.append(("edits_ui", uiSnapshots))
    }

    // MARK: Helpers

    /// A synthetic "photo": sky, sun, hills, a house, a checker board, text and a skin-toned face.
    static func scene(_ w: Int = 480, _ h: Int = 320) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let ctx = b.context
        let W = CGFloat(w), H = CGFloat(h)
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "4A7FC1")!.cgColor, RGBA(hex: "CFE3F2")!.cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: H * 0.6), options: [.drawsAfterEndLocation])
        ctx.setFillColor(RGBA(hex: "FFE9A8")!.cgColor)
        ctx.fillEllipse(in: CGRect(x: W * 0.72, y: H * 0.08, width: H * 0.16, height: H * 0.16))
        // hills
        ctx.setFillColor(RGBA(hex: "5E8C3A")!.cgColor)
        let hill = CGMutablePath()
        hill.move(to: CGPoint(x: 0, y: H * 0.62))
        for i in 0...40 {
            let x = W * CGFloat(i) / 40
            hill.addLine(to: CGPoint(x: x, y: H * (0.58 + 0.06 * sin(Double(i) * 0.35))))
        }
        hill.addLine(to: CGPoint(x: W, y: H)); hill.addLine(to: CGPoint(x: 0, y: H)); hill.closeSubpath()
        ctx.addPath(hill); ctx.fillPath()
        ctx.setFillColor(RGBA(hex: "3B5E23")!.cgColor)
        ctx.fill(CGRect(x: 0, y: H * 0.8, width: W, height: H * 0.2))
        // grass texture (deterministic)
        var seed: UInt32 = 12345
        func rnd() -> CGFloat { seed = seed &* 1664525 &+ 1013904223; return CGFloat(seed >> 8) / CGFloat(1 << 24) }
        for _ in 0..<900 {
            let x = rnd() * W, y = H * (0.64 + 0.36 * rnd())
            ctx.setFillColor(RGBA(r: 0.2 + 0.25 * Double(rnd()), g: 0.35 + 0.3 * Double(rnd()), b: 0.12, a: 1).cgColor)
            ctx.fill(CGRect(x: x, y: y, width: 1.5 + rnd() * 2, height: 3 + rnd() * 5))
        }
        // house
        ctx.setFillColor(RGBA(hex: "B5462F")!.cgColor)
        ctx.fill(CGRect(x: W * 0.12, y: H * 0.45, width: W * 0.18, height: H * 0.25))
        ctx.setFillColor(RGBA(hex: "2B2B2B")!.cgColor)
        let roof = CGMutablePath()
        roof.move(to: CGPoint(x: W * 0.1, y: H * 0.45)); roof.addLine(to: CGPoint(x: W * 0.21, y: H * 0.33)); roof.addLine(to: CGPoint(x: W * 0.32, y: H * 0.45)); roof.closeSubpath()
        ctx.addPath(roof); ctx.fillPath()
        ctx.setFillColor(RGBA(hex: "F4E7B0")!.cgColor)
        ctx.fill(CGRect(x: W * 0.16, y: H * 0.52, width: W * 0.04, height: H * 0.06))
        ctx.fill(CGRect(x: W * 0.23, y: H * 0.52, width: W * 0.04, height: H * 0.06))
        // checker board
        for j in 0..<6 { for i in 0..<6 where (i + j) % 2 == 0 {
            ctx.setFillColor(RGBA(gray: 0.1).cgColor)
            ctx.fill(CGRect(x: W * 0.42 + CGFloat(i) * 10, y: H * 0.66 + CGFloat(j) * 10, width: 10, height: 10))
        } }
        for j in 0..<6 { for i in 0..<6 where (i + j) % 2 == 1 {
            ctx.setFillColor(RGBA(gray: 0.95).cgColor)
            ctx.fill(CGRect(x: W * 0.42 + CGFloat(i) * 10, y: H * 0.66 + CGFloat(j) * 10, width: 10, height: 10))
        } }
        // face
        ctx.setFillColor(RGBA(hex: "E0AC8A")!.cgColor)
        ctx.fillEllipse(in: CGRect(x: W * 0.64, y: H * 0.4, width: W * 0.14, height: H * 0.28))
        ctx.setFillColor(RGBA(hex: "C98E6C")!.cgColor)
        ctx.fillEllipse(in: CGRect(x: W * 0.66, y: H * 0.56, width: W * 0.1, height: H * 0.05))
        ctx.setFillColor(RGBA(hex: "3A2A20")!.cgColor)
        ctx.fillEllipse(in: CGRect(x: W * 0.67, y: H * 0.48, width: W * 0.02, height: H * 0.02))
        ctx.fillEllipse(in: CGRect(x: W * 0.73, y: H * 0.48, width: W * 0.02, height: H * 0.02))
        // text
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSAttributedString(string: "LUMEN", attributes: attrs).draw(at: CGPoint(x: W * 0.05, y: H * 0.85))
        NSGraphicsContext.restoreGraphicsState()
        b.markDirty()
        return b
    }

    static func state(_ buf: PixelBuffer) -> DocumentState {
        var st = DocumentState(width: buf.width, height: buf.height)
        st.layers = [Layer.raster(name: "Background", buffer: buf)]
        return st
    }

    static func render(_ st: DocumentState) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        return RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: sp)
    }

    /// Writes buffers side by side (with a 4 px gap) as one PNG.
    static func saveRow(_ bufs: [PixelBuffer], _ name: String, _ out: URL) {
        let gap = 4
        let w = bufs.map(\.width).reduce(0, +) + gap * (bufs.count - 1), h = bufs.map(\.height).max() ?? 1
        let o = PixelBuffer(width: w, height: h)
        o.context.setFillColor(RGBA(gray: 0.2).cgColor)
        o.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        var x = 0
        for b in bufs {
            o.drawImage(b.makeCGImage(), in: CGRect(x: x, y: 0, width: b.width, height: b.height))
            x += b.width + gap
        }
        o.markDirty()
        SelfTest.save(state(o), name, out)
    }

    static func ciBuffer(_ img: CIImage, _ w: Int, _ h: Int) -> PixelBuffer {
        let sp = CanvasSpace(width: w, height: h)
        return RenderEngine.renderBuffer(img, docRect: IRect(x: 0, y: 0, width: w, height: h), space: sp)
    }

    // MARK: Adjustments

    static func adjustments(_ out: URL) {
        let base = scene()
        // Hazy version for Dehaze.
        let sp = CanvasSpace(width: base.width, height: base.height)
        let hazy = ciBuffer(EditsAdjustments.apply({ var s = AdjustmentSettings(kind: .dehaze); s.params = ["amount": -70]; return s }(), sp.place(base, at: .zero)), base.width, base.height)
        let cases: [(String, PixelBuffer, [String: Double], AdjustmentKind)] = [
            ("edits_adj_color_warm", base, ["temperature": 60, "tint": 10, "vibrance": 30], .colorWB),
            ("edits_adj_color_cool", base, ["temperature": -60, "tint": -20, "saturation": -30], .colorWB),
            ("edits_adj_clarity_plus", base, ["amount": 100], .clarity),
            ("edits_adj_clarity_minus", base, ["amount": -100], .clarity),
            ("edits_adj_dehaze_plus", hazy, ["amount": 80], .dehaze),
            ("edits_adj_dehaze_minus", base, ["amount": -70], .dehaze),
            ("edits_adj_grain", base, ["amount": 60, "size": 40, "roughness": 50], .grain),
            ("edits_adj_light_recover", base, ["highlights": -80, "shadows": 60], .light),
            ("edits_adj_light_extreme", base, ["highlights": -100, "shadows": 100, "whites": -40, "blacks": 40], .light),
            ("edits_adj_light_punch", base, ["exposure": 0.5, "contrast": 60, "whites": 50, "blacks": -60], .light),
        ]
        for (name, src, params, kind) in cases {
            var st = state(src)
            var s = AdjustmentSettings(kind: kind)
            s.params = params
            st.layers.append(Layer(name: kind.displayName, content: .adjustment(s)))
            saveRow([src, render(st)], name, out)
        }
        // Grain must be deterministic (no flicker between renders).
        do {
            var st = state(base)
            var s = AdjustmentSettings(kind: .grain); s.params = ["amount": 50]
            st.layers.append(Layer(name: "Grain", content: .adjustment(s)))
            let a = render(st), b = render(st)
            let same = memcmp(a.data, b.data, a.bytesPerRow * a.height) == 0
            print(same ? "edits_adj_grain deterministic OK" : "FAIL edits_adj_grain not deterministic")
        }
        // Presets: built-ins exist; user presets round-trip through UserDefaults JSON; old documents decode.
        do {
            let ud = UserDefaults(suiteName: "LumenEditsSelfTest")!
            ud.removePersistentDomain(forName: "LumenEditsSelfTest")
            var s = AdjustmentSettings(kind: .light); s.params = ["shadows": 55]
            AdjustmentPresets.save("Mine", s, defaults: ud)
            let back = AdjustmentPresets.userPresets(.light, defaults: ud)
            let ok1 = back.count == 1 && back[0].settings == s
            let counts = [AdjustmentKind.levels, .curves, .hueSaturation, .blackWhite, .exposure, .colorWB].map { AdjustmentPresets.builtIn($0).count }
            let old = #"{"kind":"levels","brightness":10}"#.data(using: .utf8)!
            let dec = try? JSONDecoder().decode(AdjustmentSettings.self, from: old)
            let ok2 = dec?.params.isEmpty == true && dec?.brightness == 10
            print(ok1 && ok2 && !counts.contains(0) ? "edits_adj_presets OK \(counts)" : "FAIL edits_adj_presets \(ok1) \(ok2) \(counts)")
            // Render a few built-ins
            var row: [PixelBuffer] = []
            for (k, n) in [(AdjustmentKind.blackWhite, "Infrared"), (.curves, "Cross Process (RGB)"), (.hueSaturation, "Cyanotype"), (.levels, "Increase Contrast 3")] {
                guard let p = AdjustmentPresets.builtIn(k).first(where: { $0.name == n }) else { print("FAIL missing preset \(n)"); continue }
                var st = state(base)
                st.layers.append(Layer(name: n, content: .adjustment(p.settings)))
                row.append(render(st))
            }
            saveRow(row, "edits_adj_presets_builtin", out)
        }
    }

    // MARK: Matting

    /// A cut-out red disc whose soft edge was blended against `matte` (straight colour), on a transparent layer.
    static func cutout(_ w: Int, _ h: Int, matte: RGBA, soft: Double) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        let cx = Double(w) / 2, cy = Double(h) / 2, r = Double(min(w, h)) * 0.35
        for y in 0..<h { for x in 0..<w {
            let d = hypot(Double(x) + 0.5 - cx, Double(y) + 0.5 - cy)
            let a = max(0, min(1, (r - d) / soft + 0.5))
            if a <= 0 { continue }
            // true colour: red with a little stripe texture
            let t = (x / 6) % 2 == 0 ? 0.85 : 0.7
            let tr = t, tg = 0.12, tb = 0.1
            // observed straight colour = true·a + matte·(1-a) on the soft rim, alpha = a
            let sr = tr * a + matte.r * (1 - a), sg = tg * a + matte.g * (1 - a), sb = tb * a + matte.b * (1 - a)
            let q = p + y * b.bytesPerRow + x * 4
            q[0] = UInt8(sr * a * 255); q[1] = UInt8(sg * a * 255); q[2] = UInt8(sb * a * 255); q[3] = UInt8(a * 255)
        } }
        b.markDirty()
        return b
    }

    static func over(_ layer: PixelBuffer, bg: RGBA) -> PixelBuffer {
        var st = DocumentState(width: layer.width, height: layer.height)
        let back = PixelBuffer(width: layer.width, height: layer.height)
        back.context.setFillColor(bg.cgColor); back.context.fill(CGRect(x: 0, y: 0, width: layer.width, height: layer.height)); back.markDirty()
        st.layers = [Layer.raster(name: "bg", buffer: back), Layer.raster(name: "l", buffer: layer)]
        return render(st)
    }

    static func matting(_ out: URL) {
        let blue = RGBA(hex: "2D6CDF")!
        // Defringe: a cut-out whose 4 px rim is contaminated with green.
        let green = cutout(200, 200, matte: RGBA(hex: "30D040")!, soft: 8)
        let g2 = green.copy(); Matting.defringe(g2, width: 8)
        let black = cutout(200, 200, matte: .black, soft: 10)
        let b2 = black.copy(); Matting.removeMatte(b2, white: false)
        let white = cutout(200, 200, matte: .white, soft: 10)
        let w2 = white.copy(); Matting.removeMatte(w2, white: true)
        let dec = green.copy(); Matting.decontaminate(dec)
        saveRow([over(green, bg: blue), over(g2, bg: blue), over(dec, bg: blue)], "edits_matting_defringe_decontaminate", out)
        saveRow([over(black, bg: blue), over(b2, bg: blue), over(white, bg: blue), over(w2, bg: blue)], "edits_matting_remove_matte", out)
        // numeric check: after Remove White Matte a rim pixel is red again (not pink)
        let (r0, g0, _, _) = white.pixel(100 + 70 - 2, 100), (r1, g1, _, a1) = w2.pixel(100 + 70 - 2, 100)
        print("edits_matting white rim before \(r0),\(g0) after \(r1),\(g1) a=\(a1) " + (g1 < 60 ? "OK" : "FAIL"))
    }

    // MARK: Color Range

    static func colorRange(_ out: URL) {
        let src = scene()
        var o = ColorRangeOptions()
        o.mode = .skinTones
        let skin = ColorRangeEngine.mask(src: src, options: o)
        // Detect Faces path: Vision finds no face in a synthetic drawing, so inject the face rectangle.
        let face = CGRect(x: 480 * 0.64, y: 320 * 0.4, width: 480 * 0.14, height: 320 * 0.28)
        o.detectFaces = true
        let skinFaces = ColorRangeEngine.mask(src: src, options: o, faces: [face])
        _ = ColorRangeEngine.detectFaces(src)
        saveRow([src, skin, skinFaces], "edits_colorrange_skin", out)
        var rows: [PixelBuffer] = []
        for m in [ColorRangeMode.highlights, .midtones, .shadows, .reds, .greens, .outOfGamut] {
            var oo = ColorRangeOptions(); oo.mode = m
            let d = m.toneDefaults; if m.isTonal { oo.fuzziness = d.0; oo.rangeLow = d.1; oo.rangeHigh = d.2 }
            rows.append(ColorRangeEngine.mask(src: src, options: oo))
        }
        saveRow(Array(rows[0..<3]), "edits_colorrange_tones", out)
        saveRow(Array(rows[3..<6]), "edits_colorrange_colors_gamut", out)
        // face centre selected, sky not
        let c = skin.pixel(Int(face.midX), Int(face.midY)).0, sky = skin.pixel(40, 20).0
        print("edits_colorrange skin face=\(c) sky=\(sky) " + (c > 200 && sky < 30 ? "OK" : "FAIL"))
    }

    // MARK: Content-Aware Fill

    /// Image with the sampling area tinted green and the hole outlined.
    static func samplingView(_ img: PixelBuffer, hole: PixelBuffer, sampling: PixelBuffer) -> PixelBuffer {
        let o = img.copy()
        let W = img.width, H = img.height
        o.context.saveGState()
        o.clip(toMask: SelectionOps.combine(sampling, hole, mode: .subtract).makeCGImage(), in: CGRect(x: 0, y: 0, width: W, height: H))
        o.context.setFillColor(RGBA(r: 0.1, g: 0.85, b: 0.25, a: 0.5).cgColor)
        o.context.fill(CGRect(x: 0, y: 0, width: W, height: H))
        o.context.restoreGState()
        o.context.addPath(SelectionOps.outline(hole)); o.context.setStrokeColor(RGBA(hex: "FF2D55")!.cgColor); o.context.setLineWidth(2); o.context.strokePath()
        o.markDirty()
        return o
    }

    static func stripes(_ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let ctx = b.context
        ctx.setFillColor(RGBA(hex: "F2E3C6")!.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(RGBA(hex: "C0502F")!.cgColor)
        // left half: horizontal stripes; right half: stripes at 30°
        ctx.saveGState(); ctx.clip(to: CGRect(x: 0, y: 0, width: w / 2, height: h))
        for y in stride(from: 0, to: h, by: 16) { ctx.fill(CGRect(x: 0, y: y, width: w / 2, height: 7)) }
        ctx.restoreGState()
        ctx.saveGState(); ctx.clip(to: CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        ctx.translateBy(x: CGFloat(w) * 0.75, y: CGFloat(h) / 2); ctx.rotate(by: .pi / 6)
        for y in stride(from: -h * 2, to: h * 2, by: 16) { ctx.fill(CGRect(x: -w, y: y, width: 2 * w, height: 7)) }
        ctx.restoreGState()
        b.markDirty()
        return b
    }

    static func contentAwareFill(_ out: URL) {
        // 1. Remove the house, sampling only from a custom area (sky + hills to its right).
        let img = scene()
        let W = img.width, H = img.height
        let sel = SelectionOps.rectMask(CGRect(x: W * 12 / 100 - 8, y: H * 33 / 100 - 6, width: W * 20 / 100 + 16, height: H * 37 / 100 + 12), width: W, height: H)
        let hole = ContentAwareFillEngine.holeMask(sel)
        let custom = SelectionOps.rectMask(CGRect(x: 170, y: 60, width: 110, height: 170), width: W, height: H)
        var st = CAFSettings(); st.sampling = .custom
        let t0 = CFAbsoluteTimeGetCurrent()
        let r1 = ContentAwareFillEngine.fill(image: img, hole: hole, sampling: custom, settings: st)
        let auto = ContentAwareFillEngine.autoSampling(hole: hole, image: img)
        let r2 = ContentAwareFillEngine.fill(image: img, hole: hole, sampling: auto, settings: CAFSettings())
        print(String(format: "edits_caf house fills %.2fs", CFAbsoluteTimeGetCurrent() - t0))
        saveRow([samplingView(img, hole: hole, sampling: custom), r1, samplingView(img, hole: hole, sampling: auto), r2], "edits_caf_custom_sampling", out)
        // 2. Rotation adaptation: fill a hole in the 30° stripes sampling only the horizontal stripes.
        let sb = stripes(360, 240)
        let h2 = ContentAwareFillEngine.holeMask(SelectionOps.rectMask(CGRect(x: 230, y: 80, width: 70, height: 70), width: 360, height: 240))
        let left = SelectionOps.rectMask(CGRect(x: 10, y: 10, width: 160, height: 220), width: 360, height: 240)
        var a = CAFSettings(); a.sampling = .custom; a.colorAdaptation = .none
        let n0 = ContentAwareFillEngine.fill(image: sb, hole: h2, sampling: left, settings: a)
        a.rotation = .high
        let t1 = CFAbsoluteTimeGetCurrent()
        let n1 = ContentAwareFillEngine.fill(image: sb, hole: h2, sampling: left, settings: a)
        print(String(format: "edits_caf rotation fill %.2fs", CFAbsoluteTimeGetCurrent() - t1))
        var b = a; b.rotation = .none; b.mirror = true; b.scale = true
        let n2 = ContentAwareFillEngine.fill(image: sb, hole: h2, sampling: left, settings: b)
        saveRow([samplingView(sb, hole: h2, sampling: left), n0, n1, n2], "edits_caf_rotation_adapt", out)
    }

    // MARK: Clone Source

    /// Clones the face into the sky through the active clone-source transform, dab by dab like the Clone Stamp.
    static func cloneWith(_ slot: CloneSourceSlot) -> PixelBuffer {
        let d = Document(state: state(scene()), name: "clone")
        let id = d.state.layers[0].id
        let cs = CloneSources.shared
        cs.active = 2
        cs.slot = slot
        guard let st = PaintStroke(doc: d, layerID: id, target: .content, opacity: 1, blend: .normal),
              let m = BrushTips.mask(diameter: 46, hardness: 0.8, roundness: 1, angle: 0, tipID: "round") else { return scene() }
        let src = st.base
        let dest0 = slot.point! + slot.offset!
        for j in -3...3 { for i in -3...3 {
            let p = dest0 + CGPoint(x: CGFloat(i) * 12, y: CGFloat(j) * 14)
            if cs.needsTransform, let t = cs.slot.destToSource {
                st.transformedDab(mask: m, at: p, source: src, sourceOrigin: st.origin, destToSource: t, alpha: 1)
            } else {
                st.maskedDab(mask: m, at: p, source: src, sourceOrigin: st.origin, offset: CGPoint(x: -slot.offset!.x, y: -slot.offset!.y), alpha: 1)
            }
        } }
        st.flush()
        st.applyToWorking()
        st.finish(name: "Clone Stamp")
        return render(d.state)
    }

    static func cloneSource(_ out: URL) {
        let face = CGPoint(x: 480 * 0.71, y: 320 * 0.54)
        var a = CloneSourceSlot(); a.point = face; a.offset = CGPoint(x: -200, y: -100)
        var b = a; b.rotation = 35; b.scaleW = 70; b.scaleH = 70
        var c = a; c.scaleW = 130; c.scaleH = 80; c.linked = false; c.flipV = true
        let r = [cloneWith(a), cloneWith(b), cloneWith(c)]
        saveRow(r, "edits_clonesource_transform", out)
        // Identity transform through the transformed path must equal the plain clone.
        var i = a; i.rotation = 360
        _ = i
        let t = a.destToSource!
        let q = CGPoint(x: 10, y: 20).applying(t)
        let ok = abs(q.x - (10 + 200)) < 1e-6 && abs(q.y - (20 + 100)) < 1e-6
        let bt = b.destToSource!
        let dest = face + b.offset!
        let back = dest.applying(bt)
        print("edits_clonesource mapping " + (ok && back.distance(to: face) < 1e-6 ? "OK" : "FAIL \(q) \(back)"))
        CloneSources.shared.slots = Array(repeating: CloneSourceSlot(), count: 5)
        CloneSources.shared.active = 0
    }

    // MARK: Vanishing Point

    static func vanishingPoint(_ out: URL) {
        let W = 480, H = 320
        let img = PixelBuffer(width: W, height: H)
        img.context.setFillColor(RGBA(hex: "D9D2C5")!.cgColor); img.context.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let floor = VPPlane(q: Quad(tl: CGPoint(x: 150, y: 150), tr: CGPoint(x: 330, y: 150), br: CGPoint(x: 470, y: 310), bl: CGPoint(x: 10, y: 310)))
        let hi = floor.H!.inverted!
        let p = img.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<H { for x in 0..<W {
            let uv = hi.apply(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
            guard uv.x >= 0, uv.y >= 0, uv.x <= 1, uv.y <= 1 else { continue }
            var c: (UInt8, UInt8, UInt8) = (Int(floor8(uv.x * 8)) + Int(floor8(uv.y * 8))) % 2 == 0 ? (60, 60, 70) : (225, 225, 215)
            if uv.x > 0.12 && uv.x < 0.24 && uv.y > 0.7 && uv.y < 0.85 { c = (210, 40, 40) }       // red tile marker
            if uv.x > 0.14 && uv.x < 0.22 && uv.y > 0.74 && uv.y < 0.81 { c = (250, 210, 40) }
            let q = p + y * img.bytesPerRow + x * 4
            q[0] = c.0; q[1] = c.1; q[2] = c.2; q[3] = 255
        } }
        img.markDirty()
        let m = VPModel(image: img.copy())
        // create the floor plane by clicking its 4 corners
        for c in floor.q.points { m.addPoint(c) }
        // 1. Stamp: clone the marker towards the back of the floor
        let src = floor.fromMetric(CGPoint(x: 0.18 * floor.aspect * floor.scale, y: 0.775 * floor.scale))
        m.defineStampSource(src)
        m.brushSize = 40; m.hardness = 70
        m.beginStroke()
        let d0 = floor.fromMetric(CGPoint(x: 0.7 * floor.aspect * floor.scale, y: 0.2 * floor.scale))
        let d1 = floor.fromMetric(CGPoint(x: 0.7 * floor.aspect * floor.scale, y: 0.24 * floor.scale))
        for k in 0...10 { m.paint(at: d0.lerp(d1, CGFloat(k) / 10), stamp: true) }
        m.endStroke()
        let afterStamp = m.image.copy()
        // 2. Marquee: select the marker and drag a copy towards the back-left
        let a = floor.fromMetric(CGPoint(x: 0.11 * floor.aspect * floor.scale, y: 0.68 * floor.scale))
        let b = floor.fromMetric(CGPoint(x: 0.25 * floor.aspect * floor.scale, y: 0.87 * floor.scale))
        _ = m.marqueeBegin(a); m.marqueeDrag(b); m.marqueeEnd()
        let inside = floor.fromMetric(CGPoint(x: 0.18 * floor.aspect * floor.scale, y: 0.775 * floor.scale))
        let target = floor.fromMetric(CGPoint(x: 0.3 * floor.aspect * floor.scale, y: 0.15 * floor.scale))
        _ = m.marqueeBegin(inside)
        for k in 1...8 { m.marqueeDrag(inside.lerp(target, CGFloat(k) / 8)) }
        m.marqueeEnd()
        // 3. Tear off a wall perpendicular to the back edge and paste an image onto it
        let backMid = (floor.q.tl + floor.q.tr) / 2
        let wall = m.tearOff(plane: 0, edge: 0, to: backMid + CGPoint(x: 0, y: -120))
        let poster = PixelBuffer(width: 200, height: 120)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "2E86DE")!.cgColor, RGBA(hex: "8E44AD")!.cgColor] as CFArray, locations: [0, 1])!
        poster.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 200, y: 120), options: [])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: poster.context, flipped: true)
        NSAttributedString(string: "LUMEN", attributes: [.font: NSFont.boldSystemFont(ofSize: 44), .foregroundColor: NSColor.white]).draw(at: CGPoint(x: 26, y: 30))
        NSGraphicsContext.restoreGraphicsState()
        poster.markDirty()
        if let w = wall { m.active = w; m.pasteImage(poster); m.commitPaste() }
        let result = m.image.copy()
        let withGrid = m.image.copy()
        m.gridSize = 40
        m.tool = .editPlane
        m.drawOverlay(withGrid.context, .identity)
        withGrid.markDirty()
        saveRow([img, afterStamp, result, withGrid], "edits_vanishing_point", out)
        let wallOK = wall.map { m.planes[$0].isValid } ?? false
        // stamped marker is smaller at the back (perspective): yellow pixel count near dest vs source
        func yellow(_ b: PixelBuffer, _ c: CGPoint, _ r: Int) -> Int {
            var n = 0
            for y in (Int(c.y) - r)...(Int(c.y) + r) { for x in (Int(c.x) - r)...(Int(c.x) + r) { let (rr, gg, bb, _) = b.pixel(x, y); if rr > 230 && gg > 180 && bb < 90 { n += 1 } } }
            return n
        }
        let ys = yellow(afterStamp, src, 30), yd = yellow(afterStamp, (d0 + d1) / 2, 30)
        print("edits_vp wall valid=\(wallOK) planes=\(m.planes.count) yellow src=\(ys) dest=\(yd) " + (wallOK && yd > 5 && yd < ys ? "OK" : "FAIL"))
    }

    @inline(__always) static func floor8(_ v: CGFloat) -> CGFloat { v.rounded(.down) }

    // MARK: Split / Cylinder warp

    static func warpDoc() -> (Document, UUID) {
        var st = DocumentState(width: 480, height: 320)
        let bg = PixelBuffer(width: 480, height: 320)
        bg.context.setFillColor(RGBA(gray: 0.92).cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: 480, height: 320)); bg.markDirty()
        let art = PixelBuffer(width: 480, height: 320)
        let sc = scene(240, 160)
        art.drawImage(sc.makeCGImage(), in: CGRect(x: 120, y: 80, width: 240, height: 160))
        // grid lines to visualize the warp
        art.context.setStrokeColor(RGBA(hex: "1B1F3A")!.cgColor); art.context.setLineWidth(1.5)
        for i in 0...8 { let x = 120 + CGFloat(i) * 30; art.context.move(to: CGPoint(x: x, y: 80)); art.context.addLine(to: CGPoint(x: x, y: 240)) }
        for j in 0...8 { let y = 80 + CGFloat(j) * 20; art.context.move(to: CGPoint(x: 120, y: y)); art.context.addLine(to: CGPoint(x: 360, y: y)) }
        art.context.strokePath()
        art.markDirty()
        st.layers = [Layer.raster(name: "Background", buffer: bg), Layer.raster(name: "Art", buffer: art)]
        let d = Document(state: st, name: "warp")
        return (d, st.layers[1].id)
    }

    static func splitWarp(_ out: URL) {
        var shots: [PixelBuffer] = []
        // 1. split crosswise at an off-centre point: at rest the image must not change
        do {
            let (d, id) = warpDoc()
            let before = render(d.state)
            guard let w = SplitWarpSession(doc: d, layerID: id) else { print("FAIL edits_warp session"); return }
            w.split(at: CGPoint(x: 212, y: 120), mode: .crosswise)
            let restOK = w.cols == 4 && w.rows == 4
            w.commit()
            let after = render(d.state)
            var diff = 0
            for y in stride(from: 0, to: 320, by: 3) { for x in stride(from: 0, to: 480, by: 3) {
                let a = before.pixel(x, y), b = after.pixel(x, y)
                diff = max(diff, abs(Int(a.0) - Int(b.0)), abs(Int(a.1) - Int(b.1)), abs(Int(a.2) - Int(b.2)))
            } }
            print("edits_warp split at rest: grid \(w.cols)x\(w.rows) maxdiff=\(diff) " + (restOK && diff < 40 ? "OK" : "FAIL"))
        }
        // 2. split vertically + horizontally, then drag the new intersection point
        do {
            let (d, id) = warpDoc()
            guard let w = SplitWarpSession(doc: d, layerID: id) else { return }
            w.split(at: CGPoint(x: 170, y: 100), mode: .vertically)
            w.split(at: CGPoint(x: 300, y: 200), mode: .horizontally)
            // control point at the new split column x≈170 on the new split row y≈200
            if let ci = w.xs.firstIndex(where: { abs($0 - (170 - 120) / 240.0) < 0.02 }), let ri = w.ys.firstIndex(where: { abs($0 - (200 - 80) / 160.0) < 0.02 }) {
                w.control[ri * w.xs.count + ci] = w.control[ri * w.xs.count + ci] + CGPoint(x: -22, y: -26)
            } else { print("FAIL edits_warp split lines not found \(w.xs) \(w.ys)") }
            w.updatePreview()
            w.commit()
            shots.append(render(d.state))
        }
        // 3. custom 5x5 grid with a pulled corner
        do {
            let (d, id) = warpDoc()
            guard let w = SplitWarpSession(doc: d, layerID: id) else { return }
            w.setGrid(cols: 5, rows: 5)
            w.control[0] = w.control[0] + CGPoint(x: -40, y: -40)
            w.control[w.control.count - 1] = w.control[w.control.count - 1] + CGPoint(x: 30, y: 30)
            w.commit()
            shots.append(render(d.state))
        }
        // 4. cylinder
        for b in [0.7, -0.5] {
            let (d, id) = warpDoc()
            guard let w = SplitWarpSession(doc: d, layerID: id) else { return }
            w.style = .cylinder
            w.bend = b
            w.commit()
            shots.append(render(d.state))
        }
        saveRow(Array(shots[0..<2]), "edits_warp_split_custom", out)
        saveRow(Array(shots[2..<4]), "edits_warp_cylinder", out)
    }

    // MARK: Resample

    static func resample(_ out: URL) {
        let sc = scene()
        let crop = sc.cropped(to: IRect(x: 20, y: 95, width: 110, height: 90))     // house + text edge
        var ups: [PixelBuffer] = []
        for m in ResampleMethod.allCases {
            ups.append(ImageResampler.resample(crop, to: (440, 360), method: m, noise: m == .preserveDetails ? 20 : 0))
        }
        if let mfx = MetalFXUpscale.upscale(crop.makeCGImage(), scale: 4) {
            let b = PixelBuffer(cgImage: mfx)
            ups.append(ImageResampler.resample(b, to: (440, 360), method: .bicubic, noise: 0))
            print("edits_resample MetalFX upscaler OK \(mfx.width)x\(mfx.height) registered=\(UpscalerRegistry.upscalers.map(\.name))")
        } else { print("edits_resample MetalFX unavailable") }
        saveRow(Array(ups[0..<3]), "edits_resample_up_auto_pd_pd2", out)
        saveRow(Array(ups[3..<6]), "edits_resample_up_bicubic_smoother_sharper_plain", out)
        saveRow(Array(ups[6...]), "edits_resample_up_bilinear_nearest_metalfx", out)
        var downs: [PixelBuffer] = []
        for m in [ResampleMethod.bicubicSharper, .bilinear, .nearest] { downs.append(ImageResampler.resample(sc, to: (160, 107), method: m, noise: 0)) }
        saveRow(downs, "edits_resample_down_sharper_bilinear_nearest", out)
        // whole-document Image Size with layers
        var st = state(sc)
        st.layers.append(shapeLayerEdits())
        let d = Document(state: st, name: "size")
        AppModel.shared.documents.append(d); AppModel.shared.activeDocumentID = d.id
        EditsImageSize.perform(d, width: 720, height: 480, resolution: 144, scaleStyles: true, method: .preserveDetails, noise: 0, precomputed: [:])
        let ok = d.state.width == 720 && d.state.height == 480 && d.state.layers[0].raster?.buffer.width == 720
        print("edits_resample doc image size " + (ok ? "OK" : "FAIL"))
        saveRow([render(d.state)], "edits_resample_document_720", out)
        AppModel.shared.documents.removeAll { $0.id == d.id }
    }

    static func shapeLayerEdits() -> Layer {
        var l = SelfTest.shapeLayer(CGRect(x: 300, y: 30, width: 120, height: 60), RGBA(hex: "8E44AD")!, radius: 14)
        l.effects.stroke.enabled = true; l.effects.stroke.size = 3; l.effects.stroke.paint = .color(.white)
        return l
    }

    // MARK: Lens profiles

    static func gridImage(_ w: Int, _ h: Int, step: Int = 30, line: CGFloat = 2) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let ctx = b.context
        ctx.setFillColor(RGBA(gray: 0.93).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(RGBA(gray: 0.1).cgColor); ctx.setLineWidth(line)
        for x in stride(from: 0, through: w, by: step) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)) }
        for y in stride(from: 0, through: h, by: step) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)) }
        ctx.strokePath()
        b.markDirty()
        return b
    }

    static func lensProfiles(_ out: URL) {
        let W = 480, H = 320
        let g = gridImage(W, H)
        let sp = CanvasSpace(width: W, height: H)
        let idx = Double((LensProfiles.menuNames.firstIndex { $0.hasPrefix("Fujifilm") }) ?? 1)
        func run(_ b: PixelBuffer, _ amt: Double) -> PixelBuffer {
            var f = FilterInstance(kind: .lensCorrection)
            f.values["profile"] = idx
            f.values["profDistortion"] = amt * 3; f.values["profCA"] = amt * 60; f.values["profVignette"] = amt
            return ciBuffer(f.apply(sp.place(b, at: .zero), canvas: sp.ciCanvas), W, H)
        }
        let distorted = run(g, -100)       // simulate the lens (inverse model, exaggerated)
        let corrected = run(distorted, 100)
        saveRow([g, distorted, corrected], "edits_lens_profile_fuji_simulated_corrected", out)
        var err = 0.0, n = 0.0
        for y in stride(from: 40, to: H - 40, by: 4) { for x in stride(from: 40, to: W - 40, by: 4) {
            err += abs(Double(g.pixel(x, y).1) - Double(corrected.pixel(x, y).1)); n += 1
        } }
        print(String(format: "edits_lens profiles=%d mean abs err after round trip %.1f ", LensProfiles.all.count, err / n) + (err / n < 20 ? "OK" : "FAIL"))
    }

    // MARK: Adaptive Wide Angle

    static func adaptiveWideAngle(_ out: URL) {
        let W = 480, H = 320
        let size = CGSize(width: W, height: H)
        // "World": a rectilinear scene with straight lines, seen through a wide rectilinear camera
        let world = gridImage(1400, 940, step: 70, line: 7)
        let wctx = world.context
        wctx.setFillColor(RGBA(hex: "B5462F")!.cgColor); wctx.fill(CGRect(x: 420, y: 300, width: 560, height: 360))
        wctx.setStrokeColor(RGBA(hex: "1B1F3A")!.cgColor); wctx.setLineWidth(10)
        wctx.move(to: CGPoint(x: 100, y: 180)); wctx.addLine(to: CGPoint(x: 1300, y: 180)); wctx.strokePath()
        world.markDirty()
        var ws = AWASettings(); ws.correction = .perspective; ws.focalLength = 9
        let worldCam = AWAModel(size: CGSize(width: 1400, height: 940), s: ws)
        var fs = AWASettings(); fs.correction = .fisheye; fs.focalLength = 12
        let fish = AWAModel(size: size, s: fs)
        // render the fisheye view of the world
        let img = PixelBuffer(width: W, height: H)
        let p = img.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<H { for x in 0..<W {
            let d = fish.direction(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5))
            guard d.z > 0.08 else { continue }
            let wp = worldCam.sourcePoint(d)
            let c = vpSample(world, wp.x, wp.y)
            let q = p + y * img.bytesPerRow + x * 4
            q[0] = UInt8(min(255, c.x)); q[1] = UInt8(min(255, c.y)); q[2] = UInt8(min(255, c.z)); q[3] = UInt8(min(255, c.w))
        } }
        img.markDirty()
        let sp = CanvasSpace(width: W, height: H)
        func toFish(_ w: CGPoint) -> CGPoint { fish.sourcePoint(worldCam.direction(w)) }
        // constraints: the long dark line (horizontal) and the building's left edge (vertical)
        var s0 = fs
        let m0 = AWASolver.solve(s0, size: size)
        let r0 = ciBuffer(AWASolver.render(sp.place(img, at: .zero), mesh: m0, space: sp), W, H)
        s0.constraints = [AWAConstraint(a: toFish(CGPoint(x: 150, y: 180)), b: toFish(CGPoint(x: 1250, y: 180)), kind: .horizontal),
                          AWAConstraint(a: toFish(CGPoint(x: 420, y: 300)), b: toFish(CGPoint(x: 420, y: 660)), kind: .vertical),
                          AWAConstraint(a: toFish(CGPoint(x: 420, y: 660)), b: toFish(CGPoint(x: 980, y: 660)), kind: .straight)]
        let t0 = CFAbsoluteTimeGetCurrent()
        let m1 = AWASolver.solve(s0, size: size)
        let dt = CFAbsoluteTimeGetCurrent() - t0
        let r1 = ciBuffer(AWASolver.render(sp.place(img, at: .zero), mesh: m1, space: sp), W, H)
        // straightness: max deviation of the mapped great-circle samples from their chord
        func deviation(_ mesh: AWAMesh, _ c: AWAConstraint) -> CGFloat {
            let pts = fish.greatCircle(c.a, c.b).map(mesh.map)
            let a = pts.first!, b = pts.last!, dir = (b - a).normalized
            return pts.map { abs(($0 - a).x * dir.y - ($0 - a).y * dir.x) }.max() ?? 0
        }
        let before = s0.constraints.map { deviation(m0, $0) }, after = s0.constraints.map { deviation(m1, $0) }
        let h = s0.constraints[0], hp = (m1.map(h.a), m1.map(h.b))
        // overlay constraint curves on the result
        let shown = r1.copy()
        for con in s0.constraints {
            let pts = fish.greatCircle(con.a, con.b, samples: 40).map(m1.map)
            shown.context.setStrokeColor(RGBA(hex: "FFD60A")!.cgColor); shown.context.setLineWidth(2)
            shown.context.addLines(between: pts); shown.context.strokePath()
        }
        shown.markDirty()
        saveRow([img, r0, shown], "edits_awa_fisheye_constraints", out)
        let ok = after.allSatisfy { $0 < 2.5 } && zip(before, after).allSatisfy { $0 > $1 } && abs(hp.0.y - hp.1.y) < 2
        print(String(format: "edits_awa solve %.2fs deviation before %@ after %@ ", dt, before.map { String(format: "%.1f", $0) }.joined(separator: ","),
                     after.map { String(format: "%.2f", $0) }.joined(separator: ",")) + (ok ? "OK" : "FAIL"))
    }

    // MARK: UI snapshots (LUMEN_SELFTEST_UI=1)

    static func uiSnapshots(_ out: URL) {
        guard ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" else { return }
        let st = state(scene())
        let d = Document(state: st, name: "ui")
        let app = AppModel.shared
        app.add(d)
        d.selectLayer(st.layers[0].id)
        d.state.selection = SelectionOps.rectMask(CGRect(x: 50, y: 100, width: 110, height: 130), width: 480, height: 320)
        defer { app.close(d) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize, wait: Double = 0.3) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(wait))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
        }
        var light = AdjustmentSettings(kind: .light); light.params = ["shadows": 55]
        snap(ScrollView { AdjustmentControls(s: .constant(light), doc: d, onCommit: {}).padding(10) }, "edits_ui_properties_light", CGSize(width: 300, height: 330))
        snap(ScrollView { AdjustmentControls(s: .constant(AdjustmentSettings(kind: .colorWB)), doc: d, onCommit: {}).padding(10) }, "edits_ui_properties_color", CGSize(width: 300, height: 300))
        snap(AdjustmentsPanel(), "edits_ui_adjustments_panel", CGSize(width: 300, height: 220))
        snap(DraggableCard { ColorRangeProDialog() }, "edits_ui_color_range", CGSize(width: 360, height: 470))
        snap(DraggableCard { ImageSizeProDialog() }, "edits_ui_image_size", CGSize(width: 400, height: 470))
        snap(CloneSourcePanel(), "edits_ui_clone_source_panel", CGSize(width: 290, height: 420))
        snap(DraggableCard { ContentAwareFillDialog() }, "edits_ui_content_aware_fill", CGSize(width: 1250, height: 520), wait: 6)
        snap(DraggableCard { VanishingPointDialog() }, "edits_ui_vanishing_point", CGSize(width: 1140, height: 640))
        snap(DraggableCard { AdaptiveWideAngleDialog() }, "edits_ui_adaptive_wide_angle", CGSize(width: 1080, height: 620), wait: 1)
        snap(DraggableCard { DefringeDialog() }, "edits_ui_defringe", CGSize(width: 300, height: 130))
        if let w = SplitWarpSession(doc: d, layerID: st.layers[0].id) {
            snap(HStack(spacing: 6) { SplitWarpOptions(w: w, bump: {}) }.padding(.horizontal, 8), "edits_ui_split_warp_options", CGSize(width: 900, height: 40))
            w.cancel()
        }
    }
}
