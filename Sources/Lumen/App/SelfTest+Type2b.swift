import AppKit
import SwiftUI
import ImageCratCore

// Glyphs panel / alternates, Match Font and panel snapshot self tests (see TypeSelfTests2).

enum GlyphsSelfTest {
    static func run(_ out: URL) {
        func check(_ ok: Bool, _ n: String, _ d: @autoclosure () -> String = "") { TypeSelfTests2.check(ok, n, d()) }
        let helv = GlyphCatalog.shared.glyphs("Helvetica")
        let letters = GlyphCatalog.shared.filtered("Helvetica", category: .letters, search: "")
        let byHex = GlyphCatalog.shared.filtered("Helvetica", category: .all, search: "U+0041")
        let byName = GlyphCatalog.shared.filtered("Helvetica", category: .all, search: "ampersand")
        check(helv.count > 200 && letters.count > 50 && byHex.count == 1 && byName.contains { $0.text == "&" }, "glyph catalog + search",
              "\(helv.count) \(letters.count) \(byHex.count) \(byName.count)")
        let emoji = GlyphCatalog.shared.filtered("AppleColorEmoji", category: .emoji, search: "")
        check(emoji.count > 500, "emoji font catalog", "\(emoji.count)")
        let amp = GlyphAlternates.alternates(for: "&", fontName: "HoeflerText-Regular")
        let a = GlyphAlternates.alternates(for: "a", fontName: "Montserrat-Regular")
        print("alternates: & Hoefler \(amp.map(\.label)); a Montserrat \(a.map(\.key))")
        check(!amp.isEmpty && a.contains { $0.key == "ss01" }, "opentype / aat alternates found")
        // unencoded glyph resolves back to a character + feature
        let unenc = GlyphCatalog.shared.glyphs("Montserrat-Regular").filter { $0.scalars.isEmpty }
        var resolved = 0, tried = 0
        for g in unenc.prefix(40) {
            guard let n = GlyphCatalog.glyphName(g.glyph, fontName: "Montserrat-Regular"), n.hasSuffix(".ss01") else { continue }
            tried += 1
            if GlyphAlternates.resolveUnencoded(g.glyph, fontName: "Montserrat-Regular") != nil { resolved += 1 }
        }
        check(tried == 0 || resolved > 0, "unencoded glyph resolves", "\(resolved)/\(tried)")

        // Rendering alternates in a layer (per-run feature settings)
        var st = SelfTest.baseState(640, 300)
        var x = 16.0
        for alt in [nil] + amp.prefix(4).map({ Optional($0) }) {
            var t = TypeSelfTests2.text("&", font: "HoeflerText-Regular", size: 72, at: CGPoint(x: x, y: 10))
            if let alt { t.features.extra = alt.extra }
            st.layers.append(TypeSelfTests2.layer(t))
            x += 90
        }
        var q = TypeSelfTests2.text("Quality alternates", font: "Montserrat-Regular", size: 40, at: CGPoint(x: 16, y: 120))
        q.applyStyle(CharacterStyle(features: OpenTypeFeatures(extra: ["ss01": 1])), to: NSRange(location: 0, length: 1))
        q.applyStyle(CharacterStyle(features: OpenTypeFeatures(extra: ["ss01": 1])), to: NSRange(location: 8, length: 1))
        st.layers.append(TypeSelfTests2.layer(q))
        let base = TypeSelfTests2.glyphIDs("a", "Montserrat-Regular")
        var ids: [CGGlyph] = []
        for pl in TextRenderer.layout(q).lines { for r in pl.drawnRuns {
            let n = CTRunGetGlyphCount(r.run); var g = [CGGlyph](repeating: 0, count: n); CTRunGetGlyphs(r.run, CFRange(location: 0, length: n), &g); ids += g } }
        check(ids.count > 9 && !base.isEmpty && ids[9] != base[0], "alternate applied in layout", "\(ids.prefix(12)) base \(base)")

        // Editor: select one character → alternates popup; apply; insert a glyph from the Glyphs panel
        var t = TypeSelfTests2.text("Q&A", font: "HoeflerText-Regular", size: 60, at: CGPoint(x: 16, y: 190))
        t.color = RGBA(hex: "8E44AD")!
        let layer = TypeSelfTests2.layer(t)
        st.layers.append(layer)
        let d = Document(state: st, name: "glyphs")
        let app = AppModel.shared
        app.add(d)
        defer { app.close(d) }
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        canvas.document = d
        d.selectLayer(layer.id)
        AppActions.canvas = canvas
        let tool = TextTool(kind: .text, canvas: canvas)
        tool.beginEditing(layer.id, isNew: false)
        tool.testSelect(NSRange(location: 1, length: 1))
        GlyphAlternatesPopup.shared.update(for: tool)
        let popupAlts = GlyphAlternatesPopup.shared.shownAlternates
        check(GlyphAlternatesPopup.shared.isVisible && !popupAlts.isEmpty, "on-canvas alternates popup", "\(popupAlts.count)")
        if let alt = popupAlts.first { tool.applyAlternate(alt.extra) }
        tool.testSelect(NSRange(location: 3, length: 0))
        let ok = GlyphInsert.insert(fontName: "HoeflerText-Regular", glyph: amp.last?.glyph ?? 0, text: "&", extra: amp.last?.extra ?? [:])
        tool.endEditing(commit: true)
        check(!GlyphAlternatesPopup.shared.isVisible, "popup hidden after editing")
        if let r = d.state.layer(layer.id)?.text {
            let withExtra = r.runs.filter { !($0.style.features?.extra.isEmpty ?? true) }
            check(ok && r.text == "Q&A&" && withExtra.count >= 1, "glyph insert + alternate runs", "\(r.text) \(r.runs)")
        }
        SelfTest.save(d.state, "type2_glyphs", out)
    }
}

enum MatchFontSelfTest {
    static func run(_ out: URL) {
        let fonts = ["Georgia", "Futura-Medium", "AmericanTypewriter", "Didot", "Baskerville", "Menlo-Regular", "Optima-Regular", "Rockwell-Regular"]
        var summary = DocumentState(width: 900, height: 60 + fonts.count * 70)
        let bg = PixelBuffer(width: summary.width, height: summary.height)
        bg.context.setFillColor(RGBA(hex: "F4F1EA")!.cgColor)
        bg.context.fill(CGRect(x: 0, y: 0, width: summary.width, height: summary.height))
        bg.markDirty()
        summary.layers = [Layer.raster(name: "bg", buffer: bg)]
        var top3 = 0
        var y = 10.0
        let t0 = CFAbsoluteTimeGetCurrent()
        for f in fonts {
            var st = SelfTest.baseState(700, 140)
            let t = TypeSelfTests2.text("Handgloves 2026", font: f, size: 64, at: CGPoint(x: 30, y: 25))
            st.layers.append(TypeSelfTests2.layer(t))
            let sp = CanvasSpace(width: st.width, height: st.height)
            let b = TextRenderer.docBounds(t).insetBy(dx: -12, dy: -12).integral.intersection(CGRect(x: 0, y: 0, width: 700, height: 140))
            let r = IRect(enclosing: b)
            let buf = RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: r, space: sp)
            let s = MatchFontSession()
            s.load(image: buf.makeCGImage(), docRect: b)
            s.run(async: false)
            let family = NSFont(name: f, size: 12)?.familyName ?? f
            let rank = (s.results.firstIndex { $0.fontName == f || $0.family == family }).map { $0 + 1 }
            if let k = rank, k <= 3 { top3 += 1 }
            print("matchfont \(f): recognized '\(s.text)' rank \(rank.map(String.init) ?? "-") top3 \(s.results.prefix(3).map(\.fontName))")
            // summary row: the sample and the top 3 renderings
            var src = TypeSelfTests2.text("\(f)", font: f, size: 22, at: CGPoint(x: 10, y: y + 8))
            src.color = RGBA(hex: "1B1F3A")!
            summary.layers.append(TypeSelfTests2.layer(src))
            var x = 250.0
            for (i, c) in s.results.prefix(3).enumerated() {
                var m = TypeSelfTests2.text("\(i + 1). \(c.fontName)", font: c.fontName, size: 18, at: CGPoint(x: x, y: y + 12))
                m.color = (c.fontName == f || c.family == family) ? RGBA(hex: "1E8449")! : RGBA(hex: "922B21")!
                summary.layers.append(TypeSelfTests2.layer(m))
                x += 215
            }
            y += 70
        }
        print(String(format: "matchfont: %d/%d fonts ranked top-3 (%.1fs)", top3, fonts.count, CFAbsoluteTimeGetCurrent() - t0))
        TypeSelfTests2.check(top3 >= fonts.count - 2, "match font top-3", "\(top3)/\(fonts.count)")
        SelfTest.save(summary, "type2_matchfont", out)
    }
}

enum TypeUISelfTest {
    static func run(_ out: URL) {
        var st = SelfTest.baseState(400, 300)
        var t = TypeSelfTests2.text("List one\nList two", font: "Montserrat-Regular", size: 30, at: CGPoint(x: 20, y: 20))
        t.boxSize = CGSize(width: 300, height: 200)
        t.list = TextListStyle(kind: .numbered)
        t.fitToBox = TextFit()
        t.composer = .worldReady
        t.variations = ["wght": 650]
        let l = TypeSelfTests2.layer(t)
        st.layers.append(l)
        let d = Document(state: st, name: "ui")
        let app = AppModel.shared
        app.add(d)
        d.selectLayer(l.id)
        defer { app.close(d) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize, wait: Double = 0.3) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            let end = Date().addingTimeInterval(wait)
            while Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
        }
        snap(CharacterPanel(), "type2_ui_character", CGSize(width: 300, height: 560))
        snap(ParagraphPanel(), "type2_ui_paragraph", CGSize(width: 300, height: 640))
        GlyphsPanelModel.shared.fontOverride = "HoeflerText-Regular"
        snap(GlyphsPanel(), "type2_ui_glyphs", CGSize(width: 300, height: 360))
        GlyphsPanelModel.shared.category = .unencoded
        snap(GlyphsPanel(), "type2_ui_glyphs_unencoded", CGSize(width: 300, height: 260))
        GlyphsPanelModel.shared.category = .all
        GlyphsPanelModel.shared.fontOverride = nil

        // Match Font dialog on a document with sample text (no selection → whole canvas)
        var ms = SelfTest.baseState(600, 200)
        ms.layers.append(TypeSelfTests2.layer(TypeSelfTests2.text("Handgloves", font: "Didot", size: 90, at: CGPoint(x: 40, y: 40))))
        let md = Document(state: ms, name: "matchfont")
        app.add(md)
        defer { app.close(md) }
        let session = MatchFontSession()
        session.load(from: md)
        session.run(async: false)
        snap(DraggableCard { MatchFontDialog(preloaded: session) }, "type2_ui_matchfont", CGSize(width: 500, height: 640))
    }
}

/// Type tool interactions: click inside a shape → area type; drag a box handle → Dynamic Text follows; list while editing
/// switches the editor to live mode; menu conversions.
enum TypeToolSelfTest {
    static func run(_ out: URL) {
        func check(_ ok: Bool, _ n: String, _ d: @autoclosure () -> String = "") { TypeSelfTests2.check(ok, n, d()) }
        var st = SelfTest.baseState(640, 400)
        let star = VectorPath.polygon(in: CGRect(x: 20, y: 20, width: 300, height: 300), sides: 5, starRatio: 0.55)
        let shape = Layer(name: "Star", content: .shape(ShapeContent(geometry: .path(star), fill: .color(RGBA(hex: "FFFFFF")!.withAlpha(0.4)))))
        st.layers.append(shape)
        let d = Document(state: st, name: "tool")
        let app = AppModel.shared
        app.add(d)
        defer { app.close(d) }
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        canvas.document = d
        AppActions.canvas = canvas
        d.selectLayer(shape.id)
        app.textTool.fontName = "AvenirNext-Regular"; app.textTool.fontSize = 14; app.textTool.alignment = .center
        let tool = TextTool(kind: .text, canvas: canvas)
        func ev(_ p: CGPoint) -> ToolEvent { ToolEvent(doc: p, view: canvas.docToView(p), pressure: 1, modifiers: [], clickCount: 1, isTablet: false) }
        tool.mouseDown(ev(CGPoint(x: 170, y: 180)))
        tool.testType("Clicking inside a closed shape with the Type tool creates area type that flows inside the outline of the shape.")
        tool.endEditing(commit: true)
        let areaLayer = d.state.layers.last
        check(areaLayer?.text?.area != nil && areaLayer?.id != shape.id, "click inside shape creates area type")

        // paragraph box with Dynamic Text; drag the bottom-right handle while editing
        var t = TypeSelfTests2.text("Resize me", font: "Helvetica-Bold", size: 20, at: CGPoint(x: 360, y: 40))
        t.boxSize = CGSize(width: 120, height: 60); t.fitToBox = TextFit()
        let bl = TypeSelfTests2.layer(t)
        d.addLayer(bl)
        d.selectLayer(bl.id)
        let s0 = TextRenderer.fitInfo(t)!.scale
        tool.beginEditing(bl.id, isNew: false)
        tool.mouseDown(ev(CGPoint(x: 480, y: 100)))      // bottom-right handle
        tool.mouseDragged(ev(CGPoint(x: 620, y: 200)))
        tool.mouseUp(ev(CGPoint(x: 620, y: 200)))
        tool.endEditing(commit: true)
        let r = d.state.layer(bl.id)?.text
        let s1 = r.flatMap { TextRenderer.fitInfo($0)?.scale } ?? 0
        check(r?.boxSize == CGSize(width: 260, height: 160) && s1 > s0 * 1.5, "box handle resize + live Dynamic Text", "\(String(describing: r?.boxSize)) \(s0)→\(s1)")

        // list applied while editing plain paragraph text → editor switches to live mode, layer stays visible
        var p = TypeSelfTests2.text("First\nSecond", font: "Helvetica", size: 18, at: CGPoint(x: 360, y: 250))
        p.boxSize = CGSize(width: 200, height: 100)
        let pl = TypeSelfTests2.layer(p)
        d.addLayer(pl)
        d.selectLayer(pl.id)
        tool.beginEditing(pl.id, isNew: false)
        let hiddenBefore = d.hiddenLayers.contains(pl.id)
        TypeActions2.setList(TextListStyle(kind: .bullet))
        let hiddenAfter = d.hiddenLayers.contains(pl.id)
        tool.endEditing(commit: true)
        check(hiddenBefore && !hiddenAfter && d.state.layer(pl.id)?.text?.list != nil, "list while editing → live editor")
        SelfTest.save(d.state, "type2_tool", out)

        // menu conversion with undo entry
        let before = d.history.count
        TypeActions2.convert("Convert to Point Text") { $0.convertToPointText() }
        check(d.state.layer(pl.id)?.text?.boxSize == nil && d.history.count == before + 1, "convert to point text (menu)")
    }
}
