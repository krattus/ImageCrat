import AppKit
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Headless tests of the PSD / PSB exporter (`LUMEN_SELFTEST_ONLY=psdexport`). Every document is written, checked
/// byte by byte (PSDExportValidator), read back with Lumen's importer and compared: layer kinds and settings, and the
/// composite. "native" runs leave out Lumen's private layer data, so they test exactly what Photoshop reads; "exact"
/// runs include it. Sub-filter with `LUMEN_PSDEXPORT_ONLY=adjust,fill,shape,type,smart,attr,doc,hostile,bits16,linked,txt2,
/// relink,photoshop` (the second group is in PSDExport2SelfTest).
enum PSDExportSelfTest {
    static var passed = 0, failed = 0

    static func check(_ ok: Bool, _ msg: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("PASS psdexport: \(msg)") } else { failed += 1; let d = detail(); print("FAIL psdexport: \(msg)" + (d.isEmpty ? "" : " — \(d)")) }
    }

    static func metric(_ s: String) { print("psdexport metric: \(s)") }

    static func register() {
        FeatureModules.selfTests.append(("psdexport", { out in run(out) }))
        // `LUMEN_SELFTEST_ONLY=psdexport Lumen --selftest <dir>` runs just these tests
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count,
           let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"], only.hasPrefix("psdexport") {
            _ = NSApplication.shared
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            run(out)
            print("done (psdexport only)")
            exit(failed == 0 ? 0 : 1)
        }
    }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("psdexport")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["LUMEN_PSDEXPORT_ONLY"]
        func want(_ n: String) -> Bool { only == nil || only!.split(separator: ",").contains { n.hasPrefix($0) } }
        if want("adjust") { testAdjustments(dir) }
        if want("fill") { testFills(dir) }
        if want("shape") { testShapes(dir) }
        if want("type") { testType(dir) }
        if want("smart") { testSmart(dir) }
        if want("attr") { testAttributes(dir) }
        if want("doc") { testDocument(dir) }
        if want("hostile") { testHostile(dir) }
        if want("bits16") { testBits16(dir) }
        if want("linked") { testLinked(dir) }
        if want("txt2") { testTxt2(dir) }
        if want("relink") { testRelinkFit(dir) }
        if want("photoshop") { writePhotoshopSet(dir.appendingPathComponent("for_photoshop")) }
        PSDExport.writeLumenData = true
        PSDExport.writeExternalLinks = true
        print("psdexport: \(passed) passed, \(failed) failed")
    }

    // MARK: Round trip

    struct RoundTrip {
        var back: DocumentState
        var report: PSDImportReport
        var data: Data
        var url: URL
        var notes: [PSDExportNote]
    }

    static func roundTrip(_ st: DocumentState, _ name: String, _ dir: URL, exact: Bool, large: Bool = false) -> RoundTrip? {
        PSDExport.writeLumenData = exact
        defer { PSDExport.writeLumenData = true }
        let url = dir.appendingPathComponent(name + (exact ? "" : "_native") + (large ? ".psb" : ".psd"))
        do {
            try PSDWriter.write(st, to: url, large: large)
            let notes = PSDExport.lastNotes
            let data = try Data(contentsOf: url)
            let v = PSDExportValidator.validate(data)
            check(v.problems.isEmpty, "\(name)\(exact ? "" : " (native)"): the file is structurally valid (\(v.layerCount) records, \(data.count) bytes)", v.problems.prefix(8).joined(separator: "; "))
            let res = try PSDImporter.read(data: data, name: url.lastPathComponent, baseURL: dir)
            return RoundTrip(back: res.state, report: res.report, data: data, url: url, notes: notes)
        } catch {
            check(false, "\(name): export → import", "\(error)")
            return nil
        }
    }

    static func flatten(_ st: DocumentState) -> PixelBuffer? { Compositor.shared.flatten(st, background: .white).map { PixelBuffer(cgImage: $0) } }

    /// Composite comparison; writes original | re-imported | difference × 4 when `image` is set.
    @discardableResult
    static func compare(_ a: DocumentState, _ b: DocumentState, _ what: String, mean: Double, bad: Double = 0.01, image: URL? = nil) -> PSDImportSelfTest.Diff {
        guard let x = flatten(a), let y = flatten(b) else { check(false, "\(what): composites render"); return PSDImportSelfTest.Diff() }
        let d = PSDImportSelfTest.diff(x, y)
        metric("\(what): composite mean \(String(format: "%.3f", d.mean)), max \(d.max), >24 off \(String(format: "%.4f", d.badFraction * 100)) %")
        check(d.mean <= mean && d.badFraction <= bad, "\(what): the re-imported composite matches", "mean \(String(format: "%.3f", d.mean)) max \(d.max) bad \(String(format: "%.4f", d.badFraction))")
        if let url = image ?? (d.mean > mean ? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("psdexport-\(what.replacingOccurrences(of: " ", with: "_")).png") : nil) {
            sideBySide(x, y, url)
        }
        return d
    }

    static func sideBySide(_ a: PixelBuffer, _ b: PixelBuffer, _ url: URL) {
        let w = a.width, h = a.height
        let out = PixelBuffer(width: w * 3 + 8, height: h)
        out.context.setFillColor(gray: 0.5, alpha: 1); out.context.fill(CGRect(x: 0, y: 0, width: out.width, height: h))
        out.drawImage(a.makeCGImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        out.drawImage(b.makeCGImage(), in: CGRect(x: w + 4, y: 0, width: w, height: h))
        let d = PixelBuffer(width: w, height: h)
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self), pd = d.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h { for x in 0..<w { for k in 0..<3 {
            pd[y * d.bytesPerRow + x * 4 + k] = UInt8(min(255, abs(Int(pa[y * a.bytesPerRow + x * 4 + k]) - Int(pb[y * b.bytesPerRow + x * 4 + k])) * 4))
        }; pd[y * d.bytesPerRow + x * 4 + 3] = 255 } }
        d.markDirty()
        out.drawImage(d.makeCGImage(), in: CGRect(x: 2 * w + 8, y: 0, width: w, height: h))
        out.markDirty()
        try? out.pngData()?.write(to: url)
    }

    // MARK: Settings comparison

    static func json<T: Encodable>(_ v: T) -> Any {
        let d = (try? JSONEncoder().encode(v)) ?? Data()
        return strip((try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed])) ?? [:])
    }

    static func strip(_ v: Any) -> Any {
        if let d = v as? [String: Any] { return d.filter { $0.key != "id" }.mapValues(strip) }
        if let a = v as? [Any] { return a.map(strip) }
        return v
    }

    /// Differences between `a` and `b` limited to `keys` (all keys when nil).
    static func differences<T: Encodable>(_ a: T, _ b: T, keys: [String]? = nil, tol: Double) -> [String] {
        guard var x = json(a) as? [String: Any], var y = json(b) as? [String: Any] else { return ["not comparable"] }
        if let k = keys { x = x.filter { k.contains($0.key) }; y = y.filter { k.contains($0.key) } }
        return PSDLayerStyleSelfTest.diff(x, y, tol: tol)
    }

    static func adjustmentKeys(_ k: AdjustmentKind) -> [String] {
        switch k {
        case .brightnessContrast: return ["brightness", "contrast"]
        case .levels: return ["levels"]
        case .curves: return ["curves"]
        case .exposure: return ["exposure", "offset", "gamma"]
        case .vibrance: return ["vibrance", "saturation"]
        case .hueSaturation: return ["hue", "hsSaturation", "lightness", "colorize", "hsRanges"]
        case .colorBalance: return ["shadows", "midtones", "highlights", "preserveLuminosity"]
        case .blackWhite: return ["bwReds", "bwYellows", "bwGreens", "bwCyans", "bwBlues", "bwMagentas", "bwTint", "bwTintColor"]
        case .photoFilter: return ["filterColor", "density", "preserveLuminosity"]
        case .channelMixer: return ["mixRed", "mixGreen", "mixBlue", "monochrome"]
        case .posterize: return ["posterizeLevels"]
        case .threshold: return ["thresholdLevel"]
        case .gradientMap: return ["gradient", "gradientReverse"]
        case .selectiveColor: return ["selective", "selectiveAbsolute"]
        default: return []
        }
    }

    static func near(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }
    static func near(_ a: CGRect, _ b: CGRect, _ tol: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tol && abs(a.minY - b.minY) <= tol && abs(a.maxX - b.maxX) <= tol && abs(a.maxY - b.maxY) <= tol
    }
    static func near(_ a: RGBA, _ b: RGBA, _ tol: Double = 1.0 / 255 + 1e-6) -> Bool { near(a.r, b.r, tol) && near(a.g, b.g, tol) && near(a.b, b.b, tol) }

    static func layer(_ st: DocumentState, _ name: String) -> Layer? { st.allLayers.first { $0.name == name } }

    // MARK: Adjustments

    static func testAdjustments(_ dir: URL) {
        let d = dir.appendingPathComponent("adjust")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (name, a) in PSDExportSamples.adjustmentCases() {
            var st = PSDExportSamples.base(240, 160)
            var l = Layer(name: name, content: .adjustment(a))
            if name == "levels" || name == "shadowshighlights" { l.mask = PSDExportSamples.ellipseMask(240, 160, CGRect(x: 20, y: 10, width: 150, height: 120)) }
            if name == "curves" { l.opacity = 0.6 }
            st.layers.append(l)
            let baked = PSDExportAdjust.encode(a).blocks == nil
            if let rt = roundTrip(st, "adjust_" + name, d, exact: false) {
                let b = rt.back.layers.last
                if baked {
                    check(b?.isRaster == true, "\(name): no Photoshop adjustment layer — written as the adjusted pixels", "\(b?.kindName ?? "missing")")
                    compare(st, rt.back, "\(name) (baked)", mean: 0.6, bad: 0.002)
                } else {
                    let want: AdjustmentKind = a.kind == .desaturate ? .channelMixer : a.kind
                    let got = b?.adjustment
                    check(got?.kind == want, "\(name): comes back as a \(want.displayName) adjustment layer", "\(b?.kindName ?? "missing")")
                    if let g = got, a.kind != .desaturate {
                        let tol = a.kind == .curves ? 0.003 : (a.kind == .exposure ? 1e-5 : (a.kind == .gradientMap || a.kind == .photoFilter || a.kind == .blackWhite ? 0.003 : 0.0001))
                        let diffs = differences(a, g, keys: adjustmentKeys(a.kind), tol: tol)
                        check(diffs.isEmpty, "\(name): settings survive the Photoshop encoding", diffs.prefix(6).joined(separator: "; "))
                    }
                    check((b?.mask != nil) == (l.mask != nil), "\(name): the mask comes back")
                    compare(st, rt.back, name, mean: a.kind == .desaturate ? 2.5 : 0.8, bad: a.kind == .desaturate ? 0.02 : 0.003)
                }
            }
            if let rt = roundTrip(st, "adjust_" + name, d, exact: true) {
                let g = rt.back.layers.last?.adjustment
                check(g?.kind == a.kind && differences(a, g ?? a, tol: 1e-9).isEmpty, "\(name): the exact Lumen settings are restored from the Lumen data")
            }
        }
        // a stack: masked, clipped, partly transparent and baked adjustments over shapes
        let st = PSDExportSamples.adjustments()
        if let rt = roundTrip(st, "adjust_stack", d, exact: false) {
            let kinds = rt.back.allLayers.map { $0.isAdjustment ? $0.adjustment!.kind.rawValue : $0.kindName }
            metric("adjustment stack (native) comes back as: \(kinds.joined(separator: ", "))")
            check(layer(rt.back, "Black & White (clipped)")?.isClipped == true, "a clipped adjustment stays clipped")
            check(abs((layer(rt.back, "Hue/Saturation")?.opacity ?? 0) - 0.7) < 0.01, "adjustment opacity survives")
            compare(st, rt.back, "adjustment stack", mean: 0.8, bad: 0.004, image: d.appendingPathComponent("adjust_stack_compare.png"))
        }
    }

    // MARK: Fills

    static func testFills(_ dir: URL) {
        let st = PSDExportSamples.fills()
        guard let rt = roundTrip(st, "fills", dir, exact: false) else { return }
        for l in st.layers where l.isFill {
            guard let b = layer(rt.back, l.name) else { check(false, "fill “\(l.name)” comes back"); continue }
            check(b.isFill, "fill “\(l.name)” is a fill layer again", b.kindName)
            check(b.mask != nil, "fill “\(l.name)” keeps its mask")
            switch (l.fill?.paint, b.fill?.paint) {
            case (.color(let x)?, .color(let y)?): check(near(x, y), "solid colour survives")
            case (.pattern(let i, let s)?, .pattern(let j, let t)?): check(i == j && near(s, t, 0.001), "pattern id and scale survive", "\(j) \(t)")
            case (.gradient(let x)?, .gradient(let y)?):
                check(x.type == y.type, "“\(l.name)”: gradient style survives")
                if x.start == nil { check(near(x.angle, y.angle, 0.01) && near(x.scale, y.scale, 0.001), "“\(l.name)”: gradient angle and scale survive", "\(y.angle) \(y.scale)") }
                check(x.gradient.sortedStops.count <= y.gradient.sortedStops.count, "“\(l.name)”: gradient stops survive")
            default: check(false, "fill “\(l.name)” paint kind", "\(String(describing: b.fill?.paint))")
            }
        }
        compare(st, rt.back, "fill layers", mean: 1.0, bad: 0.006, image: dir.appendingPathComponent("fills_compare.png"))
        check(rt.data.range(of: Data("Patt".utf8)) != nil, "the pattern a fill uses is stored in the file ('Patt')")
    }

    // MARK: Shapes

    static func testShapes(_ dir: URL) {
        let st = PSDExportSamples.shapes()
        if let rt = roundTrip(st, "shapes", dir, exact: false) {
            for l in st.layers where l.isShape {
                guard let b = layer(rt.back, l.name), let s0 = l.shape else { check(false, "shape “\(l.name)” comes back"); continue }
                check(b.isShape, "shape “\(l.name)” is a shape layer again", b.kindName)
                guard let s1 = b.shape else { continue }
                switch (s0.geometry, s1.geometry, s0.transform.isIdentity) {
                case (.rectangle(let r0, let k0), .rectangle(let r1, let k1), true):
                    check(near(r0, r1, 0.5) && near(k0, k1, 0.5), "“\(l.name)”: stays a live rectangle with its corner radius", "\(r1) \(k1)")
                case (.ellipse(let r0), .ellipse(let r1), true):
                    check(near(r0, r1, 0.5), "“\(l.name)”: stays a live ellipse", "\(r1)")
                default:
                    check(near(s0.path.bounds, s1.path.bounds, 0.75), "“\(l.name)”: the outline survives as a path", "\(s0.path.bounds) vs \(s1.path.bounds)")
                }
                check(s0.stroke.paint.isNone == s1.stroke.paint.isNone, "“\(l.name)”: stroke on/off survives")
                if !s0.stroke.paint.isNone {
                    check(near(s0.stroke.width, s1.stroke.width, 0.01) && s0.stroke.alignment == s1.stroke.alignment && s0.stroke.cap == s1.stroke.cap
                          && s0.stroke.join == s1.stroke.join && s0.stroke.dash == s1.stroke.dash, "“\(l.name)”: stroke width, alignment, caps, joins and dashes survive")
                }
                check(s0.fill.isNone == s1.fill.isNone, "“\(l.name)”: fill on/off survives")
            }
            check(layer(rt.back, "Ellipse with vector mask")?.mask != nil, "a shape's own vector mask is kept as a pixel mask")
            check(layer(rt.back, "Star")?.effects.dropShadow.enabled == true, "a shape keeps its layer style")
            compare(st, rt.back, "shapes", mean: 1.0, bad: 0.006, image: dir.appendingPathComponent("shapes_compare.png"))
        }
        if let rt = roundTrip(st, "shapes", dir, exact: true) {
            for l in st.layers where l.isShape {
                check(layer(rt.back, l.name)?.shape == l.shape, "“\(l.name)”: exact geometry restored from the Lumen data")
            }
            check(layer(rt.back, "Ellipse with vector mask")?.vectorMask == layer(st, "Ellipse with vector mask")?.vectorMask, "the shape's vector mask is restored from the Lumen data")
        }
    }

    // MARK: Type

    static func testType(_ dir: URL) {
        let st = PSDExportSamples.type()
        if let rt = roundTrip(st, "type", dir, exact: false) {
            for l in st.layers where l.isText {
                guard let b = layer(rt.back, l.name), let t0 = l.text else { check(false, "text “\(l.name)” comes back"); continue }
                check(b.isText, "text “\(l.name)” is a type layer again", b.kindName)
                guard let t1 = b.text else { continue }
                check(t1.text == t0.text, "“\(l.name)”: the text survives", t1.text)
                let installed = PSDExportText.fontInfo(t0.fontName).installed
                if installed { check(PSDExportText.fontInfo(t1.fontName).ps == PSDExportText.fontInfo(t0.fontName).ps, "“\(l.name)”: the font survives", "\(t1.fontName)") }
                let scale = sqrt(Double(t0.transform.c * t0.transform.c + t0.transform.d * t0.transform.d))
                check(near(t1.fontSize, t0.fontSize * scale, 0.01), "“\(l.name)”: the size survives", "\(t1.fontSize)")
                check(near(t1.color, t0.color), "“\(l.name)”: the colour survives")
                check(t1.alignment == t0.alignment && t1.orientation == t0.orientation && t1.allCaps == t0.allCaps, "“\(l.name)”: alignment, orientation and caps survive")
                check(near(t1.tracking, t0.tracking, 0.5) && (t1.leading == nil) == (t0.leading == nil), "“\(l.name)”: tracking and leading survive")
                check((t1.boxSize == nil) == (t0.boxSize == nil), "“\(l.name)”: point / paragraph mode survives")
                check(t1.warp?.style == t0.warp?.style, "“\(l.name)”: the warp survives")
                check(t1.runs.count == t0.runs.count, "“\(l.name)”: style runs survive", "\(t1.runs.count) vs \(t0.runs.count)")
                if installed {
                    let r0 = TextRenderer.docBounds(t0), r1 = TextRenderer.docBounds(t1)
                    check(near(r0, r1, 2), "“\(l.name)”: the text sits in the same place", "\(r0.integral) vs \(r1.integral)")
                }
            }
            if let m0 = layer(st, "Mixed runs")?.text, let m1 = layer(rt.back, "Mixed runs")?.text {
                let a = m0.styleSegments().map { m0.applying($0.style) }, b = m1.styleSegments().map { m1.applying($0.style) }
                let same = a.count == b.count && zip(a, b).allSatisfy { x, y in
                    x.fontName == y.fontName && near(x.fontSize, y.fontSize, 0.01) && near(x.color, y.color) && x.underline == y.underline
                        && x.strikethrough == y.strikethrough && x.fauxBold == y.fauxBold && near(x.tracking, y.tracking, 0.5) && near(x.baselineShift, y.baselineShift, 0.01)
                }
                check(same, "every run of a mixed-style text keeps its font, size, colour, tracking, baseline shift and decorations")
            }
            check(rt.report.missingFonts.contains("NoSuchFont-Regular"), "a font that is not installed is reported as missing on import")
            check(layer(rt.back, "Text with style")?.effects.stroke.enabled == true, "a type layer keeps its layer style")
            // the missing font is drawn with a different fallback on each side: leave it out of the picture comparison
            var a = st, b = rt.back
            a.updateLayer(layer(a, "Missing font")!.id) { $0.isVisible = false }
            if let m = layer(b, "Missing font") { b.updateLayer(m.id) { $0.isVisible = false } }
            compare(a, b, "type", mean: 1.0, bad: 0.006, image: dir.appendingPathComponent("type_compare.png"))
        }
        if let rt = roundTrip(st, "type", dir, exact: true) {
            for l in st.layers where l.isText { check(layer(rt.back, l.name)?.text == l.text, "“\(l.name)”: exact text settings restored from the Lumen data") }
        }
    }

    // MARK: Smart objects

    static func testSmart(_ dir: URL) {
        let linked = dir.appendingPathComponent("linked-source.png")
        try? PSDExportSamples.checker(100, 60).pngData()?.write(to: linked)
        let st = PSDExportSamples.smart(linkedFile: linked)
        if let rt = roundTrip(st, "smart", dir, exact: false) {
            for l in st.layers where l.isSmartObject {
                guard let b = layer(rt.back, l.name), let s0 = l.smart else { check(false, "smart object “\(l.name)” comes back"); continue }
                check(b.isSmartObject, "“\(l.name)” is a smart object again", b.kindName)
                guard let s1 = b.smart else { continue }
                let baked = !s0.filters.isEmpty || s0.warp != nil
                if !baked {
                    let ok = zip(s0.quad.points, s1.quad.points).allSatisfy { $0.distance(to: $1) < 0.5 }
                    check(ok, "“\(l.name)”: the placement survives", "\(s1.quad.points)")
                    check(s0.source.size == s1.source.size, "“\(l.name)”: the contents keep their size", "\(s1.source.size)")
                }
            }
            if case .document(let inner)? = layer(rt.back, "Layered contents")?.smart?.source {
                check(inner.layers.map(\.kindName) == ["Shape Layer", "Type Layer"], "a layered smart object is embedded as a PSB with live shape and type layers", inner.layers.map(\.kindName).joined(separator: ", "))
            } else { check(false, "a layered smart object is embedded as a document") }
            compare(st, rt.back, "smart objects", mean: 1.0, bad: 0.006, image: dir.appendingPathComponent("smart_compare.png"))
        }
        if let rt = roundTrip(st, "smart", dir, exact: true) {
            let f = layer(rt.back, "Smart filter (baked)")?.smart
            check(f?.filters.first?.kind == .gaussianBlur, "the smart filter is restored from the Lumen data")
            check(layer(rt.back, "Mesh warp (baked)")?.smart?.warp != nil, "the mesh warp is restored from the Lumen data")
            check(layer(rt.back, "Linked file")?.smart?.linkedURL?.lastPathComponent == "linked-source.png", "the link to the file is restored from the Lumen data")
            compare(st, rt.back, "smart objects (exact)", mean: 0.5, bad: 0.002)
        }
        // links to external files ('liFE' in 'lnkE'; on by default), and the embedded copy when switched off
        if let rt = roundTrip(st, "smart_linked", dir, exact: false) {
            check(layer(rt.back, "Linked file")?.smart?.linkedURL?.lastPathComponent == "linked-source.png", "a linked smart object is written as a link ('liFE') and resolves on import")
        }
        PSDExport.writeExternalLinks = false
        if let rt = roundTrip(st, "smart_linked_embedded", dir, exact: false) {
            check(layer(rt.back, "Linked file")?.smart?.source.size == CGSize(width: 100, height: 60), "with links switched off the linked file is embedded")
        }
        PSDExport.writeExternalLinks = true
    }

    // MARK: Attributes

    static func testAttributes(_ dir: URL) {
        let st = PSDExportSamples.attributes()
        if let rt = roundTrip(st, "attributes", dir, exact: false) {
            var bad: [String] = []
            for l in st.allLayers {
                guard let b = layer(rt.back, l.name) else {
                    if !(l.isRaster && (l.raster?.buffer.opaqueBounds() == nil)) { bad.append("\(l.name): missing") }
                    continue
                }
                var why: [String] = []
                if b.isVisible != l.isVisible { why.append("visibility") }
                if !near(b.opacity, l.opacity, 0.003) { why.append("opacity") }
                if !near(b.fillOpacity, l.fillOpacity, 0.003) { why.append("fill opacity") }
                if b.blendMode != l.blendMode && !(l.isGroup && l.blendMode == .passThrough && b.blendMode == .passThrough) { why.append("blend \(b.blendMode)") }
                if b.isClipped != l.isClipped { why.append("clipping") }
                if b.colorLabel != l.colorLabel { why.append("label") }
                if b.locks != l.locks { why.append("locks \(b.locks)") }
                if b.knockout != l.knockout { why.append("knockout") }
                if b.blendIf != l.blendIf { why.append("blend if \(b.blendIf)") }
                if (b.channelR, b.channelG, b.channelB) != (l.channelR, l.channelG, l.channelB) { why.append("channels") }
                if b.blendClippedAsGroup != l.blendClippedAsGroup || b.blendInteriorEffectsAsGroup != l.blendInteriorEffectsAsGroup { why.append("advanced blending") }
                if (b.mask == nil) != (l.mask == nil) { why.append("mask presence") }
                if let m0 = l.mask, let m1 = b.mask {
                    if m0.isEnabled != m1.isEnabled || m0.isLinked != m1.isLinked { why.append("mask enabled / linked") }
                    if !near(m0.density, m1.density, 0.003) || !near(m0.feather, m1.feather, 0.001) { why.append("mask density / feather \(m1.density) \(m1.feather)") }
                }
                if (b.vectorMask == nil) != (l.vectorMask == nil) || b.vectorMaskEnabled != l.vectorMaskEnabled { why.append("vector mask") }
                if l.isGroup && b.isExpanded != l.isExpanded { why.append("expanded") }
                if (l.linkID == nil) != (b.linkID == nil) { why.append("link") }
                if !why.isEmpty { bad.append("\(l.name): \(why.joined(separator: ", "))") }
            }
            check(bad.isEmpty, "every layer keeps visibility, opacity, fill, blend mode, clipping, label, locks, knockout, Blend If, channels, masks and links", bad.joined(separator: " | "))
            check(layer(rt.back, "Linked A")?.linkID == layer(rt.back, "Linked B")?.linkID, "linked layers stay linked together")
            let b = rt.back
            check(near(b.resolution, 300, 0.01), "resolution survives", "\(b.resolution)")
            check(b.globalLight == st.globalLight, "global light survives")
            check(b.guides.map { "\($0.isVertical)\($0.position)" } == st.guides.map { "\($0.isVertical)\($0.position)" }, "guides survive")
            check(Set(b.paths.map(\.name)) == Set(st.paths.map(\.name)) && b.paths.allSatisfy { p in st.paths.contains { near($0.path.bounds, p.path.bounds, 0.1) } }, "saved paths and the work path survive")
            check(b.alphaChannels.map(\.name) == ["Selection A"], "saved alpha channels survive", b.alphaChannels.map(\.name).joined(separator: ","))
            if let a0 = st.alphaChannels.first?.buffer, let a1 = b.alphaChannels.first?.buffer {
                check(PSDExport.grayPlane(a0) == PSDExport.grayPlane(a1), "the alpha channel's pixels survive")
            }
            compare(st, rt.back, "masks and blending", mean: 0.8, bad: 0.005, image: dir.appendingPathComponent("attributes_compare.png"))
        }
        let ab = PSDExportSamples.artboards()
        if let rt = roundTrip(ab, "artboards", dir, exact: false) {
            for l in ab.layers {
                let b = layer(rt.back, l.name)
                check(b?.artboard?.rect == l.artboard?.rect, "artboard “\(l.name)” keeps its rectangle", "\(String(describing: b?.artboard?.rect))")
                check(b?.artboard?.background.map { near($0, l.artboard?.background ?? .clear) } ?? (l.artboard?.background == nil), "artboard “\(l.name)” keeps its background")
            }
            compare(ab, rt.back, "artboards", mean: 0.8, bad: 0.005)
        }
    }

    // MARK: Document level

    static func testDocument(_ dir: URL) {
        var st = PSDExportSamples.shapes()
        st.bitDepth = .sixteen
        if let rt = roundTrip(st, "sixteen_bit", dir, exact: false) {
            let v = PSDExportValidator.validate(rt.data)
            check(v.globalKeys.contains("Lr16"), "a 16-bit document keeps its layers in 'Lr16'")
            check(rt.back.bitDepth == .sixteen, "the document opens as 16-bit")
            check(rt.back.layers.count == st.layers.count && rt.back.layers.dropFirst().allSatisfy(\.isShape), "16-bit shape layers stay live")
            compare(st, rt.back, "16-bit", mean: 1.0, bad: 0.006)
        }
        var t = PSDExportSamples.type()
        t.profileName = CGColorSpace.displayP3 as String
        if let rt = roundTrip(t, "type", dir, exact: false, large: true) {
            check(rt.data.prefix(6) == Data([0x38, 0x42, 0x50, 0x53, 0, 2]), "PSB output is version 2")
            check(rt.back.allLayers.filter(\.isText).count == t.allLayers.filter(\.isText).count, "PSB keeps the type layers live")
            check(rt.back.profileName == "Display P3", "the colour profile is embedded", rt.back.profileName)
        }
        var s = PSDExportSamples.smart()
        s.bitDepth = .thirtyTwo
        if let rt = roundTrip(s, "smart_psb", dir, exact: true, large: true) {
            check(rt.back.allLayers.filter(\.isSmartObject).count == s.allLayers.filter(\.isSmartObject).count, "PSB keeps smart objects (8-byte 'lnk2' length)")
            check(rt.back.bitDepth == .sixteen, "a 32-bit document is written as 16-bit")
        }
        let all = PSDExportSamples.everything()
        if let rt = roundTrip(all, "everything", dir, exact: false) {
            var a = all, b = rt.back
            for n in ["Missing font"] {
                if let l = layer(a, n) { a.updateLayer(l.id) { $0.isVisible = false } }
                if let l = layer(b, n) { b.updateLayer(l.id) { $0.isVisible = false } }
            }
            check(rt.back.allLayers.count >= all.allLayers.count - 1, "everything: all layers come back", "\(rt.back.allLayers.count) of \(all.allLayers.count)")
            compare(a, b, "everything", mean: 1.0, bad: 0.006, image: dir.appendingPathComponent("everything_compare.png"))
        }
        // transparency in the merged image (no background layer)
        var tr = DocumentState(width: 120, height: 80)
        tr.layers = [PSDExportSamples.shape("Blob", .ellipse(CGRect(x: 10, y: 10, width: 100, height: 60)), fill: .color(RGBA(r: 0.2, g: 0.5, b: 0.9, a: 1)))]
        if let rt = roundTrip(tr, "transparent", dir, exact: false), let merged = PSDImporter.mergedImage(data: rt.data) {
            let p = merged.data.assumingMemoryBound(to: UInt8.self)
            check(p[3] == 0 && p[40 * merged.bytesPerRow + 60 * 4 + 3] == 255, "the merged image carries the document's transparency")
        }
    }

    // MARK: Robustness

    static func testHostile(_ dir: URL) {
        let d = dir.appendingPathComponent("hostile")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        for (name, st) in PSDExportSamples.hostile() {
            for large in [false, true] {
                let url = d.appendingPathComponent(name + (large ? ".psb" : ".psd"))
                do {
                    try PSDWriter.write(st, to: url, large: large)
                    let data = try Data(contentsOf: url)
                    let v = PSDExportValidator.validate(data)
                    check(v.problems.isEmpty, "\(name)\(large ? " (PSB)" : ""): written and structurally valid", v.problems.prefix(5).joined(separator: "; "))
                    let back = try? PSDImporter.read(data: data, name: name)
                    check(back != nil || st.layers.isEmpty, "\(name)\(large ? " (PSB)" : ""): reads back")
                } catch {
                    check(false, "\(name): write", "\(error)")
                }
            }
        }
        // a canvas wider than PSD allows is written as PSB
        var wide = DocumentState(width: 30_010, height: 6)
        wide.layers = [Layer.raster(name: "Strip", buffer: PixelBuffer(width: 40, height: 6, gray: 0), origin: IPoint(x: 29_960, y: 0))]
        let url = d.appendingPathComponent("wide.psb")
        if (try? PSDWriter.write(wide, to: url, large: true)) != nil, let data = try? Data(contentsOf: url) {
            let v = PSDExportValidator.validate(data)
            check(v.problems.isEmpty, "a 30010 px wide canvas is written as a valid PSB", v.problems.joined(separator: "; "))
        } else { check(false, "a 30010 px wide canvas is written as PSB") }
    }

    // MARK: Files for checking in Photoshop

    static func writePhotoshopSet(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let linked = dir.appendingPathComponent("linked-source.png")
        try? PSDExportSamples.checker(100, 60).pngData()?.write(to: linked)
        var sixteen = PSDExportSamples.shapes(); sixteen.bitDepth = .sixteen
        // vertical type is not composed into 'Txt2' (a document with it gets none): it has a file of its own, so the
        // other type layers are checked with Photoshop's text engine data
        func horizontal(_ st: DocumentState) -> DocumentState {
            var s = st
            func strip(_ ls: [Layer]) -> [Layer] {
                ls.compactMap { l in
                    if l.text?.orientation == .vertical { return nil }
                    var c = l
                    if case .group(var g) = l.content { g.children = strip(g.children); c.content = .group(g) }
                    return c
                }
            }
            s.layers = strip(s.layers)
            return s
        }
        var vertical = PSDExportSamples.base(640, 420)
        vertical.layers += PSDExportSamples.type().layers.filter { $0.text?.orientation == .vertical }
        let files: [(String, DocumentState, Bool)] = [
            ("01_adjustment_layers", PSDExportSamples.adjustments(), false),
            ("02_fill_layers", PSDExportSamples.fills(), false),
            ("03_shapes_and_vector_masks", PSDExportSamples.shapes(), false),
            ("04_type_layers", horizontal(PSDExportSamples.type()), false),
            ("04b_vertical_type_without_Txt2", vertical, false),
            ("05_smart_objects", PSDExportSamples.smart(), false),
            ("06_masks_blending_groups_resources", PSDExportSamples.attributes(), false),
            ("07_artboards", PSDExportSamples.artboards(), false),
            ("08_everything", horizontal(PSDExportSamples.everything()), false),
            ("09_sixteen_bit_shapes", sixteen, false),
            ("10_everything_large_document", horizontal(PSDExportSamples.everything()), true),
        ]
        // links are recorded as if the files were already where they will be checked (LUMEN_PHOTOSHOP_SET_FOLDER)
        PSDExport.recordedFolder = ProcessInfo.processInfo.environment["LUMEN_PHOTOSHOP_SET_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        defer { PSDExport.recordedFolder = nil }
        for (name, st, large) in files {
            let url = dir.appendingPathComponent(name + (large ? ".psb" : ".psd"))
            do {
                try PSDWriter.write(st, to: url, large: large)
                let data = try Data(contentsOf: url)
                let v = PSDExportValidator.validate(data)
                check(v.problems.isEmpty, "for Photoshop: \(name) is valid", v.problems.prefix(5).joined(separator: "; "))
                if st.allLayers.contains(where: \.isText) {
                    let composed = st.allLayers.allSatisfy { $0.text.map(PSDExportText.composable) ?? true }
                    check((v.globalKeys.contains("Txt2")) == composed, "for Photoshop: \(name) \(composed ? "has" : "has no") text engine data ('Txt2')")
                }
                try? flatten(st)?.pngData()?.write(to: dir.appendingPathComponent(name + ".png"))
                let summary = Dictionary(grouping: PSDExport.lastNotes, by: \.status).map { "\($0.key.rawValue) \($0.value.count)" }.sorted().joined(separator: ", ")
                metric("for Photoshop \(name): \(summary)")
                for n in PSDExport.lastNotes where n.status != .editable { metric("  \(n.status.rawValue) — \(n.layer) [\(n.feature)]: \(n.detail)") }
            } catch { check(false, "for Photoshop: \(name)", "\(error)") }
        }
        // linked smart object written as a link ('liFE' in 'lnkE', placed with 'SoLE'); the file name is kept from the
        // first round of checks so the copy replaces it
        let st = PSDExportSamples.smart(linkedFile: linked)
        let url = dir.appendingPathComponent("11_EXPERIMENTAL_linked_smart_object.psd")
        if (try? PSDWriter.write(st, to: url)) != nil {
            try? flatten(st)?.pngData()?.write(to: dir.appendingPathComponent("11_EXPERIMENTAL_linked_smart_object.png"))
            let data = (try? Data(contentsOf: url)) ?? Data()
            check(PSDExportValidator.validate(data).problems.isEmpty && globalBlocks(data).contains { $0.0 == "lnkE" }, "for Photoshop: the linked smart object file is valid and links its file")
        }
    }
}
