import AppKit
import PDFKit
import UniformTypeIdentifiers
import ImageCratCore

/// Headless tests of the PDF / Illustrator importer (`LUMEN_SELFTEST_ONLY=pdfimport`). The oracle is PDFKit's own
/// rendering of the page (`PDFImport.rasterize`); every editable import is composited and compared with it, and a
/// side-by-side PNG (PDFKit | Lumen | difference) is written for each file.
enum PDFVectorSelfTest {
    static var passed = 0, failed = 0

    static func check(_ ok: Bool, _ msg: String) {
        if ok { passed += 1; print("PASS pdfimport: \(msg)") } else { failed += 1; print("FAIL pdfimport: \(msg)") }
    }
    static func info(_ msg: String) { print("INFO pdfimport: \(msg)") }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("pdfimport")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_ONLY"]
        func want(_ n: String) -> Bool { only == nil || only!.split(separator: ",").contains { n.hasPrefix($0) } }
        let t0 = Date()
        // ad-hoc: LUMEN_PDFIMPORT_FILE=<path>[:<path>…] (LUMEN_PDFIMPORT_RES, LUMEN_PDFIMPORT_PAGES) imports those files and prints the numbers
        if let files = ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_FILE"] {
            let res = Double(ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_RES"] ?? "") ?? 150
            let maxPages = Int(ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_PAGES"] ?? "") ?? 2
            for (n, f) in files.split(separator: ":").enumerated() {
                let url = URL(fileURLWithPath: String(f))
                guard let pdf = try? PDFVectorImport.open(url) else { info("adhoc \(url.lastPathComponent): cannot open"); continue }
                for p in 0..<Swift.min(pdf.pageCount, maxPages) {
                    guard let r = importAndCompare(url, page: p, resolution: res, dir: dir, tag: "adhoc\(n)_p\(p + 1)") else { info("adhoc \(url.lastPathComponent) p\(p + 1): failed"); continue }
                    info("adhoc \(url.lastPathComponent) p\(p + 1) \(r.state.width)×\(r.state.height): " + describe(r) + " groups \(r.report.groups) masks \(r.report.masks) softmasks \(r.report.softMasks) rasterized \(r.report.rasterized) fonts \(r.report.fonts) notes \(r.report.notes)")
                }
            }
            print("pdfimport: adhoc done")
            return
        }
        if want("shapes") { testShapes(dir) }
        if want("gradients") { testGradients(dir) }
        if want("images") { testImages(dir) }
        if want("text") { testText(dir) }
        if want("groups") { testGroups(dir) }
        if want("fallbacks") { testFallbacks(dir) }
        if want("layers") { testOptionalContent(dir) }
        if want("geometry") { testGeometry(dir) }
        if want("complex") { testComplex(dir) }
        if want("export") { testLumenExport(dir) }
        if want("errors") { testErrors(dir) }
        if want("loader") { testLoader(dir) }
        if want("real") { testRealFiles(dir) }
        if want("fuzz") { testFuzz(dir) }
        if only?.contains("ui") == true { testUI(dir) }
        info(String(format: "finished in %.1f s", Date().timeIntervalSince(t0)))
        print("pdfimport: \(passed) passed, \(failed) failed")
    }

    // MARK: Oracle

    struct Diff {
        var mean = 999.0
        var max = 255
        /// Share of pixels that differ by more than 40 levels in some channel.
        var bad = 1.0
        /// Difference after allowing each edge to sit a pixel off (antialiasing / glyph weight).
        var tolerant = 1.0
        var text: String { String(format: "mean %.2f, max %d, off-pixels %.2f%%, shape mismatch %.3f", mean, max, bad * 100, tolerant) }
    }

    /// PDFKit's rendering of a page on white, optionally with glyphs placed at exact (unquantized) positions and
    /// without font smoothing, which is how Lumen's own type and shape renderers draw.
    static func oracle(_ page: PDFPage, resolution: Double, box: PDFDisplayBox = .cropBox, exactText: Bool = false) -> CGImage? {
        if !exactText { return PDFImport.rasterize(page, resolution: resolution, box: box, white: true) }
        let b = page.bounds(for: box)
        let s = resolution / 72
        var w = Int((b.width * s).rounded()), h = Int((b.height * s).rounded())
        let rot = page.rotation % 360
        if rot == 90 || rot == 270 { swap(&w, &h) }
        guard w > 0, h > 0, w < 30000, h < 30000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.setShouldSmoothFonts(false)
        ctx.setAllowsFontSubpixelQuantization(false); ctx.setShouldSubpixelQuantizeFonts(false)
        ctx.setAllowsFontSubpixelPositioning(true); ctx.setShouldSubpixelPositionFonts(true)
        ctx.scaleBy(x: s, y: s)
        page.draw(with: box, to: ctx)
        return ctx.makeImage()
    }

    static func diff(_ a: CGImage, _ b: CGImage) -> Diff {
        guard a.width == b.width, a.height == b.height else { return Diff() }
        let pa = PixelBuffer(cgImage: a), pb = PixelBuffer(cgImage: b)
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self)
        var total = 0, mx = 0, bad = 0
        for r in 0..<pa.height {
            for c in 0..<pa.width {
                var worst = 0
                for k in 0..<4 {
                    let d = abs(Int(x[r * pa.bytesPerRow + c * 4 + k]) - Int(y[r * pb.bytesPerRow + c * 4 + k]))
                    total += d
                    if d > worst { worst = d }
                }
                if worst > mx { mx = worst }
                if worst > 40 { bad += 1 }
            }
        }
        var d = Diff()
        d.mean = Double(total) / Double(pa.width * pa.height * 4)
        d.max = mx
        d.bad = Double(bad) / Double(pa.width * pa.height)
        // shapes on white: compare the ink (inverted luminance as coverage) with a one-pixel edge tolerance
        d.tolerant = tolerantMismatch(pa, pb)
        return d
    }

    /// Like `PDFVectorOutliner.mismatch`, on opaque images: a pixel only counts when no neighbour of the other
    /// image explains its value.
    static func tolerantMismatch(_ a: PixelBuffer, _ b: PixelBuffer) -> Double {
        let w = a.width, h = a.height
        let pa = a.data.assumingMemoryBound(to: UInt8.self), pb = b.data.assumingMemoryBound(to: UInt8.self)
        var penalty = 0, ink = 0
        for y in 0..<h {
            let y0 = Swift.max(0, y - 1), y1 = Swift.min(h - 1, y + 1)
            for x in 0..<w {
                for k in 0..<3 {
                    let va = Int(pa[y * a.bytesPerRow + x * 4 + k]), vb = Int(pb[y * b.bytesPerRow + x * 4 + k])
                    ink += Swift.max(255 - va, 255 - vb)
                    if abs(va - vb) <= 6 { continue }
                    var minA = 255, maxA = 0, minB = 255, maxB = 0
                    for yy in y0...y1 {
                        for xx in Swift.max(0, x - 1)...Swift.min(w - 1, x + 1) {
                            let na = Int(pa[yy * a.bytesPerRow + xx * 4 + k]), nb = Int(pb[yy * b.bytesPerRow + xx * 4 + k])
                            minA = Swift.min(minA, na); maxA = Swift.max(maxA, na); minB = Swift.min(minB, nb); maxB = Swift.max(maxB, nb)
                        }
                    }
                    if va > maxB { penalty += va - maxB } else if va < minB { penalty += minB - va }
                    if vb > maxA { penalty += vb - maxA } else if vb < minA { penalty += minA - vb }
                }
            }
        }
        return ink == 0 ? 0 : Double(penalty) / Double(ink)
    }

    static func sideBySide(_ a: CGImage, _ b: CGImage, _ url: URL) {
        let w = a.width, h = a.height
        guard b.width == w, b.height == h, let ctx = CGContext(data: nil, width: w * 3 + 16, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w * 3 + 16, height: h))
        ctx.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(b, in: CGRect(x: w + 8, y: 0, width: w, height: h))
        // amplified difference
        let pa = PixelBuffer(cgImage: a), pb = PixelBuffer(cgImage: b)
        let d = PixelBuffer(width: w, height: h)
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self), z = d.data.assumingMemoryBound(to: UInt8.self)
        for r in 0..<h { for c in 0..<w {
            for k in 0..<3 { z[r * d.bytesPerRow + c * 4 + k] = UInt8(Swift.min(255, abs(Int(x[r * pa.bytesPerRow + c * 4 + k]) - Int(y[r * pb.bytesPerRow + c * 4 + k])) * 4)) }
            z[r * d.bytesPerRow + c * 4 + 3] = 255
        } }
        d.markDirty()
        ctx.draw(d.makeCGImage(), in: CGRect(x: w * 2 + 16, y: 0, width: w, height: h))
        if let img = ctx.makeImage() { FilesSelfTest.writePNG(img, url) }
    }

    struct Result {
        var state: DocumentState
        var report: PDFVectorReport
        var diff: Diff
        /// Against PDFKit with exact glyph placement and no font smoothing.
        var exact: Diff
        var seconds: Double
        var leaves: [Layer] { state.allLayers.filter { !$0.isGroup } }
        func count(_ f: (Layer) -> Bool) -> Int { leaves.filter(f).count }
    }

    /// Imports a page as editable layers and compares its composite with PDFKit.
    @discardableResult
    static func importAndCompare(_ url: URL, page index: Int = 0, resolution: Double = 144, box: PDFDisplayBox = .cropBox, options: PDFVectorOptions = PDFVectorOptions(),
                                 password: String? = nil, dir: URL, tag: String? = nil) -> Result? {
        guard let pdf = PDFDocument(url: url) else { return nil }
        if pdf.isLocked, !pdf.unlock(withPassword: password ?? "") { return nil }
        guard let page = pdf.page(at: index) else { return nil }
        let t = Date()
        guard let (st, report) = PDFVectorImport.state(page: page, in: pdf, box: box, resolution: resolution, options: options) else { return nil }
        let secs = Date().timeIntervalSince(t)
        guard let mine = Compositor.shared.flatten(st, background: .white), let ref = oracle(page, resolution: st.resolution, box: box) else { return nil }
        let d = diff(ref, mine)
        var e = d
        if let ref2 = oracle(page, resolution: st.resolution, box: box, exactText: true) { e = diff(ref2, mine) }
        let name = tag ?? url.deletingPathExtension().lastPathComponent
        sideBySide(ref, mine, dir.appendingPathComponent("\(name)_compare.png"))
        Compositor.shared.clearCaches()
        return Result(state: st, report: report, diff: d, exact: e, seconds: secs)
    }

    static func describe(_ r: Result) -> String {
        let l = r.leaves
        return "\(l.count) layers (\(l.filter(\.isShape).count) shape, \(l.filter(\.isText).count) text, \(l.filter(\.isRaster).count) pixel), " + r.diff.text
            + String(format: " | exact-text oracle: mean %.2f | %.2fs", r.exact.mean, r.seconds)
    }

    // MARK: Synthetic corpus

    static func testShapes(_ dir: URL) {
        let url = dir.appendingPathComponent("shapes.pdf")
        PDFVectorTestCorpus.shapes(url)
        guard let r = importAndCompare(url, dir: dir) else { check(false, "shapes.pdf imports"); return }
        info("shapes: " + describe(r))
        check(r.diff.mean < 1.0 && r.diff.bad < 0.004, "shapes: composite matches PDFKit (\(r.diff.text))")
        check(r.count { $0.isRaster } == 0 && r.report.rasterCount == 0, "shapes: everything stays vector (\(r.count { $0.isShape }) shape layers, no pixels)")
        let shapes = r.leaves.compactMap { $0.shape }
        check(shapes.contains { if case .rectangle = $0.geometry { return $0.fill.solidColor.map { $0.r > 0.8 && $0.g < 0.35 } ?? false }; return false }, "shapes: red rectangle is a live rectangle shape")
        check(shapes.contains { !$0.stroke.paint.isNone && !$0.stroke.dash.isEmpty && $0.stroke.cap == .round && abs($0.stroke.width - 12) < 0.2 }, "shapes: dashed round-cap stroke keeps width 12 px, cap and dash")
        check(shapes.contains { !$0.fill.isNone && !$0.stroke.paint.isNone }, "shapes: fill + stroke in one shape layer")
        check(r.leaves.contains { $0.opacity > 0.45 && $0.opacity < 0.55 }, "shapes: constant alpha becomes layer opacity 50%")
        check(r.leaves.contains { $0.blendMode == .multiply }, "shapes: Multiply blend mode on the layer")
        check(r.state.allLayers.contains { $0.vectorMask != nil }, "shapes: elliptical clip becomes a vector mask")
        // the twelve stripes under the clip alternate two colours: nothing to merge, but they share one clip group
        check(r.state.allLayers.contains { $0.isGroup && $0.vectorMask != nil && $0.children.count == 12 }, "shapes: clipped stripes sit in one clip group with a vector mask")
        check(r.report.text.contains("shape layer"), "shapes: report lists shape layers")
    }

    static func testGradients(_ dir: URL) {
        let url = dir.appendingPathComponent("gradients.pdf")
        PDFVectorTestCorpus.gradients(url)
        guard let r = importAndCompare(url, dir: dir) else { check(false, "gradients.pdf imports"); return }
        info("gradients: " + describe(r))
        check(r.diff.mean < 1.5 && r.diff.bad < 0.01, "gradients: composite matches PDFKit (\(r.diff.text))")
        let grads: [GradientFill] = r.leaves.compactMap { l in if case .gradient(let g)? = l.shape?.fill { return g }; return nil }
        check(grads.filter { $0.type == .linear }.count == 2, "gradients: two axial shadings are linear gradient fills (\(grads.filter { $0.type == .linear }.count))")
        check(grads.filter { $0.type == .radial }.count == 1, "gradients: radial shading is a radial gradient fill")
        // moving and scaling a gradient shape takes the gradient along
        if var l = r.leaves.first(where: { if case .gradient? = $0.shape?.fill { return true }; return false }), case .gradient(let g0)? = l.shape?.fill, let s0 = g0.start {
            l.translate(dx: 30, dy: -12)
            if case .gradient(let g1)? = l.shape?.fill, let s1 = g1.start { check(abs(s1.x - s0.x - 30) < 0.01 && abs(s1.y - s0.y + 12) < 0.01, "gradients: a moved shape keeps its gradient in place on the shape") }
            let sc = LayerTransformer.apply(Homography(affine: CGAffineTransform(scaleX: 2, y: 2)), to: l, space: CanvasSpace(width: r.state.width, height: r.state.height))
            if case .gradient(let g2)? = sc.shape?.fill, let s2 = g2.start { check(abs(s2.x - (s0.x + 30) * 2) < 0.01, "gradients: a scaled shape scales its gradient") }
        } else { check(false, "gradients: gradient shape with end points") }
        check(grads.allSatisfy { $0.gradient.stops.count >= 3 && $0.gradient.stops.count <= 24 }, "gradients: stops recovered (\(grads.map { $0.gradient.stops.count }))")
        check(r.report.rasterized.keys.contains { $0.contains("gradient") } && r.count { $0.isRaster } == 1, "gradients: the gradient that ends inside its clip is rasterized and reported")
    }

    static func testImages(_ dir: URL) {
        let url = dir.appendingPathComponent("images.pdf")
        PDFVectorTestCorpus.images(url)
        guard let r = importAndCompare(url, dir: dir) else { check(false, "images.pdf imports"); return }
        info("images: " + describe(r))
        check(r.diff.mean < 1.0 && r.diff.bad < 0.004, "images: composite matches PDFKit (\(r.diff.text))")
        let px = r.leaves.filter(\.isRaster)
        check(px.count == 3 && r.report.images == 3, "images: three image layers (\(px.count))")
        check(px.contains { $0.opacity > 0.65 && $0.opacity < 0.75 }, "images: image alpha 0.7 is the layer's opacity")
        check(px.contains { l in l.raster.map { b in (0..<b.buffer.height).contains { y in (0..<b.buffer.width).contains { x in b.buffer.alpha(x, y) == 0 } } } ?? false }, "images: soft-masked image keeps its transparent hole")
        check(r.report.rasterCount == 0, "images: images are not counted as fallbacks")
    }

    static func testText(_ dir: URL) {
        let url = dir.appendingPathComponent("text.pdf")
        PDFVectorTestCorpus.text(url)
        guard let r = importAndCompare(url, dir: dir) else { check(false, "text.pdf imports"); return }
        info("text: " + describe(r) + " fonts \(r.report.fonts)")
        let texts = r.leaves.compactMap { $0.text }
        info("text layers: " + texts.map { "“\($0.text.replacingOccurrences(of: "\n", with: "⏎"))” \($0.fontName) \(String(format: "%.1f", $0.fontSize))" }.joined(separator: " | "))
        check(r.diff.tolerant < 0.05, "text: composite matches PDFKit within edge tolerance (\(r.diff.text))")
        check(r.diff.mean < 2.5, String(format: "text: type layers are close to PDFKit's own text rendering (mean %.2f)", r.diff.mean))
        for (s, f, size) in PDFVectorTestCorpus.textSamples {
            let hit = texts.first { $0.text == s }
            check(hit != nil && hit!.fontName == f && abs(hit!.fontSize - Double(size) * 2) < 0.1, "text: “\(s)” is a type layer in \(f) at \(Int(size * 2)) px")
        }
        check(texts.contains { $0.text == "Rotated" && !$0.transform.isIdentity && $0.color.r > 0.7 }, "text: rotated red text keeps its rotation and colour")
        let para = texts.first { $0.text.hasPrefix("A paragraph of plain text") }
        check(para != nil && para!.text.contains("\n"), "text: the wrapped paragraph is one multi-line type layer (\(para?.text.components(separatedBy: "\n").count ?? 0) lines)")
        check(r.report.textLayers == texts.count && r.report.rasterCount == 0, "text: nothing rasterized, \(texts.count) text layers reported")

        // fonts that are not installed: outlines from the embedded program
        var o = PDFVectorOptions()
        o.editableText = false
        if let r2 = importAndCompare(url, options: o, dir: dir, tag: "text_outlined") {
            info("text outlined: " + describe(r2))
            check(r2.count { $0.isText } == 0 && r2.report.outlinedText >= 7 && r2.report.rasterCount == 0, "text: with editable text off every block is outlined from the embedded font (\(r2.report.outlinedText))")
            check(r2.diff.tolerant < 0.05, "text: outlines match PDFKit within edge tolerance (\(r2.diff.text))")
            check(r2.exact.mean < 1.5, String(format: "text: outlines match PDFKit drawn with exact glyph placement (mean %.2f)", r2.exact.mean))
        }
    }

    static func testGroups(_ dir: URL) {
        let url = dir.appendingPathComponent("transparency.pdf")
        PDFVectorTestCorpus.transparency(url)
        if let r = importAndCompare(url, dir: dir) {
            info("transparency: " + describe(r))
            check(r.diff.mean < 1.5 && r.diff.bad < 0.01, "transparency: composite matches PDFKit (\(r.diff.text))")
            check(r.state.allLayers.contains { $0.isGroup && $0.opacity > 0.45 && $0.opacity < 0.55 && $0.children.count == 2 }, "transparency: transparency layer is a group at 50% with its two shapes")
            check(r.leaves.contains { $0.blendMode == .screen }, "transparency: Screen blend mode kept")
        } else { check(false, "transparency.pdf imports") }

        let g = dir.appendingPathComponent("groups.pdf")
        PDFVectorTestCorpus.groups(g)
        if let r = importAndCompare(g, dir: dir) {
            info("groups: " + describe(r) + " reasons \(r.report.rasterized)")
            check(r.diff.mean < 1.5 && r.diff.bad < 0.01, "groups: composite matches PDFKit (\(r.diff.text))")
            // Core Graphics draws a knockout group like an ordinary one, so the layers match and are kept
            check(r.report.rasterized["knockout group"] == nil || r.count { $0.isRaster } >= 1, "groups: the knockout group is checked against PDFKit's rendering (kept as layers when they match)")
            check(r.state.allLayers.contains { $0.isGroup && abs($0.opacity - 0.7) < 0.01 && $0.children.count == 2 }, "groups: the isolated group at 70% stays a group of two shapes")
            check(r.leaves.contains { l in l.shape?.fill.solidColor.map { $0.r > 0.4 && $0.b > 0.4 && $0.g < 0.1 } ?? false }, "groups: a form that draws itself is imported once (no endless recursion)")
        } else { check(false, "groups.pdf imports") }

        let c = dir.appendingPathComponent("cmykgroup.pdf")
        PDFVectorTestCorpus.cmykGroup(c)
        if let r = importAndCompare(c, dir: dir) {
            info("cmyk group: " + describe(r) + " reasons \(r.report.rasterized)")
            check(r.diff.mean < 1.0, "groups: translucency inside a CMYK-blending group matches PDFKit (\(r.diff.text))")
            check(r.report.rasterized["transparency blended in a CMYK group"] == 1 && r.count { $0.isRaster } == 1,
                  "groups: a group Lumen would blend differently (CMYK blending) is rasterized from the PDF and reported")
            var o = PDFVectorOptions(); o.exactAppearance = false
            if let r2 = importAndCompare(c, options: o, dir: dir, tag: "cmykgroup_layers") {
                check(r2.count { $0.isRaster } == 0 && r2.count { $0.isShape } == 3 && r2.report.notes.contains { $0.contains("CMYK") },
                      "groups: with exact appearance off the CMYK group stays shapes and the report says colours may differ (\(r2.diff.text))")
            }
        } else { check(false, "cmykgroup.pdf imports") }
    }

    static func testFallbacks(_ dir: URL) {
        let cases: [(String, (URL) -> Void, String)] = [
            ("pattern", PDFVectorTestCorpus.pattern, "pattern fill"), ("mesh", PDFVectorTestCorpus.mesh, "mesh gradient"),
            ("type3", PDFVectorTestCorpus.type3, "Type 3 font"),
        ]
        for (name, make, reason) in cases {
            let url = dir.appendingPathComponent("\(name).pdf")
            make(url)
            guard let r = importAndCompare(url, dir: dir) else { check(false, "\(name).pdf imports"); continue }
            info("\(name): " + describe(r) + " reasons \(r.report.rasterized)")
            check(r.diff.mean < 1.0 && r.diff.bad < 0.005, "\(name): composite matches PDFKit (\(r.diff.text))")
            check(r.report.rasterized[reason] == 1 && r.count { $0.isRaster } == 1, "\(name): “\(reason)” is rasterized in place and reported")
            check(r.count { $0.isShape } >= 1, "\(name): the rest of the page stays vector")
            // stacking: the pixel layer is above the background shape
            let order = r.leaves
            check(order.first?.isShape == true && order.last?.isRaster == true, "\(name): pixel layer keeps its place in the stacking order")
        }
        // a soft mask set through an ExtGState becomes the layer's mask; the shape stays a shape
        let sm = dir.appendingPathComponent("softmask.pdf")
        PDFVectorTestCorpus.softMask(sm)
        if let r = importAndCompare(sm, dir: dir) {
            info("softmask: " + describe(r) + " reasons \(r.report.rasterized)")
            check(r.diff.mean < 1.0 && r.diff.bad < 0.005, "softmask: composite matches PDFKit (\(r.diff.text))")
            let masked = r.leaves.first { $0.mask != nil }
            check(masked?.isShape == true && r.count { $0.isRaster } == 0 && r.report.softMasks == 1, "softmask: the masked object stays a shape with a layer mask")
            check(masked?.mask.map { m in m.buffer.format == .gray && m.outsideValue == 0 && m.buffer.width > 100 } ?? false, "softmask: the luminosity mask is a gray layer mask")
        } else { check(false, "softmask.pdf imports") }

        let a = dir.appendingPathComponent("annotation.pdf")
        PDFVectorTestCorpus.annotation(a)
        if let r = importAndCompare(a, dir: dir) {
            info("annotation: " + describe(r))
            check(r.diff.mean < 1.0, "annotation: appearance stream is imported like PDFKit draws it (\(r.diff.text))")
        } else { check(false, "annotation.pdf imports") }
    }

    static func testOptionalContent(_ dir: URL) {
        let url = dir.appendingPathComponent("layers.pdf")
        PDFVectorTestCorpus.optionalContent(url)
        guard let r = importAndCompare(url, dir: dir) else { check(false, "layers.pdf imports"); return }
        info("layers: " + describe(r) + " top level: \(r.state.layers.map { "\($0.name)\($0.isVisible ? "" : " (hidden)")" })")
        check(r.state.layers.map(\.name) == ["Artwork", "Hidden Notes"], "layers: optional content groups become top-level groups named after the PDF layers")
        check(r.state.layers.first?.isVisible == true && r.state.layers.last?.isVisible == false, "layers: a layer that is off in the PDF arrives hidden")
        check(r.state.layers.last?.children.count == 1 && r.state.layers.first?.children.count == 2, "layers: hidden layer still holds its artwork")
        check(r.diff.mean < 1.0, "layers: composite (hidden layer not shown) matches PDFKit (\(r.diff.text))")
        check(r.report.layerNames == ["Artwork", "Hidden Notes"], "layers: report names the layers")
    }

    static func testGeometry(_ dir: URL) {
        for rot in [0, 90, 180, 270] {
            let url = dir.appendingPathComponent("rotate\(rot).pdf")
            PDFVectorTestCorpus.rotated(url, rotate: rot)
            guard let r = importAndCompare(url, resolution: 100, dir: dir) else { check(false, "rotate\(rot).pdf imports"); continue }
            let expect = rot % 180 == 0 ? (417, 250) : (250, 417)
            check(r.state.width == expect.0 && r.state.height == expect.1, "geometry: /Rotate \(rot) with a crop box → \(r.state.width)×\(r.state.height)")
            check(r.diff.mean < 1.0 && r.diff.bad < 0.004, "geometry: /Rotate \(rot) composite matches PDFKit (\(r.diff.text))")
        }
        // media box instead of the crop box
        if let r = importAndCompare(dir.appendingPathComponent("rotate90.pdf"), resolution: 100, box: .mediaBox, dir: dir, tag: "rotate90_media") {
            check(r.state.width == 306 && r.state.height == 444 && r.diff.mean < 1.0, "geometry: media box choice is honoured (\(r.state.width)×\(r.state.height), \(r.diff.text))")
        }
        let uu = dir.appendingPathComponent("userunit.pdf")
        PDFVectorTestCorpus.userUnit(uu)
        if let r = importAndCompare(uu, resolution: 72, dir: dir), let pdf = PDFDocument(url: uu), let p = pdf.page(at: 0), let ref = PDFImport.rasterize(p, resolution: 72) {
            check(r.state.width == ref.width && r.state.height == ref.height && r.diff.mean < 1.0, "geometry: /UserUnit page has the same size as the flattened import (\(r.state.width)×\(r.state.height), \(r.diff.text))")
        } else { check(false, "userunit.pdf imports") }
        let z = dir.appendingPathComponent("zerobox.pdf")
        PDFVectorTestCorpus.zeroBox(z)
        do {
            var s = PDFImport.Settings(); s.mode = .editable
            let docs = try PDFImport.documents(url: z, settings: s)
            check(docs.allSatisfy { $0.state.width >= 1 && $0.state.height >= 1 }, "geometry: a zero-size media box still yields a valid document (\(docs.first?.state.width ?? 0)×\(docs.first?.state.height ?? 0))")
        } catch { check(error.localizedDescription.contains("usable size"), "geometry: a zero-size page is refused with a message (\(error.localizedDescription))") }
        let hg = dir.appendingPathComponent("huge.pdf")
        PDFVectorTestCorpus.hugeBox(hg)
        if let pdf = PDFDocument(url: hg), let p = pdf.page(at: 0) {
            let t = Date()
            var o = PDFVectorOptions(); o.maxDimension = 4096; o.maxPixels = 12_000_000
            let res = PDFVectorImport.state(page: p, in: pdf, resolution: 300, options: o)
            check(res != nil && res!.0.width <= 4096 && res!.0.height <= 4096 && res!.1.notes.contains { $0.contains("very large") },
                  "geometry: a 40000×30000 pt page is imported at a reduced resolution (\(res?.0.width ?? 0)×\(res?.0.height ?? 0)) with a note")
            check(Date().timeIntervalSince(t) < 20, String(format: "geometry: huge page imports quickly (%.1fs)", Date().timeIntervalSince(t)))
        } else { check(false, "huge.pdf opens") }
    }

    static func testComplex(_ dir: URL) {
        // runs of same-coloured paths merge into few layers
        let merged = dir.appendingPathComponent("merge.pdf")
        PDFVectorTestCorpus.complex(merged, count: 3000, colors: 6, runs: 500)
        if let r = importAndCompare(merged, resolution: 100, dir: dir) {
            info("merge: " + describe(r) + " — \(r.report.mergedPaths) paths")
            check(r.report.mergedPaths == 3000 && r.count { $0.isShape } <= 40 && r.count { $0.isRaster } == 0, "complex: 3000 paths in runs of one colour merge into \(r.count { $0.isShape }) shape layers")
            check(r.diff.mean < 1.0 && r.diff.bad < 0.004, "complex: merged shapes match PDFKit (\(r.diff.text))")
        } else { check(false, "merge.pdf imports") }
        // colours alternate: nothing merges, the layer limit is hit and the rest is rasterized in place
        let many = dir.appendingPathComponent("many.pdf")
        PDFVectorTestCorpus.complex(many, count: 4000, colors: 40, runs: 1)
        var o = PDFVectorOptions(); o.maxLayers = 250
        if let r = importAndCompare(many, resolution: 100, options: o, dir: dir) {
            info("many: " + describe(r) + " reasons \(r.report.rasterized) notes \(r.report.notes)")
            check(r.leaves.count <= 252 && r.count { $0.isRaster } >= 1, "complex: 4000 unmergeable paths stop at the layer limit (\(r.leaves.count) layers, \(r.count { $0.isRaster }) pixel band)")
            check(r.diff.mean < 1.0 && r.diff.bad < 0.004, "complex: layers + rasterized remainder match PDFKit (\(r.diff.text))")
            check(r.report.notes.contains { $0.contains("layer limit") }, "complex: the report says the limit was hit")
            check(r.seconds < 30, String(format: "complex: imports in %.1fs", r.seconds))
        } else { check(false, "many.pdf imports") }
    }

    static func testLumenExport(_ dir: URL) {
        let st = FilesSelfTest.sampleState()
        let url = dir.appendingPathComponent("lumen_export.pdf")
        do { try PDFExport.write(st, to: url) } catch { check(false, "PDF export threw \(error)"); return }
        guard let r = importAndCompare(url, resolution: 72, dir: dir) else { check(false, "lumen_export.pdf imports"); return }
        info("lumen export: " + describe(r))
        check(r.state.width == st.width && r.state.height == st.height, "export round trip: same size at 72 ppi")
        check(r.leaves.contains { $0.text?.text == "Hello Lumen" }, "export round trip: the type layer comes back as editable text")
        check(r.leaves.contains { $0.isShape }, "export round trip: the shape layer comes back as a shape")
        check(r.diff.tolerant < 0.05 && r.exact.mean < 2, "export round trip: composite matches PDFKit (\(r.diff.text))")
        let back = FilesSelfTest.diff(st, r.state)
        check(back < 2.5, String(format: "export round trip: composite matches the original Lumen document (mean diff %.2f)", back))
    }

    // MARK: Errors

    static func testErrors(_ dir: URL) {
        func message(_ url: URL, _ s: PDFImport.Settings = PDFImport.Settings()) -> String {
            do { _ = try PDFImport.documents(url: url, settings: s); return "" } catch { return error.localizedDescription }
        }
        let legacy = dir.appendingPathComponent("legacy8.ai")
        PDFVectorTestCorpus.legacyIllustrator(legacy)
        var m = message(legacy)
        check(m.contains("PostScript-based Illustrator file") && m.contains("Create PDF Compatible File"), "errors: legacy (Illustrator 8) file is refused with re-save advice")
        let eps = dir.appendingPathComponent("drawing.eps")
        PDFVectorTestCorpus.eps(eps)
        m = (try? DocumentIO.load(url: eps)).map { _ in "" } ?? message(eps)
        check(m.contains("EPS") && m.contains("PDF"), "errors: EPS is refused with advice (\(m.prefix(60))…)")
        let ph = dir.appendingPathComponent("no_pdf_content.ai")
        PDFVectorTestCorpus.placeholder(ph)
        m = message(ph)
        check(m.contains("saved without PDF content") && m.contains("Create PDF Compatible File"), "errors: Illustrator file without PDF content is refused with re-save advice")
        // the same notice page in a real .pdf is an ordinary page
        let asPDF = dir.appendingPathComponent("notice_page.pdf")
        try? FileManager.default.copyItem(at: ph, to: asPDF)
        check(!message(asPDF).isEmpty, "errors: the notice page is recognised by its text in a .pdf too")
        let junk = dir.appendingPathComponent("junk.pdf")
        try? Data((0..<4000).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) }).write(to: junk)
        check(message(junk).contains("damaged"), "errors: a file that is not a PDF gives a clear message")
        let trunc = dir.appendingPathComponent("truncated.pdf")
        if let d = try? Data(contentsOf: dir.appendingPathComponent("shapes.pdf")) { try? d.prefix(d.count / 3).write(to: trunc) }
        m = message(trunc)
        check(true, "errors: truncated PDF does not crash (\(m.isEmpty ? "opened" : String(m.prefix(50))))")
        // encrypted
        let enc = dir.appendingPathComponent("encrypted.pdf")
        PDFVectorTestCorpus.encrypted(enc, password: "s3cret")
        m = message(enc)
        check(m.contains("password-protected"), "errors: encrypted PDF without a password is refused with a message in automated runs")
        var s = PDFImport.Settings(); s.password = "wrong"
        check(message(enc, s).contains("password-protected"), "errors: a wrong password is refused")
        s.password = "s3cret"; s.mode = .editable
        do {
            let docs = try PDFImport.documents(url: enc, settings: s)
            check(docs.first.map { $0.state.allLayers.contains { $0.isShape } } ?? false, "errors: encrypted PDF opens as editable layers with its password")
        } catch { check(false, "encrypted PDF with password threw \(error.localizedDescription)") }
        check(PDFDocument(url: URL(fileURLWithPath: "/nonexistent/x.pdf")) == nil && !message(URL(fileURLWithPath: "/nonexistent/x.pdf")).isEmpty, "errors: a missing file throws")
    }

    // MARK: Loader, Place, paste

    static func testLoader(_ dir: URL) {
        let app = AppModel.shared
        let saved = (app.documents, app.activeDocumentID, PDFVectorImport.headlessSettings, AppActions.pasteboard, AppActions.clipboard)
        defer {
            app.documents = saved.0; app.activeDocumentID = saved.1; PDFVectorImport.headlessSettings = saved.2
            AppActions.pasteboard = saved.3; AppActions.clipboard = saved.4
        }
        let ai = dir.appendingPathComponent("artwork.ai")
        PDFVectorTestCorpus.shapes(ai)
        check(DocumentIO.customLoaders["ai"] != nil && DocumentIO.customLoaders["ait"] != nil, "loader: .ai and .ait are registered")
        check(DocumentIO.extraOpenTypes.contains { $0.preferredFilenameExtension == "ai" || $0.identifier.contains("illustrator") }, "loader: the Illustrator type is offered by the Open / Place panels")
        check(DocumentIO.extraOpenTypes.contains(.pdf), "loader: PDF is still offered")
        PDFVectorImport.headlessSettings = nil
        PDFVectorImport.clearReports()
        do {
            let d = try DocumentIO.load(url: ai)
            check(d.state.layers.count == 1 && d.state.layers[0].isRaster, "loader: automated default for .ai is a flattened first page")
            var s = PDFImport.Settings(); s.mode = .editable; s.resolution = 144
            PDFVectorImport.headlessSettings = s
            let e = try DocumentIO.load(url: ai)
            check(e.state.allLayers.filter(\.isShape).count >= 10 && e.state.width == 800, "loader: .ai opens as editable layers through File ▸ Open (\(e.state.allLayers.count) layers)")
            check(PDFVectorImport.report(for: e.id) != nil && PDFVectorImport.reports.first?.report.file == "artwork.ai", "loader: an import report is recorded for the document")
            check(PDFVectorReportDialog.text(PDFVectorImport.reports).contains("shape layer"), "loader: the report dialog has text to show")
            check(e.fileURL == ai, "loader: a single-page import is associated with its file")
        } catch { check(false, "loader threw \(error.localizedDescription)") }

        // multi-page: two selected pages → two documents
        let multi = dir.appendingPathComponent("multi.pdf")
        PDFVectorTestCorpus.multiPage(multi)
        do {
            var s = PDFImport.Settings(pages: [0, 2], resolution: 72); s.mode = .editable
            let docs = try PDFImport.documents(url: multi, settings: s)
            check(docs.count == 2 && docs[1].name.contains("Page 3") && docs.allSatisfy { $0.state.width == 200 }, "loader: selected pages open as separate editable documents")
            check(docs[1].state.allLayers.contains { $0.text?.text == "Page 3" }, "loader: page 3 has its own text layer")
            s.mode = .flattened
            let flat = try PDFImport.documents(url: multi, settings: s)
            check(flat.count == 2 && flat[0].state.layers.count == 1 && flat[0].state.layers[0].isRaster, "loader: flattened mode still gives one pixel layer per page")
        } catch { check(false, "multi-page import threw \(error.localizedDescription)") }

        // Place Embedded / Linked / Replace Contents
        var s = PDFImport.Settings(); s.mode = .editable; s.resolution = 72
        PDFVectorImport.headlessSettings = s
        let host = Document.newBlank(width: 600, height: 500, background: .white, name: "host")
        app.add(host)
        AppActions.placeFile(ai)
        if let so = host.activeLayer?.smart, case .document(let inner) = so.source {
            check(inner.allLayers.contains { $0.isShape }, "place: a placed .ai is a smart object that contains the editable document (\(inner.allLayers.count) layers)")
            check(abs(so.quad.bounds.width - 400) < 1, "place: placed at its natural size")
        } else { check(false, "place: placed .ai is a smart object with a document source") }
        AppActions.placeLinked(ai)
        if let l = host.activeLayer, let so = l.smart {
            check(so.linkedURL == ai, "place: Place Linked keeps the link to the .ai file")
            if case .document = so.source { check(true, "place: linked .ai holds the editable document") } else { check(false, "place: linked .ai holds the editable document") }
            let pdfURL = dir.appendingPathComponent("gradients.pdf")
            if !FileManager.default.fileExists(atPath: pdfURL.path) { PDFVectorTestCorpus.gradients(pdfURL) }
            check(AppActions.replaceSmartContents(of: l.id, in: host, with: pdfURL), "place: Replace Contents accepts a PDF")
            if case .document(let inner)? = host.state.layer(l.id)?.smart?.source {
                check(inner.width == 360 && inner.allLayers.contains { if case .gradient? = $0.shape?.fill { return true }; return false }, "place: replaced contents are the editable PDF (gradient shapes inside)")
            } else { check(false, "place: replaced contents are a document") }
        } else { check(false, "place: Place Linked made a smart object") }

        // how a placed vector document renders when enlarged
        let big = Document.newBlank(width: 1200, height: 900, background: .white, name: "big")
        app.add(big)
        AppActions.placeFile(ai)
        if let id = big.activeLayerID, var so = big.state.layer(id)?.smart {
            so.quad = Quad(rect: CGRect(x: 0, y: 0, width: 1200, height: 900))
            big.updateLayer(id) { $0.smart = so }
            var o = PDFImport.Settings(); o.mode = .editable; o.resolution = 216
            if let direct = try? PDFImport.documents(url: ai, settings: o).first, let a = Compositor.shared.flatten(big.state, background: .white),
               let b = Compositor.shared.flatten(direct.state, background: .white) {
                let d = diff(a, b)
                sideBySide(b, a, dir.appendingPathComponent("placed_3x_compare.png"))
                info("placed ×3 vs. imported at 3× resolution: \(d.text)")
                check(d.mean < 0.5 && d.bad < 0.004, "place: a placed vector document enlarged 3× is as sharp as a 3× import (\(d.text))")
            }
        }
        app.close(big)
        app.close(host)

        // paste vector PDF from a private pasteboard
        let pb = NSPasteboard(name: NSPasteboard.Name("lumen.selftest.pdfimport"))
        defer { pb.releaseGlobally() }
        AppActions.pasteboard = pb
        AppActions.clipboard = nil
        pb.clearContents()
        if let data = try? Data(contentsOf: ai) { pb.setData(data, forType: .pdf) }
        let target = Document.newBlank(width: 900, height: 700, resolution: 144, background: .white, name: "paste")
        app.add(target)
        let before = target.state.layers.count
        AppActions.paste()
        let pasted = target.state.layers.last
        check(target.state.layers.count == before + 1 && (pasted?.isGroup ?? false) && (pasted?.children.contains { $0.isShape || $0.isGroup } ?? false),
              "paste: PDF data on the pasteboard pastes as a group of editable layers (\(pasted?.children.count ?? 0) children)")
        let pastedBounds = Compositor.shared.contentBounds(pasted ?? Layer.raster(name: "x", width: 1, height: 1), state: target.state)
        check(pastedBounds.map { abs($0.midX - 450) < 60 && abs($0.midY - 350) < 60 } ?? false,
              "paste: pasted artwork is centred on the canvas at the document's resolution (\(pastedBounds.map { "\($0.integral)" } ?? "no bounds"))")
        // a PDF that only wraps a photo is left to the normal image paste
        pb.clearContents()
        let photo = dir.appendingPathComponent("photo_only.pdf")
        PDFVectorTestCorpus.cgPDF(photo, size: CGSize(width: 120, height: 90)) { c, _ in c.draw(PDFVectorTestCorpus.testImage(120, 90), in: CGRect(x: 0, y: 0, width: 120, height: 90)) }
        if let data = try? Data(contentsOf: photo) { pb.setData(data, forType: .pdf) }
        check(!PDFVectorImport.pasteVector(from: pb), "paste: a PDF that is only a picture is not pasted as vector layers")
        app.close(target)
        Compositor.shared.clearCaches()
    }

    // MARK: Real files

    static let illustratorFiles: [String] = {
        let base = "/Applications/Adobe Illustrator 2026"
        let scripts = base + "/Scripting.localized/Sample Scripts.localized/AppleScript.localized"
        let shapes = base + "/Adobe Illustrator.app/Contents/Required/UXP/extensions/com.adobe.illustrator.videoplayer/shapes"
        return [scripts + "/Calendar.localized/CalendarTemplate.ai", scripts + "/Analyze Documents.localized/Documents to Analyze.localized/GradientTestFile.ai",
                scripts + "/Analyze Documents.localized/Documents to Analyze.localized/FontTest.ai", scripts + "/Analyze Documents.localized/Documents to Analyze.localized/PlacedFileTest.ai",
                scripts + "/Analyze Documents.localized/Documents to Analyze.localized/PlacedItemTest.ai", scripts + "/Collect for Output.localized/Docs.localized/Sample.ai",
                shapes + "/Combine_artwork.ait", shapes + "/Drawing_Shapes.ait", shapes + "/Combining_Shapes.ait", shapes + "/Creating_Lines.ait"]
    }()

    static let systemPDFs: [String] = [
        "/System/Library/Frameworks/Automator.framework/Versions/A/Resources/Automator Launching.pdf",
        "/Applications/Xcode.app/Contents/Resources/Acknowledgments.pdf",
        "/Library/Documentation/License.lpdf/Contents/Resources/English.lproj/License.pdf",
        "/System/Library/Audio/MIDI Devices/Generic/Images/Keyboard.pdf",
        "/System/Library/PrivateFrameworks/PassKitMacHelper.framework/Versions/A/Resources/AppleCardIcon.pdf",
    ]

    /// Files that ship inside application bundles on this Mac (read only). Missing ones are skipped, not failed.
    static func testRealFiles(_ dir: URL) {
        var seen = 0
        for path in illustratorFiles + systemPDFs {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { info("real: skipped (not installed) \(url.lastPathComponent)"); continue }
            guard let pdf = try? PDFVectorImport.open(url) else { check(false, "real: \(url.lastPathComponent) opens"); continue }
            seen += 1
            for p in 0..<min(pdf.pageCount, 3) {
                let tag = "real_" + url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: " ", with: "_") + (pdf.pageCount > 1 ? "_p\(p + 1)" : "")
                guard let r = importAndCompare(url, page: p, resolution: 110, dir: dir, tag: tag) else { check(false, "real: \(url.lastPathComponent) page \(p + 1) imports"); continue }
                info("real \(url.lastPathComponent) p\(p + 1): " + describe(r) + (r.report.rasterized.isEmpty ? "" : " rasterized \(r.report.rasterized)")
                     + (r.report.fonts.isEmpty ? "" : " fonts \(r.report.fonts)") + (r.report.layerNames.isEmpty ? "" : " layers \(r.report.layerNames)"))
                // Plain means on text pages measure glyph antialiasing (PDFKit snaps glyphs to pixels and darkens stems,
                // outlines do not); the edge-tolerant mismatch is what tells a wrong import from a right one.
                check(r.diff.tolerant < 0.03 && Swift.min(r.diff.mean, r.exact.mean) < 6.5, "real: \(url.lastPathComponent) p\(p + 1) matches PDFKit (\(r.diff.text); exact-text mean \(String(format: "%.2f", r.exact.mean)))")
                check(!r.report.flattened, "real: \(url.lastPathComponent) p\(p + 1) is imported as layers, not flattened")
            }
        }
        if seen == 0 { info("real: no bundled Illustrator / PDF files found on this machine") }
        // Illustrator files saved without PDF content ship with Illustrator's presets: the error path on a real file
        let preset = "/Applications/Adobe Illustrator 2026/Presets.localized/en_US/Symbols/Nature.ai"
        if FileManager.default.fileExists(atPath: preset) {
            do { _ = try PDFVectorImport.open(URL(fileURLWithPath: preset)); check(false, "real: Nature.ai (no PDF content) is refused") }
            catch { check(error.localizedDescription.contains("saved without PDF content"), "real: Nature.ai (saved without PDF content) is refused with re-save advice") }
        } else { info("real: skipped (not installed) Nature.ai") }
    }

    /// Offscreen snapshots of the import dialog and the report (opt-in: `LUMEN_PDFIMPORT_ONLY=ui`), for a visual check.
    static func testUI(_ dir: URL) {
        let url = dir.appendingPathComponent("ui_multi.pdf")
        PDFVectorTestCorpus.multiPage(url)
        guard let pdf = PDFDocument(url: url) else { return }
        let m = ImportPDFModel(pdf: pdf, illustrator: true)
        FilesSelfTest.snapshot(ImportPDFView(m: m).padding(12), size: CGSize(width: 454, height: 516), to: dir.appendingPathComponent("ui_import_dialog.png"))
        var s = PDFImport.Settings(); s.mode = .editable
        let shapes = dir.appendingPathComponent("ui_shapes.pdf")
        PDFVectorTestCorpus.text(shapes)
        PDFVectorImport.clearReports()
        _ = try? PDFImport.documents(url: shapes, settings: s)
        let pat = dir.appendingPathComponent("ui_pattern.pdf")
        PDFVectorTestCorpus.pattern(pat)
        _ = try? PDFImport.documents(url: pat, settings: s)
        FilesSelfTest.snapshot(PDFVectorReportDialog(), size: CGSize(width: 540, height: 420), to: dir.appendingPathComponent("ui_report.png"))
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ui_import_dialog.png").path), "ui: snapshots written")
    }

    // MARK: Fuzz

    /// Truncated and mutated copies of corpus files: every outcome is fine except a crash or a hang.
    static func testFuzz(_ dir: URL) {
        var sources: [Data] = []
        for n in ["shapes", "gradients", "images", "text", "transparency", "groups", "layers", "softmask", "type3", "mesh"] {
            if let d = try? Data(contentsOf: dir.appendingPathComponent("\(n).pdf")) { sources.append(d) }
        }
        if sources.isEmpty {
            let u = dir.appendingPathComponent("fuzz_seed.pdf")
            PDFVectorTestCorpus.shapes(u)
            if let d = try? Data(contentsOf: u) { sources.append(d) }
        }
        for p in illustratorFiles.prefix(2) { if let d = try? Data(contentsOf: URL(fileURLWithPath: p)), d.count < 2_000_000 { sources.append(d) } }
        // LUMEN_PDFIMPORT_SEED picks another random sequence (for hunting; the default is fixed so runs are repeatable)
        let seed0: UInt64 = 0x9E3779B97F4A7C15 &+ (UInt64(ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_SEED"] ?? "") ?? 0) &* 0xD1B54A32D192ED03
        var seed = seed0
        func rnd(_ n: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(Swift.max(1, n))) }
        var opened = 0, imported = 0, flattened = 0, slowest = 0.0
        let rounds = 320
        let start = Date()
        // a hang must not stall the whole self-test run silently: say so and stop
        var beat = Date()
        var fuzzing = true
        let watchdog = Thread {
            while fuzzing {
                Thread.sleep(forTimeInterval: 2)
                if fuzzing, Date().timeIntervalSince(beat) > 120 {
                    print("FAIL pdfimport: fuzz: an import did not finish within 120 s (hang)")
                    fflush(stdout)
                    exit(3)
                }
            }
        }
        watchdog.start()
        defer { fuzzing = false }
        for i in 0..<rounds {
            var d = sources[i % sources.count]
            switch i % 4 {
            case 0: d = d.prefix(rnd(d.count) + 1)                                   // truncate
            case 1: for _ in 0..<(1 + rnd(24)) { d[rnd(d.count)] = UInt8(rnd(256)) }     // flip bytes
            case 2:                                                                     // corrupt inside a stream / numbers
                let at = rnd(d.count), n = Swift.min(d.count - at, 1 + rnd(200))
                for k in 0..<n { d[at + k] = UInt8(48 + rnd(10)) }
            default:                                                                    // cut a piece out of the middle
                let at = rnd(d.count), n = Swift.min(d.count - at, 1 + rnd(d.count / 4 + 1))
                d.removeSubrange(at..<(at + n))
            }
            beat = Date()
            guard let pdf = PDFDocument(data: d), !pdf.isLocked, pdf.pageCount > 0, let page = pdf.page(at: 0) else { continue }
            opened += 1
            let t = Date()
            var o = PDFVectorOptions(); o.maxPixels = 4_000_000; o.maxDimension = 2400
            if let (st, rep) = PDFVectorImport.state(page: page, in: pdf, resolution: 72, options: o) {
                imported += 1
                if rep.flattened { flattened += 1 }
                if i % 8 == 0 { _ = Compositor.shared.flatten(st, background: .white); Compositor.shared.clearCaches() }
            }
            let dt = Date().timeIntervalSince(t)
            if dt > 5 {   // keep the file that was slow, to reproduce
                try? d.write(to: dir.appendingPathComponent("fuzz_slow_\(i).pdf"))
                info(String(format: "fuzz: mutation %d took %.1fs (saved as fuzz_slow_%d.pdf)", i, dt, i))
            }
            slowest = Swift.max(slowest, dt)
        }
        info(String(format: "fuzz: %d mutated files, %d opened by PDFKit, %d imported (%d flattened), slowest %.2fs, total %.1fs", rounds, opened, imported, flattened, slowest, Date().timeIntervalSince(start)))
        // PDFKit rejects most broken files before the importer sees them, so the interpreter also gets pages of
        // random operators and operands inside a valid file (these always open)
        let ops = ["q", "Q", "cm", "w", "J", "j", "M", "d", "gs", "m", "l", "c", "v", "y", "h", "re", "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n", "W", "W*",
                   "BT", "ET", "Tc", "Tw", "Tz", "TL", "Tf", "Tr", "Ts", "Td", "TD", "Tm", "T*", "Tj", "TJ", "'", "\"", "CS", "cs", "SC", "SCN", "sc", "scn", "G", "g", "RG", "rg",
                   "K", "k", "sh", "Do", "BMC", "BDC", "EMC", "MP", "DP", "BX", "EX", "d0", "d1", "ri", "i"]
        let operands = ["0", "1", "-1", "0.5", "72", "300", "12", "40", "150", "0.2", "0.9", "3", "/F1", "/Fm0", "/GS0", "/Sh0", "/P0", "/Cs0", "/Pattern", "/OC", "/MC0", "(text)",
                        "<48656C6C6F>", "[1 2 3]", "[(A) -120 (B)]", "[4 2]", "<< /W 2 /H 2 /BPC 8 /CS /G >>", "true", "null"]
        // tokens that swallow what follows them: used rarely, or every page would be one unterminated string
        let nasty = ["1e9", "-99999999999", ".", "--3", "(un(bal)anced", "<4", "[", "]", "<<", ">>", "%c\n", "99999999999999999999999999", "\u{0}"]
        var soup = 0, soupSlowest = 0.0, soupLayers = 0, soupFlat = 0, soupOff = 0, soupCompared = 0
        seed = seed0 ^ 0x5EED_50FF_1234_ABCD   // independent of the mutations above (their draws depend on which files exist)
        for i in 0..<120 {
            var content = ""
            var clean = true
            var depth = 0   // saved states are kept balanced: PDFKit itself draws pages with a dangling q differently
            func junk() -> String { clean = false; return nasty[rnd(nasty.count)] }
            func n(_ range: Int) -> String { rnd(500) == 0 ? junk() : String(rnd(range) - range / 6) }
            for _ in 0..<(20 + rnd(160)) {
                // mostly well-formed constructs with random numbers, with random operators and junk sprinkled in
                switch rnd(16) {
                case 0: content += "q "; depth += 1
                case 1: if depth > 0 { content += "Q "; depth -= 1 }
                case 2: content += "\(Double(3 + rnd(27)) / 10) \(Double(rnd(3)) / 10) \(Double(rnd(3)) / 10) \(Double(3 + rnd(27)) / 10) \(n(200)) \(n(150)) cm "
                case 3: content += "\(Double(rnd(10)) / 9) \(Double(rnd(10)) / 9) \(Double(rnd(10)) / 9) \(rnd(2) == 0 ? "rg" : "RG") "
                case 4: content += "\(Double(rnd(10)) / 9) \(Double(rnd(10)) / 9) \(Double(rnd(10)) / 9) \(Double(rnd(10)) / 9) \(rnd(2) == 0 ? "k" : "K") "
                case 5: content += "\(n(300)) \(n(200)) \(n(200)) \(n(150)) re \(["f", "f*", "S", "B", "B*", "W n", "W* n", "n"][rnd(8)]) "
                case 6: content += "\(n(300)) \(n(200)) m \(n(300)) \(n(200)) l \(n(300)) \(n(200)) \(n(300)) \(n(200)) \(n(300)) \(n(200)) c \(["h f", "S", "s", "b", "b*", "f*", "h W n"][rnd(7)]) "
                case 7: content += "\(n(12)) w \(rnd(3)) J \(rnd(3)) j \(1 + rnd(12)) M [\(rnd(9)) \(rnd(9))] \(rnd(5)) d "
                case 8: content += "BT /F1 \(n(40)) Tf \(n(300)) \(n(200)) Td \(rnd(30) == 0 ? 4 + rnd(4) : rnd(4)) Tr (Text \(rnd(99))) Tj [(ab) \(n(900)) (cd)] TJ T* (x) ' ET "
                case 9: content += rnd(4) == 0 ? "/GS1 gs " : "/GS0 gs "
                case 10: content += "/Fm0 Do "
                case 11: content += "/Sh0 sh "
                case 12: content += "/Pattern cs /P0 scn /Cs0 CS \(Double(rnd(10)) / 9) SCN "
                case 13: content += rnd(2) == 0 ? "/OC /MC0 BDC " : "EMC "
                case 14: content += "BI /W 2 /H 2 /BPC 8 /CS /G ID abcd EI "
                default:
                    for _ in 0..<rnd(7) { content += (rnd(60) == 0 ? junk() : operands[rnd(operands.count)]) + " " }
                    let op = ops[rnd(ops.count)]
                    if op == "q" || op == "Q" { continue }
                    content += op + " "
                }
            }
            content += String(repeating: "Q ", count: depth)
            let u = dir.appendingPathComponent("soup.pdf")
            PDFVectorTestCorpus.raw(u, resources: "/Font << /F1 5 0 R >> /XObject << /Fm0 6 0 R >> /ExtGState << /GS0 7 0 R /GS1 12 0 R >> /Shading << /Sh0 8 0 R >> /Pattern << /P0 9 0 R >> /ColorSpace << /Cs0 [/Separation /Spot /DeviceRGB 10 0 R] >> /Properties << /MC0 11 0 R >>",
                                    catalogExtra: "/OCProperties << /OCGs [11 0 R] /D << /OFF [11 0 R] >> >>", content: content) { r in
                r.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
                r.stream("/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Group << /S /Transparency >>", "0.2 0.6 0.9 rg 10 10 80 60 re f 1 0 0 RG 4 w 20 20 m 90 80 l S")
                r.add("<< /Type /ExtGState /ca 0.5 /CA 0.3 /BM /Multiply /LW 3 /D [[2 1] 0] >>")
                r.add("<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [0 0 100 0] /Function << /FunctionType 2 /Domain [0 1] /C0 [1 0 0] /C1 [0 0 1] /N 1 >> /Extend [true true] >>")
                r.add("<< /PatternType 2 /Shading 8 0 R /Matrix [1 0 0 1 10 10] >>")
                r.add("<< /FunctionType 2 /Domain [0 1] /C0 [1 1 1] /C1 [0.2 0.4 0.6] /N 1 >>")
                r.add("<< /Type /OCG /Name (Soup) >>")
                r.add("<< /Type /ExtGState /SMask << /Type /Mask /S /Luminosity /G 13 0 R >> >>")
                r.stream("/Type /XObject /Subtype /Form /BBox [0 0 300 200] /Group << /S /Transparency /CS /DeviceGray >>", "0.3 g 0 0 300 200 re f 1 g 40 30 200 120 re f")
            }
            beat = Date()
            guard let pdf = PDFDocument(url: u), let page = pdf.page(at: 0) else { continue }
            let t = Date()
            if let (st, rep) = PDFVectorImport.state(page: page, in: pdf, resolution: 72) {
                soup += 1
                soupLayers += st.allLayers.count
                if rep.flattened { soupFlat += 1 }
                // differential check: random but valid content should still look like PDFKit's rendering (pages with
                // junk numbers are only imported: PDFKit itself can take minutes on e.g. dashed text at size 1e11)
                if let mine = Compositor.shared.flatten(st, background: .white), clean, let ref = oracle(page, resolution: 72) {
                    soupCompared += 1
                    let d = diff(ref, mine)
                    if d.tolerant > 0.03 {
                        soupOff += 1
                        if soupOff <= 6 {
                            try? FileManager.default.copyItem(at: u, to: dir.appendingPathComponent("soup_off_\(i).pdf"))
                            sideBySide(ref, mine, dir.appendingPathComponent("soup_off_\(i)_compare.png"))
                            info("fuzz: random page \(i) differs from PDFKit (\(d.text)) — kept as soup_off_\(i).pdf")
                        }
                    }
                }
                Compositor.shared.clearCaches()
            }
            var dt = Date().timeIntervalSince(t)
            if dt > 5 {
                // Core Graphics itself can need half a minute for junk such as dashed outlines of enormous type; an
                // import that has to render such a page is slow for that reason, not hung. Only time beyond what
                // PDFKit takes for the same page counts.
                beat = Date()
                let t2 = Date()
                _ = PDFImport.rasterize(page, resolution: 72)
                let own = Date().timeIntervalSince(t2)
                try? FileManager.default.copyItem(at: u, to: dir.appendingPathComponent("soup_slow_\(i).pdf"))
                info(String(format: "fuzz: random page %d took %.1fs (PDFKit alone: %.1fs; kept as soup_slow_%d.pdf)", i, dt, own, i))
                dt = Swift.max(0, dt - own * 2)
            }
            soupSlowest = Swift.max(soupSlowest, dt)
        }
        info(String(format: "fuzz: %d pages of random operators imported (%d layers in all, %d flattened; %d compared with PDFKit, %d not matching), slowest %.2fs", soup, soupLayers, soupFlat, soupCompared, soupOff, soupSlowest))
        check(soup >= 100, "fuzz: random operator streams import without a crash (\(soup) of 120)")
        check(soupCompared >= 40 && soupOff * 20 <= soupCompared, "fuzz: pages of random valid content still match PDFKit (\(soupCompared - soupOff) of \(soupCompared))")
        slowest = Swift.max(slowest, soupSlowest)
        check(true, "fuzz: \(rounds) truncated / mutated files without a crash")
        check(slowest < 20, String(format: "fuzz: no hang (slowest import %.2fs)", slowest))
    }
}
