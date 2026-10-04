import AppKit
import CoreImage
import ImageCratCore

enum HTMLExportSelfTest {
    static func check(_ ok: Bool, _ msg: @autoclosure () -> String) { ComponentsSelfTest.check(ok, "html: " + msg()) }

    static func text(_ s: String, _ font: String, _ size: Double, _ color: String, _ pos: CGPoint, name: String) -> Layer {
        var t = TextContent()
        t.text = s; t.fontName = font; t.fontSize = size; t.color = RGBA(hex: color)!; t.position = pos
        return Layer(name: name, content: .text(t))
    }

    /// A small landing-page style design: heading, paragraph, gradient card with shadow, photo, nav row, button,
    /// ellipse with stroke, star (SVG), rotated badge, multiply overlay.
    static func sampleDesign() -> DocumentState {
        let W = 800, H = 520
        var st = DocumentState(width: W, height: H)
        let bg = PixelBuffer(width: W, height: H)
        bg.context.setFillColor(RGBA(hex: "F4F1EA")!.cgColor); bg.context.fill(CGRect(x: 0, y: 0, width: W, height: H)); bg.markDirty()
        st.layers = [Layer.raster(name: "Background", buffer: bg)]

        // nav row: three evenly spaced pills in a group
        var pills: [Layer] = []
        for (i, c) in ["1B1F3A", "3D5A80", "98C1D9"].enumerated() {
            var p = SelfTest.shapeLayer(CGRect(x: 40 + Double(i) * 104, y: 28, width: 88, height: 30), RGBA(hex: c)!, radius: 15)
            p.name = "Pill \(i + 1)"
            pills.append(p)
        }
        let nav = Layer(name: "Nav Row", content: .group(GroupContent(children: pills, isExpanded: true)))

        var title = text("Design to Web", "Helvetica-Bold", 46, "1B1F3A", CGPoint(x: 40, y: 84), name: "Title")
        title.effects.dropShadow.enabled = true; title.effects.dropShadow.distance = 3; title.effects.dropShadow.size = 4
        title.effects.dropShadow.opacity = 0.35; title.effects.dropShadow.useGlobalLight = false; title.effects.dropShadow.angle = 120
        var sub = text("SPACED SUBHEAD", "Helvetica", 15, "3D5A80", CGPoint(x: 42, y: 146), name: "Subhead")
        sub.text?.tracking = 180
        var body = text("Text layers become real HTML text, shapes become CSS boxes and pixels become optimised images.", "Georgia", 17, "333333", CGPoint(x: 40, y: 182), name: "Body Copy")
        body.text?.boxSize = CGSize(width: 330, height: 110)
        body.text?.leading = 25

        // gradient card with shadow
        var card = Layer(name: "Card", content: .shape(ShapeContent(geometry: .rectangle(CGRect(x: 420, y: 60, width: 330, height: 200), cornerRadius: 22),
            fill: .gradient(GradientFill(gradient: ColorGradient(name: "g", stops: [GradientStop(location: 0, color: RGBA(hex: "7F00FF")!), GradientStop(location: 1, color: RGBA(hex: "FF8C00")!)]), angle: 20)))))
        card.effects.dropShadow.enabled = true; card.effects.dropShadow.distance = 10; card.effects.dropShadow.size = 22
        card.effects.dropShadow.opacity = 0.35; card.effects.dropShadow.useGlobalLight = false; card.effects.dropShadow.angle = 90
        let cardLabel = text("Gradient card", "Helvetica-Bold", 22, "FFFFFF", CGPoint(x: 446, y: 214), name: "Card Label")

        // photo (raster with a round-rect alpha)
        let photo = PixelBuffer(width: 150, height: 110)
        photo.context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 150, height: 110), cornerWidth: 14, cornerHeight: 14, transform: nil))
        photo.context.clip()
        photo.drawImage(ComponentsSelfTest.photo(150, 110, "0B7285", "63E6BE").makeCGImage(), in: CGRect(x: 0, y: 0, width: 150, height: 110))
        photo.markDirty()
        let photoLayer = Layer.raster(name: "Hero Photo", buffer: photo, origin: IPoint(x: 580, y: 84))

        // button group: plate + centred label
        var plate = SelfTest.shapeLayer(CGRect(x: 40, y: 330, width: 170, height: 52), RGBA(hex: "E94F37")!, radius: 12)
        plate.name = "Plate"
        let measure = TextRenderer.layout(text("Get started", "Helvetica-Bold", 18, "FFFFFF", .zero, name: "x").text!)
        let lw = measure.lines.reduce(CGRect.null) { $0.union($1.bounds) }
        let btnLabel = text("Get started", "Helvetica-Bold", 18, "FFFFFF", CGPoint(x: 40 + (170 - lw.width) / 2 - lw.minX, y: 345), name: "Label")
        let button = Layer(name: "CTA Button", content: .group(GroupContent(children: [plate, btnLabel], isExpanded: true)))

        // ellipse with stroke, star, rotated badge, multiply overlay
        var ring = Layer(name: "Ring", content: .shape(ShapeContent(geometry: .ellipse(CGRect(x: 260, y: 320, width: 80, height: 80)), fill: .color(RGBA(hex: "FFD166")!))))
        var rs = ring.shape!; rs.stroke = StrokeStyle(paint: .color(RGBA(hex: "1B1F3A")!), width: 5, alignment: .inside); ring.shape = rs
        let star = Layer(name: "Star", content: .shape(ShapeContent(geometry: .polygon(CGRect(x: 380, y: 310, width: 100, height: 100), sides: 5, starRatio: 0.45), fill: .color(RGBA(hex: "06D6A0")!))))
        var badge = SelfTest.shapeLayer(CGRect(x: 540, y: 330, width: 120, height: 44), RGBA(hex: "118AB2")!, radius: 8)
        badge.name = "Badge"
        let c = CGPoint(x: 600, y: 352)
        var bs = badge.shape!
        bs.transform = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: -0.26).translatedBy(x: -c.x, y: -c.y)
        badge.shape = bs
        var tintBox = SelfTest.shapeLayer(CGRect(x: 690, y: 300, width: 80, height: 120), RGBA(hex: "EF476F")!, radius: 0)
        tintBox.name = "Multiply Box"; tintBox.blendMode = .multiply; tintBox.opacity = 0.8
        let under = SelfTest.shapeLayer(CGRect(x: 660, y: 340, width: 80, height: 50), RGBA(hex: "FFD166")!, radius: 6)
        let footer = text("Footer note — exported with Lumen", "Helvetica", 12, "777777", CGPoint(x: 40, y: 470), name: "Footer Note")

        st.layers += [nav, title, sub, body, card, cardLabel, photoLayer, button, ring, star, badge, under, tintBox, footer]
        return st
    }

    static func savePNG(_ cg: CGImage?, _ url: URL) {
        guard let cg, let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    static func wellFormed(_ xml: String) -> String? {
        do { _ = try XMLDocument(xmlString: xml, options: []); return nil } catch { return "\(error.localizedDescription)" }
    }

    /// Every rule has balanced braces and every declaration is `property: value;`.
    static func cssProblems(_ css: String) -> [String] {
        var problems: [String] = []
        var depth = 0
        for (i, raw) in css.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("{") { depth += 1; continue }
            if line == "}" { depth -= 1; continue }
            if line.contains("{") && line.hasSuffix("}") { continue }        // one-line rule
            if depth > 0 {
                let ok = line.range(of: "^(--)?[-a-z0-9]+: [^;]+;$", options: .regularExpression) != nil
                if !ok { problems.append("line \(i + 1): \(line)") }
            }
            if depth < 0 { problems.append("unbalanced } at line \(i + 1)") }
        }
        if depth != 0 { problems.append("unbalanced braces") }
        if css.contains("«") || css.contains("»") { problems.append("unresolved colour token") }
        return problems
    }

    static func run(_ dir: URL) {
        let st = sampleDesign()
        ComponentsSelfTest.save(st, "h00_design", dir)

        // 1. Absolute layout, px
        var opt = HTMLExportOptions()
        opt.title = "Design to Web"
        let r = HTMLExporter.export(st, options: opt)
        let folder = dir.appendingPathComponent("web_absolute")
        do {
            let page = try HTMLExporter.write(r, to: folder, options: opt)
            check(FileManager.default.fileExists(atPath: page.path) && FileManager.default.fileExists(atPath: folder.appendingPathComponent("style.css").path), "writes index.html and style.css")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("assets").path)) ?? []
            check(files.contains("hero-photo.png") && files.contains("hero-photo@2x.png"), "image assets written, with @2x variants (\(files.sorted()))")
            if let a = FilesSelfTest.imageSize(folder.appendingPathComponent("assets/hero-photo.png")), let b = FilesSelfTest.imageSize(folder.appendingPathComponent("assets/hero-photo@2x.png")) {
                check(a.0 == 150 && a.1 == 110 && b.0 == 300 && b.1 == 220, "@2x asset has twice the pixels (\(a.0)×\(a.1) → \(b.0)×\(b.1))")
            } else { check(false, "asset sizes readable") }
        } catch { check(false, "write: \(error)") }
        let err = wellFormed(r.html)
        check(err == nil, "HTML is well-formed\(err.map { ": \($0)" } ?? "")")
        let cp = cssProblems(r.css)
        check(cp.isEmpty, "CSS is valid (balanced rules, property: value; declarations)\(cp.isEmpty ? "" : " — \(cp.prefix(3))")")
        let h = r.html, c = r.css
        check(h.contains("<h1 class=\"title\">Design to Web</h1>"), "largest text becomes <h1> with real text")
        check(h.contains("<p class=\"body-copy\">") && h.contains("Text layers become real HTML text"), "paragraph text is real HTML text in a <p>")
        check(c.contains("font-family: Helvetica, \"Helvetica Neue\", Arial, sans-serif") && c.contains("font-family: Georgia, \"Times New Roman\", Times, serif"), "font families with web fallbacks")
        check(c.contains("font-weight: 700") && c.contains("font-size: 46px") && c.contains("line-height: 25px"), "font weight, size and line-height")
        check(c.contains("letter-spacing: 0.18em"), "letter-spacing from tracking")
        check(c.contains("text-shadow:"), "drop shadow on type → text-shadow")
        check(c.contains("border-radius: 22px") && c.contains("linear-gradient(") && c.contains("box-shadow:"), "rounded gradient card → border-radius + linear-gradient + box-shadow")
        check(c.contains("border-radius: 50%") && c.contains("border: 5px solid"), "ellipse with stroke → border-radius 50% + border")
        check(h.contains("<svg class=\"star\"") && h.contains("<path d=\"M"), "non-rectangular shape → inline SVG")
        check(c.contains("transform: rotate(") && c.contains("mix-blend-mode: multiply") && c.contains("opacity: 0.8"), "rotation → transform, blend mode → mix-blend-mode, opacity")
        check(h.contains("<img class=\"hero-photo\" src=\"assets/hero-photo.png\" srcset=\"assets/hero-photo.png 1x, assets/hero-photo@2x.png 2x\" width=\"150\" height=\"110\" alt=\"Hero Photo\" />"), "raster layer → <img> with srcset and alt")
        check(h.contains("<nav class=\"nav-row\">") && h.contains("<button class=\"cta-button\" type=\"button\">"), "groups → nested elements with semantic tags (nav, button)")
        check(c.contains(":root {") && c.contains("--color-1:") && c.contains("var(--color-"), "CSS variables for the document's colours")
        check(c.contains("background-color: var(--color-") && !h.contains("background.png"), "uniform background layer → page background colour (no image)")
        check(r.images.count == 1 && r.textCount == 6 && r.svgCount == 1, "element summary: \(r.elementCount) elements, \(r.textCount) text, \(r.boxCount) boxes, \(r.svgCount) svg, \(r.images.count) image")
        check(r.warnings.isEmpty, "nothing had to be rasterised in the sample\(r.warnings.isEmpty ? "" : ": \(r.warnings)")")

        // 2. Visual diff in WebKit
        var single = opt; single.singleFile = true
        let rs = HTMLExporter.export(st, options: single)
        check(rs.html.contains("<style>") && rs.html.contains("data:image/png;base64,") && !rs.html.contains("href=\"style.css\"") && rs.assets.count == 1, "single-file export embeds the CSS and the images")
        check(wellFormed(rs.html) == nil, "single-file HTML is well-formed")
        let rep = HTMLVisualDiff.checkSync(result: rs)
        savePNG(rep.snapshot, dir.appendingPathComponent("h01_web_absolute.png"))
        savePNG(rep.reference, dir.appendingPathComponent("h01_reference.png"))
        print("html visual diff (absolute, px): \(rep.label) \(rep.detail)")
        check(rep.error == nil && rep.pixelMatch >= 0.94, "visual diff: WebKit render vs document — \(rep.label)")

        // 3. Flex / auto layout
        var fo = single; fo.layout = .flex
        let rf = HTMLExporter.export(st, options: fo)
        check(rf.css.contains("display: flex") && rf.css.contains("gap: 16px"), "row of evenly spaced layers → flex container with gap")
        check(rf.css.contains("justify-content: center") && rf.css.contains("align-items: center") && !rf.html.contains("class=\"plate\""), "button: plate becomes the container's background, label centred by flexbox")
        check(wellFormed(rf.html) == nil && cssProblems(rf.css).isEmpty, "flex export is well-formed")
        let repF = HTMLVisualDiff.checkSync(result: rf)
        savePNG(repF.snapshot, dir.appendingPathComponent("h02_web_flex.png"))
        print("html visual diff (flex): \(repF.label)")
        check(repF.error == nil && repF.pixelMatch >= 0.94, "visual diff (flex layout) — \(repF.label)")

        // 4. rem units
        var ro = single; ro.units = .rem
        let rr = HTMLExporter.export(st, options: ro)
        check(rr.css.contains("font-size: 2.875rem") && rr.css.contains("html { font-size: min(16px"), "rem units (46px → 2.875rem) with a fluid root size")
        let repR = HTMLVisualDiff.checkSync(result: rr)
        print("html visual diff (rem): \(repR.label)")
        check(repR.error == nil && repR.pixelMatch >= 0.94, "visual diff (rem units) — \(repR.label)")

        // 5. Options: no variables / no semantics / alt text / JPEG
        var po = opt; po.cssVariables = false; po.semanticTags = false; po.retina = false; po.responsive = false
        po.altText = [st.layers.first { $0.name == "Hero Photo" }!.id: "Turquoise gradient with a white dot"]
        let rp = HTMLExporter.export(st, options: po)
        check(!rp.css.contains(":root") && !rp.css.contains("var(--") && rp.css.contains("#1b1f3a"), "without CSS variables colours are literals")
        check(!rp.html.contains("<h1") && rp.html.contains("<div class=\"title\">") && !rp.html.contains("<script"), "without semantic tags everything is a div; non-responsive export has no script")
        check(rp.html.contains("alt=\"Turquoise gradient with a white dot\"") && !rp.html.contains("srcset"), "alt text field is used; no srcset without @2x")

        // 6. Effects CSS cannot express are rasterised
        var st2 = st
        var bevel = SelfTest.shapeLayer(CGRect(x: 250, y: 420, width: 140, height: 60), RGBA(hex: "8338EC")!, radius: 10)
        bevel.name = "Bevel Box"; bevel.effects.bevel.enabled = true; bevel.effects.bevel.size = 8
        var warped = text("Warped", "Helvetica-Bold", 30, "1B1F3A", CGPoint(x: 430, y: 430), name: "Warped Type")
        warped.text?.warp = TextWarp(style: .arc, bend: 40)
        st2.layers += [bevel, warped]
        let r2 = HTMLExporter.export(st2, options: single)
        check(r2.html.contains("<img class=\"bevel-box\"") && r2.html.contains("<img class=\"warped-type\"") && r2.warnings.count == 2, "bevel and warped type fall back to images (\(r2.warnings.count) notes)")
        let rep2 = HTMLVisualDiff.checkSync(result: r2)
        print("html visual diff (with raster fallbacks): \(rep2.label)")
        check(rep2.error == nil && rep2.pixelMatch >= 0.94, "visual diff with rasterised fallbacks — \(rep2.label)")

        // 7. Copy CSS / Copy as SVG
        let cardCSS = HTMLExporter.css(for: st.layers.first { $0.name == "Card" }!, in: st)
        check(cardCSS.hasPrefix(".card {") && cardCSS.contains("left: 420px") && cardCSS.contains("linear-gradient(") && cardCSS.contains("#7f00ff") && !cardCSS.contains("«"), "Copy CSS (shape): \(cardCSS.split(separator: "\n").count) lines")
        let titleCSS = HTMLExporter.css(for: st.layers.first { $0.name == "Title" }!, in: st)
        check(titleCSS.contains("font-size: 46px") && titleCSS.contains("color: #1b1f3a") && titleCSS.contains("text-shadow"), "Copy CSS (type)")
        let photoCSS = HTMLExporter.css(for: st.layers.first { $0.name == "Hero Photo" }!, in: st)
        check(photoCSS.contains("width: 150px") && photoCSS.contains("export this layer as an image"), "Copy CSS (pixels): box only, with a note")
        let svg = LayerSVGExport.svg(for: st.layers.first { $0.name == "Star" }!, in: st) ?? ""
        check(svg.hasPrefix("<svg xmlns=") && svg.contains("fill=\"#06d6a0\"") && wellFormed(svg) == nil, "Copy as SVG (star): well-formed, \(svg.count) chars")
        let svgText = LayerSVGExport.svg(for: st.layers.first { $0.name == "Title" }!, in: st) ?? ""
        check(svgText.contains("<path d=\"M") && wellFormed(svgText) == nil, "Copy as SVG (type → outlines)")
        var ringStroke = ShapeContent(geometry: .polygon(CGRect(x: 0, y: 0, width: 100, height: 100), sides: 6, starRatio: 1),
                                      fill: .gradient(GradientFill(gradient: ColorGradient.presets[3], type: .radial)))
        ringStroke.stroke = StrokeStyle(paint: .color(.black), width: 4, alignment: .inside, dash: [2, 1])
        let svg3 = LayerSVGExport.svg(for: ringStroke)
        check(svg3.contains("<radialGradient") && svg3.contains("clip-path=") && svg3.contains("stroke-dasharray") && wellFormed(svg3) == nil, "SVG: gradient fill, inside stroke (clip-path), dashes")
        try? svg.data(using: .utf8)?.write(to: dir.appendingPathComponent("h03_star.svg"))

        // 8. Artboard export
        var ab = DocumentState(width: 900, height: 600)
        var board = Layer(name: "Phone", content: .group(GroupContent(children: [
            SelfTest.shapeLayer(CGRect(x: 120, y: 80, width: 200, height: 60), RGBA(hex: "3A86FF")!, radius: 10),
            text("Artboard", "Helvetica-Bold", 28, "111111", CGPoint(x: 120, y: 170), name: "Heading"),
        ], isExpanded: true)))
        if case .group(var g) = board.content { g.artboard = Artboard(rect: CGRect(x: 100, y: 50, width: 320, height: 400), background: RGBA(hex: "FFFBE6")); board.content = .group(g) }
        ab.layers = [board]
        var ao = single; ao.artboardID = board.id
        let ra = HTMLExporter.export(ab, options: ao)
        check(ra.pageSize == CGSize(width: 320, height: 400) && ra.css.contains("width: 320px") && ra.css.contains("left: 20px"), "artboard export: the page is the artboard (320×400), positions relative to it")
        let repA = HTMLVisualDiff.checkSync(result: ra)
        savePNG(repA.snapshot, dir.appendingPathComponent("h04_web_artboard.png"))
        check(repA.error == nil && repA.pixelMatch >= 0.94, "visual diff (artboard) — \(repA.label)")

        // 9. A document with components exports like any other (instances are images)
        let (d, s1, l1, i1) = ComponentsSelfTest.buttonDoc(480, 200)
        AppModel.shared.add(d)
        d.selectedLayerIDs = [s1, l1, i1]; d.activeLayerID = i1
        ComponentActions.createComponent(d, name: "Button")
        let rc = HTMLExporter.export(d.state, options: single)
        let repC = HTMLVisualDiff.checkSync(result: rc)
        check(rc.html.contains("<img class=\"button\"") && repC.error == nil && repC.pixelMatch >= 0.97, "component instances export as images — \(repC.label)")
        AppModel.shared.close(d)
    }
}
