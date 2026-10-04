import AppKit
@testable import LumenUltra
import SwiftUI
import UniformTypeIdentifiers
import ImageCratCore

/// Headless tests of the web-export module: `LUMEN_SELFTEST_ONLY=webexport Lumen --selftest <dir>`.
/// Environment: LUMEN_WEBEXPORT_EFFORT=fast|thorough|max, LUMEN_WEBEXPORT_LARGE=0|1, LUMEN_WEBEXPORT_ONLY=<corpus name filter>,
/// LUMEN_WEBEXPORT_SKIP=engine|app to run only one half.
enum WebExportSelfTest {
    static func check(_ ok: Bool, _ msg: String) { WXSelfTestCore.check(ok, msg) }
    static func say(_ s: String) { WXSelfTestCore.say(s) }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("webexport")
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let effort: UPEffort = env["LUMEN_WEBEXPORT_EFFORT"] == "max" ? .maximum : (env["LUMEN_WEBEXPORT_EFFORT"] == "fast" ? .fast : (env["LUMEN_WEBEXPORT_EFFORT"] == "thorough" ? .thorough : (debug ? .fast : .thorough)))
        let large = env["LUMEN_WEBEXPORT_LARGE"].map { $0 == "1" } ?? !debug
        say("Lumen web export self test — \(debug ? "debug" : "release") build, effort \(effort.title), \(large ? "large" : "small") corpus, \(ProcessInfo.processInfo.activeProcessorCount) cores")
        if env["LUMEN_WEBEXPORT_SKIP"] != "engine" { WXSelfTestCore.run(dir, large: large, effort: effort, only: env["LUMEN_WEBEXPORT_ONLY"]) }
        if env["LUMEN_WEBEXPORT_SKIP"] != "app" && env["LUMEN_WEBEXPORT_ONLY"] == nil { appTests(dir) }
        say("webexport: \(WXSelfTestCore.passed) passed, \(WXSelfTestCore.failed) failed")
        try? WXSelfTestCore.report.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }

    // MARK: documents

    static func vectorState() -> DocumentState {
        var st = DocumentState(width: 360, height: 220)
        st.layers = [Layer(name: "Fill", content: .fill(FillContent(paint: .color(RGBA(hex: "F4F5F7")!))))]
        st.layers.append(SelfTest.shapeLayer(CGRect(x: 24, y: 24, width: 140, height: 110), RGBA(hex: "2E86AB")!, radius: 18))
        var ell = ShapeContent(geometry: .ellipse(CGRect(x: 120, y: 70, width: 120, height: 120)),
                               fill: .gradient(GradientFill(gradient: .twoColor(RGBA(hex: "FF8C00")!, RGBA(hex: "7F00FF")!), type: .linear, angle: 0)))
        ell.stroke = StrokeStyle(paint: .color(RGBA(hex: "1B1F3A")!), width: 4, alignment: .center)
        st.layers.append(Layer(name: "Ellipse", content: .shape(ell)))
        var t = TextContent()
        t.text = "Lumen"; t.fontName = "Helvetica-Bold"; t.fontSize = 44; t.color = RGBA(hex: "1B1F3A")!; t.position = CGPoint(x: 190, y: 30)
        st.layers.append(Layer(name: "Title", content: .text(t)))
        return st
    }

    static func hybridState() -> DocumentState {
        var st = vectorState()
        let buf = PixelBuffer(width: 120, height: 80)
        let g = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "8EC5FC")!.cgColor, RGBA(hex: "E0C3FC")!.cgColor] as CFArray, locations: [0, 1])!
        buf.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 120, y: 80), options: [])
        buf.context.setFillColor(RGBA(hex: "E94F37")!.cgColor); buf.context.fillEllipse(in: CGRect(x: 30, y: 20, width: 50, height: 40))
        buf.markDirty()
        st.layers.insert(Layer.raster(name: "Pixels", buffer: buf, origin: IPoint(x: 220, y: 120)), at: 2)
        return st
    }

    static func rasterize(svg: Data, width: Int, height: Int) -> UPImage? {
        guard let img = NSImage(data: svg) else { return nil }
        let ctx = WXCorpus.context(width, height)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        img.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return WXCorpus.image(ctx)
    }

    final class XMLCheck: NSObject, XMLParserDelegate {
        var elements: [String: Int] = [:]
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) { elements[name, default: 0] += 1 }
    }

    static func appTests(_ dir: URL) {
        say("")
        say("— APP INTEGRATION")
        // document → pixels
        let vst = vectorState()
        guard let vimg = WXDoc.image(vst) else { check(false, "document renders to pixels"); return }
        check(vimg.width == 360 && vimg.height == 220 && !vimg.hasAlpha, "document → straight RGBA (\(vimg.width)×\(vimg.height))")
        var tst = SelfTest.baseState(200, 120)
        tst.layers = [SelfTest.shapeLayer(CGRect(x: 30, y: 20, width: 120, height: 70))]
        if let timg = WXDoc.image(tst) {
            check(timg.hasAlpha && timg.px[3] == 0, "transparent document keeps alpha")
            if let r = UPLossless.encode(timg), let d = UPBridge.decode(r.data) { check(d.image.visuallyIdentical(to: UPReduce.canonical(timg, keepHiddenRGB: false)), "document PNG round trip through ImageIO") }
        }
        var deep = SelfTest.baseState(96, 64)
        deep.bitDepth = .sixteen
        if let dimg = WXDoc.image(deep) {
            check(dimg.px16 != nil, "16-bit document gives 16-bit samples")
            if let r = UPLossless.encode(dimg) {
                let v = UPValidator.validate(r.data)
                check(v.ok && (v.image?.visuallyIdentical(to: UPReduce.canonical(dimg, keepHiddenRGB: false)) ?? false), "16-bit document encodes losslessly (\(v.formatLabel), \(r.data.count) B)")
            }
        }

        // "Use Ultra PNG when saving PNG": the normal exporter's file is re-packed, pixels identical
        let saved = (WebExportPrefs.ultraPNGOnSave, WebExportPrefs.onSaveEffort)
        defer { WebExportPrefs.ultraPNGOnSave = saved.0; WebExportPrefs.onSaveEffort = saved.1 }
        let plain = dir.appendingPathComponent("hook_plain.png"), ultra = dir.appendingPathComponent("hook_ultra.png")
        WebExportPrefs.ultraPNGOnSave = false
        try? DocumentIO.export(hybridState(), to: plain, format: .png, quality: 1, scale: 1)
        WebExportPrefs.ultraPNGOnSave = true; WebExportPrefs.onSaveEffort = .fast
        try? DocumentIO.export(hybridState(), to: ultra, format: .png, quality: 1, scale: 1)
        WebExportPrefs.ultraPNGOnSave = false
        if let a = try? Data(contentsOf: plain), let b = try? Data(contentsOf: ultra), let da = UPBridge.decode(a), let db = UPBridge.decode(b) {
            check(b.count < a.count, "Export As with the preference on is smaller: \(a.count) → \(b.count) B")
            check(da.image.visuallyIdentical(to: db.image), "…and decodes to identical pixels")
            let v = UPValidator.validate(b)
            check(v.ok, "…and is a valid PNG (\(v.chunks.joined(separator: " ")))")
            let srcProps = CGImageSourceCreateWithData(b as CFData, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
            check((srcProps?[kCGImagePropertyDPIWidth] as? Double) != nil || !UPValidator.validate(a).chunks.contains("pHYs"), "…and keeps the resolution chunk")
            say("  Export As hook: \(a.count) B → \(b.count) B (" + WXSelfTestCore.pct(b.count, a.count).trimmingCharacters(in: .whitespaces) + ")")
        } else { check(false, "export hook files readable") }
        // existing PNG re-pack keeps an ICC profile and refuses gray conversion with it
        if let p3 = CGColorSpace(name: CGColorSpace.displayP3), let cg = UPBridge.cgImage(WXCorpus.grayRamp(64, 32, alpha: false), space: p3),
           let tagged = UPBridge.encode(cg, type: UTType.png.identifier, props: [:]), let opt = UPRecompress.optimise(tagged, effort: .fast) {
            let v = UPValidator.validate(opt)
            check(v.ok && v.chunks.contains("iCCP") && v.colorType != 0 && v.colorType != 4, "re-pack keeps the ICC profile and stays RGB (\(v.formatLabel), \(tagged.count) → \(opt.count) B)")
            if let d = UPBridge.decode(opt) { check(d.cg.colorSpace?.name == CGColorSpace.displayP3, "ImageIO still sees Display P3") }
        } else { check(false, "ICC-tagged PNG re-pack") }

        // SVG
        let svg = SVGExport.export(vst, options: SVGExportOptions())
        try? svg.data.write(to: dir.appendingPathComponent("vector.svg"))
        let xc = XMLCheck()
        let xp = XMLParser(data: svg.data); xp.delegate = xc
        check(xp.parse(), "SVG is well-formed XML")
        check(svg.vectorLayers == 4 && svg.rasterLayers == 0 && (xc.elements["path"] ?? 0) >= 3 && xc.elements["linearGradient"] == 1 && xc.elements["rect"] == 1, "vector document → pure SVG (\(xc.elements))")
        if let ras = rasterize(svg: svg.data, width: 360, height: 220) {
            WXSelfTestCore.writePNG(ras, dir.appendingPathComponent("vector_svg_rendered.png"))
            WXSelfTestCore.writePNG(vimg, dir.appendingPathComponent("vector_document.png"))
            let q = UPMetricReference(vimg).compare(ras)
            check(q.ssim > 0.93, "SVG renders like the document (SSIM \(String(format: "%.3f", q.ssim)))")
        } else { check(false, "SVG can be rasterised by AppKit") }
        let png = UPLossless.encode(vimg)?.data.count ?? 0
        let tsvg = WXTransfer.estimate(svg.data, mime: "image/svg+xml")
        say("  vector logo: SVG \(svg.data.count) B (\(tsvg.brotli) B Brotli, \(tsvg.gzip) B gzip) vs Ultra lossless PNG \(png) B")
        var lo = SVGExportOptions(); lo.liveText = true
        let live = SVGExport.export(vst, options: lo)
        check(live.svg.contains("<text") && live.data.count < svg.data.count, "live <text> option (\(live.data.count) B)")
        let hst = hybridState()
        let hyb = SVGExport.export(hst, options: SVGExportOptions())
        try? hyb.data.write(to: dir.appendingPathComponent("hybrid.svg"))
        let hx = XMLCheck()
        let hp = XMLParser(data: hyb.data); hp.delegate = hx
        check(hp.parse() && hx.elements["image"] == 1 && hyb.rasterLayers == 1 && hyb.vectorLayers == 4, "hybrid SVG embeds the pixel layer once, in stacking order (\(hx.elements))")
        if let himg = WXDoc.image(hst), let ras = rasterize(svg: hyb.data, width: 360, height: 220) {
            WXSelfTestCore.writePNG(ras, dir.appendingPathComponent("hybrid_svg_rendered.png"))
            check(UPMetricReference(himg).compare(ras).ssim > 0.9, "hybrid SVG renders like the document")
        }
        var vo = SVGExportOptions(); vo.mode = .vectorOnly
        let onlyV = SVGExport.export(hst, options: vo)
        check(onlyV.skippedLayers == 1 && !onlyV.svg.contains("<image"), "vector-only mode leaves pixel layers out and says so")
        var adj = hst
        adj.layers[3].blendMode = .multiply
        let flat = SVGExport.export(adj, options: SVGExportOptions())
        check(flat.rasterLayers == 4 && !flat.notes.isEmpty, "blend modes force the layers below into the embedded raster (\(flat.rasterLayers) layers)")
        check(SVGExport.num(0.5, 2) == ".5" && SVGExport.num(-0.25, 2) == "-.25" && SVGExport.num(12.0, 2) == "12" && SVGExport.num(-0.001, 2) == "0", "compact number formatting")

        // dialog sessions (driven synchronously)
        let doc = Document(state: hybridState(), name: "Web Test.imagecrat")
        AppModel.shared.add(doc)
        defer { AppModel.shared.close(doc) }
        let s = UltraPNGSession(document: doc, synchronous: true)
        s.effort = .fast
        s.schedule()
        check(s.resultData != nil && s.exact != nil && s.normalPNG != nil && s.optimisedCG != nil, "Ultra PNG session produces a file (\(s.sizeLine))")
        if let d = s.resultData { check(UPValidator.validate(d).ok, "session file is a valid PNG"); try? d.write(to: dir.appendingPathComponent("dialog_perceptual.png")) }
        check(s.importanceCG != nil, "importance overlay exists")
        s.protect(rect: CGRect(x: 100, y: 60, width: 120, height: 100))
        check(s.protectedPixels == 120 * 100 && s.maps?.protect[80 * 360 + 150] == 1 && s.resultData != nil, "Protect rectangle enters the importance map and re-encodes")
        s.protectTool = .brush
        s.protect(brushAt: CGPoint(x: 40, y: 40), commit: true)
        check(s.protectedPixels > 120 * 100, "Protect brush adds to the mask")
        s.preset = 0
        if let d = s.resultData, let dec = UPValidator.validate(d).image, let src = s.source {
            // user-protected pixels must be reproduced exactly, whatever path the encoder takes
            var worst = 0
            for i in s.maps?.pristine ?? [] { for c in 0..<4 { worst = max(worst, abs(Int(dec.px[Int(i) * 4 + c]) - Int(src.px[Int(i) * 4 + c]))) } }
            check(worst == 0, "protected region stays pristine (max channel difference \(worst), \(s.info))")
        }
        s.lossy = false
        check(s.resultData != nil && s.info.contains("verified"), "lossless mode verifies its output (\(s.info))")
        s.keepDPI = true; s.copyright = "© Test"; s.schedule()
        if let d = s.resultData { let v = UPValidator.validate(d); check(v.ok && v.chunks.contains("pHYs") && v.chunks.contains("tEXt") && v.chunks.contains("sRGB"), "metadata options write chunks (\(v.chunks.joined(separator: " ")))") }
        s.keepProfile = false; s.keepDPI = false; s.copyright = ""; s.schedule()
        if let d = s.resultData { let v = UPValidator.validate(d); check(v.chunks == ["IHDR", "IDAT", "IEND"] || v.chunks == ["IHDR", "PLTE", "IDAT", "IEND"] || v.chunks == ["IHDR", "PLTE", "tRNS", "IDAT", "IEND"], "strip-all leaves only critical chunks (\(v.chunks.joined(separator: " ")))") }
        let cancelled = UPProgress(); cancelled.cancel()
        check(UPLossless.encode(WXCorpus.screenshot(), progress: cancelled) == nil && UPLossy.encode(WXCorpus.screenshot(), progress: cancelled) == nil, "cancelled encodes stop and return nothing")

        let w = SmallestForWebSession(document: doc, synchronous: true)
        w.analyse()
        check(!w.candidates.isEmpty && w.winner != nil && !w.snippet.isEmpty, "Smallest for Web: \(w.candidates.count) formats, winner \(w.winner?.rawValue ?? "—")")
        for c in w.candidates { say("    " + WXSelfTestCore.pad(c.kind.rawValue, 24) + WXSelfTestCore.num(c.totalBytes) + "  " + c.setting + (c.targetMet ? "" : "  (target not reached)")) }
        let folder = dir.appendingPathComponent("web_set")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        w.displayWidthText = "180"; w.x3 = false
        w.selected = Set(w.candidates.prefix(2).map(\.kind))
        w.updateSnippet()
        var exported = 0
        w.export(to: folder) { n, _ in exported = n }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        check(exported >= 4 && listing.contains("web-test.html") && listing.contains { $0.contains("-180.") } && listing.contains { $0.contains("-360.") }, "responsive export writes @1x/@2x files + HTML (\(listing.sorted().joined(separator: ", ")))")
        check(w.downscaleHint == nil, "no downscale hint when the document already fits")
        w.displayWidthText = "100"; w.x2 = true
        check(w.downscaleHint != nil, "downscale hint: \(w.downscaleHint ?? "")")

        // offscreen snapshots of the dialogs for a visual check
        s.lossy = true; s.preset = 1; s.view = .split; s.showImportance = true
        FilesSelfTest.snapshot(UltraPNGDialog(session: s), size: CGSize(width: 968, height: 640), to: dir.appendingPathComponent("ui_ultra_png.png"))
        FilesSelfTest.snapshot(SmallestForWebDialog(session: w), size: CGSize(width: 900, height: 560), to: dir.appendingPathComponent("ui_smallest_for_web.png"))
        FilesSelfTest.snapshot(SVGExportDialog(doc: doc), size: CGSize(width: 460, height: 300), to: dir.appendingPathComponent("ui_svg_export.png"))
        FilesSelfTest.snapshot(UltraPNGPrefsDialog(), size: CGSize(width: 400, height: 220), to: dir.appendingPathComponent("ui_ultra_prefs.png"))
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ui_ultra_png.png").path), "dialog snapshots written")
        s.cancelWork(); w.cancel()
    }
}
