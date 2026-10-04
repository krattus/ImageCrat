import ImageCratCore
import AppKit
import CoreImage

/// Bevel & Emboss and the inner effects: what belongs inside the layer stays inside it whatever else the style holds and
/// whichever effect was added first; Outer Bevel / Emboss / Pillow Emboss stay within their band; the bevel's shading
/// is smooth (no terraces, no grid); the canvas at 25 / 50 / 100 % matches the full render; PSD keeps the effects.
/// `LUMEN_SELFTEST_ONLY=bevelfx Lumen --selftest <dir>`; `LUMEN_BEVELFX_IMAGES=<dir>` writes the repro renders there
/// (default `<dir>/bevelfx`).
enum BevelFXSelfTest {
    static var passes = 0, failures = 0

    static func register() {
        FeatureModules.selfTests.append(("bevelfx", { out in run(out) }))
    }

    static func check(_ c: Bool, _ msg: @autoclosure () -> String) {
        if c { passes += 1; print("PASS bevelfx: \(msg())") } else { failures += 1; print("FAIL bevelfx: \(msg())") }
    }

    static let W = 900, H = 900
    static let circle = CGRect(x: 85, y: 85, width: 730, height: 730)
    static let radius = 365.0, center = 450.0
    static let blueGrey = RGBA(hex: "6F8299")!

    // MARK: Documents

    static func circleBuffer() -> PixelBuffer {
        let b = PixelBuffer(width: W, height: H)
        b.context.setFillColor(blueGrey.cgColor); b.context.fillEllipse(in: circle); b.markDirty()
        return b
    }

    static func circleLayer(_ kind: String = "shape") -> Layer {
        switch kind {
        case "raster": return Layer.raster(name: "Circle", buffer: circleBuffer())
        case "smart":
            return Layer(name: "Circle", content: .smartObject(SmartObjectContent(source: .image(circleBuffer()), quad: Quad(rect: CGRect(x: 0, y: 0, width: W, height: H)))))
        case "smart-scaled":
            return Layer(name: "Circle", content: .smartObject(SmartObjectContent(source: .image(circleBuffer()), quad: Quad(rect: CGRect(x: 60, y: 40, width: 780, height: 780)))))
        case "fill+vmask":
            var l = Layer(name: "Circle", content: .fill(FillContent(paint: .color(blueGrey)))); l.vectorMask = .ellipse(circle); return l
        case "raster+mask":
            let full = PixelBuffer(width: W, height: H); full.context.setFillColor(blueGrey.cgColor); full.context.fill(CGRect(x: 0, y: 0, width: W, height: H)); full.markDirty()
            var l = Layer.raster(name: "Circle", buffer: full)
            let m = PixelBuffer(width: W, height: H, gray: 0); m.context.setFillColor(CGColor(gray: 1, alpha: 1)); m.context.fillEllipse(in: circle); m.markDirty()
            l.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0)
            return l
        case "group":
            var g = Layer(name: "Group", content: .group(GroupContent(children: [circleLayer()]))); g.blendMode = .normal; return g
        case "text":
            var t = TextContent(); t.text = "O"; t.fontSize = 700; t.position = CGPoint(x: 120, y: 60); t.color = blueGrey
            return Layer(name: "Text", content: .text(t))
        default:
            return Layer(name: "Circle", content: .shape(ShapeContent(geometry: .ellipse(circle), fill: .color(blueGrey))))
        }
    }

    static func state(_ fx: LayerEffects, kind: String = "shape", background: Bool = false) -> DocumentState {
        var st = DocumentState(width: W, height: H)
        st.layers = []
        if background {
            let bg = PixelBuffer(width: W, height: H)
            bg.context.setFillColor(RGBA(hex: "D8D8D8")!.cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: W, height: H)); bg.markDirty()
            st.layers.append(Layer.raster(name: "Background", buffer: bg))
        }
        var l = circleLayer(kind)
        l.effects = fx
        st.layers.append(l)
        return st
    }

    static func render(_ st: DocumentState) -> PixelBuffer {
        RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: st.canvasRect, space: CanvasSpace(width: st.width, height: st.height))
    }

    /// Largest alpha (transparent document) where the bare layer has none.
    static func spill(bare: PixelBuffer, _ img: PixelBuffer) -> Int {
        var mx = 0
        for y in 0..<bare.height { for x in 0..<bare.width where bare.alpha(x, y) == 0 { mx = max(mx, Int(img.alpha(x, y))) } }
        return mx
    }

    /// Distance of pixel (x, y) outside the circle's edge (negative inside).
    static func outside(_ x: Int, _ y: Int) -> Double { hypot(Double(x) + 0.5 - center, Double(y) + 0.5 - center) - radius }

    static func innerShadow(_ size: Double = 20, _ distance: Double = 12) -> ShadowEffect {
        var s = LayerEffects().innerShadow
        s.enabled = true; s.size = size; s.distance = distance
        return s
    }

    static func fx(bevelSize: Double = 50, soften: Double = 0, technique: BevelTechnique = .smooth,
                   style: BevelStyle = .innerBevel, withIS: Bool = true) -> LayerEffects {
        var f = LayerEffects()
        if withIS { f.innerShadow = innerShadow() }
        f.bevel.enabled = true; f.bevel.size = bevelSize; f.bevel.soften = soften; f.bevel.technique = technique; f.bevel.style = style
        return f
    }

    // MARK: Run

    static func run(_ out: URL) {
        passes = 0; failures = 0
        let env = ProcessInfo.processInfo.environment
        let imgDir = env["LUMEN_BEVELFX_IMAGES"].map { URL(fileURLWithPath: $0) } ?? out.appendingPathComponent("bevelfx")
        try? FileManager.default.createDirectory(at: imgDir, withIntermediateDirectories: true)
        let t0 = Date()
        images(imgDir)
        innerSpill()
        effectOrder()
        layerKinds()
        outsideStyles()
        smoothness()
        zoomAgreement()
        liveEdits()
        psd(out)
        print("bevelfx: \(passes) passed, \(failures) failed (\(String(format: "%.1f", Date().timeIntervalSince(t0))) s)")
    }

    /// The repro renders (also used to look at the result).
    static func images(_ dir: URL) {
        func save(_ name: String, _ f: LayerEffects) {
            try? render(state(f, background: true)).pngData()?.write(to: dir.appendingPathComponent(name + ".png"))
        }
        save("is_then_bevel50", fx())
        save("bevel50_no_is", fx(withIS: false))
        save("is_bevel60_soften16", fx(bevelSize: 60, soften: 16))
        save("is_bevel50_chiselhard", fx(technique: .chiselHard))
        save("is_bevel40_chiselsoft", fx(bevelSize: 40, technique: .chiselSoft))
        save("is_emboss40", fx(bevelSize: 40, style: .emboss))
        save("is_outerbevel30", fx(bevelSize: 30, style: .outerBevel))
        save("is_pillow40", fx(bevelSize: 40, style: .pillowEmboss))
        print("bevelfx: images in \(dir.path)")
    }

    // MARK: Inner effects stay inside

    static func innerSpill() {
        var combos: [(String, LayerEffects)] = []
        combos.append(("Inner Shadow alone", { var f = LayerEffects(); f.innerShadow = innerShadow(); return f }()))
        combos.append(("Inner Bevel 5 (defaults)", { var f = LayerEffects(); f.bevel.enabled = true; return f }()))
        combos.append(("Inner Shadow + Inner Bevel 5", { var f = LayerEffects(); f.innerShadow = innerShadow(); f.bevel.enabled = true; return f }()))
        combos.append(("Inner Shadow + Inner Bevel 50", fx()))
        combos.append(("Inner Shadow + Inner Bevel 50, soften 16", fx(soften: 16)))
        combos.append(("Inner Shadow + Inner Bevel 60 Chisel Hard", fx(bevelSize: 60, technique: .chiselHard)))
        combos.append(("Inner Shadow + Inner Bevel 40 Chisel Soft, soften 8", fx(bevelSize: 40, soften: 8, technique: .chiselSoft)))
        combos.append(("two Inner Shadows + Inner Bevel 50", { var f = fx(); f.extraInnerShadows = [innerShadow(40, 30)]; return f }()))
        combos.append(("Inner Bevel 50 Down + Ring contour + texture", { var f = fx(); f.bevel.directionUp = false; f.bevel.contourEnabled = true
            f.bevel.contour = Contour(preset: .ring); f.bevel.textureEnabled = true; return f }()))
        combos.append(("every inner effect + Inner Bevel 50", { var f = fx(soften: 4)
            f.extraInnerShadows = [innerShadow(60, 0)]
            f.innerGlow.enabled = true; f.innerGlow.size = 40; f.innerGlow.blendMode = .normal; f.innerGlow.color = .white
            f.satin.enabled = true; f.satin.size = 30
            f.colorOverlay.enabled = true; f.colorOverlay.opacity = 0.3; f.colorOverlay.blendMode = .screen
            f.gradientOverlay.enabled = true; f.gradientOverlay.opacity = 0.4; f.gradientOverlay.blendMode = .overlay
            f.patternOverlay.enabled = true; f.patternOverlay.opacity = 0.3; f.patternOverlay.blendMode = .multiply
            f.stroke.enabled = true; f.stroke.position = .inside; f.stroke.size = 6
            return f }()))
        combos.append(("Inner Glow (center, precise) + Satin + Inner Bevel 30", { var f = fx(bevelSize: 30, withIS: false)
            f.innerGlow.enabled = true; f.innerGlow.source = .center; f.innerGlow.technique = .precise; f.innerGlow.size = 50
            f.satin.enabled = true; return f }()))
        for kind in ["shape", "raster"] {
            let bare = render(state(LayerEffects(), kind: kind))
            for (name, f) in combos {
                let s = spill(bare: bare, render(state(f, kind: kind)))
                check(s <= 1, "\(kind): \(name) draws nothing outside the layer (max alpha outside \(s)/255)")
            }
        }
    }

    /// Inner Shadow then Bevel, and Bevel then Inner Shadow, added one at a time on a live document as the Layer Style
    /// dialog does, shown on the canvas at 25 / 50 / 100 %.
    static func effectOrder() {
        let zs: [CGFloat] = [0.25, 0.5, 1]
        for order in ["Inner Shadow first", "Bevel first"] {
            let doc = Document(state: state(LayerEffects()), name: "order")
            let id = doc.state.layers.last!.id
            var bare: [CGFloat: PixelBuffer] = [:]
            for z in zs { bare[z] = ZoomFXSelfTest.shown(doc, z, offset: .zero) }
            var worst = 0, far = 0
            func step(_ body: (inout Layer) -> Void) {
                doc.updateLayer(id, body)
                for z in zs {
                    let b = bare[z]!, img = ZoomFXSelfTest.shown(doc, z, offset: .zero)
                    // a resampled anti-aliased edge may differ by a level or two right at the edge; further out nothing
                    worst = max(worst, spill(bare: b, img))
                    for y in 0..<img.height { for x in 0..<img.width {
                        let d = hypot((Double(x) + 0.5) / Double(z) - center, (Double(y) + 0.5) / Double(z) - center) - radius
                        if d > 4 / Double(z) { far = max(far, Int(img.alpha(x, y))) }
                    } }
                }
            }
            let addIS: (inout Layer) -> Void = { $0.effects.innerShadow = innerShadow() }
            let addBevel: (inout Layer) -> Void = { $0.effects.bevel.enabled = true }
            if order == "Inner Shadow first" { step(addIS); step(addBevel) } else { step(addBevel); step(addIS) }
            step { $0.effects.bevel.size = 50 }
            step { $0.effects.bevel.soften = 16 }
            step { $0.effects.innerShadow.size = 40; $0.effects.innerShadow.distance = 30 }
            step { $0.effects.innerShadow.enabled = false }
            step { $0.effects.innerShadow.enabled = true }
            step { $0.effects.extraInnerShadows = [innerShadow(10, 5)] }
            check(far == 0 && worst <= 3, "\(order): adding and editing Inner Shadow and Bevel on the canvas never draws outside the layer (alpha \(far)/255 beyond the edge, \(worst)/255 at the resampled edge)")
        }
    }

    static func layerKinds() {
        for kind in ["smart", "smart-scaled", "fill+vmask", "raster+mask", "group", "text"] {
            let bare = render(state(LayerEffects(), kind: kind))
            let s = spill(bare: bare, render(state(fx(), kind: kind)))
            check(s <= 1, "\(kind): Inner Shadow + Inner Bevel 50 stay inside the layer (max alpha outside \(s)/255)")
        }
    }

    // MARK: Outer Bevel, Emboss, Pillow Emboss

    /// These draw outside, but only within their band: Outer Bevel `size`, Emboss and Pillow Emboss `size / 2`
    /// (Photoshop centres them on the edge), plus the technique's smoothing.
    static func outsideStyles() {
        let cases: [(String, BevelStyle, BevelTechnique, Double, Double)] = [
            ("Outer Bevel 30", .outerBevel, .smooth, 30, 30), ("Outer Bevel 30 Chisel Hard", .outerBevel, .chiselHard, 30, 30),
            ("Emboss 40", .emboss, .smooth, 40, 20), ("Emboss 40 Chisel Hard", .emboss, .chiselHard, 40, 20),
            ("Pillow Emboss 40", .pillowEmboss, .smooth, 40, 20),
        ]
        for (name, style, tech, size, band) in cases {
            let f = fx(bevelSize: size, technique: tech, style: style, withIS: false)
            let img = render(state(f))
            let sigma = tech == .smooth ? (0.25 + size * size * 0.01).squareRoot() : 0.5
            let limit = band + 3 * sigma + 2
            var inBand = 0, beyond = 0, beyondAt = 0.0
            for y in 0..<H { for x in 0..<W {
                let d = outside(x, y)
                guard d > 1.5 else { continue }
                let a = Int(img.alpha(x, y))
                if d < band - 1 { inBand = max(inBand, a) }
                if d > limit, a > beyond { beyond = a; beyondAt = d }
            } }
            check(inBand >= 40, "\(name): shades outside the layer within its band (max alpha \(inBand)/255 within \(Int(band)) px)")
            check(beyond <= 2, "\(name): nothing beyond its band (max alpha \(beyond)/255 beyond \(Int(limit)) px\(beyond > 2 ? String(format: ", at %.0f px", beyondAt) : ""))")
        }
        // Inner Bevel and Emboss inside the layer both light the upper left and shade the lower right (light at 120°)
        let base = Int(render(state(LayerEffects(), background: true)).pixel(450, 450).0)
        func edgeReds(_ f: LayerEffects) -> (Int, Int) {
            let img = render(state(f, background: true))
            let ul = Int(img.pixel(Int(center - (radius - 6) * 0.5), Int(center - (radius - 6) * 0.866)).0)
            let lr = Int(img.pixel(Int(center + (radius - 6) * 0.5), Int(center + (radius - 6) * 0.866)).0)
            return (ul, lr)
        }
        for style in [BevelStyle.innerBevel, .emboss] {
            let (ul, lr) = edgeReds(fx(bevelSize: 30, style: style, withIS: false))
            check(ul > base + 25 && lr < base - 25, "\(style.displayName): lit at the upper left, shaded at the lower right inside the edge (red \(ul) / \(base) / \(lr))")
        }
        var down = fx(bevelSize: 30, withIS: false); down.bevel.directionUp = false
        let (ul, lr) = edgeReds(down)
        check(ul < base - 25 && lr > base + 25, "Direction Down: shaded at the upper left, lit at the lower right (red \(ul) / \(base) / \(lr))")
    }

    // MARK: Smooth shading

    /// 8-bit composite along the four axis rays from the edge inwards: the shading is a smooth curve (second difference
    /// within rounding), and the interior beyond the bevel is one flat colour (no grid, no rings).
    static func smoothness() {
        let cases: [(String, LayerEffects, Bool)] = [
            ("Inner Bevel 50 Smooth", fx(withIS: false), true),
            ("Inner Bevel 50 Smooth with Inner Shadow", fx(), true),
            ("Inner Bevel 60 Smooth, soften 16", fx(bevelSize: 60, soften: 16, withIS: false), true),
            ("Inner Bevel 120 Smooth", fx(bevelSize: 120, withIS: false), true),
            ("Inner Bevel 40 Chisel Soft", fx(bevelSize: 40, technique: .chiselSoft, withIS: false), false),
            ("Inner Bevel 50 Chisel Hard", fx(technique: .chiselHard, withIS: false), false),
        ]
        for (name, f, rays) in cases {
            let img = render(state(f, background: true))
            func gray(_ x: Int, _ y: Int) -> Double { let p = img.pixel(x, y); return (Double(p.0) + Double(p.1) + Double(p.2)) / 3 }
            let size = f.bevel.size
            if rays {
                var worst = 0.0, worstRay = ""
                let c = Int(center), r = Int(radius)
                let raysDef: [(String, (Int) -> (Int, Int))] = [("left", { (c - r + $0, c) }), ("right", { (c + r - 1 - $0, c) }),
                                                                ("top", { (c, c - r + $0) }), ("bottom", { (c, c + r - 1 - $0) })]
                for (rn, at) in raysDef {
                    let v = (3..<Int(size + 20)).map { i -> Double in let p = at(i); return gray(p.0, p.1) }
                    for i in 1..<(v.count - 1) {
                        let d2 = abs(v[i - 1] - 2 * v[i] + v[i + 1])
                        if d2 > worst { worst = d2; worstRay = "\(rn) at \(i + 3) px" }
                    }
                }
                check(worst <= 2.4, "\(name): shading changes smoothly along the radius (max 2nd difference \(String(format: "%.2f", worst)) levels, \(worstRay))")
            }
            var lo = 255.0, hi = 0.0
            for y in stride(from: 0, to: H, by: 2) { for x in stride(from: 0, to: W, by: 2) where outside(x, y) < -(size + 30) {
                let g = gray(x, y); lo = min(lo, g); hi = max(hi, g)
            } }
            check(hi - lo <= 1, "\(name): flat interior beyond the bevel (range \(String(format: "%.1f", hi - lo)) levels)")
        }
    }

    // MARK: Canvas vs full render

    static func zoomAgreement() {
        let cases: [(String, LayerEffects)] = [("Inner Shadow + Inner Bevel 50", fx()), ("Emboss 40", fx(bevelSize: 40, style: .emboss)),
                                              ("Outer Bevel 30, soften 8", fx(bevelSize: 30, soften: 8, style: .outerBevel))]
        for (name, f) in cases {
            let st = state(f, background: true)
            let doc = Document(state: st, name: name), ref = ZoomFXSelfTest.flat(st)
            var worst = 0
            for z: CGFloat in [0.25, 0.5, 1] {
                worst = max(worst, ZoomFXSelfTest.diff(ZoomFXSelfTest.shown(ref, z), ZoomFXSelfTest.shown(doc, z)).max)
            }
            check(worst <= 3, "\(name): canvas at 25 / 50 / 100 % matches the full render resampled (max \(worst)/255)")
        }
    }

    /// Editing the bevel on a live document (the canvas' cached Core Image context) shows the same pixels as a fresh,
    /// uncached render of the same settings: no cached height map of other settings is reused.
    static func liveEdits() {
        let doc = Document(state: state(fx(bevelSize: 5), background: true), name: "live")
        let id = doc.state.layers.last!.id
        var worst = 0
        let edits: [(inout Layer) -> Void] = [
            { $0.effects.bevel.size = 50 }, { $0.effects.bevel.size = 5 }, { $0.effects.bevel.soften = 10 },
            { $0.effects.bevel.technique = .chiselHard }, { $0.effects.bevel.style = .emboss }, { $0.effects.bevel.size = 50 },
            { $0.effects.bevel.contourEnabled = true; $0.effects.bevel.contour = Contour(preset: .ring) }, { $0.effects.bevel.contourEnabled = false },
            { $0.effects.bevel.style = .innerBevel; $0.effects.bevel.technique = .smooth },
        ]
        _ = ZoomFXSelfTest.shown(doc, 1, offset: .zero)
        for e in edits {
            doc.updateLayer(id, e)
            worst = max(worst, ZoomFXSelfTest.diff(ZoomFXSelfTest.shown(doc, 1, offset: .zero), render(doc.state)).max)
        }
        check(worst <= 2, "live Bevel edits on the canvas match fresh renders (max \(worst)/255)")
    }

    // MARK: PSD

    static func psd(_ out: URL) {
        var f = fx(bevelSize: 50, soften: 6, technique: .chiselSoft)
        f.extraInnerShadows = [innerShadow(40, 30)]
        if let back = PSDLayerStyle.decode(PSDLayerStyle.encode(f)) {
            check(back.bevel.enabled && back.bevel.style == .innerBevel && back.bevel.technique == .chiselSoft
                  && abs(back.bevel.size - 50) < 0.01 && abs(back.bevel.soften - 6) < 0.01,
                  "PSD layer style keeps Bevel & Emboss (style, technique, size, soften)")
            check(back.innerShadows.filter(\.enabled).map(\.size) == [20, 40],
                  "PSD layer style keeps both Inner Shadows in order (sizes \(back.innerShadows.filter(\.enabled).map(\.size)))")
        } else {
            check(false, "PSD layer style decodes")
        }
        let url = out.appendingPathComponent("bevelfx.psd")
        do {
            try PSDWriter.write(state(f, background: true), to: url)
            let st = try PSDReader.read(url: url)
            let fx2 = st.layers.last?.effects
            check(fx2?.bevel.enabled == true && fx2?.bevel.style == .innerBevel && fx2?.innerShadows.filter(\.enabled).count == 2,
                  "PSD file round trip keeps Inner Shadow ×2 and Inner Bevel")
        } catch {
            check(false, "PSD file round trip: \(error)")
        }
    }
}
