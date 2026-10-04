import AppKit
import SwiftUI
import ImageCratCore

/// Type feature self tests (mixed runs, vertical, warp, type on a path, OpenType, paragraph settings, Codable).
/// Set LUMEN_SELFTEST_ONLY=type to run only these.
extension SelfTest {
    static func textLayer(_ t: TextContent, _ name: String = "Text") -> Layer { Layer(name: name, content: .text(t)) }

    static func runTypeTests(_ out: URL) {
        // LUMEN_SELFTEST_ONLY=type2… runs only the matching feature-module tests (skips the rest of the suite).
        if let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"], only.hasPrefix("type2") {
            for (name, t) in FeatureModules.selfTests where name.hasPrefix(only) { t(out) }
            print("done (\(only) only)")
            exit(0)
        }
        // Mixed run styles
        do {
            var st = baseState(560, 300)
            var t = TextContent()
            t.text = "Mixed Styles\nin one layer"
            t.fontName = "Helvetica"; t.fontSize = 48; t.color = RGBA(hex: "1B1F3A")!
            t.position = CGPoint(x: 30, y: 40)
            t.applyStyle(CharacterStyle(fontName: "Helvetica-Bold", fontSize: 72, color: RGBA(hex: "E94F37")!), to: NSRange(location: 0, length: 5))
            t.applyStyle(CharacterStyle(fontName: "Georgia-Italic", color: RGBA(hex: "2E86DE")!, underline: true), to: NSRange(location: 6, length: 6))
            t.applyStyle(CharacterStyle(tracking: 300, strikethrough: true), to: NSRange(location: 16, length: 3))
            t.applyStyle(CharacterStyle(fontSize: 28, baselineShift: 18, fauxBold: true), to: NSRange(location: 20, length: 5))
            t.applyStyle(CharacterStyle(color: RGBA(hex: "27AE60")!, fauxItalic: true, horizontalScale: 1.6), to: NSRange(location: 20, length: 2))
            print("mixed runs: \(t.runs.count) \(t.runs.map { "\($0.location)+\($0.length)" })")
            st.layers.append(textLayer(t))
            // identical-to-default overrides must be dropped, adjacent identical runs coalesced
            var t2 = t
            t2.applyStyle(CharacterStyle(fontSize: 48), to: NSRange(location: 12, length: 4))
            t2.applyStyle(CharacterStyle(color: .white), to: NSRange(location: 0, length: 2))
            t2.applyStyle(CharacterStyle(color: .white), to: NSRange(location: 2, length: 3))
            let whiteRuns = t2.runs.filter { $0.style.color == .white }
            print(whiteRuns.count == 1 && whiteRuns[0].length == 5 ? "PASS run coalesce" : "FAIL run coalesce \(t2.runs)")
            // round trip through the editor representation
            let ed = TextRenderer.attributedString(t, scale: 2, forEditor: true)
            let back = TextRenderer.content(from: ed, base: t)
            print(back.runs == t.runs ? "PASS editor runs roundtrip" : "FAIL editor runs roundtrip\n\(back.runs)\n\(t.runs)")
            save(st, "type_mixed_runs", out)
        }

        // Vertical type: point (CJK + Latin) and a box that wraps into several columns
        do {
            var st = baseState(480, 360)
            var t = TextContent()
            t.orientation = .vertical
            t.text = "縦書きテキスト\nVERTICAL"
            t.fontName = "HiraginoSans-W6"; t.fontSize = 36; t.color = RGBA(hex: "1B1F3A")!
            t.position = CGPoint(x: 150, y: 20)   // top-right anchor
            st.layers.append(textLayer(t))
            var b = TextContent()
            b.orientation = .vertical
            b.text = "Columns flow right to left in a box"
            b.fontName = "Helvetica-Bold"; b.fontSize = 22; b.color = RGBA(hex: "8E44AD")!
            b.position = CGPoint(x: 220, y: 30); b.boxSize = CGSize(width: 240, height: 300)
            b.applyStyle(CharacterStyle(color: RGBA(hex: "E94F37")!), to: NSRange(location: 0, length: 7))
            st.layers.append(textLayer(b))
            var bl = shapeLayer(CGRect(x: 220, y: 30, width: 240, height: 300), RGBA(hex: "FFFFFF")!.withAlpha(0.25), radius: 0)
            bl.name = "box"
            st.layers.insert(bl, at: 1)
            save(st, "type_vertical", out)
        }

        // Warp Text styles
        for (style, bend) in [(WarpStyle.arc, 50.0), (.flag, 60), (.bulge, 50), (.fish, 45), (.rise, 50), (.twist, 40), (.arch, 50), (.squeeze, 60)] {
            var st = baseState(480, 300)
            var t = TextContent()
            t.text = "WARP TEXT"
            t.fontName = "Helvetica-Bold"; t.fontSize = 72; t.color = RGBA(hex: "1B1F3A")!
            t.position = CGPoint(x: 50, y: 100)
            t.warp = TextWarp(style: style, bend: bend)
            var l = textLayer(t)
            l.effects.stroke.enabled = true; l.effects.stroke.size = 2; l.effects.stroke.paint = .color(.white)
            st.layers.append(l)
            let q = TextRenderer.docQuad(t)
            st.layers.append(Layer(name: "bounds", content: .shape(ShapeContent(geometry: .path(VectorPath(subpaths: [Subpath(points: q.points.map { PathPoint($0) }, closed: true)])),
                                                                                  fill: .none, stroke: StrokeStyle(paint: .color(RGBA(hex: "E94F37")!), width: 1)))))
            save(st, "type_warp_\(style.rawValue)", out)
        }

        // Type on a circular path (+ an open wave path, centered)
        do {
            var st = baseState(480, 360)
            let circle = VectorPath.ellipse(CGRect(x: 120, y: 60, width: 240, height: 240))
            st.layers.append(Layer(name: "circle", content: .shape(ShapeContent(geometry: .path(circle), fill: .none,
                                                                                  stroke: StrokeStyle(paint: .color(RGBA(hex: "FFFFFF")!), width: 1)))))
            var t = TextContent()
            t.text = "TYPE ON A CIRCULAR PATH • LUMEN •"
            t.fontName = "Helvetica-Bold"; t.fontSize = 22; t.color = RGBA(hex: "1B1F3A")!; t.tracking = 80
            t.pathText = TextOnPath(path: circle, startOffset: 0)
            t.applyStyle(CharacterStyle(color: RGBA(hex: "E94F37")!), to: NSRange(location: 24, length: 9))
            st.layers.append(textLayer(t))
            // flipped inside
            var t3 = t
            t3.text = "inside the circle, flipped"; t3.runs = []; t3.fontName = "Georgia-Italic"; t3.fontSize = 18; t3.tracking = 0
            t3.pathText = TextOnPath(path: circle, startOffset: 180, flipped: true)
            t3.alignment = .center
            st.layers.append(textLayer(t3))
            save(st, "type_path_circle", out)
            let b = TextRenderer.docBounds(t)
            print("path text bounds \(b)")

            var st2 = baseState(480, 300)
            var wave = VectorPath()
            wave.subpaths = [Subpath(points: [
                PathPoint(anchor: CGPoint(x: 30, y: 180), inControl: CGPoint(x: 30, y: 180), outControl: CGPoint(x: 110, y: 60)),
                PathPoint(anchor: CGPoint(x: 240, y: 150), inControl: CGPoint(x: 170, y: 60), outControl: CGPoint(x: 310, y: 240)),
                PathPoint(anchor: CGPoint(x: 450, y: 120), inControl: CGPoint(x: 380, y: 240), outControl: CGPoint(x: 450, y: 120)),
            ], closed: false)]
            st2.layers.append(Layer(name: "wave", content: .shape(ShapeContent(geometry: .path(wave), fill: .none,
                                                                               stroke: StrokeStyle(paint: .color(.white), width: 1)))))
            var w = TextContent()
            w.text = "Text flowing along an open bezier path"
            w.fontName = "Avenir Next"; w.fontName = "AvenirNext-DemiBold"; w.fontSize = 24; w.color = RGBA(hex: "2E4057")!
            w.alignment = .center
            w.pathText = TextOnPath(path: wave, startOffset: Double(PathSampler(wave).total / 2))
            st2.layers.append(textLayer(w))
            save(st2, "type_path_wave", out)
        }

        // OpenType features
        do {
            var st = baseState(560, 360)
            let sample = "office 1/2 3/4 1st 2nd 0123456789 Small Caps & Qag"
            var y = 20.0
            for (label, f) in [("default", OpenTypeFeatures()),
                               ("no liga + frac + ordn", OpenTypeFeatures(standardLigatures: false, fractions: true, ordinals: true)),
                               ("smcp + onum", OpenTypeFeatures(oldStyleFigures: true, smallCaps: true)),
                               ("salt + swsh + dlig", OpenTypeFeatures(discretionaryLigatures: true, swash: true, stylisticAlternates: true))] {
                var t = TextContent()
                t.text = sample
                t.fontName = "Seravek"; t.fontSize = 26; t.color = RGBA(hex: "1B1F3A")!
                t.position = CGPoint(x: 16, y: y); t.features = f
                st.layers.append(textLayer(t, label))
                var cap = TextContent(); cap.text = label; cap.fontSize = 11; cap.color = RGBA(hex: "5D4037")!; cap.position = CGPoint(x: 18, y: y + 36)
                st.layers.append(textLayer(cap))
                y += 60
            }
            // per-run feature override (fractions only on "1/2") with Iowan Old Style small caps
            var t = TextContent()
            t.text = "Avenir: 1/2 cup, Small Caps 2024"
            t.fontName = "AvenirNext-Regular"; t.fontSize = 28; t.color = RGBA(hex: "8E44AD")!
            t.position = CGPoint(x: 16, y: y + 10)
            t.applyStyle(CharacterStyle(features: OpenTypeFeatures(fractions: true)), to: NSRange(location: 7, length: 3))
            t.applyStyle(CharacterStyle(features: OpenTypeFeatures(oldStyleFigures: true, smallCaps: true)), to: NSRange(location: 16, length: 16))
            st.layers.append(textLayer(t))
            save(st, "type_opentype", out)
        }

        // Paragraph settings: indents, space before/after, justify variants, hyphenation
        do {
            var st = baseState(620, 420)
            let para = "Typography is the art and technique of arranging type to make written language legible, readable and appealing when displayed.\nA second paragraph demonstrates space before and after together with hyphenation of extraordinarily incomprehensible words."
            var x = 12.0
            for (align, hyph) in [(TextAlign.justify, true), (.justifyCenter, false), (.justifyAll, false)] {
                var t = TextContent()
                t.text = para
                t.fontName = "Georgia"; t.fontSize = 14; t.color = RGBA(hex: "1B1F3A")!
                t.position = CGPoint(x: x, y: 20); t.boxSize = CGSize(width: 190, height: 380)
                t.alignment = align
                t.leftIndent = 10; t.rightIndent = 6; t.firstLineIndent = 22
                t.spaceBefore = 10; t.spaceAfter = 8
                t.hyphenate = hyph
                st.layers.insert(shapeLayer(CGRect(x: x, y: 20, width: 190, height: 380), RGBA(hex: "FFFFFF")!.withAlpha(0.35), radius: 0), at: 1)
                st.layers.append(textLayer(t))
                x += 202
            }
            save(st, "type_paragraph", out)
        }

        // Codable: documents without the new keys still decode; new keys round-trip.
        do {
            var t = TextContent()
            t.text = "abc"; t.runs = [TextStyleRun(location: 0, length: 1, style: CharacterStyle(fontSize: 20))]
            t.warp = TextWarp(style: .flag, bend: 20); t.orientation = .vertical; t.features.smallCaps = true
            t.pathText = TextOnPath(path: .ellipse(CGRect(x: 0, y: 0, width: 10, height: 10)), startOffset: 3)
            let data = try! JSONEncoder().encode(t)
            let back = try? JSONDecoder().decode(TextContent.self, from: data)
            print(back == t ? "PASS text codable roundtrip" : "FAIL text codable roundtrip")
            var obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
            for k in ["runs", "leftIndent", "rightIndent", "firstLineIndent", "spaceBefore", "spaceAfter", "hyphenate", "features", "orientation", "warp", "pathText", "antialias", "allCaps"] { obj.removeValue(forKey: k) }
            let old = try! JSONSerialization.data(withJSONObject: obj)
            if let o = try? JSONDecoder().decode(TextContent.self, from: old), o.text == "abc", o.runs.isEmpty, o.orientation == .horizontal, o.warp == nil {
                print("PASS text codable legacy")
            } else { print("FAIL text codable legacy") }
        }

        // Convert to Shape outlines: warped, vertical, path and mixed-run text
        do {
            var st = baseState(560, 360)
            var a = TextContent(); a.text = "OUTLINE"; a.fontName = "Helvetica-Bold"; a.fontSize = 60; a.position = CGPoint(x: 20, y: 20)
            a.warp = TextWarp(style: .arc, bend: 50)
            var b = TextContent(); b.text = "縦書"; b.orientation = .vertical; b.fontName = "HiraginoSans-W6"; b.fontSize = 40; b.position = CGPoint(x: 540, y: 20)
            var c = TextContent(); c.text = "ALONG THE CIRCLE PATH"; c.fontName = "Helvetica-Bold"; c.fontSize = 18
            c.pathText = TextOnPath(path: .ellipse(CGRect(x: 60, y: 150, width: 180, height: 180)))
            var m = TextContent(); m.text = "Mixed italic"; m.fontName = "Helvetica"; m.fontSize = 36; m.position = CGPoint(x: 280, y: 280)
            m.applyStyle(CharacterStyle(fontSize: 50, fauxItalic: true), to: NSRange(location: 6, length: 6))
            for t in [a, b, c, m] {
                let vp = VectorPath.from(cgPath: TextRenderer.outlinePath(t))
                st.layers.append(Layer(name: "outline", content: .shape(ShapeContent(geometry: .path(vp), fill: .color(RGBA(hex: "2E4057")!)))))
            }
            save(st, "type_outlines", out)
        }

        runTypeEditorTest(out)
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" { runTypePanelSnapshots(out) }

        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"] == "type" {
            print("done (type only)")
            exit(0)
        }
    }

    /// Drives the on-canvas editor headlessly: selection-only styling, typing, read-back into runs.
    static func runTypeEditorTest(_ out: URL) {
        var st = baseState(480, 240)
        var t = TextContent()
        t.text = "Hello World"
        t.fontName = "Helvetica"; t.fontSize = 40; t.color = RGBA(hex: "1B1F3A")!
        t.position = CGPoint(x: 30, y: 40)
        let layer = textLayer(t)
        st.layers.append(layer)
        let d = Document(state: st, name: "type-editor")
        let app = AppModel.shared
        app.add(d)
        defer { app.close(d) }
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        canvas.document = d
        d.zoom = 2
        d.selectLayer(layer.id)
        let tool = TextTool(kind: .text, canvas: canvas)
        tool.beginEditing(layer.id, isNew: false)
        print(abs((tool.testEditorFontSize ?? 0) - 80) < 0.01 ? "PASS editor zoom scaling" : "FAIL editor zoom scaling \(String(describing: tool.testEditorFontSize))")
        // style "World" only
        tool.testSelect(NSRange(location: 6, length: 5))
        guard let tg = TypeEdit.target(doc: d, id: layer.id), tg.editing, tg.hasSelection else { print("FAIL editor target"); return }
        var v = tg.binding.wrappedValue
        v.fontSize = 64; v.color = RGBA(hex: "E94F37")!; v.fauxItalic = true
        tg.binding.wrappedValue = v
        // paragraph change goes to the layer
        // (SwiftUI bindings snapshot their value; views rebuild them after each change, so re-fetch here too)
        guard let tgp = TypeEdit.target(doc: d, id: layer.id) else { return }
        var v2 = tgp.binding.wrappedValue
        v2.alignment = .center
        tgp.binding.wrappedValue = v2
        // caret at the end: typing style, then type
        tool.testSelect(NSRange(location: 11, length: 0))
        tool.testType("!!")
        tool.testSelect(NSRange(location: 0, length: 0))
        tool.testType("Oh ")
        tool.endEditing(commit: true)
        guard let r = d.state.layer(layer.id)?.text else { print("FAIL editor result"); return }
        let ok = r.text == "Oh Hello World!!" && r.runs.count == 1 && r.runs[0].location == 9 && r.runs[0].length == 7
            && r.runs[0].style.fontSize == 64 && r.runs[0].style.fauxItalic == true && r.fontSize == 40 && r.alignment == .center
        print(ok ? "PASS editor selection styling" : "FAIL editor selection styling: \(r.text) \(r.runs) align \(r.alignment)")
        // whole layer when not editing: font size change clears run overrides of that field
        guard let tg2 = TypeEdit.target(doc: d, id: layer.id), !tg2.editing else { print("FAIL layer target"); return }
        var w = tg2.binding.wrappedValue
        w.fontSize = 30
        tg2.binding.wrappedValue = w
        tg2.commit()
        if let r2 = d.state.layer(layer.id)?.text {
            let ok2 = r2.fontSize == 30 && r2.runs.count == 1 && r2.runs[0].style.fontSize == nil && r2.runs[0].style.fauxItalic == true
            print(ok2 ? "PASS layer-wide styling" : "FAIL layer-wide styling \(r2.runs)")
            var s2 = baseState(480, 240)
            s2.layers.append(textLayer(r2))
            save(s2, "type_editor_result", out)
        }
    }

    /// Offscreen snapshots of the Character / Paragraph panels and the Warp Text dialog (LUMEN_SELFTEST_UI=1).
    static func runTypePanelSnapshots(_ out: URL) {
        var st = baseState(400, 200)
        var t = TextContent(); t.text = "Panel"; t.warp = TextWarp(style: .flag, bend: 30)
        let l = textLayer(t)
        st.layers.append(l)
        let d = Document(state: st, name: "panels")
        let app = AppModel.shared
        app.add(d)
        d.selectLayer(l.id)
        defer { app.close(d) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
        }
        snap(CharacterPanel(), "ui_character_panel", CGSize(width: 300, height: 520))
        snap(ParagraphPanel(), "ui_paragraph_panel", CGSize(width: 300, height: 300))
        snap(DraggableCard { WarpTextDialog() }, "ui_warp_dialog", CGSize(width: 380, height: 260))
        snap(HStack { TextOptionsExtras() }, "ui_text_options_extras", CGSize(width: 200, height: 40))
    }
}
