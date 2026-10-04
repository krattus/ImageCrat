import AppKit
import ImageIO
import ImageCratCore

// Synthetic PSDs (built byte by byte with `PSDTestFile`) covering what no bundled real file contains.

extension PSDImportSelfTest {
    static let W = 300, H = 200

    // MARK: Helpers

    static func near(_ a: Double, _ b: Double, _ tol: Double = 1e-6) -> Bool { abs(a - b) <= tol }
    static func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.01) -> Bool { a.distance(to: b) <= tol }

    static func solid(_ w: Int, _ h: Int, _ c: RGBA) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        b.context.setFillColor(c.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: w, height: h)); b.markDirty()
        return b
    }

    /// Gradient with a soft-edged disc: exercises colour and partial transparency.
    static func picture(_ w: Int, _ h: Int, seed: Int = 0) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w {
            let dx = Double(x) - Double(w) / 2, dy = Double(y) - Double(h) / 2
            let a = clamp(1.4 - (dx * dx + dy * dy).squareRoot() / (Double(min(w, h)) / 2), 0, 1)
            let al = Int((a * 255).rounded())
            let r = (x * 255 / max(1, w - 1) + seed * 40) % 256, g = y * 255 / max(1, h - 1), bl = (x + y + seed * 90) % 256
            let i = y * b.bytesPerRow + x * 4
            p[i] = UInt8((r * al + 127) / 255); p[i + 1] = UInt8((g * al + 127) / 255); p[i + 2] = UInt8((bl * al + 127) / 255); p[i + 3] = UInt8(al)
        } }
        b.markDirty()
        return b
    }

    static func file(_ layers: [PSDTestLayer] = [], w: Int = W, h: Int = H) -> PSDTestFile {
        var f = PSDTestFile(width: w, height: h)
        f.layers = layers
        f.merged = Array(repeating: [UInt8](repeating: 255, count: w * h), count: 3)
        return f
    }

    static func background(_ w: Int = W, _ h: Int = H, _ c: RGBA = RGBA(hex: "DDE6F0")!) -> PSDTestLayer {
        PSDTestLayer(name: "Background", buffer: solid(w, h, c), origin: .zero)
    }

    @discardableResult
    static func load(_ f: PSDTestFile, _ name: String, _ dir: URL? = nil) -> PSDImporter.Result? {
        let data = f.data()
        if let dir { try? data.write(to: dir.appendingPathComponent(name + (f.large ? ".psb" : ".psd"))) }
        do {
            let r = try PSDImporter.read(data: data, name: name, baseURL: dir)
            PSDImportModule.addPatterns(r.patterns)
            return r
        } catch { check(false, "\(name): import threw \(error)"); return nil }
    }

    static func compare(_ a: DocumentState, _ b: DocumentState) -> Diff {
        guard let x = flatten(a), let y = flatten(b) else { return Diff() }
        return diff(x, y)
    }

    static func status(_ r: PSDImporter.Result, _ s: PSDImportReport.Status, _ feature: String) -> Bool {
        r.report.items.contains { $0.status == s && $0.feature == feature }
    }

    // MARK: Type

    static func testText(_ dir: URL) {
        let red = RGBA(r: 0.9, g: 0.1, b: 0.1), blue = RGBA(r: 0.1, g: 0.2, b: 0.8)
        func textLayer(_ name: String, _ block: Data, pixels: Bool = false) -> PSDTestLayer {
            var l = pixels ? PSDTestLayer(name: name, buffer: picture(60, 30), origin: IPoint(x: 20, y: 30)) : PSDTestLayer(name: name)
            l.add("TySh", block)
            return l
        }
        // point text, the three alignments: Photoshop's origin is on the first baseline (start / middle / end)
        for (just, align, tag) in [(0, TextAlign.left, "left"), (2, .center, "centre"), (1, .right, "right")] {
            let block = PSDTestFile.typeBlock(text: "Hello PSD", runs: [.init(length: 9, font: 0, size: 20, color: red)], fonts: ["Helvetica"],
                                              transform: [2, 0, 0, 2, 150, 100], justification: just)
            guard let r = load(file([background(), textLayer("T", block)]), "text_\(tag)", dir), let t = r.state.layers.last?.text else { check(false, "point text (\(tag)) imports as type"); continue }
            check(t.text == "Hello PSD" && t.fontName == "Helvetica" && near(t.fontSize, 40) && t.color == red && t.alignment == align && t.boxSize == nil,
                  "point text (\(tag)): text, font, size × transform scale, colour, alignment (\(t.fontName) \(t.fontSize) \(t.alignment))")
            let L = TextRenderer.layout(t)
            if let line = L.lines.first {
                let ax = align == .left ? line.bounds.minX : (align == .center ? line.bounds.midX : line.bounds.maxX)
                let p = CGPoint(x: ax, y: line.transform.ty).applying(TextRenderer.docTransform(t))
                check(near(p, CGPoint(x: 150, y: 100), 0.05), "point text (\(tag)): the baseline anchor lands on the transform origin (\(p))")
            }
            check(status(r, .editable, "Type") && r.report.missingFonts.isEmpty, "point text (\(tag)): reported as editable, no font substituted")
            if tag == "left", let cg = Compositor.shared.flatten(r.state, background: .white) { writePNG(cg, dir.appendingPathComponent("synthetic_text_left.png")) }
        }
        // rotated + scaled transform: rotation stays in the layer transform, the scale goes into the sizes
        do {
            let a = Double.pi / 6, s = 1.5
            let m = [cos(a) * s, sin(a) * s, -sin(a) * s, cos(a) * s, 80, 60]
            let block = PSDTestFile.typeBlock(text: "Tilt", runs: [.init(length: 4, size: 30)], fonts: ["Helvetica"], transform: m)
            if let t = load(file([background(), textLayer("T", block)]), "text_rotated")?.state.layers.last?.text {
                let tr = t.transform
                check(near(t.fontSize, 45) && near(Double(tr.a), cos(a), 1e-6) && near(Double(tr.b), sin(a), 1e-6) && near(Double(tr.tx), 80) && near(Double(tr.ty), 60),
                      "rotated text: size 30 × 1.5 = \(t.fontSize), rotation kept in the transform")
            } else { check(false, "rotated text imports") }
        }
        // mixed runs
        do {
            let runs: [PSDTestFile.TextRun] = [
                .init(length: 5, font: 0, size: 20, color: red, extra: "/AutoLeading false /Leading 30.0"),
                .init(length: 4, font: 1, size: 30, color: blue, extra: "/Tracking 100 /Underline true /FauxItalic true /Strikethrough true /BaselineShift 4.0 /HorizontalScale 1.5 /AutoLeading false /Leading 30.0"),
            ]
            let block = PSDTestFile.typeBlock(text: "Hello PSD", runs: runs, fonts: ["Helvetica", "Helvetica-Bold"], transform: [2, 0, 0, 2, 20, 120])
            if let t = load(file([background(), textLayer("T", block)]), "text_runs", dir)?.state.layers.last?.text {
                check(t.fontName == "Helvetica" && near(t.fontSize, 40) && t.color == red && t.leading.map { near($0, 60) } == true, "mixed runs: the first run is the layer default (leading \(String(describing: t.leading)))")
                let r = t.runs.first
                check(t.runs.count == 1 && r?.location == 5 && r?.length == 4 && r?.style.fontName == "Helvetica-Bold" && r?.style.fontSize.map { near($0, 60) } == true && r?.style.color == blue
                      && r?.style.tracking == 100 && r?.style.underline == true && r?.style.strikethrough == true && r?.style.fauxItalic == true && r?.style.baselineShift.map { near($0, 8) } == true
                      && r?.style.horizontalScale.map { near($0, 1.5) } == true,
                      "mixed runs: second run keeps font, size, colour, tracking, underline, strikethrough, faux italic, baseline shift, scale (\(t.runs.count) run)")
            } else { check(false, "mixed-run text imports") }
        }
        // paragraph (box) text
        do {
            let lorem = "Lorem ipsum dolor sit amet, consectetur adipiscing elit"
            let block = PSDTestFile.typeBlock(text: lorem, runs: [.init(length: (lorem as NSString).length, size: 14)], fonts: ["Helvetica"],
                                              transform: [1, 0, 0, 1, 30, 40], justification: 3, box: CGRect(x: 0, y: 0, width: 200, height: 80),
                                              paragraphExtra: "/StartIndent 10.0\n/EndIndent 5.0\n/FirstLineIndent 12.0\n/SpaceBefore 3.0\n/SpaceAfter 4.0\n/AutoHyphenate true")
            if let t = load(file([background(), textLayer("T", block)]), "text_box", dir)?.state.layers.last?.text {
                check(t.boxSize == CGSize(width: 200, height: 80) && t.position == .zero && near(Double(t.transform.tx), 30) && near(Double(t.transform.ty), 40), "paragraph text: box size and place")
                check(t.alignment == .justify && t.leftIndent == 10 && t.rightIndent == 5 && t.firstLineIndent == 12 && t.spaceBefore == 3 && t.spaceAfter == 4 && t.hyphenate,
                      "paragraph text: justification, indents, spacing, hyphenation")
                check(TextRenderer.layout(t).lines.count > 1, "paragraph text wraps inside its box")
            } else { check(false, "paragraph text imports") }
        }
        // missing font: substituted, recorded, traits kept
        do {
            let block = PSDTestFile.typeBlock(text: "Missing", runs: [.init(length: 7, size: 24)], fonts: ["NoSuchFamilyXYZ-BoldItalic"], transform: [1, 0, 0, 1, 20, 60])
            if let r = load(file([background(), textLayer("T", block)]), "text_missing_font"), let t = r.state.layers.last?.text {
                let f = NSFont(name: t.fontName, size: 12)
                let traits = f.map { NSFontManager.shared.traits(of: $0) } ?? []
                check(f != nil && traits.contains(.boldFontMask) && traits.contains(.italicFontMask), "missing font: an installed bold-italic substitute is used (\(t.fontName))")
                check(r.report.missingFonts == ["NoSuchFamilyXYZ-BoldItalic"] && status(r, .substituted, "Font") && r.report.summary.contains("1 font substituted"), "missing font is named in the report and the summary")
            } else { check(false, "text with a missing font still imports as type") }
            let known = PSDFontMatcher.resolve("MyriadPro-Bold")
            check(NSFont(name: known.name, size: 12) != nil, "MyriadPro-Bold resolves to an installed font (\(known.name), substituted \(known.substituted))")
            check(PSDFontMatcher.resolve("Helvetica-Bold") == ("Helvetica-Bold", false), "an installed PostScript name is used as is")
        }
        // warp, vertical, superscript, all caps, paragraph marks, escapes
        do {
            var block = PSDTestFile.typeBlock(text: "Arc", runs: [.init(length: 3, size: 40)], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 60, 120], warp: ("warpArc", 40, 10, -20))
            var t = load(file([background(), textLayer("T", block)]), "text_warp", dir)?.state.layers.last?.text
            check(t?.warp == TextWarp(style: .arc, bend: 40, horizontalDistortion: 10, verticalDistortion: -20), "Warp Text: style, bend and distortions")
            block = PSDTestFile.typeBlock(text: "縦", runs: [.init(length: 1, size: 40)], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 60, 40], vertical: true)
            t = load(file([background(), textLayer("T", block)]), "text_vertical")?.state.layers.last?.text
            check(t?.orientation == .vertical && t?.text == "縦", "vertical type")
            block = PSDTestFile.typeBlock(text: "x2", runs: [.init(length: 1, size: 20), .init(length: 1, size: 20, extra: "/FontBaseline 1")], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 60, 40])
            t = load(file([background(), textLayer("T", block)]), "text_super")?.state.layers.last?.text
            let sup = t?.runs.first?.style ?? t.map { CharacterStyle(fontSize: $0.fontSize, baselineShift: $0.baselineShift) }
            let sizes = [t?.fontSize ?? 0, sup?.fontSize ?? 0].sorted()
            check(t?.runs.count == 1 && near(sizes[0], 20 * 0.583, 0.01) && near(sizes[1], 20, 0.01), "superscript becomes a smaller, raised run (\(sizes))")
            block = PSDTestFile.typeBlock(text: "caps", runs: [.init(length: 4, size: 20, extra: "/FontCaps 2")], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 60, 40])
            check(load(file([background(), textLayer("T", block)]), "text_caps")?.state.layers.last?.text?.allCaps == true, "All Caps")
            block = PSDTestFile.typeBlock(text: "one\rtwo", runs: [.init(length: 7, size: 20)], fonts: ["Helvetica"], transform: [2, 0, 0, 2, 60, 40], paragraphExtra: "/AutoLeading 1.5")
            t = load(file([background(), textLayer("T", block)]), "text_autoleading")?.state.layers.last?.text
            check(t?.leading.map { near($0, 60) } == true, "auto leading other than 120 % becomes a fixed line spacing (\(String(describing: t?.leading)))")
            let odd = "Hi (there) \\ ✓ 日本\rSecond"
            block = PSDTestFile.typeBlock(text: odd, runs: [.init(length: (odd as NSString).length, size: 20)], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 10, 40])
            t = load(file([background(), textLayer("T", block)]), "text_escapes")?.state.layers.last?.text
            check(t?.text == "Hi (there) \\ ✓ 日本\nSecond", "engine data strings: parentheses, backslash, non-ASCII, paragraph marks (\(t?.text ?? "nil"))")
        }
        // damaged engine data: keep Photoshop's pixels, say why
        do {
            let block = PSDTestFile.typeBlock(text: "Broken", runs: [.init(length: 6, size: 20)], fonts: ["Helvetica"], transform: [1, 0, 0, 1, 20, 60], damageEngineData: true)
            if let r = load(file([background(), textLayer("T", block, pixels: true)]), "text_damaged") {
                let l = r.state.layers.last
                check(l?.isRaster == true && l?.raster?.frame == IRect(x: 20, y: 30, width: 60, height: 30) && status(r, .flattened, "Type"), "damaged type data: the layer keeps its pixels and the report says so")
            }
            if let r = load(file([background(), textLayer("T", block)]), "text_damaged_nopixels") {
                check(r.state.layers.count == 1 && status(r, .skipped, "Type"), "damaged type data without pixels: layer left out, reported")
            }
        }
    }

    // MARK: Shapes, vector masks, fills

    static func rectPath(_ r: CGRect) -> VectorPath { VectorPath.rect(r) }

    static func shapeLayer(_ name: String, _ p: VectorPath, fill: (String, Data), flags: UInt32 = 0, ops: [Int]? = nil, startsFilled: Bool = false) -> PSDTestLayer {
        var l = PSDTestLayer(name: name)
        l.add(fill.0, fill.1)
        l.add("vmsk", PSDTestFile.vectorMask(p, width: W, height: H, flags: flags, ops: ops, startsFilled: startsFilled))
        return l
    }

    static func testShapes(_ dir: URL) {
        let red = RGBA(r: 0.85, g: 0.2, b: 0.15), blue = RGBA(r: 0.1, g: 0.3, b: 0.8)
        // solid fill + stroke, compared with the same shape built directly in Lumen
        do {
            var p = VectorPath.ellipse(CGRect(x: 40, y: 30, width: 140, height: 100))
            p.subpaths += VectorPath.rect(CGRect(x: 150, y: 90, width: 100, height: 70)).subpaths
            var l = shapeLayer("Shape", p, fill: ("SoCo", PSDTestFile.solidFill(red)))
            l.add("vstk", PSDTestFile.stroke(width: 6, color: blue, alignment: "strokeStyleAlignInside", cap: "strokeStyleRoundCap", join: "strokeStyleRoundJoin", dash: [2, 1]))
            if let r = load(file([background(), l]), "shape_stroke", dir), let s = r.state.layers.last?.shape {
                check(s.fill == .color(red) && s.stroke.paint == .color(blue) && s.stroke.width == 6 && s.stroke.alignment == .inside && s.stroke.cap == .round && s.stroke.join == .round && s.stroke.dash == [2, 1],
                      "shape: solid fill and stroke (width, alignment, caps, joins, dashes)")
                let got = s.path.subpaths.flatMap(\.points), want = p.subpaths.flatMap(\.points)
                let worst = zip(got, want).map { max($0.anchor.distance(to: $1.anchor), $0.inControl.distance(to: $1.inControl), $0.outControl.distance(to: $1.outControl)) }.max() ?? 99
                check(got.count == want.count && worst < 0.001, "shape: every anchor and handle survives (worst error \(worst) px)")
                var exp = DocumentState(width: W, height: H)
                var sc = ShapeContent(geometry: .path(p), fill: .color(red))
                sc.stroke = StrokeStyle(paint: .color(blue), width: 6, alignment: .inside, cap: .round, join: .round, dash: [2, 1])
                exp.layers = [Layer.raster(name: "Background", buffer: solid(W, H, RGBA(hex: "DDE6F0")!)), Layer(name: "Shape", content: .shape(sc))]
                let d = compare(exp, r.state)
                check(d.mean < 0.05, String(format: "shape: composite equals the same shape drawn in Lumen (mean %.3f, max %d)", d.mean, d.max))
                if let cg = Compositor.shared.flatten(r.state, background: .white) { writePNG(cg, dir.appendingPathComponent("synthetic_shape_stroke.png")) }
                check(status(r, .editable, "Shape"), "shape is reported as editable")
            } else { check(false, "shape layer imports as a shape") }
        }
        // live primitives from origination data
        do {
            let rc = CGRect(x: 50, y: 40, width: 160, height: 90)
            var l = shapeLayer("Rect", .rect(rc), fill: ("SoCo", PSDTestFile.solidFill(red)))
            l.add("vogk", PSDTestFile.origination(type: 1, rect: rc))
            var g = load(file([background(), l]), "shape_live_rect")?.state.layers.last?.shape?.geometry
            check(g == .rectangle(rc, cornerRadius: 0), "live rectangle stays a rectangle (\(String(describing: g)))")
            l = shapeLayer("Round", .rect(rc, radius: 18), fill: ("SoCo", PSDTestFile.solidFill(red)))
            l.add("vogk", PSDTestFile.origination(type: 2, rect: rc, radius: 18))
            g = load(file([background(), l]), "shape_live_rrect")?.state.layers.last?.shape?.geometry
            check(g == .rectangle(rc, cornerRadius: 18), "live rounded rectangle keeps its corner radius")
            l = shapeLayer("Ellipse", .ellipse(rc), fill: ("SoCo", PSDTestFile.solidFill(red)))
            l.add("vogk", PSDTestFile.origination(type: 5, rect: rc))
            g = load(file([background(), l]), "shape_live_ellipse")?.state.layers.last?.shape?.geometry
            check(g == .ellipse(rc), "live ellipse stays an ellipse")
            // origination that no longer matches the path (edited / rotated shape): plain path
            let rot = VectorPath.rect(rc).applying(CGAffineTransform(translationX: 130, y: 85).rotated(by: 0.5).translatedBy(x: -130, y: -85))
            l = shapeLayer("Rotated", rot, fill: ("SoCo", PSDTestFile.solidFill(red)))
            l.add("vogk", PSDTestFile.origination(type: 1, rect: rc))
            g = load(file([background(), l]), "shape_live_rotated")?.state.layers.last?.shape?.geometry
            if case .path? = g { check(true, "rotated rectangle falls back to a path") } else { check(false, "rotated rectangle falls back to a path (\(String(describing: g)))") }
        }
        // Boolean operations and compound paths
        do {
            var p = VectorPath.rect(CGRect(x: 40, y: 40, width: 200, height: 120))
            p.subpaths += VectorPath.ellipse(CGRect(x: 90, y: 60, width: 100, height: 80)).subpaths
            func ops(_ o: [Int], _ name: String, filled: Bool = false, flags: UInt32 = 0) -> ([PathOperation], PSDImporter.Result?) {
                let r = load(file([background(), shapeLayer("S", p, fill: ("SoCo", PSDTestFile.solidFill(red)), flags: flags, ops: o, startsFilled: filled)]), name)
                return (r?.state.layers.last?.shape?.path.subpaths.map(\.operation) ?? [], r)
            }
            check(ops([1, 2], "shape_subtract").0 == [.combine, .subtract], "path operations: subtract")
            check(ops([1, 3], "shape_intersect").0 == [.combine, .intersect], "path operations: intersect")
            check(ops([1, 0], "shape_exclude").0 == [.combine, .exclude], "path operations: exclude")
            let (compound, r) = ops([1, -1], "shape_compound")
            check(compound == [.combine, .exclude], "compound path: the second contour cuts a hole")
            if let r, let buf = flatten(r.state) {
                let mid = buf.psdTestPixel(140, 100), edge = buf.psdTestPixel(50, 50)
                check(abs(Int(mid.0) - 0xDD) < 3 && edge.0 > 200 && edge.1 < 70, "compound path renders with a hole (centre \(mid), rim \(edge))")
            }
            let filled = ops([2, 2], "shape_startsfilled", filled: true)
            check(filled.0.count == 3 && filled.0.first == .combine, "“starts filled” path gets a surrounding rectangle to subtract from")
            let inv = ops([1, 1], "shape_inverted", flags: 1)
            if let r = inv.1, let buf = flatten(r.state) {
                let inside = buf.psdTestPixel(60, 50), outside = buf.psdTestPixel(10, 10)
                check(abs(Int(inside.0) - 0xDD) < 3 && outside.1 < 70, "inverted vector mask fills the outside (inside \(inside), outside \(outside))")
            }
        }
        // gradient and pattern content, 'vscg', fill switched off
        do {
            let grad = GradientFill(gradient: .twoColor(red, blue, name: "RB"), type: .linear, angle: 0, scale: 1, reverse: false, dither: false)
            var r = load(file([background(), shapeLayer("G", rectPath(CGRect(x: 40, y: 40, width: 200, height: 100)), fill: ("GdFl", PSDTestFile.versioned(PSDTestFile.gradientFillDescriptor(grad))))]), "shape_gradient", dir)
            if case .gradient(let g)? = r?.state.layers.last?.shape?.fill {
                check(g.type == .linear && g.angle == 0 && g.gradient.stops.count == 2 && g.gradient.sortedStops.first?.color == red, "gradient-filled shape")
                if let buf = r.flatMap({ flatten($0.state) }) {
                    let a = buf.psdTestPixel(45, 90), b = buf.psdTestPixel(235, 90)
                    check(a.0 > 180 && a.2 < 90 && b.2 > 170 && b.0 < 80, "gradient runs left (red) to right (blue) across the shape (\(a) → \(b))")
                }
            } else { check(false, "gradient-filled shape") }
            let pat = picture(16, 16, seed: 2)
            var f = file([background(), shapeLayer("P", rectPath(CGRect(x: 40, y: 40, width: 200, height: 100)), fill: ("PtFl", PSDTestFile.versioned(PSDTestFile.patternFillDescriptor(id: "psd-test-pattern-1", name: "Dots", scale: 2))))])
            f.globalBlocks = [("Patt", PSDTestFile.pattern(id: "psd-test-pattern-1", name: "Dots", image: pat))]
            r = load(f, "shape_pattern", dir)
            check(r?.state.layers.last?.shape?.fill == .pattern(id: "psd-test-pattern-1", scale: 2) && r?.patterns.first?.id == "psd-test-pattern-1" && r?.patterns.first?.image.width == 16,
                  "pattern-filled shape: the pattern stored in the file is decoded and referenced")
            check(AppModel.shared.customPatterns.contains { $0.id == "psd-test-pattern-1" }, "the file's pattern is added to the pattern library")
            if let got = r?.patterns.first?.image {
                // the builder stores straight colour without transparency: compare with the picture over black
                var worst = 0
                for y in 0..<16 { for x in 0..<16 { let a = got.psdTestPixel(x, y), b = pat.psdTestPixel(x, y); if b.3 == 255 { worst = max(worst, abs(Int(a.0) - Int(b.0)), abs(Int(a.1) - Int(b.1)), abs(Int(a.2) - Int(b.2))) } } }
                check(worst <= 1, "pattern pixels decode exactly (worst \(worst))")
            }
            var l = PSDTestLayer(name: "V")
            var key = BinaryWriter(); key.ascii("SoCo")
            l.add("vscg", key.data + PSDTestFile.solidFill(blue))
            l.add("vmsk", PSDTestFile.vectorMask(rectPath(CGRect(x: 10, y: 10, width: 50, height: 50)), width: W, height: H))
            l.add("vstk", PSDTestFile.stroke(width: 4, color: red, fillEnabled: false))
            r = load(file([background(), l]), "shape_vscg")
            check(r?.state.layers.last?.shape?.fill == PaintStyle.none && r?.state.layers.last?.shape?.stroke.paint == .color(red), "'vscg' content with the fill switched off keeps only the stroke")
            l = shapeLayer("Missing", rectPath(CGRect(x: 10, y: 10, width: 50, height: 50)), fill: ("PtFl", PSDTestFile.versioned(PSDTestFile.patternFillDescriptor(id: "not-in-file", name: "Gone", scale: 1))))
            r = load(file([background(), l]), "shape_pattern_missing")
            check(r?.state.layers.last?.isShape == true && r.map { status($0, .substituted, "Shape") } == true, "a pattern that is not in the file is substituted and reported")
        }
    }

    static func testFills(_ dir: URL) {
        let teal = RGBA(r: 0.1, g: 0.6, b: 0.6)
        var l = PSDTestLayer(name: "Solid"); l.add("SoCo", PSDTestFile.solidFill(teal))
        var r = load(file([background(), l]), "fill_solid")
        check(r?.state.layers.last?.fill?.paint == .color(teal) && r.map { status($0, .editable, "Fill layer") } == true, "solid colour fill layer")
        let grad = GradientFill(gradient: ColorGradient(name: "3", stops: [GradientStop(location: 0, color: .black), GradientStop(location: 0.4, color: teal), GradientStop(location: 1, color: RGBA(r: 1, g: 1, b: 1, a: 0.5))]),
                                type: .radial, angle: 45, scale: 1.5, reverse: true, dither: true)
        l = PSDTestLayer(name: "Gradient"); l.add("GdFl", PSDTestFile.versioned(PSDTestFile.gradientFillDescriptor(grad)))
        r = load(file([background(), l]), "fill_gradient", dir)
        if case .gradient(let g)? = r?.state.layers.last?.fill?.paint {
            let s = g.gradient.sortedStops
            check(g.type == .radial && g.angle == 45 && near(g.scale, 1.5) && g.reverse && g.dither && s.count == 3 && near(s[1].location, 0.4, 0.001) && near(s[2].color.a, 0.5, 0.001) && g.start == nil,
                  "gradient fill layer: type, angle, scale, reverse, dither, colour and opacity stops")
            var exp = DocumentState(width: W, height: H)
            exp.layers = [Layer.raster(name: "Background", buffer: solid(W, H, RGBA(hex: "DDE6F0")!)), Layer(name: "Gradient", content: .fill(FillContent(paint: .gradient(grad))))]
            let d = r.map { compare(exp, $0.state) } ?? Diff()
            check(d.mean < 0.6, String(format: "gradient fill layer: composite equals the same fill made in Lumen (mean %.3f)", d.mean))
        } else { check(false, "gradient fill layer") }
        l = PSDTestLayer(name: "Offset"); l.add("GdFl", PSDTestFile.versioned(PSDTestFile.gradientFillDescriptor(GradientFill(gradient: .twoColor(.black, .white), type: .linear, angle: 0), offset: CGPoint(x: 10, y: 0))))
        r = load(file([background(), l]), "fill_gradient_offset")
        if case .gradient(let g)? = r?.state.layers.last?.fill?.paint { check(g.start.map { near($0, CGPoint(x: 30, y: 100), 0.01) } == true && g.end.map { near($0, CGPoint(x: 330, y: 100), 0.01) } == true, "gradient offset becomes explicit end points (\(String(describing: g.start)))") } else { check(false, "gradient offset") }
        var f = file()
        l = PSDTestLayer(name: "Pattern"); l.add("PtFl", PSDTestFile.versioned(PSDTestFile.patternFillDescriptor(id: "psd-test-pattern-2", name: "Tile", scale: 1)))
        // a fill layer's mask: left half only
        var maskPlane = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H { for x in 0..<(W / 2) { maskPlane[y * W + x] = 255 } }
        l.setMask(IRect(x: 0, y: 0, width: W, height: H), maskPlane)
        f.layers = [background(), l]
        f.globalBlocks = [("Patt", PSDTestFile.pattern(id: "psd-test-pattern-2", name: "Tile", image: solid(8, 8, RGBA(r: 0.2, g: 0.8, b: 0.3))))]
        r = load(f, "fill_pattern", dir)
        check(r?.state.layers.last?.fill?.paint == .pattern(id: "psd-test-pattern-2", scale: 1) && r?.state.layers.last?.mask != nil, "pattern fill layer with its mask")
        if let buf = r.flatMap({ flatten($0.state) }) {
            let a = buf.psdTestPixel(20, 100), b = buf.psdTestPixel(280, 100)
            check(abs(Int(a.1) - 204) < 4 && abs(Int(b.0) - 0xDD) < 3, "pattern fill shows through its mask only (\(a), \(b))")
        }
    }

    static func testVectorMasks(_ dir: URL) {
        let circle = VectorPath.ellipse(CGRect(x: 100, y: 50, width: 100, height: 100))
        // pixel layer with a vector mask that Photoshop also rendered into channel -2
        var l = PSDTestLayer(name: "Pixels", buffer: solid(W, H, RGBA(r: 0.8, g: 0.2, b: 0.2)), origin: .zero)
        l.add("vmsk", PSDTestFile.vectorMask(circle, width: W, height: H))
        l.setRenderedVectorMask(IRect(x: 100, y: 50, width: 100, height: 100), [UInt8](repeating: 255, count: 100 * 100))
        var r = load(file([background(), l]), "vmask_pixels", dir)
        var got = r?.state.layers.last
        check(got?.isRaster == true && got?.vectorMask?.subpaths.count == 1 && got?.mask == nil && got?.vectorMaskEnabled == true, "vector mask on a pixel layer stays a path (Photoshop's rendering of it is not added as a pixel mask)")
        if let buf = r.flatMap({ flatten($0.state) }) {
            let inside = buf.psdTestPixel(150, 100), corner = buf.psdTestPixel(104, 54)
            check(inside.0 > 190 && inside.1 < 70 && abs(Int(corner.0) - 0xDD) < 3, "vector mask clips the layer to the circle (\(inside), \(corner))")
        }
        // vector mask + real pixel mask (channel -3), disabled flag
        var real = [UInt8](repeating: 255, count: 60 * 40)
        for i in 0..<(60 * 20) { real[i] = 64 }
        l = PSDTestLayer(name: "Both", buffer: solid(W, H, RGBA(r: 0.2, g: 0.2, b: 0.8)), origin: .zero)
        l.add("vmsk", PSDTestFile.vectorMask(circle, width: W, height: H, flags: 4))
        l.setRenderedVectorMask(IRect(x: 100, y: 50, width: 100, height: 100), [UInt8](repeating: 255, count: 100 * 100), real: (IRect(x: 120, y: 80, width: 60, height: 40), real, 0))
        r = load(file([background(), l]), "vmask_both")
        got = r?.state.layers.last
        check(got?.vectorMask != nil && got?.vectorMaskEnabled == false && got?.mask?.frame == IRect(x: 120, y: 80, width: 60, height: 40) && got?.mask?.buffer.psdTestGray(0, 0) == 64 && got?.mask?.outsideValue == 0,
              "vector mask (disabled) plus the real pixel mask from channel -3")
        // group and adjustment layers take vector masks too
        var open = PSDTestLayer(name: "</Layer group>"); open.flags = 24
        var b4 = BinaryWriter(); b4.u32(3); open.add("lsct", b4.data)
        var grp = PSDTestLayer(name: "Group"); grp.flags = 24
        var b1 = BinaryWriter(); b1.u32(1); b1.ascii("8BIM"); b1.ascii("pass"); grp.add("lsct", b1.data)
        grp.add("vmsk", PSDTestFile.vectorMask(circle, width: W, height: H))
        var adj = PSDTestLayer(name: "Invert"); adj.add("nvrt", Data())
        adj.add("vmsk", PSDTestFile.vectorMask(circle, width: W, height: H))
        r = load(file([background(), open, PSDTestLayer(name: "Child", buffer: solid(W, H, RGBA(r: 0.2, g: 0.7, b: 0.2)), origin: .zero), grp, adj]), "vmask_group", dir)
        let ls = r?.state.layers ?? []
        check(ls.count == 3 && ls[1].isGroup && ls[1].vectorMask != nil && ls[1].blendMode == .passThrough && ls[1].children.count == 1 && ls[2].isAdjustment && ls[2].vectorMask != nil,
              "vector masks on a group and on an adjustment layer; pass-through comes from the section divider")
    }

    // MARK: Adjustments

    static func testAdjustments(_ dir: URL) {
        func adj(_ key: String, _ data: Data, _ name: String = "Adj") -> (AdjustmentSettings?, PSDImporter.Result?) {
            var l = PSDTestLayer(name: name); l.add(key, data)
            let r = load(file([background(), l]), "adj_\(key.trimmingCharacters(in: .whitespaces))")
            return (r?.state.layers.last?.adjustment, r)
        }
        var w = BinaryWriter()
        // levels: version, composite + R + G + B records (+ 25 unused)
        w.u16(2)
        for rec in [[10, 240, 5, 250, 120], [0, 255, 0, 255, 100], [20, 200, 0, 255, 80], [0, 255, 30, 220, 250]] { for v in rec { w.u16(UInt16(v)) } }
        for _ in 0..<25 { for v in [0, 255, 0, 255, 100] { w.u16(UInt16(v)) } }
        var (s, r) = adj("levl", w.data)
        check(s?.kind == .levels && s?.levels[0] == LevelsChannel(inBlack: 10, inWhite: 240, gamma: 1.2, outBlack: 5, outWhite: 250) && s?.levels[2].inBlack == 20 && s?.levels[2].gamma == 0.8 && s?.levels[3].outBlack == 30 && s?.levels[3].gamma == 2.5,
              "Levels: composite and per-channel input, output and gamma")
        check(r.map { status($0, .editable, "Adjustment") } == true, "adjustment layers are reported as editable")
        // curves: composite (3 points) and blue (2 points), bit mask form
        w = BinaryWriter(); w.u8(0); w.u16(1); w.u32(0b1001)
        w.u16(3); for (o, i) in [(0, 0), (160, 128), (255, 255)] { w.u16(UInt16(o)); w.u16(UInt16(i)) }
        w.u16(2); for (o, i) in [(20, 0), (255, 255)] { w.u16(UInt16(o)); w.u16(UInt16(i)) }
        (s, _) = adj("curv", w.data)
        check(s?.kind == .curves && s?.curves[0].points.count == 3 && s.map { near($0.curves[0].points[1], CGPoint(x: 128.0 / 255, y: 160.0 / 255), 0.0001) } == true
              && s?.curves[3].points.first.map { near($0, CGPoint(x: 0, y: 20.0 / 255), 0.0001) } == true && s?.curves[1].isIdentity == true, "Curves: composite and blue curve points")
        // brightness/contrast: descriptor form and the legacy block
        var l = PSDTestLayer(name: "BC")
        l.add("brit", PSDTestFile.u16([0, 0, 0, 0]))
        l.add("CgEd", PSDTestFile.versioned(PSDDescriptor(classID: "null", [("Vrsn", .integer(1)), ("Brgh", .integer(25)), ("Cntr", .integer(-10)), ("means", .integer(127)), ("Lab ", .bool(false)), ("useLegacy", .bool(false))])))
        s = load(file([background(), l]), "adj_CgEd")?.state.layers.last?.adjustment
        check(s?.kind == .brightnessContrast && s?.brightness == 25 && s?.contrast == -10, "Brightness/Contrast from 'CgEd'")
        (s, _) = adj("brit", PSDTestFile.u16([40, 15, 127, 0]))
        check(s?.brightness == 40 && s?.contrast == 15, "Brightness/Contrast from the legacy 'brit' block")
        // colour balance
        (s, _) = adj("blnc", PSDTestFile.u16([10, -20, 30, -40, 50, -60, 70, -80, 90]) + Data([1, 0]))
        check(s?.kind == .colorBalance && s?.shadows == ToneTriple(cyanRed: 10, magentaGreen: -20, yellowBlue: 30) && s?.midtones == ToneTriple(cyanRed: -40, magentaGreen: 50, yellowBlue: -60)
              && s?.highlights == ToneTriple(cyanRed: 70, magentaGreen: -80, yellowBlue: 90) && s?.preserveLuminosity == true, "Color Balance: shadows, midtones, highlights")
        // hue/saturation: master + reds range
        w = BinaryWriter(); w.u16(2); w.u8(0); w.u8(0)
        for v in [0, 25, 0, 30, -40, 10] { w.i16(Int16(v)) }
        for i in 0..<6 {
            for v in HueRange.defaultRanges[i] { w.i16(Int16(v)) }
            for v in (i == 0 ? [15, -30, 5] : [0, 0, 0]) { w.i16(Int16(v)) }
        }
        (s, _) = adj("hue2", w.data)
        check(s?.kind == .hueSaturation && s?.hue == 30 && s?.hsSaturation == -40 && s?.lightness == 10 && s?.colorize == false && s?.hsRanges[0].hue == 15 && s?.hsRanges[0].saturation == -30
              && s?.hsRanges[0].range == [315, 345, 15, 45] && s?.hsRanges[3].isIdentity == true, "Hue/Saturation: master values and a colour range")
        w = BinaryWriter(); w.u16(2); w.u8(1); w.u8(0)
        for v in [200, 50, -10, 0, 0, 0] { w.i16(Int16(v)) }
        for i in 0..<6 { for v in HueRange.defaultRanges[i] { w.i16(Int16(v)) }; for _ in 0..<3 { w.i16(0) } }
        var l2 = PSDTestLayer(name: "Colorize"); l2.add("hue2", w.data)
        s = load(file([background(), l2]), "adj_hue2_colorize")?.state.layers.last?.adjustment
        check(s?.colorize == true && s?.hue == -160 && s?.hsSaturation == 100 && s?.lightness == -10, "Hue/Saturation Colorize: hue 200° and saturation 50 % mapped to Lumen's ranges")
        // selective colour
        w = BinaryWriter(); w.u16(1); w.u16(1)
        for _ in 0..<4 { w.i16(0) }
        for i in 0..<9 { for v in [i * 5, -i * 5, i, -i] { w.i16(Int16(v)) } }
        (s, _) = adj("selc", w.data)
        check(s?.kind == .selectiveColor && s?.selectiveAbsolute == true && s?.selective[2] == SelectiveColorEntry(cyan: 10, magenta: -10, yellow: 2, black: -2) && s?.selective[8].cyan == 40, "Selective Color: method and the nine colour groups")
        // channel mixer
        (s, _) = adj("mixr", PSDTestFile.u16([1, 0, 70, 20, 10, 0, 5, 0, 90, 10, 0, -5, 10, 10, 80, 0, 0, 0, 0, 0, 0, 0]))
        check(s?.kind == .channelMixer && s?.monochrome == false && s?.mixRed == [70, 20, 10, 5] && s?.mixGreen == [0, 90, 10, -5] && s?.mixBlue == [10, 10, 80, 0], "Channel Mixer: three output rows with constants")
        (s, _) = adj("mixr", PSDTestFile.u16([1, 1, 30, 60, 10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        check(s?.monochrome == true && s?.mixRed == [30, 60, 10, 0], "Channel Mixer: monochrome")
        // gradient map
        w = BinaryWriter(); w.u16(1); w.u8(1); w.u8(0); w.unicode("Duo"); w.u16(2)
        for (loc, c) in [(0, [65535, 0, 0]), (4096, [0, 0, 65535])] { w.u32(UInt32(loc)); w.u32(50); w.u16(0); for v in c { w.u16(UInt16(v)) }; w.u16(0); w.u16(0) }
        w.u16(2); for (loc, o) in [(0, 255), (4096, 128)] { w.u32(UInt32(loc)); w.u32(50); w.u16(UInt16(o)) }
        w.u16(2); w.u16(4096); w.u16(32); w.u16(0)
        (s, _) = adj("grdm", w.data)
        let gs = s?.gradient.sortedStops ?? []
        check(s?.kind == .gradientMap && s?.gradientReverse == true && gs.count == 2 && gs.first?.color == RGBA(r: 1, g: 0, b: 0) && gs.last.map { near($0.color.b, 1) && near($0.color.a, 128.0 / 255, 0.001) } == true && s?.gradient.name == "Duo",
              "Gradient Map: colour stops, opacity stops, reverse, name")
        // photo filter (version 2: RGB colour)
        w = BinaryWriter(); w.u16(2); w.u16(0); for v in [60652, 35466, 0, 0] { w.u16(UInt16(v)) }; w.u32(40); w.u8(1)
        (s, _) = adj("phfl", w.data)
        check(s?.kind == .photoFilter && s?.density == 40 && s.map { near($0.filterColor.r, 60652.0 / 65535, 0.001) && near($0.filterColor.g, 35466.0 / 65535, 0.001) } == true && s?.preserveLuminosity == true, "Photo Filter: colour and density")
        // exposure
        w = BinaryWriter(); w.u16(1); for v: Float in [1.5, -0.1, 0.8] { w.u32(v.bitPattern) }; w.u16(0)
        (s, _) = adj("expA", w.data)
        check(s?.kind == .exposure && s.map { near($0.exposure, 1.5) && near($0.offset, -0.1, 1e-6) && near($0.gamma, 0.8, 1e-6) } == true, "Exposure: exposure, offset, gamma")
        // vibrance, black & white
        (s, _) = adj("vibA", PSDTestFile.versioned(PSDDescriptor(classID: "null", [("vibrance", .integer(45)), ("Strt", .integer(-20))])))
        check(s?.kind == .vibrance && s?.vibrance == 45 && s?.saturation == -20, "Vibrance")
        (s, _) = adj("blwh", PSDTestFile.versioned(PSDDescriptor(classID: "null", [("Rd  ", .integer(10)), ("Yllw", .integer(20)), ("Grn ", .integer(30)), ("Cyn ", .integer(40)), ("Bl  ", .integer(50)), ("Mgnt", .integer(60)),
                                                                                  ("useTint", .bool(true)), ("tintColor", PSDTestFile.colorDescriptor(RGBA(r: 0.8, g: 0.6, b: 0.4)))])))
        check(s?.kind == .blackWhite && s?.bwReds == 10 && s?.bwYellows == 20 && s?.bwGreens == 30 && s?.bwCyans == 40 && s?.bwBlues == 50 && s?.bwMagentas == 60 && s?.bwTint == true
              && s.map { near($0.bwTintColor.g, 0.6, 0.001) } == true, "Black & White: six weights and the tint")
        // posterize, threshold, invert
        (s, _) = adj("post", PSDTestFile.u16([6, 0])); check(s?.kind == .posterize && s?.posterizeLevels == 6, "Posterize")
        (s, _) = adj("thrs", PSDTestFile.u16([90, 0])); check(s?.kind == .threshold && s?.thresholdLevel == 90, "Threshold")
        (s, _) = adj("nvrt", Data()); check(s?.kind == .invert, "Invert")
        // colour lookup has no equivalent: left out and reported, the rest of the file still opens
        w = BinaryWriter(); w.u16(1)
        (s, r) = adj("clrL", w.data + PSDTestFile.versioned(PSDDescriptor(classID: "null", [("lookupType", .enumerated(type: "colorLookupType", value: "3DLUT")), ("Nm  ", .string("Crisp_Warm.look"))])), "Lookup")
        check(s == nil && r?.state.layers.count == 1 && r.map { status($0, .skipped, "Adjustment") && $0.report.summary.contains("1 left out") } == true, "Color Lookup: left out and reported")
        // damaged settings never take the file down
        (s, r) = adj("levl", Data([0, 2, 0, 1]))
        check(r != nil && s == nil && r.map { status($0, .skipped, "Adjustment") } == true, "truncated adjustment data: the layer is dropped, the file opens")
        // an adjustment acts on the layers below, through its mask
        var inv = PSDTestLayer(name: "Invert"); inv.add("nvrt", Data())
        var mp = [UInt8](repeating: 0, count: W * H)
        for y in 0..<H { for x in (W / 2)..<W { mp[y * W + x] = 255 } }
        inv.setMask(IRect(x: 0, y: 0, width: W, height: H), mp, defaultColor: 0, feather: nil)
        if let res = load(file([background(W, H, RGBA(r: 1, g: 0.5, b: 0)), inv]), "adj_masked", dir), let buf = flatten(res.state) {
            let a = buf.psdTestPixel(20, 100), b = buf.psdTestPixel(280, 100)
            check(a.0 == 255 && abs(Int(a.1) - 128) < 3 && b.0 == 0 && abs(Int(b.1) - 127) < 3 && b.2 == 255, "masked Invert adjusts only the right half (\(a), \(b))")
        }
    }
}

extension PixelBuffer {
    /// Straight (un-premultiplied) RGBA of one pixel — test helper.
    func psdTestPixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        guard format == .rgba, x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0, 0) }
        let p = data.assumingMemoryBound(to: UInt8.self) + y * bytesPerRow + x * 4
        let a = Int(p[3])
        if a == 0 { return (0, 0, 0, 0) }
        func un(_ v: UInt8) -> UInt8 { UInt8(min(255, (Int(v) * 255 + a / 2) / a)) }
        return (un(p[0]), un(p[1]), un(p[2]), UInt8(a))
    }
    func psdTestGray(_ x: Int, _ y: Int) -> UInt8 {
        guard format == .gray, x >= 0, y >= 0, x < width, y < height else { return 0 }
        return data.assumingMemoryBound(to: UInt8.self)[y * bytesPerRow + x]
    }
}
