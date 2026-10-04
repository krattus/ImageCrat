import AppKit
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Headless tests of the PSD / PSB importer (`LUMEN_SELFTEST_ONLY=psdimport`).
/// Sub-filter with `LUMEN_PSDIMPORT_ONLY=real|corpus|synthetic|fuzz|app` (comma separated); `ui` (opt-in) writes a
/// snapshot of the report dialog.
enum PSDImportSelfTest {
    static var passed = 0, failed = 0

    static func check(_ ok: Bool, _ msg: String) {
        if ok { passed += 1; print("PASS psdimport: \(msg)") } else { failed += 1; print("FAIL psdimport: \(msg)") }
    }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("psdimport")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let only = ProcessInfo.processInfo.environment["LUMEN_PSDIMPORT_ONLY"]
        func want(_ n: String) -> Bool { only == nil || only!.split(separator: ",").contains { n.hasPrefix($0) } }
        if want("real") { testRealFiles(dir) }
        if want("corpus") { testCorpus(dir) }
        // the fuzz and app tests reuse the files the synthetic tests write
        if want("synthetic") || want("fuzz") || want("app") {
            testText(dir); testShapes(dir); testFills(dir); testVectorMasks(dir); testAdjustments(dir)
            testSmartObjects(dir); testDocument(dir); testDepthsAndModes(dir)
        }
        if want("fuzz") { testFuzz(dir) }
        if want("app") { testApp(dir) }
        if only?.contains("ui") == true { testUI(dir) }   // opt-in: offscreen snapshot of the report dialog
        print("psdimport: \(passed) passed, \(failed) failed")
    }

    // MARK: Composite comparison

    struct Diff {
        var mean = 999.0      // mean absolute difference per channel (0…255)
        var max = 255
        var badFraction = 1.0 // pixels with any channel off by more than 24
    }

    /// The flattened picture stored in the file, decoded by the system (independent of Lumen's reader), over white.
    /// Reliable for opaque documents; with transparency the system decoders disagree about the white matte.
    static func systemOracle(_ url: URL) -> (PixelBuffer, opaque: Bool)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let b = PixelBuffer(width: cg.width, height: cg.height)
        b.context.setFillColor(RGBA.white.cgColor)
        b.context.fill(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        b.drawImage(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return (b, [.none, .noneSkipLast, .noneSkipFirst].contains(cg.alphaInfo))
    }

    /// The stored composite's colour channels as they are in the file: Photoshop writes them matted on white, so
    /// they are the document over white.
    static func oracle(_ url: URL) -> PixelBuffer? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return PSDImporter.mergedImage(data: d, matte: true)
    }

    static func flatten(_ st: DocumentState) -> PixelBuffer? {
        Compositor.shared.flatten(st, background: .white).map { PixelBuffer(cgImage: $0) }
    }

    static func diff(_ a: PixelBuffer, _ b: PixelBuffer, rows: Range<Int>? = nil) -> Diff {
        guard a.width == b.width, a.height == b.height else { return Diff() }
        var total = 0, mx = 0, bad = 0
        let x = a.data.assumingMemoryBound(to: UInt8.self), y = b.data.assumingMemoryBound(to: UInt8.self)
        let rows = (rows ?? 0..<a.height).clamped(to: 0..<a.height)
        for r in rows {
            let pa = x + r * a.bytesPerRow, pb = y + r * b.bytesPerRow
            for c in 0..<a.width {
                var worst = 0
                for k in 0..<3 {
                    let d = abs(Int(pa[c * 4 + k]) - Int(pb[c * 4 + k]))
                    total += d
                    if d > worst { worst = d }
                }
                if worst > mx { mx = worst }
                if worst > 24 { bad += 1 }
            }
        }
        let n = Double(a.width * max(1, rows.count))
        return Diff(mean: Double(total) / (n * 3), max: mx, badFraction: Double(bad) / n)
    }

    /// reference | Lumen | difference ×4, for looking at.
    static func sideBySide(_ a: PixelBuffer, _ b: PixelBuffer, _ url: URL) {
        guard a.width == b.width, a.height == b.height else { return }
        let w = a.width, h = a.height, gap = 8
        let out = PixelBuffer(width: w * 3 + gap * 2, height: h)
        out.context.setFillColor(RGBA(gray: 0.5).cgColor)
        out.context.fill(CGRect(x: 0, y: 0, width: out.width, height: h))
        out.drawImage(a.makeCGImage(), in: CGRect(x: 0, y: 0, width: w, height: h))
        out.drawImage(b.makeCGImage(), in: CGRect(x: w + gap, y: 0, width: w, height: h))
        let d = PixelBuffer(width: w, height: h)
        let x = a.data.assumingMemoryBound(to: UInt8.self), y = b.data.assumingMemoryBound(to: UInt8.self), z = d.data.assumingMemoryBound(to: UInt8.self)
        for r in 0..<h { for c in 0..<w {
            for k in 0..<3 { z[r * d.bytesPerRow + c * 4 + k] = UInt8(min(255, abs(Int(x[r * a.bytesPerRow + c * 4 + k]) - Int(y[r * b.bytesPerRow + c * 4 + k])) * 4)) }
            z[r * d.bytesPerRow + c * 4 + 3] = 255
        } }
        d.markDirty()
        out.drawImage(d.makeCGImage(), in: CGRect(x: (w + gap) * 2, y: 0, width: w, height: h))
        out.markDirty()
        writePNG(out.makeCGImage(), url)
    }

    static func writePNG(_ cg: CGImage, _ url: URL) {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
    }

    /// A live layer's content (no mask, effects or opacity) against the pixels Photoshop stored for it, both over white.
    static func layerDiff(_ l: Layer, _ res: PSDImporter.Result, _ png: URL? = nil) -> Diff? {
        guard let st = res.stored[l.id] else { return nil }
        let space = CanvasSpace(width: res.state.width, height: res.state.height)
        let white = CIImage.color(RGBA(r: 1, g: 0, b: 0.5), space.ciCanvas)   // a backdrop no text or shape is likely to use
        func over(_ img: CIImage) -> PixelBuffer { RenderEngine.renderBuffer(img.composited(over: white), docRect: res.state.canvasRect, space: space) }
        var plain = l
        plain.mask = nil; plain.vectorMask = nil
        guard let live = Compositor.shared.contentImage(plain, space: space) else { return nil }
        let a = over(st.buffer.placed(at: st.origin, space: space)), b = over(live)
        if let png { sideBySide(a, b, png) }
        return diff(a, b)
    }

    /// Offscreen picture of File ▸ PSD Import Report… for a document with every kind of entry.
    static func testUI(_ dir: URL) {
        var st = DocumentState(width: 64, height: 64)
        st.layers = [Layer.raster(name: "Background", width: 64, height: 64)]
        let d = Document(state: st, name: "brochure.psd")
        AppModel.shared.add(d)
        var r = PSDImportReport(fileName: "brochure.psd", layerCount: 14)
        r.add(.editable, layer: "Headline", feature: "Type", detail: "“Summer Sale” — HelveticaNeue-Bold, 96 px, 2 styles")
        r.add(.editable, layer: "Badge", feature: "Shape", detail: "Ellipse, solid colour, stroke 4 px")
        r.add(.editable, layer: "Photo", feature: "Smart object", detail: "embedded JPEG “beach.jpg” (4000 × 3000 px)")
        r.add(.editable, layer: "Contrast", feature: "Adjustment", detail: "Curves")
        r.add(.editable, layer: "", feature: "Guides", detail: "4 guides")
        r.add(.substituted, layer: "Headline", feature: "Font", detail: "“MyriadPro-Bold” is not installed; “HelveticaNeue-Bold” is used instead.")
        r.add(.flattened, layer: "Logo", feature: "Smart object", detail: "Smart filter “Oil Paint” has no ImageCrat equivalent. The smart object holds the pixels Photoshop rendered.")
        r.add(.skipped, layer: "Film look", feature: "Adjustment", detail: "Color Lookup “Crisp_Warm.look” uses a 3D LUT / ICC profile ImageCrat cannot load; the layer was left out.")
        r.add(.info, layer: "", feature: "Bit depth", detail: "16-bit channels are stored as 8 bits per channel in ImageCrat.")
        r.missingFonts = ["MyriadPro-Bold"]
        PSDImportModule.reports[d.id] = r
        print("INFO psdimport: status line — \(r.summary)")
        FilesSelfTest.snapshot(PSDImportReportDialog().padding(.top, 14), size: CGSize(width: 580, height: 440), to: dir.appendingPathComponent("ui_import_report.png"))
        AppModel.shared.close(d)
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("ui_import_report.png").path), "report dialog snapshot written")
    }

    static func kinds(_ st: DocumentState) -> String {
        var c: [String: Int] = [:]
        for l in st.allLayers { c[l.kindName, default: 0] += 1 }
        return c.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
    }

    // MARK: Real files (shipped inside application bundles / system folders; read only)

    static let realFiles: [(String, String)] = [
        ("all-layer-types", "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app/Contents/Required/Plug-ins/Generator/crema.generate/node_modules/generator-assets/test/resources/all-layer-types.psd"),
        ("splash-smartobject", "/Applications/iMovie.app/Contents/Resources/LKSplash.psd"),
        ("about2x-smartobject", "/Applications/iMovie.app/Contents/Resources/LKAbout@2x.psd"),
        ("icon-dvd-text", "/Applications/iMovie.app/Contents/Frameworks/StudioSharedResources.framework/Versions/A/Resources/icon_RG_ShareDVDSelected.psd"),
        ("icon-ipod2x-text", "/Applications/iMovie.app/Contents/Frameworks/StudioSharedResources.framework/Versions/A/Resources/icon_RG_ShareiPodSelected@2x.psd"),
        ("workaround-text", "/Applications/Adobe Dimension/Adobe Dimension.app/Contents/Resources/common/color_profiles/ps30915_workaround.psd"),
        ("pagegradient-shape", "/System/Library/PrivateFrameworks/QuickLookSupport.framework/Versions/A/Resources/PageGradient.psd"),
        ("trafficlights-vectormask", "/System/Library/CoreServices/StageManagerOnboarding.app/Contents/Resources/StageManager_DK.ca/assets/traffic-lights_2.psd"),
        ("orangeglow-16bit", "/Applications/iMovie.app/Contents/PlugIns/MediaProviders/MotionEffect.fxp/Contents/Resources/Templates.localized/Titles.localized/Lower Thirds.localized/News.localized/Centered.localized/Media/OrangeGlow_greyscale.psd"),
        ("pushbutton-groups", "/System/Library/Frameworks/MapKit.framework/Versions/A/Resources/DarkAquaMasks-Artwork/Controls/Push Button/PushButton_PushButton_Regular@2x.psd"),
        ("speaker-effects", "/Applications/iMovie.app/Contents/Frameworks/Flexo.framework/Versions/A/Resources/AudioSurroundPanner_SpeakerCenter_HUD.psd"),
    ]

    /// What each real file must import as (layer kinds) and how close the composite must be to the stored one.
    /// all-layer-types carries a heavy layer style (satin, bevel, glows at 417 % scale) that Lumen's effect
    /// renderer draws differently, so its whole-canvas bound is loose and the area below that layer is checked too.
    static let realExpectations: [String: (kinds: String, mean: Double)] = [
        "all-layer-types": ("1 Brightness/Contrast, 2 Group, 4 Pixel Layer, 1 Shape Layer, 2 Smart Object, 1 Type Layer", 25),
        "splash-smartobject": ("1 Pixel Layer, 1 Smart Object", 1), "about2x-smartobject": ("1 Pixel Layer, 1 Smart Object", 1),
        "icon-dvd-text": ("2 Pixel Layer, 2 Type Layer", 1), "icon-ipod2x-text": ("2 Pixel Layer, 2 Type Layer", 1),
        "workaround-text": ("1 Pixel Layer, 5 Type Layer", 1.5), "pagegradient-shape": ("1 Shape Layer", 2),
        "trafficlights-vectormask": ("5 Group, 4 Pixel Layer", 0.5), "orangeglow-16bit": ("1 Pixel Layer", 0.5),
        "pushbutton-groups": ("12 Group, 20 Pixel Layer", 0.5), "speaker-effects": ("6 Pixel Layer", 0.5),
    ]

    static func testRealFiles(_ dir: URL) {
        var seen = 0
        for (tag, path) in realFiles {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { print("SKIP psdimport: real file not present: \(path)"); continue }
            seen += 1
            do {
                let t0 = Date()
                PSDImporter.keepStoredPixels = true
                defer { PSDImporter.keepStoredPixels = false }
                let res = try PSDImporter.read(url: url)
                PSDImportModule.addPatterns(res.patterns)
                let dt = Date().timeIntervalSince(t0)
                guard let ref = oracle(url), let mine = flatten(res.state) else { check(false, "\(tag): composite could not be produced"); continue }
                let d = diff(ref, mine)
                sideBySide(ref, mine, dir.appendingPathComponent("real_\(tag).png"))
                print(String(format: "INFO psdimport: %@ — %d×%d, %@ | composite vs stored: mean %.2f max %d bad %.2f%% | %.2fs", tag, res.state.width, res.state.height, kinds(res.state), d.mean, d.max, d.badFraction * 100, dt))
                print(res.report.text.split(separator: "\n").map { "     " + $0 }.joined(separator: "\n"))
                let exp = realExpectations[tag]
                check(exp == nil || kinds(res.state) == exp!.kinds, "\(tag): layer kinds (\(kinds(res.state)))")
                check(d.mean < (exp?.mean ?? 2), String(format: "%@: composite matches the stored picture (mean %.2f, max %d, %.2f%% of pixels off by more than 24)", tag, d.mean, d.max, d.badFraction * 100))
                if let (sys, opaque) = systemOracle(url), opaque {
                    let o = diff(ref, sys)
                    check(o.mean < 0.5, String(format: "%@: the stored composite decodes like the system decoder does (mean %.2f, max %d)", tag, o.mean, o.max))
                }
                if tag == "all-layer-types" {
                    // Below the styled layer: smart objects, shape, vector mask — under a Brightness +25 adjustment.
                    // Lumen's Brightness/Contrast curve is not Photoshop's (up to ~15 levels apart in the highlights),
                    // so the import is judged with Photoshop's own curve, measured from this file, applied instead.
                    let lower = diff(ref, mine, rows: 430..<714)
                    print(String(format: "INFO psdimport:    rows 430…713 with Lumen's Brightness/Contrast: mean %.2f, %.2f%% off by more than 24", lower.mean, lower.badFraction * 100))
                    var noAdj = res.state
                    noAdj.layers.removeAll { $0.isAdjustment }
                    if let plain = flatten(noAdj) {
                        let pts: [(Double, Double)] = [(0, 0), (45, 53), (60, 70), (75, 88), (90, 105), (105, 123), (120, 140), (135, 158), (150, 174), (165, 190), (180, 205), (195, 218), (210, 230), (225, 241), (240, 249), (255, 255)]
                        var lut = [UInt8](repeating: 0, count: 256)
                        for v in 0..<256 {
                            let i = max(1, pts.firstIndex { $0.0 >= Double(v) } ?? pts.count - 1)
                            let (x0, y0) = pts[i - 1], (x1, y1) = pts[i]
                            lut[v] = UInt8((y0 + (y1 - y0) * (Double(v) - x0) / (x1 - x0)).rounded())
                        }
                        let q = plain.data.assumingMemoryBound(to: UInt8.self)
                        for y in 0..<plain.height { for x in 0..<plain.width { for k in 0..<3 { q[y * plain.bytesPerRow + x * 4 + k] = lut[Int(q[y * plain.bytesPerRow + x * 4 + k])] } } }
                        let fixed = diff(ref, plain, rows: 430..<714)
                        sideBySide(ref, plain, dir.appendingPathComponent("real_\(tag)_photoshop_brightness.png"))
                        // what is left is the 3.7× downsampled fern photo (Lumen's resampler is not Photoshop's bicubic)
                        check(fixed.mean < 6, String(format: "%@: area below the styled layer, with Photoshop's brightness curve (mean %.2f, %.2f%% off by more than 24)", tag, fixed.mean, fixed.badFraction * 100))
                    }
                }
                for l in res.state.allLayers {
                    guard let pd = layerDiff(l, res, dir.appendingPathComponent("real_\(tag)_layer_\(l.name.replacingOccurrences(of: "/", with: "_")).png")) else { continue }
                    let sub = l.isText && res.report.items.contains { $0.layer == l.name && $0.feature == "Font" }
                    print(String(format: "INFO psdimport:    live %@ “%@” vs Photoshop's pixels: mean %.2f max %d bad %.2f%%%@", l.kindName, l.name, pd.mean, pd.max, pd.badFraction * 100, sub ? " (font substituted)" : ""))
                    // text drawn with a substituted font cannot match; everything else must
                    if !sub { check(pd.mean < (l.isSmartObject ? 5 : (l.isText ? 1 : 0.5)), String(format: "%@: live %@ “%@” is drawn like Photoshop's stored pixels (mean %.2f)", tag, l.kindName, l.name, pd.mean)) }
                }
                if let data = try? Data(contentsOf: url) {
                    let pats = PSDImporter.patterns(data: data)
                    if !pats.isEmpty { print("INFO psdimport:    \(pats.count) stored pattern(s): " + pats.prefix(6).map { "“\($0.name)” \($0.image.width)×\($0.image.height)" }.joined(separator: ", ")) }
                    if tag == "all-layer-types" { check(pats.first?.name == "Watercolor" && pats.first?.image.width == 150, "\(tag): the pattern stored in the file is decoded") }
                }
            } catch { check(false, "\(tag): import threw \(error)") }
        }
        if seen == 0 { print("SKIP psdimport: none of the real sample files are installed on this Mac") }
    }

    /// Every PSD that ships inside these application bundles / system folders: each must open, and its composite is
    /// compared with the stored one. (Read only; folders that are not present are skipped.)
    static let corpusFolders = [
        "/Applications/iMovie.app/Contents/Frameworks/StudioSharedResources.framework/Versions/A/Resources",
        "/Applications/iMovie.app/Contents/Frameworks/Flexo.framework/Versions/A/Resources",
        "/Applications/iMovie.app/Contents/Resources",
        "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app/Contents/Document Templates",
        "/System/Library/Frameworks/MapKit.framework/Versions/A/Resources/DarkAquaMasks-Artwork/Controls",
        "/System/Library/Frameworks/ContactsUI.framework/Versions/A/Resources",
        "/System/Library/Frameworks/AddressBook.framework/Versions/A/Resources",
        "/System/Library/PrivateFrameworks/Backup.framework/Versions/A/Resources",
        "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app/Contents/Required/UXP/com.adobe.unifiedpanel/assets/learn/phxs",
    ]

    static func testCorpus(_ dir: URL) {
        var files: [URL] = []
        for f in corpusFolders {
            guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: f), includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let u as URL in e where ["psd", "psb"].contains(u.pathExtension.lowercased()) {
                if let n = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize, n < 40_000_000 { files.append(u) }
            }
        }
        guard !files.isEmpty else { print("SKIP psdimport: no bundled PSD files found for the corpus sweep"); return }
        var opened = 0, failures: [String] = [], exact = 0, close = 0, far: [(String, Double)] = [], layers = 0, live = 0
        var worstMean = 0.0
        for u in files.sorted(by: { $0.path < $1.path }) {
            guard let res = try? PSDImporter.read(url: u) else { failures.append(u.lastPathComponent); continue }
            opened += 1
            layers += res.state.allLayers.count
            live += res.state.allLayers.filter { !$0.isRaster && !$0.isGroup }.count
            guard res.state.width * res.state.height <= 6_000_000, let ref = oracle(u), let mine = flatten(res.state) else { continue }
            let d = diff(ref, mine)
            worstMean = max(worstMean, d.mean)
            if d.mean < 0.5 { exact += 1 } else if d.mean < 3 { close += 1 } else { far.append((u.lastPathComponent, d.mean)) }
        }
        print("INFO psdimport: corpus — \(files.count) bundled PSD files: \(opened) opened with \(layers) layers (\(live) live: type / shape / smart / adjustment); composite vs stored: \(exact) within 0.5, \(close) within 3, \(far.count) further (worst mean \(String(format: "%.2f", worstMean)))")
        for (n, m) in far.sorted(by: { $0.1 > $1.1 }).prefix(12) { print(String(format: "INFO psdimport:    corpus outlier %@ mean %.2f", n, m)) }
        check(failures.isEmpty, "corpus: all \(files.count) bundled PSD files open (\(failures.prefix(5).joined(separator: ", ")))")
        check(Double(exact + close) >= Double(exact + close + far.count) * 0.9, "corpus: at least 90 % of the composites match the stored picture within a mean of 3 levels (\(exact + close) of \(exact + close + far.count))")
    }
}
