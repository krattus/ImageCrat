import AppKit
import CoreImage
import ImageCratCore

// Synthetic files for `psdfidelity`: one per cause found by comparing a real banner with Photoshop's own rendering.

extension PSDFidelitySelfTest {
    typealias T = PSDImportSelfTest

    static func synthetic(_ dir: URL) {
        missingFont(dir)
        fontNames()
        kerning()
        styleScale()
        glowFalloff(dir)
        shadowSettings(dir)
        cmykArt(dir)
    }

    /// 'lfx2' payload as Photoshop writes it (version 0, descriptor version 16).
    static func lfx2(_ items: [(String, PSDDescriptorValue)]) -> Data {
        var w = BinaryWriter(); w.u32(0)
        return w.data + PSDDescriptor(classID: "null", items).serializedVersioned()
    }

    static func px(_ v: Double) -> PSDDescriptorValue { .unitFloat(unit: "#Pxl", value: v) }
    static func pct(_ v: Double) -> PSDDescriptorValue { .unitFloat(unit: "#Prc", value: v) }

    static func glowDescriptor(size: Double, range: Double, color: RGBA = .black, mode: String = "Nrml", technique: String = "SfBL") -> PSDDescriptorValue {
        .object(PSDDescriptor(classID: "OrGl", [("enab", .bool(true)), ("present", .bool(true)), ("Md  ", .enumerated(type: "BlnM", value: mode)),
                                                ("Clr ", PSDTestFile.colorDescriptor(color)), ("Opct", pct(100)), ("GlwT", .enumerated(type: "BETE", value: technique)),
                                                ("Ckmt", px(0)), ("blur", px(size)), ("Nose", pct(0)), ("ShdN", pct(0)), ("AntA", .bool(false)), ("Inpr", pct(range))]))
    }

    /// Opaque black rectangle (a shape with straight edges to measure effect falloff against).
    static func block(_ name: String, _ r: IRect) -> PSDTestLayer { PSDTestLayer(name: name, buffer: T.solid(r.width, r.height, .black), origin: IPoint(x: r.x, y: r.y)) }

    // MARK: Missing fonts

    /// A type layer whose font is not installed shows the pixels Photoshop stored until it is edited, keeps them through
    /// moves, transforms and .lumen save / load, is flagged, and gets a substitute of about the original's width.
    static func missingFont(_ dir: URL) {
        let condensed = ["DINCondensed-Bold", "AvenirNextCondensed-Bold", "HelveticaNeue-CondensedBold", "Futura-CondensedExtraBold", "ArialNarrow-Bold"].first { NSFont(name: $0, size: 12) != nil }
        guard let face = condensed else { print("SKIP psdfidelity: no condensed system font to draw the stored pixels with"); return }
        // "Photoshop's pixels": the text drawn with a condensed face (what the missing font looked like)
        let text = "SUMMER SALE TODAY", size = 40.0
        var drawn = TextContent(); drawn.text = text; drawn.fontName = face; drawn.fontSize = size; drawn.color = RGBA(hex: "C8102E")!
        let ink = TextRenderer.docBounds(drawn)
        let rect = IRect(x: 30, y: 60, width: Int(ink.width.rounded(.up)) + 2, height: Int(ink.height.rounded(.up)) + 2)
        let stored = PixelBuffer(width: rect.width, height: rect.height)
        let sp = CanvasSpace(width: rect.width, height: rect.height)
        var local = drawn; local.transform = CGAffineTransform(translationX: 1 - ink.minX, y: 1 - ink.minY)
        let rendered = RenderEngine.renderBuffer(TextRenderer.render(local, space: sp), docRect: IRect(x: 0, y: 0, width: rect.width, height: rect.height), space: sp)
        memcpy(stored.data, rendered.data, min(stored.bytesPerRow * stored.height, rendered.bytesPerRow * rendered.height)); stored.markDirty()
        let inkRect = stored.opaqueBounds() ?? IRect(x: 0, y: 0, width: rect.width, height: rect.height)

        let missing = "NoSuchTitlingXYZ-Bold"
        let blk = PSDTestFile.typeBlock(text: text, runs: [.init(length: (text as NSString).length, size: size, color: drawn.color)], fonts: [missing], transform: [1, 0, 0, 1, 31, 60 + size * 0.8])
        var layer = PSDTestLayer(name: "Headline", buffer: stored, origin: IPoint(x: rect.x, y: rect.y))
        layer.add("TySh", blk)
        guard let r = T.load(T.file([T.background(), layer], w: 400, h: 200), "fidelity_missing_font", dir), let l = r.state.layers.last, var t = l.text else {
            check(false, "a type layer with a missing font imports as type"); return
        }
        check(t.missingFonts == [missing] && t.showsStoredPixels, "missing font: the layer stays a type layer, names the missing font and shows the stored pixels (\(t.fontName))")
        let space = CanvasSpace(width: r.state.width, height: r.state.height)
        func pixels(_ t: TextContent) -> PixelBuffer { RenderEngine.renderBuffer(TextRenderer.render(t, space: space), docRect: r.state.canvasRect, space: space) }
        func expected(_ origin: IPoint) -> PixelBuffer { RenderEngine.renderBuffer(space.place(stored, at: origin), docRect: r.state.canvasRect, space: space) }
        var d = T.diff(pixels(t), expected(IPoint(x: rect.x, y: rect.y)))
        check(d.max <= 1, "missing font: the layer draws exactly the pixels Photoshop stored (max \(d.max))")
        let report = r.report.items.first { $0.feature == "Font" && $0.layer == "Headline" }
        check(report?.status == .substituted && report?.detail.contains("until its text is edited") == true && r.report.missingFonts.contains(missing),
              "missing font: the import report lists it and says the stored pixels are shown until editing (\(report?.detail ?? "none"))")
        check(t.missingFontNote?.contains(missing) == true && t.missingFontNote?.contains("until the text is edited") == true, "missing font: the Layers panel warning names the font (\(t.missingFontNote ?? "none"))")
        // width of the substitute against the stored pixels
        let target = Double(inkRect.width)
        let sub = PSDText.inkWidth(t)
        var plain = t; plain.fontName = PSDFontMatcher.resolve(missing).name
        let naive = PSDText.inkWidth(plain)
        check(abs(sub / target - 1) < 0.1 && abs(sub / target - 1) < abs(naive / target - 1),
              String(format: "missing font: the substitute (%@) is about as wide as the stored pixels (%.0f vs %.0f px; %@ would be %.0f)", t.fontName, sub, target, plain.fontName, naive))

        // moves and transforms keep the pixels
        var moved = l
        moved.translate(dx: 13, dy: -7)
        d = T.diff(pixels(moved.text!), expected(IPoint(x: rect.x + 13, y: rect.y - 7)))
        check(moved.text!.showsStoredPixels && d.max <= 1, "missing font: moving the layer moves the stored pixels (max \(d.max))")
        var scaled = t
        scaled.transform = t.transform.concatenating(CGAffineTransform(scaleX: 1.5, y: 1.5))
        let sb = TextRenderer.docBounds(scaled)
        check(scaled.showsStoredPixels && abs(sb.width - CGFloat(rect.width) * 1.5) < 1, String(format: "missing font: transforming the layer scales the stored pixels (%.1f px wide, expected %.1f)", sb.width, Double(rect.width) * 1.5))
        // editing the text or a character setting switches to the substitute; going back (undo) shows the pixels again
        var edited = t; edited.text += "!"
        check(!edited.showsStoredPixels && T.diff(pixels(edited), expected(IPoint(x: rect.x, y: rect.y))).mean > 0.3, "missing font: editing the text draws it with the substitute")
        var sized = t; sized.fontSize += 2
        check(!sized.showsStoredPixels, "missing font: changing a character setting drops the stored pixels")
        var tracked = t; tracked.applyStyle(CharacterStyle(tracking: 50), to: NSRange(location: 0, length: 3))
        check(!tracked.showsStoredPixels, "missing font: styling part of the text drops the stored pixels")
        check(t.showsStoredPixels, "missing font: the unedited layer (undo) still shows the stored pixels")

        // .lumen: kept while valid, dropped once edited, optional for older files
        let doc = Document(state: r.state, name: "fidelity.imagecrat")
        let url = dir.appendingPathComponent("fidelity_missing_font.imagecrat")
        do {
            try DocumentIO.saveNative(doc, to: url)
            let back = try DocumentIO.load(url: url)
            let bt = back.state.layers.last?.text
            check(bt?.showsStoredPixels == true && bt?.missingFonts == [missing] && bt.map { T.diff(pixels($0), expected(IPoint(x: rect.x, y: rect.y))).max <= 1 } == true,
                  "missing font: the stored pixels survive saving and reopening the .imagecrat file")
            var st = r.state
            st.layers.update(l.id) { if case .text(var x) = $0.content { x.text = "WINTER SALE"; $0.content = .text(x) } }
            try DocumentIO.saveNative(Document(state: st, name: "edited.imagecrat"), to: url)
            let back2 = try DocumentIO.load(url: url)
            check(back2.state.layers.last?.text?.storedPixels == nil && back2.state.layers.last?.text?.missingFonts == [missing], "missing font: once edited, the stale pixels are not saved (the warning stays)")
        } catch { check(false, "missing font: .imagecrat round trip threw \(error)") }
        if let data = try? JSONEncoder().encode(t), var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj["storedPixels"] = nil; obj["missingFonts"] = nil
            let old = (try? JSONSerialization.data(withJSONObject: obj)).flatMap { try? JSONDecoder().decode(TextContent.self, from: $0) }
            check(old != nil && old?.storedPixels == nil && old?.missingFonts.isEmpty == true && old?.text == t.text, "missing font: type layers saved before these fields existed still decode")
        }
        // installed fonts: drawn live as before
        let ok = PSDTestFile.typeBlock(text: text, runs: [.init(length: (text as NSString).length, size: size)], fonts: ["Helvetica-Bold"], transform: [1, 0, 0, 1, 31, 92])
        var okLayer = PSDTestLayer(name: "Installed", buffer: stored, origin: IPoint(x: rect.x, y: rect.y)); okLayer.add("TySh", ok)
        let r2 = T.load(T.file([T.background(), okLayer], w: 400, h: 200), "fidelity_installed_font")
        t = r2?.state.layers.last?.text ?? TextContent()
        check(t.storedPixels == nil && t.missingFonts.isEmpty && !t.showsStoredPixels, "an installed font is drawn live (no stored pixels kept)")
    }

    /// PostScript names → installed fonts: the same family and style under a different PostScript name is the font itself.
    static func fontNames() {
        if NSFontManager.shared.availableMembers(ofFontFamily: "Times New Roman") != nil {
            let r = PSDFontMatcher.resolve("TimesNewRoman-Bold")
            check(NSFont(name: r.name, size: 12).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true && !r.substituted,
                  "font names: “TimesNewRoman-Bold” is the installed Times New Roman Bold (\(r.name)), not a substitute")
        }
        if let m = NSFontManager.shared.availableMembers(ofFontFamily: "Helvetica Neue"), m.contains(where: { ($0[1] as? String) == "Medium" }) {
            let r = PSDFontMatcher.resolve("HelveticaNeueXYZ-Medium")
            check(r.substituted, "font names: an unknown family is a substitute (\(r.name))")
            let w = NSFont(name: PSDFontMatcher.resolve("NoSuchFamilyQ-Medium").name, size: 12).map { NSFontManager.shared.weight(of: $0) } ?? 0
            check((5...7).contains(w), "font names: a missing Medium face gets a medium-weight substitute (weight \(w))")
        }
        check(FontLookup.installed("Helvetica") && !FontLookup.installed("NoSuchFontAtAll-Regular"), "font names: installed-font lookup (AppKit or Core Text)")
    }

    /// Type is drawn with the font's pair kerning (Photoshop's default "Metrics"): without tracking no kern value may be
    /// set, since any value, 0 included, turns kerning off.
    static func kerning() {
        let text = "AVATAR WAVE YA"
        let blk = PSDTestFile.typeBlock(text: text, runs: [.init(length: (text as NSString).length, size: 60)], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 10, 100])
        var l = PSDTestLayer(name: "Kern"); l.add("TySh", blk)
        guard let t = T.load(T.file([T.background(), l], w: 600, h: 200), "fidelity_kerning")?.state.layers.last?.text, let line = TextRenderer.layout(t).lines.first else {
            check(false, "kerning: type imports"); return
        }
        let f = NSFont(name: "Helvetica", size: 60)!
        let kerned = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f])), nil, nil, nil)
        let flat = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: f, .kern: 0.0])), nil, nil, nil)
        let w = CTLineGetTypographicBounds(line.line, nil, nil, nil)
        check(abs(w - kerned) < 0.5 && kerned < flat - 3, String(format: "kerning: the font's pair kerning is applied (%.1f px; kerned %.1f, unkerned %.1f)", w, kerned, flat))
        var tracked = t; tracked.tracking = 100
        let wt = TextRenderer.layout(tracked).lines.first.map { CTLineGetTypographicBounds($0.line, nil, nil, nil) } ?? 0
        check(wt > w + 50, String(format: "kerning: tracking still widens the line (%.1f px)", wt))
    }

    // MARK: Layer style

    /// 'Scl ' in the layer style follows the document resolution (416.7 % at 300 ppi); the sizes are not multiplied by it.
    static func styleScale() {
        var l = block("Glow", IRect(x: 100, y: 40, width: 100, height: 120))
        l.add("lfx2", lfx2([("Scl ", pct(416.7)), ("masterFXSwitch", .bool(true)), ("OrGl", glowDescriptor(size: 20, range: 50))]))
        let r = T.load(T.file([T.background(T.W, T.H, .white), l]), "fidelity_style_scale")
        let g = r?.state.layers.last?.effects.outerGlow
        check(g?.enabled == true && g.map { abs($0.size - 20) < 1e-6 } == true, "layer style: a 416.7 % style scale leaves the 20 px glow at 20 px (\(g?.size ?? -1))")
    }

    /// Outer glow, softer: full strength at the edge with the default 50 % range, fading out within the size (measured
    /// on a real banner: a 70 px glow at 50 % reaches ~0.7 next to the shape and 0 at ~55 px).
    static func glowFalloff(_ dir: URL) {
        func strength(range: Double) -> [Double]? {
            var l = block("Glow", IRect(x: 100, y: 40, width: 100, height: 120))
            l.add("lfx2", lfx2([("masterFXSwitch", .bool(true)), ("OrGl", glowDescriptor(size: 40, range: range))]))
            guard let r = T.load(T.file([T.background(T.W, T.H, .white), l]), "fidelity_glow_\(Int(range))", dir), let b = T.flatten(r.state) else { return nil }
            // darkness to the right of the shape's right edge (x = 200), on its middle row
            return [1, 10, 20, 40, 60].map { 1 - Double(b.psdTestPixel(199 + $0, 100).0) / 255 }
        }
        guard let s = strength(range: 50), let wide = strength(range: 100) else { check(false, "glow: test files import"); return }
        let txt = s.map { String(format: "%.2f", $0) }.joined(separator: " ")
        check(s[0] > 0.85, "glow: full strength at the shape's edge with the default 50 % range (\(txt) at 1/10/20/40/60 px)")
        check(s[2] > 0.15 && s[2] < 0.5 && s[3] < 0.06 && s[4] < 0.01, "glow: a 40 px glow fades out within its size (\(txt))")
        check(wide[0] < s[0] - 0.25 && wide[0] > 0.3, String(format: "glow: a 100 %% range is softer at the edge (%.2f vs %.2f)", wide[0], s[0]))
        var l = block("P", IRect(x: 0, y: 0, width: 10, height: 10))
        l.add("lfx2", lfx2([("OrGl", glowDescriptor(size: 12, range: 37, technique: "PrBL"))]))
        let g = T.load(T.file([l]), "fidelity_glow_parse")?.state.layers.last?.effects.outerGlow
        check(g?.technique == .precise && g?.range == 37, "glow: technique and range are read from the file")
    }

    /// Drop shadow: "Use Global Light" off keeps the shadow's own angle; noise, contour and "Layer Knocks Out" are read.
    static func shadowSettings(_ dir: URL) {
        func shadow(_ uglg: Bool, angle: Double) -> PSDDescriptorValue {
            .object(PSDDescriptor(classID: "DrSh", [("enab", .bool(true)), ("present", .bool(true)), ("Md  ", .enumerated(type: "BlnM", value: "Nrml")),
                                                    ("Clr ", PSDTestFile.colorDescriptor(.black)), ("Opct", pct(100)), ("uglg", .bool(uglg)), ("lagl", .unitFloat(unit: "#Ang", value: angle)),
                                                    ("Dstn", px(12)), ("Ckmt", pct(0)), ("blur", px(0)), ("Nose", pct(8)), ("AntA", .bool(false)),
                                                    ("TrnS", .object(PSDDescriptor(classID: "ShpC", [("Nm  ", .string("Custom")), ("Crv ", .list([
                                                        .object(PSDDescriptor(classID: "CrPt", [("Hrzn", .double(0)), ("Vrtc", .double(0))])),
                                                        .object(PSDDescriptor(classID: "CrPt", [("Hrzn", .double(128)), ("Vrtc", .double(200))])),
                                                        .object(PSDDescriptor(classID: "CrPt", [("Hrzn", .double(255)), ("Vrtc", .double(255))]))]))]))),
                                                    ("layerConceals", .bool(false))]))
        }
        var light = BinaryWriter(); light.u32(120)
        for (uglg, tag) in [(false, "own angle"), (true, "global light")] {
            var l = PSDTestLayer(name: "S", buffer: T.solid(60, 60, RGBA(hex: "3070C0")!), origin: IPoint(x: 120, y: 70))
            l.add("lfx2", lfx2([("masterFXSwitch", .bool(true)), ("DrSh", shadow(uglg, angle: 0))]))
            var f = T.file([T.background(T.W, T.H, .white), l]); f.resources = [(1037, "", light.data)]
            guard let r = T.load(f, "fidelity_shadow_\(uglg)", dir), let fx = r.state.layers.last?.effects, let b = T.flatten(r.state) else { check(false, "shadow (\(tag)) imports"); continue }
            let sh = fx.dropShadow
            check(sh.useGlobalLight == uglg && sh.angle == 0 && abs(sh.noise - 8) < 1e-9 && sh.contour.preset == .custom && !sh.layerKnocksOut,
                  "shadow (\(tag)): Use Global Light, angle, noise, contour and Layer Knocks Out are read")
            // angle 0: light from the right, shadow to the left; global light 120°: shadow down-right
            let left = b.psdTestPixel(115, 100).0, below = b.psdTestPixel(150, 135).0
            check(uglg ? (below < 100 && left > 200) : (left < 100 && below > 200), "shadow (\(tag)): drawn in the right direction (left \(left), below \(below))")
        }
    }

    // MARK: CMYK colour

    /// Vector art in CMYK and CMYK documents convert like Photoshop: relative colorimetric with black point compensation
    /// (rich black is black, not the ~(31,31,31) of a plain colorimetric conversion).
    static func cmykArt(_ dir: URL) {
        // a press profile (as Illustrator embeds) when one is installed: its black point is far from black, which is where
        // the compensation shows; the generic profile otherwise
        let press = (try? Data(contentsOf: URL(fileURLWithPath: "/Library/Application Support/Adobe/Color/Profiles/Recommended/CoatedFOGRA39.icc"))).flatMap { CGColorSpace(iccData: $0 as CFData) }
        guard let cmyk = press ?? CGColorSpace(name: CGColorSpace.genericCMYK).flatMap({ $0.copyICCData() }).flatMap({ CGColorSpace(iccData: $0) }) else { check(false, "CMYK profile"); return }
        func pdf(_ space: CGColorSpace, _ colors: [[CGFloat]]) -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 30 * colors.count, height: 20)
            guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
            ctx.beginPDFPage(nil)
            for (i, c) in colors.enumerated() {
                ctx.setFillColor(CGColor(colorSpace: space, components: c + [1])!)
                ctx.fill(CGRect(x: 30 * i, y: 0, width: 30, height: 20))
            }
            ctx.endPDFPage(); ctx.closePDF()
            return data as Data
        }
        let inks: [[CGFloat]] = [[0.742, 0.688, 0.672, 0.969], [0, 1, 1, 0], [0, 0, 0, 0]]
        let art = pdf(cmyk, inks)
        func place(_ data: Data, _ name: String) -> PixelBuffer? {
            let size = CGSize(width: 30 * inks.count, height: 20)
            let quad = Quad(rect: CGRect(x: 20, y: 20, width: size.width * 2, height: size.height * 2))
            var f = T.file([T.background(T.W, T.H, .white), T.smartLayer("Art", id: "id-\(name)", quad: quad, size: size)])
            f.globalBlocks = [("lnk2", PSDTestFile.link(id: "id-\(name)", name: "\(name).ai", data: data))]
            guard let r = T.load(f, "fidelity_\(name)", dir), r.state.layers.last?.isSmartObject == true else { return nil }
            return T.flatten(r.state)
        }
        guard let b = place(art, "cmyk_art") else { check(false, "CMYK vector art imports as a smart object"); return }
        let black = b.psdTestPixel(50, 40), red = b.psdTestPixel(110, 40), paper = b.psdTestPixel(170, 40)
        // a plain colorimetric conversion of the same inks, for comparison
        let rel = CGColor(colorSpace: cmyk, components: inks[0] + [1])!.converted(to: sRGBSpace, intent: .relativeColorimetric, options: nil)!.components!
        let relBlack = Int((rel[0] * 255).rounded())
        check(Int(black.0) < 12 && Int(black.1) < 12 && Int(black.2) < 12 && (relBlack < 20 || Int(black.0) < relBlack - 12),
              "CMYK art (\(press != nil ? "Coated FOGRA39" : "Generic CMYK")): rich black is black with black point compensation (\(black); colorimetric \(relBlack))")
        check(paper.0 >= 252 && paper.1 >= 252 && paper.2 >= 252 && red.0 > 200 && red.1 < 60, "CMYK art: paper stays white and red stays red (\(paper), \(red))")
        // RGB art is untouched
        let rgbArt = pdf(sRGBSpace, [[0.1, 0.1, 0.1], [0.9, 0.2, 0.2], [1, 1, 1]])
        if let c = place(rgbArt, "rgb_art") {
            let p = c.psdTestPixel(50, 40)
            check(abs(Int(p.0) - 26) <= 2 && abs(Int(p.1) - 26) <= 2, "RGB art keeps its colours (\(p))")
        }
        // CMYK document: same conversion
        var f = PSDTestFile(width: 20, height: 10); f.mode = 4
        var l = PSDTestLayer(name: "Ink"); l.rect = IRect(x: 0, y: 0, width: 20, height: 10)
        let full = [UInt8](repeating: 255, count: 200)
        var c = full, m = full, y = full, k = full
        for i in 0..<200 where i % 20 < 10 { c[i] = 64; m[i] = 82; y[i] = 84; k[i] = 25 }   // stored inverted: 255 = no ink
        l.planes = [0: c, 1: m, 2: y, 3: k, -1: full]
        f.layers = [l]; f.merged = [c, m, y, k]
        if let px = T.load(f, "fidelity_cmyk_doc")?.state.layers.first?.raster?.buffer {
            let rb = px.psdTestPixel(5, 5), white = px.psdTestPixel(15, 5)
            check(rb.0 < 14 && rb.1 < 14 && rb.2 < 14 && white.0 >= 252, "CMYK document: rich black converts to black, paper to white (\(rb), \(white))")
        } else { check(false, "CMYK document imports") }
    }
}
