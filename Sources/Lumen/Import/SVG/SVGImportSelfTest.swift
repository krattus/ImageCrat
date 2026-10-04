import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import ImageCratCore

/// Headless tests of the SVG importer: `LUMEN_SELFTEST_ONLY=svgimport Lumen --selftest <dir>`.
/// Environment: LUMEN_SVGIMPORT_ONLY=<name filter> runs matching corpus cases only;
/// LUMEN_SVGIMPORT_FILES=<folder> imports every .svg / .svgz in a folder and writes comparison sheets (no pass / fail);
/// LUMEN_SVGIMPORT_FUZZ=<n> sets the number of fuzz mutations (default 400).
enum SVGImportSelfTest {
    static var passed = 0, failed = 0
    static var log: [String] = []

    static func check(_ ok: Bool, _ msg: String) {
        if ok { passed += 1; print("PASS svgimport: \(msg)") } else { failed += 1; print("FAIL svgimport: \(msg)") }
        log.append((ok ? "PASS " : "FAIL ") + msg)
    }
    static func say(_ s: String) { print("svgimport: \(s)"); log.append(s) }

    static func run(_ out: URL) {
        let dir = out.appendingPathComponent("svgimport")
        let env = ProcessInfo.processInfo.environment
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let folder = env["LUMEN_SVGIMPORT_FILES"] { SVGImportQA.importFolder(URL(fileURLWithPath: folder), out: dir.appendingPathComponent("files")); return }
        let only = env["LUMEN_SVGIMPORT_ONLY"]
        if only == nil {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        passed = 0; failed = 0; log = []
        if env["LUMEN_SVGIMPORT_STRESS"] != nil { stress(); return }
        if only == "ui" { uiSnapshots(dir); return }
        if env["LUMEN_SVGIMPORT_FUZZ_ONLY"] != nil { fuzz(env["LUMEN_SVGIMPORT_FUZZ"].flatMap { Int($0) } ?? 400); return }
        let saved = SVGImportUI.defaultSettings
        SVGImportUI.defaultSettings = SVGImportSettings()
        defer { SVGImportUI.defaultSettings = saved }
        if only == nil { units() }
        corpus(dir, only: only)
        if only == nil {
            hostile()
            fuzz(env["LUMEN_SVGIMPORT_FUZZ"].flatMap { Int($0) } ?? 400)
            roundTrip(dir)
            integration(dir)
        }
        say("svgimport: \(passed) passed, \(failed) failed")
        try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}

extension SVGImportSelfTest {
    /// Renders the same batch over and over and counts renders that differ from the first (rasterizer reliability).
    static func stress() {
        let cases = SVGImportCorpus.cases().filter { ["mask-soft-variants", "blend-modes", "image-embedded", "text-simple", "pattern-raster"].contains($0.name) }
        var svgs = cases.map(\.svg) + cases.map(\.svg)
        var size = (320, 160)
        if let d = ProcessInfo.processInfo.environment["LUMEN_SVGIMPORT_STRESS_DIR"] {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".svg") }.sorted()
            svgs = files.compactMap { try? String(contentsOfFile: d + "/" + $0, encoding: .utf8) }
            size = (320, 110)
            for (i, img) in SVGImportWebKit.render(svgs, width: size.0, height: size.1).enumerated() {
                let cover = img.map { PixelBuffer(cgImage: $0).opaqueBounds().map { "\($0.width)×\($0.height)" } ?? "empty" } ?? "nil"
                print("tile \(i) \(files[i]): \(cover)")
            }
        }
        var first: [CGImage?] = []
        var bad = 0, empty = 0
        let rounds = Int(ProcessInfo.processInfo.environment["LUMEN_SVGIMPORT_STRESS"] ?? "") ?? 30
        let t0 = CFAbsoluteTimeGetCurrent()
        for round in 0..<rounds {
            let out = SVGImportWebKit.render(svgs, width: size.0, height: size.1)
            if round == 0 { first = out; continue }
            for (i, img) in out.enumerated() {
                guard let a = img, let b = first[i] else { empty += 1; continue }
                let m = SVGImportQA.compare(a, b)
                if m.mean > 0.01 { bad += 1; print("round \(round) tile \(i): \(m.text)") }
            }
        }
        print(String(format: "stress: %d rounds × %d tiles, %d differ, %d missing, %.0f ms per batch", rounds, svgs.count, bad, empty, (CFAbsoluteTimeGetCurrent() - t0) * 1000 / Double(rounds)))
    }

    // MARK: Corpus against the WebKit oracle

    static func corpus(_ dir: URL, only: String?) {
        let sheets = dir.appendingPathComponent("corpus")
        try? FileManager.default.createDirectory(at: sheets, withIntermediateDirectories: true)
        var worst = 0.0
        var n = 0
        for c in SVGImportCorpus.cases() where only == nil || c.name.contains(only!) {
            autoreleasepool {
                do {
                    var s = SVGImportSettings()
                    s.minimumSide = 0
                    let r = try SVGImport.load(data: Data(c.svg.utf8), name: c.name + ".svg", settings: s)
                    let st = r.state
                    let structure = SVGImportQA.outline(st.layers)
                    guard let l = SVGImportQA.lumen(st) else { check(false, "\(c.name): composites"); return }
                    if only != nil { print(SVGImportQA.describe(st.layers)); print(r.report.text) }
                    if c.oracle {
                        guard let o = SVGImportQA.oracle(c.svg, st.width, st.height) else { check(false, "\(c.name): WebKit oracle available"); return }
                        let m = SVGImportQA.compare(o, l, soft: c.soft)
                        SVGImportQA.sheet(o, l, to: sheets.appendingPathComponent(c.name + ".png"))
                        check(m.mean <= c.maxMean && m.bad <= c.maxBad, "\(c.name): matches WebKit (\(m.text)\(c.soft ? ", half-size comparison" : "")) — \(structure)")
                        worst = max(worst, m.mean); n += 1
                    } else {
                        SVGImportQA.writePNG(l, sheets.appendingPathComponent(c.name + ".png"))
                        check(true, "\(c.name): imported (WebKit is not a valid reference for this feature) — \(structure)")
                    }
                    if let want = c.outline { check(structure == want, "\(c.name): structure \(structure) == \(want)") }
                    check(r.report.rasterized == c.rasterized, "\(c.name): \(r.report.rasterized) rasterized (expected \(c.rasterized))")
                    for f in c.verify?(st, r.report) ?? [] { check(false, "\(c.name): \(f)") }
                } catch {
                    check(false, "\(c.name): imports (\(error.localizedDescription))")
                }
                Compositor.shared.clearCaches()
            }
        }
        say(String(format: "corpus: %d cases compared with WebKit, worst mean difference %.2f / 255", n, worst))
    }
}

extension SVGImportSelfTest {
    /// Offscreen pictures of the import dialog and the report (opt-in: LUMEN_SVGIMPORT_ONLY=ui), for looking at.
    static func uiSnapshots(_ dir: URL) {
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height, alignment: .top).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
            say("wrote \(name).png")
        }
        snap(SVGImportDialogView(m: SVGImportDialogModel(natural: CGSize(width: 24, height: 24), initial: SVGImportSettings())), "ui_import_dialog", CGSize(width: 372, height: 236))
        let ns = "xmlns='http://www.w3.org/2000/svg'"
        let r = try? SVGImport.load(data: Data("<svg \(ns) width='200' height='120'><defs><pattern id='p' width='6' height='6' patternUnits='userSpaceOnUse'><rect width='3' height='3'/></pattern><filter id='b'><feGaussianBlur stdDeviation='2'/></filter><clipPath id='c'><circle cx='50' cy='50' r='40'/></clipPath></defs><g clip-path='url(#c)'><rect id='Tiles' width='100' height='120' fill='url(#p)'/><circle cx='50' cy='50' r='20' fill='#c03'/></g><rect x='120' y='20' width='60' height='40' filter='url(#b)'/><text x='110' y='100' font-family='Definitely Missing' font-size='12'>Hi <tspan fill='red'>there</tspan></text><animate/></svg>".utf8), name: "sample.svg")
        SVGImportReports.last = r?.report
        snap(SVGImportReportDialog(), "ui_report_dialog", CGSize(width: 540, height: 420))
        SVGImportReports.last = nil
    }
}

/// Oracle rendering and image comparison shared by the tests.
enum SVGImportQA {
    struct Metric {
        /// Mean absolute channel difference (0…255).
        var mean = 999.0
        /// Share of pixels whose largest channel difference exceeds 48.
        var bad = 1.0
        var maxDiff = 255
        var text: String { String(format: "mean %.2f, %.2f%% off, max %d", mean, bad * 100, maxDiff) }
    }

    static func overWhite(_ cg: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(RGBA.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// The SVG as the system browser engine draws it at w × h, over white.
    static func oracle(_ svg: String, _ w: Int, _ h: Int) -> CGImage? {
        guard let img = SVGImportWebKit.render([svg], width: w, height: h).first ?? nil else { return nil }
        return overWhite(img, w, h)
    }

    static func lumen(_ st: DocumentState) -> CGImage? { Compositor.shared.flatten(st, background: .white) }

    /// Half-size copy: differences in how glyph edges are antialiased fade, misplaced or mis-sized text does not.
    static func softened(_ img: CGImage) -> CGImage {
        let w = max(1, img.width / 2), h = max(1, img.height / 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }

    static func compare(_ a0: CGImage, _ b0: CGImage, soft: Bool = false) -> Metric {
        let a = soft ? softened(a0) : a0, b = soft ? softened(b0) : b0
        guard a.width == b.width, a.height == b.height else { return Metric() }
        let pa = PixelBuffer(cgImage: a), pb = PixelBuffer(cgImage: b)
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self)
        var total = 0.0
        var bad = 0, mx = 0
        for r in 0..<pa.height {
            let ra = x + r * pa.bytesPerRow, rb = y + r * pb.bytesPerRow
            for c in 0..<pa.width {
                let i = c * 4
                let d0 = abs(Int(ra[i]) - Int(rb[i])), d1 = abs(Int(ra[i + 1]) - Int(rb[i + 1])), d2 = abs(Int(ra[i + 2]) - Int(rb[i + 2]))
                total += Double(d0 + d1 + d2)
                let m = max(d0, max(d1, d2))
                if m > 48 { bad += 1 }
                mx = max(mx, m)
            }
        }
        let n = Double(pa.width * pa.height)
        return Metric(mean: total / (n * 3), bad: Double(bad) / n, maxDiff: mx)
    }

    /// Oracle | Lumen | difference (×4), for looking at.
    static func sheet(_ a: CGImage, _ b: CGImage, to url: URL) {
        let w = a.width, h = a.height
        guard b.width == w, b.height == h,
              let ctx = CGContext(data: nil, width: w * 3 + 8, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(RGBA(gray: 0.5).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w * 3 + 8, height: h))
        ctx.draw(a, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(b, in: CGRect(x: w + 4, y: 0, width: w, height: h))
        let pa = PixelBuffer(cgImage: a), pb = PixelBuffer(cgImage: b)
        let d = PixelBuffer(width: w, height: h)
        let x = pa.data.assumingMemoryBound(to: UInt8.self), y = pb.data.assumingMemoryBound(to: UInt8.self), z = d.data.assumingMemoryBound(to: UInt8.self)
        for r in 0..<h {
            for c in 0..<w {
                let i = r * pa.bytesPerRow + c * 4, j = r * d.bytesPerRow + c * 4
                for k in 0..<3 { z[j + k] = UInt8(min(255, abs(Int(x[i + k]) - Int(y[i + k])) * 4)) }
                z[j + 3] = 255
            }
        }
        d.markDirty()
        ctx.draw(d.makeCGImage(), in: CGRect(x: 2 * w + 8, y: 0, width: w, height: h))
        guard let img = ctx.makeImage() else { return }
        writePNG(img, url)
    }

    static func writePNG(_ img: CGImage, _ url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    /// One-line structure dump ("group[shape, text]") for assertions and logs.
    static func outline(_ layers: [Layer]) -> String {
        layers.map { l -> String in
            var s: String
            switch l.content {
            case .raster: s = "pixel"
            case .text: s = "text"
            case .shape: s = "shape"
            case .smartObject: s = "smart"
            case .group(let g): s = "group[" + outline(g.children) + "]"
            case .fill: s = "fill"
            case .adjustment: s = "adjustment"
            }
            if l.vectorMask != nil { s += "+vm" }
            if l.mask != nil { s += "+mask" }
            if l.effects.hasAny { s += "+fx" }
            if !l.isVisible { s += "(hidden)" }
            return s
        }.joined(separator: ", ")
    }

    /// Multi-line description of a layer tree (debugging aid: `LUMEN_SVGIMPORT_ONLY` prints it).
    static func describe(_ layers: [Layer], indent: String = "  ") -> String {
        var out: [String] = []
        for l in layers.reversed() {
            var s = "\(indent)\(l.kindName) “\(l.name)”"
            if l.opacity < 0.999 { s += String(format: " opacity %.2f", l.opacity) }
            if l.blendMode != .normal && l.blendMode != .passThrough { s += " \(l.blendMode.rawValue)" }
            if l.isGroup { s += l.blendMode == .passThrough ? " pass-through" : " isolated" }
            switch l.content {
            case .text(let t): s += " font \(t.fontName) \(String(format: "%.1f", t.fontSize)) at (\(Int(t.position.x)),\(Int(t.position.y))) runs \(t.runs.count) align \(t.alignment.rawValue)"
            case .shape(let sh):
                s += " \(sh.geometry.kindName)"
                if case .gradient(let g) = sh.fill { s += " gradient \(g.type.rawValue) stops \(g.gradient.stops.count)\(g.shape == nil ? "" : " shaped")" }
                if !sh.stroke.paint.isNone { s += String(format: " stroke %.2f", sh.stroke.width) + (sh.stroke.dash.isEmpty ? "" : " dashed") }
            case .raster(let r): s += " \(r.buffer.width)×\(r.buffer.height) at (\(r.origin.x),\(r.origin.y))"
            case .smartObject(let so): s += " \(Int(so.source.size.width))×\(Int(so.source.size.height))"
            default: break
            }
            if let m = l.mask {
                let p = m.buffer.data.assumingMemoryBound(to: UInt8.self)
                let mid = m.buffer.height / 2 * m.buffer.bytesPerRow
                let samples = stride(from: 0, to: m.buffer.width, by: max(1, m.buffer.width / 8)).map { String(p[mid + $0]) }.joined(separator: ",")
                s += " mask \(m.buffer.width)×\(m.buffer.height) at (\(m.origin.x),\(m.origin.y)) [\(samples)]"
            }
            if l.vectorMask != nil { s += " vector-mask" }
            if l.effects.hasAny { s += " effects" }
            if !l.isVisible { s += " hidden" }
            out.append(s)
            if l.isGroup { out.append(describe(l.children, indent: indent + "  ")) }
        }
        return out.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Imports every SVG of a folder and writes a comparison sheet and a summary line for each (exploration, not a test).
    static func importFolder(_ folder: URL, out: URL) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var files: [URL]
        if folder.pathExtension.lowercased() == "txt", let list = try? String(contentsOf: folder, encoding: .utf8) {
            // a text file with one path per line
            files = list.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        } else {
            files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { ["svg", "svgz"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        var lines: [String] = ["#\tfile\tsize\tmean\tbad%\tmax\tms\tlayers\trasterized\tnotes\tpath"]
        let maxSide = ProcessInfo.processInfo.environment["LUMEN_SVGIMPORT_MAXSIDE"].flatMap { Int($0) } ?? 900
        for (index, f) in files.enumerated() { autoreleasepool {
            let t0 = CFAbsoluteTimeGetCurrent()
            guard let data = try? Data(contentsOf: f) else { return }
            do {
                var settings = SVGImportSettings()
                if let doc = try? SVGImportXML.parse(data) {
                    // large artwork is imported smaller: every layer is a bitmap while it is composited
                    let d = SVGImport.defaultPixelSize(SVGImport.naturalSize(doc))
                    if max(d.0, d.1) > maxSide { if d.0 >= d.1 { settings.width = maxSide } else { settings.height = maxSide } }
                }
                let r = try SVGImport.load(data: data, baseURL: f.deletingLastPathComponent(), name: f.lastPathComponent, settings: settings)
                let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                let st = r.state
                var m = Metric()
                let raw = String(decoding: (try? SVGImportXML.prepare(data)) ?? data, as: UTF8.self)
                if let o = oracle(raw, st.width, st.height), let l = lumen(st) {
                    m = compare(o, l)
                    // sheets only where there is something to look at
                    if m.mean > 0.6 || m.bad > 0.004 || ProcessInfo.processInfo.environment["LUMEN_SVGIMPORT_SHEETS"] == "all" { sheet(o, l, to: out.appendingPathComponent(String(format: "%04d-", index) + f.deletingPathExtension().lastPathComponent + ".png")) }
                }
                let notes = r.report.items.map { "\($0.kind.rawValue): \($0.message)" + ($0.count > 1 ? " ×\($0.count)" : "") }.joined(separator: " | ")
                lines.append("\(index)\t\(f.lastPathComponent)\t\(st.width)x\(st.height)\t\(String(format: "%.2f", m.mean))\t\(String(format: "%.2f", m.bad * 100))\t\(m.maxDiff)\t\(Int(ms))\t\(outline(st.layers).prefix(160))\t\(r.report.rasterized)\t\(notes.prefix(300))\t\(f.path)")
            } catch {
                lines.append("\(index)\t\(f.lastPathComponent)\tERROR \(error.localizedDescription)\t\(f.path)")
            }
            print(lines.last!)
            Compositor.shared.clearCaches()
        } }
        try? lines.joined(separator: "\n").write(to: out.appendingPathComponent("summary.tsv"), atomically: true, encoding: .utf8)
    }
}

