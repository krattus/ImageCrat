import AppKit
import SwiftUI
import ImageCratCore

/// Self tests for lists, area type, variable fonts, emoji, world-ready text, Dynamic Text, glyph alternates and
/// Match Font. Run with `LUMEN_SELFTEST_ONLY=type2 Lumen --selftest <dir>` (or a longer prefix such as type2_area).
enum TypeSelfTests2 {
    static func register() {
        let tests: [(String, (URL) -> Void)] = [
            ("type2_lists", lists),
            ("type2_area", area),
            ("type2_variable", variable),
            ("type2_emoji", emoji),
            ("type2_world", world),
            ("type2_dynamic", dynamic),
            ("type2_convert", convert),
            ("type2_codable", codable),
            ("type2_glyphs", glyphs),
            ("type2_tool", { TypeToolSelfTest.run($0) }),
            ("type2_matchfont", matchFont),
            ("type2_ui", ui),
        ]
        FeatureModules.selfTests.append(contentsOf: tests)
    }

    static func layer(_ t: TextContent, _ name: String = "Text") -> Layer { Layer(name: name, content: .text(t)) }

    static func outline(_ p: VectorPath, _ color: RGBA = RGBA(hex: "FFFFFF")!, fill: RGBA? = nil) -> Layer {
        Layer(name: "outline", content: .shape(ShapeContent(geometry: .path(p), fill: fill.map { .color($0) } ?? .none,
                                                            stroke: StrokeStyle(paint: .color(color), width: 1))))
    }

    static func boxOutline(_ t: TextContent) -> Layer {
        outline(.rect(CGRect(origin: t.position, size: t.boxSize ?? .zero)), RGBA(hex: "FFFFFF")!.withAlpha(0.8), fill: RGBA(hex: "FFFFFF")!.withAlpha(0.25))
    }

    static func text(_ s: String, font: String, size: Double, at p: CGPoint, color: String = "1B1F3A") -> TextContent {
        var t = TextContent()
        t.text = s; t.fontName = font; t.fontSize = size; t.color = RGBA(hex: color)!; t.position = p
        return t
    }

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        print(ok ? "PASS \(name)" : "FAIL \(name) \(detail())")
    }

    // MARK: Lists

    static func lists(_ out: URL) {
        var st = SelfTest.baseState(720, 420)
        var a = text("Bulleted list item one\nSecond item wraps onto a following line to show the hanging indent\n\nThird item after an empty paragraph",
                     font: "Helvetica", size: 17, at: CGPoint(x: 16, y: 16))
        a.boxSize = CGSize(width: 220, height: 190)
        a.list = TextListStyle(kind: .bullet, bullet: .disc)
        a.spaceAfter = 4
        var b = text("Numbered from three\nFourth item\nFifth item is long enough to wrap in the box",
                     font: "Georgia", size: 17, at: CGPoint(x: 250, y: 16))
        b.boxSize = CGSize(width: 220, height: 190)
        b.list = TextListStyle(kind: .numbered, numbering: .decimal, start: 3)
        var c = text("Roman one\nRoman two\nRoman three\nRoman four", font: "Palatino-Roman", size: 17, at: CGPoint(x: 484, y: 16))
        c.boxSize = CGSize(width: 220, height: 190)
        c.list = TextListStyle(kind: .numbered, numbering: .upperRoman, suffix: ")")
        var d = text("Custom arrow glyph\nColoured markers\nCentered alignment", font: "AvenirNext-Medium", size: 17, at: CGPoint(x: 16, y: 220))
        d.boxSize = CGSize(width: 220, height: 180)
        d.list = TextListStyle(kind: .bullet, bullet: .custom, customGlyph: "→", markerColor: RGBA(hex: "E94F37")!)
        d.alignment = .center
        var e = text("alpha item\nbeta item\ngamma item", font: "Helvetica", size: 17, at: CGPoint(x: 250, y: 220))
        e.list = TextListStyle(kind: .numbered, numbering: .lowerAlpha, suffix: ".")   // point text list
        var f = text("البند الأول\nالبند الثاني في القائمة\nالبند الثالث", font: "GeezaPro", size: 18, at: CGPoint(x: 484, y: 220))
        f.boxSize = CGSize(width: 220, height: 180)
        f.composer = .worldReady; f.direction = .rtl; f.alignment = .right
        f.list = TextListStyle(kind: .numbered)
        for t in [a, b, c, d, f] { st.layers.append(boxOutline(t)) }
        for t in [a, b, c, d, e, f] { st.layers.append(layer(t)) }
        SelfTest.save(st, "type2_lists", out)
        let L = TextRenderer.layout(b)
        let markers = L.lines.filter { $0.isMarker }.count
        check(markers == 3, "list markers", "\(markers)")
        check(NumberingStyle.roman(1994) == "MCMXCIV" && NumberingStyle.alpha(28) == "AB", "list numbering formats")
        // bullets of point text sit left of the text (hanging indent) and text starts at the same x for all items
        let E = TextRenderer.layout(e)
        let textXs = E.lines.filter { !$0.isMarker }.map { $0.transform.tx }
        check(Set(textXs.map { Int($0.rounded()) }).count == 1, "list hanging indent aligned", "\(textXs)")
    }

    // MARK: Area type

    static func area(_ out: URL) {
        var st = SelfTest.baseState(720, 380)
        let star = VectorPath.polygon(in: CGRect(x: 20, y: 20, width: 340, height: 340), sides: 5, starRatio: 0.5)
        let circle = VectorPath.ellipse(CGRect(x: 380, y: 30, width: 320, height: 320))
        st.layers.append(outline(star, fill: RGBA(hex: "FFFFFF")!.withAlpha(0.35)))
        st.layers.append(outline(circle, fill: RGBA(hex: "FFFFFF")!.withAlpha(0.35)))
        let lorem = "Area type flows inside any closed path. Each line is intersected with the shape, so the text follows the outline of a star or a circle while respecting paragraph alignment. Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris."
        var base = text(lorem, font: "Helvetica", size: 12, at: .zero)
        base.alignment = .center
        let a = TextContent.areaText(in: star, base: base)
        var bb = base
        bb.alignment = .justify; bb.fontName = "Georgia"; bb.fontSize = 13
        bb.text = lorem + " " + lorem
        let b = TextContent.areaText(in: circle, base: bb)
        st.layers.append(layer(a)); st.layers.append(layer(b))
        SelfTest.save(st, "type2_area", out)
        // every line lies inside the shape
        func inside(_ t: TextContent, _ p: VectorPath) -> Bool {
            let L = TextRenderer.layout(t)
            let cg = p.cgPath
            for l in L.lines where !l.isMarker {
                let r = l.bounds.offsetBy(dx: t.position.x, dy: t.position.y).insetBy(dx: 1, dy: 3)
                for q in [CGPoint(x: r.minX, y: r.midY), CGPoint(x: r.maxX, y: r.midY)] where !cg.contains(q) { return false }
            }
            return L.lines.count > 3
        }
        check(inside(a, star), "area text inside star")
        check(inside(b, circle), "area text inside circle")
    }

    // MARK: Variable fonts

    static func variable(_ out: URL) {
        var st = SelfTest.baseState(720, 420)
        var y = 12.0
        var found: [String] = []
        for (font, tag, values) in [("Skia-Regular", "wght", [0.48, 1.0, 1.8, 3.2]), ("Skia-Regular", "wdth", [0.62, 1.0, 1.3]),
                                    ("Montserrat-Regular", "wght", [100.0, 400, 900]), ("BodoniModa-Regular", "opsz", [6.0, 96])] {
            let axes = FontAxis.axes(fontName: font)
            guard axes.contains(where: { $0.tag == tag }) else { print("SKIP variable \(font) \(tag)"); continue }
            found.append("\(font):\(axes.map { "\($0.tag)[\($0.min)…\($0.max)]" }.joined(separator: ","))")
            var x = 12.0
            for v in values {
                var t = text("\(tag) \(v)", font: font, size: 30, at: CGPoint(x: x, y: y))
                t.variations = [tag: v]
                st.layers.append(layer(t))
                x += Double(TextRenderer.layout(t).baseRect.width) + 18
            }
            y += 52
        }
        // per-run axis override
        var r = text("Variable weight per run", font: "Montserrat-Regular", size: 40, at: CGPoint(x: 12, y: y + 6))
        r.variations = ["wght": 200]
        r.applyStyle(CharacterStyle(variations: ["wght": 900]), to: NSRange(location: 9, length: 6))
        st.layers.append(layer(r))
        SelfTest.save(st, "type2_variable", out)
        print("variable fonts: \(found)")
        // weight really changes the outline: compare ink of wght 100 vs 900
        var t1 = text("MMMM", font: "Montserrat-Regular", size: 60, at: .zero); t1.variations = ["wght": 100]
        var t2 = t1; t2.variations = ["wght": 900]
        let i1 = inkArea(TextRenderer.outlinePath(t1)), i2 = inkArea(TextRenderer.outlinePath(t2))
        check(Double(i2) > Double(i1) * 1.8, "variable wght changes glyphs", "\(i1) vs \(i2)")
    }

    static func inkArea(_ p: CGPath) -> Int {
        let b = p.boundingBoxOfPath.integral
        guard b.width > 0, b.height > 0, let ctx = CGContext(data: nil, width: Int(b.width), height: Int(b.height), bitsPerComponent: 8, bytesPerRow: 0,
                                                             space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        ctx.translateBy(x: -b.minX, y: -b.minY)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(p); ctx.fillPath()
        guard let d = ctx.data else { return 0 }
        let bp = d.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * ctx.height)
        var n = 0
        for i in 0..<(ctx.bytesPerRow * ctx.height) where bp[i] > 127 { n += 1 }
        return n
    }

    // MARK: Emoji & colour fonts

    static func emoji(_ out: URL) {
        var st = SelfTest.baseState(640, 360)
        let a = text("Emoji 👋🏽 in Helvetica 🌍🎉", font: "Helvetica", size: 34, at: CGPoint(x: 16, y: 16))
        var b = text("Family 👨‍👩‍👧 flags 🇪🇪🇯🇵 keycap 1️⃣ ❤️", font: "Georgia", size: 28, at: CGPoint(x: 16, y: 76))
        b.applyStyle(CharacterStyle(fontSize: 44), to: NSRange(location: 7, length: 8))
        var c = text("Wrapping 😀 emoji 🚀 inside 🍕 a justified 🎨 paragraph box 🌈 works ✅", font: "AvenirNext-Regular", size: 22, at: CGPoint(x: 16, y: 150))
        c.boxSize = CGSize(width: 300, height: 190); c.alignment = .justify
        let circle = VectorPath.ellipse(CGRect(x: 360, y: 150, width: 240, height: 180))
        var d = text("🌟 emoji on a path 🌙 ☀️ ⭐", font: "Helvetica-Bold", size: 22, at: .zero)
        d.pathText = TextOnPath(path: circle, startOffset: 0)
        st.layers.append(boxOutline(c)); st.layers.append(outline(circle))
        for t in [a, b, c, d] { st.layers.append(layer(t)) }
        SelfTest.save(st, "type2_emoji", out)
        // the emoji run uses the colour font
        let L = TextRenderer.layout(a)
        var fonts = Set<String>()
        for pl in L.lines { for r in pl.drawnRuns { if let f = (CTRunGetAttributes(r.run) as NSDictionary)[kCTFontAttributeName as String] { fonts.insert(CTFontCopyPostScriptName(f as! CTFont) as String) } } }
        check(fonts.contains("AppleColorEmoji"), "emoji falls back to Apple Color Emoji", "\(fonts)")
        // colour pixels actually rendered
        let sp = CanvasSpace(width: st.width, height: st.height)
        var s2 = DocumentState(width: 640, height: 80)
        s2.layers = [layer(text("🍎🍏", font: "Helvetica", size: 48, at: CGPoint(x: 10, y: 5)))]
        let buf = RenderEngine.renderBuffer(Compositor.shared.composite(s2), docRect: s2.canvasRect, space: CanvasSpace(width: 640, height: 80))
        var red = 0, green = 0
        for yy in stride(from: 0, to: 80, by: 2) { for xx in stride(from: 0, to: 140, by: 2) {
            let (r8, g8, b8, a8) = buf.pixel(xx, yy)
            let pr = Double(r8) / 255, pg = Double(g8) / 255, pb = Double(b8) / 255, pa = Double(a8) / 255
            if pr > 0.6 && pg < 0.35 && pa > 0.5 { red += 1 }
            if pg > 0.5 && pr < 0.6 && pb < 0.4 && pa > 0.5 { green += 1 }
        } }
        _ = sp
        check(red > 20 && green > 20, "emoji rendered in colour", "red \(red) green \(green)")
    }

    // MARK: World-ready (RTL + complex scripts)

    static func world(_ out: URL) {
        var st = SelfTest.baseState(720, 520)
        var y = 12.0
        let samples: [(String, String, Double)] = [
            ("مرحبا بالعالم — نص عربي 123 مع English", "GeezaPro", 30),
            ("שלום עולם — טקסט בעברית", "ArialHebrew", 30),
            ("नमस्ते दुनिया — क्षत्रिय श्री हिन्दी", "KohinoorDevanagari-Regular", 30),
            ("สวัสดีชาวโลก ภาษาไทย", "Thonburi", 30),
            ("தமிழ் எழுத்து · ಕನ್ನಡ · বাংলা লিপি", "Kohinoor Bangla", 26),
        ]
        for (s, f, size) in samples {
            var t = text(s, font: f, size: size, at: CGPoint(x: 12, y: y))
            t.composer = .worldReady
            st.layers.append(layer(t))
            y += size * 1.6
        }
        // Arabic paragraph, RTL, right aligned, justified, with first-line indent on the right
        var ar = text("هذا نص عربي طويل يلتف داخل مربع النص. يجب أن تكون الحروف متصلة بشكل صحيح وأن يبدأ كل سطر من اليمين. النص الثاني هنا.",
                      font: "GeezaPro", size: 20, at: CGPoint(x: 12, y: y + 6))
        ar.boxSize = CGSize(width: 330, height: 170); ar.composer = .worldReady; ar.direction = .rtl; ar.alignment = .justify
        ar.firstLineIndent = 30
        // Thai paragraph (no spaces between words: dictionary line breaking)
        var th = text("ภาษาไทยเป็นภาษาที่ไม่มีการเว้นวรรคระหว่างคำการตัดบรรทัดจึงต้องใช้พจนานุกรมเพื่อหาตำแหน่งที่ถูกต้อง",
                      font: "Thonburi", size: 20, at: CGPoint(x: 360, y: y + 6))
        th.boxSize = CGSize(width: 340, height: 170)
        st.layers.append(boxOutline(ar)); st.layers.append(boxOutline(th))
        st.layers.append(layer(ar)); st.layers.append(layer(th))
        // Arabic on a path keeps joining
        var wave = VectorPath()
        wave.subpaths = [Subpath(points: [
            PathPoint(anchor: CGPoint(x: 60, y: 500), inControl: CGPoint(x: 60, y: 500), outControl: CGPoint(x: 200, y: 430)),
            PathPoint(anchor: CGPoint(x: 660, y: 500), inControl: CGPoint(x: 520, y: 430), outControl: CGPoint(x: 660, y: 500)),
        ], closed: false)]
        var ap = text("مرحبا بالعالم على المسار", font: "GeezaPro", size: 26, at: .zero)
        ap.pathText = TextOnPath(path: wave, startOffset: 0)
        st.layers.append(outline(wave)); st.layers.append(layer(ap))
        SelfTest.save(st, "type2_world", out)

        // Shaping checks: Arabic joins (contextual forms → glyphs differ from isolated forms),
        // Devanagari conjunct forms fewer glyphs than characters, RTL box lines are right-aligned.
        let joined = glyphIDs("بب", "GeezaPro"), isolated = glyphIDs("ب", "GeezaPro")
        check(joined.count == 2 && joined[0] != isolated.first && joined[1] != isolated.first, "arabic contextual joining", "\(joined) vs \(isolated)")
        let deva = glyphIDs("क्ष", "KohinoorDevanagari-Regular")
        check(deva.count < 3, "devanagari conjunct shaping", "\(deva)")
        let L = TextRenderer.layout(ar)
        let rights = L.lines.filter { !$0.isMarker }.map { $0.bounds.maxX }
        check(rights.count > 2 && rights.dropFirst().allSatisfy { abs($0 - rights[1]) < 1.5 } && rights[1] > 320 && abs(rights[1] - rights[0] - 30) < 1.5,
              "rtl lines flush right (first-line indent on the right)", "\(rights)")
        let thL = TextRenderer.layout(th).lines.filter { !$0.isMarker }
        check(thL.count >= 2, "thai wraps", "\(thL.count)")
        // path Arabic uses one shaped line (slices) so joining is kept
        let P = TextRenderer.layout(ap)
        check(!P.lines.isEmpty && P.lines.allSatisfy { $0.slices != nil }, "arabic on path keeps shaping")
    }

    static func glyphIDs(_ s: String, _ font: String) -> [CGGlyph] {
        let f = CTFontCreateWithName(font as CFString, 20, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: f]))
        var out: [CGGlyph] = []
        for r in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(r)
            var g = [CGGlyph](repeating: 0, count: n)
            CTRunGetGlyphs(r, CFRange(location: 0, length: n), &g)
            out += g
        }
        return out
    }

    // MARK: Dynamic Text

    static func dynamic(_ out: URL) {
        var st = SelfTest.baseState(720, 420)
        var a = text("Dynamic Text fills its box", font: "Helvetica-Bold", size: 24, at: CGPoint(x: 16, y: 16))
        a.boxSize = CGSize(width: 300, height: 120)
        a.fitToBox = TextFit()
        var b = a
        b.position = CGPoint(x: 340, y: 16); b.boxSize = CGSize(width: 360, height: 260)
        var c = text("SALE", font: "Futura-Bold", size: 20, at: CGPoint(x: 16, y: 160))
        c.boxSize = CGSize(width: 300, height: 110); c.alignment = .center
        c.fitToBox = TextFit(adjustTracking: true)
        c.applyStyle(CharacterStyle(color: RGBA(hex: "E94F37")!), to: NSRange(location: 0, length: 2))
        var d = text("Fits the circle shape too, with mixed sizes", font: "Georgia", size: 10, at: .zero)
        d.alignment = .center
        d.applyStyle(CharacterStyle(fontSize: 20), to: NSRange(location: 0, length: 4))
        d = TextContent.areaText(in: .ellipse(CGRect(x: 360, y: 290, width: 200, height: 120)), base: d)
        d.fitToBox = TextFit()
        st.layers.append(outline(.ellipse(CGRect(x: 360, y: 290, width: 200, height: 120)), fill: RGBA(hex: "FFFFFF")!.withAlpha(0.3)))
        for t in [a, b, c] { st.layers.append(boxOutline(t)) }
        for t in [a, b, c, d] { st.layers.append(layer(t)) }
        SelfTest.save(st, "type2_dynamic", out)
        let fa = TextRenderer.fitInfo(a)!, fb = TextRenderer.fitInfo(b)!, fc = TextRenderer.fitInfo(c)!
        print(String(format: "dynamic text: small box %.1fpx, large box %.1fpx, tracking-fit %.1fpx +%.0f", 24 * fa.scale, 24 * fb.scale, 20 * fc.scale, fc.tracking))
        check(fb.scale > fa.scale * 1.3, "dynamic text grows with the box")
        let La = TextRenderer.layout(a)
        check(!La.overflowed && !La.brokeWords, "dynamic text fits")
        // the text fills the box: the fitted layout is near the box's width or height
        let used = La.lines.reduce(CGRect.null) { $0.union($1.bounds) }
        check(used.width > 300 * 0.8 || used.maxY > 120 * 0.75, "dynamic text fills box", "\(used)")
        // live update: resize the box (as the Type tool handles do) and the size follows
        var a2 = a
        a2.resizeBox(to: CGSize(width: 600, height: 240))
        check(TextRenderer.fitInfo(a2)!.scale > fa.scale * 1.5, "dynamic text follows box resize")
    }

    // MARK: Conversions

    static func convert(_ out: URL) {
        var t = text("one two three four five six seven eight nine ten", font: "Helvetica", size: 20, at: CGPoint(x: 10, y: 10))
        t.boxSize = CGSize(width: 150, height: 300)
        let nLines = TextRenderer.layout(t).lines.count
        var p = t
        p.convertToPointText()
        let hard = p.text.components(separatedBy: "\n").count
        check(p.boxSize == nil && hard == nLines, "convert to point text", "\(hard) vs \(nLines): \(p.text.debugDescription)")
        var q = p
        q.convertToParagraphText()
        check(q.boxSize != nil && TextRenderer.layout(q).lines.count == nLines, "convert to paragraph text")
        var a = TextContent.areaText(in: .ellipse(CGRect(x: 0, y: 0, width: 200, height: 200)), base: t)
        a.convertToParagraphText()
        check(a.area == nil && a.boxSize == CGSize(width: 200, height: 200), "area to paragraph text")
        // insertText shifts runs
        var r = text("abcdef", font: "Helvetica", size: 10, at: .zero)
        r.applyStyle(CharacterStyle(fontSize: 20), to: NSRange(location: 3, length: 3))
        r.insertText("XY", at: 1)
        check(r.text == "aXYbcdef" && r.runs.first?.location == 5 && r.runs.first?.length == 3, "insertText keeps runs", "\(r.runs)")
    }

    // MARK: Codable

    static func codable(_ out: URL) {
        var t = TextContent()
        t.text = "abc"
        t.list = TextListStyle(kind: .numbered, numbering: .lowerRoman, start: 4, hangingIndent: 30)
        t.area = AreaTextShape(path: .ellipse(CGRect(x: 0, y: 0, width: 50, height: 40)), inset: 2)
        t.fitToBox = TextFit(adjustTracking: true)
        t.composer = .worldReady; t.direction = .rtl
        t.variations = ["wght": 700]
        t.features.extra = ["ss02": 1, "aat:17:1": 1]
        t.applyStyle(CharacterStyle(variations: ["wdth": 80]), to: NSRange(location: 0, length: 1))
        let data = try! JSONEncoder().encode(t)
        let back = try? JSONDecoder().decode(TextContent.self, from: data)
        check(back == t, "type2 codable roundtrip")
        var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        for k in ["list", "area", "fitToBox", "composer", "direction", "variations"] { obj.removeValue(forKey: k) }
        if var f = obj["features"] as? [String: Any] { f.removeValue(forKey: "extra"); obj["features"] = f }
        let old = try! JSONSerialization.data(withJSONObject: obj)
        let o = try? JSONDecoder().decode(TextContent.self, from: old)
        check(o != nil && o!.list == nil && o!.area == nil && o!.composer == .latin && o!.variations.isEmpty && o!.features.extra.isEmpty,
              "type2 codable legacy")
        // corrupt / partial values decode tolerantly
        obj["list"] = ["kind": "numbered"]
        obj["direction"] = "sideways"
        let partial = try! JSONSerialization.data(withJSONObject: obj)
        let pz = try? JSONDecoder().decode(TextContent.self, from: partial)
        check(pz?.list?.kind == .numbered && pz?.list?.start == 1 && pz?.direction == .auto, "type2 codable partial")
    }

    // Filled in by the glyph / match-font / UI files.
    static func glyphs(_ out: URL) { GlyphsSelfTest.run(out) }
    static func matchFont(_ out: URL) { MatchFontSelfTest.run(out) }
    static func ui(_ out: URL) { TypeUISelfTest.run(out) }
}
