import AppKit
import CoreImage
import ImageCratCore

/// Fidelity of opened Photoshop files against Photoshop's own rendering (`LUMEN_SELFTEST_ONLY=psdfidelity`).
/// Synthetic files reproduce each cause found in real documents; `LUMEN_PSDFIDELITY_FILE=<a.psd>` also measures a real
/// file against the composite stored in it. Diagnostics: `LUMEN_PSDFIDELITY_LAYERS=1` (per-layer differences against
/// the pixels Photoshop stored), `LUMEN_PSDFIDELITY_DUMP=1` (layer records, styles, type engine data),
/// `LUMEN_PSDFIDELITY_REPEAT=<n>` (read timing only), `LUMEN_PSDFIDELITY_FILE_ONLY=1` (skip the synthetic files).
enum PSDFidelitySelfTest {
    static var passed = 0, failed = 0

    static func register() {
        FeatureModules.selfTests.append(("psdfidelity", { out in run(out) }))
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count,
           let only = ProcessInfo.processInfo.environment["LUMEN_SELFTEST_ONLY"], only.hasPrefix("psdfidelity") {
            _ = NSApplication.shared
            let out = URL(fileURLWithPath: args[i + 1])
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            setlinebuf(stdout)
            run(out)
            print("done (psdfidelity only)")
            exit(failed == 0 ? 0 : 1)
        }
    }

    static func check(_ ok: Bool, _ msg: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS psdfidelity: \(msg())") } else { failed += 1; print("FAIL psdfidelity: \(msg())") }
    }

    static func run(_ out: URL) {
        passed = 0; failed = 0
        let dir = out.appendingPathComponent("psdfidelity")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.environment["LUMEN_PSDFIDELITY_FILE_ONLY"] == nil { synthetic(dir) }
        if let p = ProcessInfo.processInfo.environment["LUMEN_PSDFIDELITY_FILE"], FileManager.default.fileExists(atPath: p) {
            if ProcessInfo.processInfo.environment["LUMEN_PSDFIDELITY_DUMP"] != nil { dumpRecords(URL(fileURLWithPath: p)) } else { realFile(URL(fileURLWithPath: p), dir) }
        }
        print("psdfidelity: \(passed) passed, \(failed) failed")
    }

    // MARK: Real file (opt-in)

    static func realFile(_ url: URL, _ dir: URL) {
        if let n = ProcessInfo.processInfo.environment["LUMEN_PSDFIDELITY_REPEAT"].flatMap(Int.init) {
            for _ in 0..<n { let t0 = Date(); _ = try? PSDImporter.read(url: url); print(String(format: "INFO psdfidelity: read %.0f ms", Date().timeIntervalSince(t0) * 1000)) }
            return
        }
        PSDImporter.keepStoredPixels = true
        defer { PSDImporter.keepStoredPixels = false }
        let t0 = Date()
        guard let res = try? PSDImporter.read(url: url) else { check(false, "\(url.lastPathComponent) opens"); return }
        print(String(format: "INFO psdfidelity: read %.0f ms", Date().timeIntervalSince(t0) * 1000))
        guard let ref = PSDImportSelfTest.oracle(url), let mine = PSDImportSelfTest.flatten(res.state) else { check(false, "composite"); return }
        let d = PSDImportSelfTest.diff(ref, mine)
        print(String(format: "INFO psdfidelity: composite mean %.2f max %d bad %.2f%%", d.mean, d.max, d.badFraction * 100))
        PSDImportSelfTest.sideBySide(ref, mine, dir.appendingPathComponent("real_composite.png"))
        PSDImportSelfTest.writePNG(mine.makeCGImage(), dir.appendingPathComponent("real_lumen.png"))
        // the areas of the 300 × 600 banner these tests were written for
        for (n, r) in res.state.height == res.state.width * 2 ? regions(res.state.width, res.state.height) : [] {
            let e = diff(ref, mine, r)
            print(String(format: "INFO psdfidelity:    region %@ mean %.2f max %d bad %.2f%%", n, e.mean, e.max, e.badFraction * 100))
        }
        check(d.mean < 3, String(format: "%@: the composite matches Photoshop's (mean %.2f, %.2f%% off by more than 24)", url.lastPathComponent, d.mean, d.badFraction * 100))
        // type layers with a missing font: what Photoshop drew is shown; the substitute takes about the same room
        for l in res.state.allLayers {
            guard let t = l.text, let p = t.storedPixels else { continue }
            let ratio = PSDText.inkWidth(t) / Double(p.buffer.opaqueBounds()?.width ?? p.buffer.width)
            print(String(format: "INFO psdfidelity:    “%@”: missing %@, shows stored pixels %@, substitute %@ at %.0f%% of the stored width", l.name, t.missingFonts.joined(separator: ", "), t.showsStoredPixels ? "yes" : "no", t.fontName, ratio * 100))
            check(t.showsStoredPixels && abs(ratio - 1) < 0.15, String(format: "“%@”: stored pixels shown, substitute %@ within 15%% of the original width (%.0f%%)", l.name, t.fontName, ratio * 100))
        }
        guard ProcessInfo.processInfo.environment["LUMEN_PSDFIDELITY_LAYERS"] != nil else { return }
        print(res.report.text)
        for l in res.state.allLayers {
            var s = "INFO psdfidelity: layer “\(l.name)” \(l.kindName) \(l.blendMode.rawValue) op \(Int(l.opacity * 100)) fill \(Int(l.fillOpacity * 100))"
            if l.isClipped { s += " clipped" }
            if !l.isVisible { s += " hidden" }
            if l.effects.hasAny { s += " fx[\(l.effects.enabled ? "" : "off: ")\(l.effects.activeNames.joined(separator: ","))]" }
            if l.mask != nil { s += " mask" }
            if l.vectorMask != nil { s += " vmask" }
            if !l.blendIf.isDefault { s += " blendIf \(l.blendIf)" }
            if l.blendInteriorEffectsAsGroup { s += " infx" }
            if !l.blendClippedAsGroup { s += " !clbl" }
            if let pd = PSDImportSelfTest.layerDiff(l, res, dir.appendingPathComponent("layer_\(l.name.replacingOccurrences(of: "/", with: "_")).png")) {
                s += String(format: " | content vs stored mean %.2f max %d bad %.2f%%", pd.mean, pd.max, pd.badFraction * 100)
            }
            print(s)
        }
        // what each live layer costs: the composite with that layer's content replaced by Photoshop's stored pixels
        for l in res.state.allLayers where res.stored[l.id] != nil {
            var st = res.state
            st.layers.update(l.id) { x in
                let s = res.stored[l.id]!
                x.content = .raster(s)
            }
            guard let alt = PSDImportSelfTest.flatten(st) else { continue }
            let a = PSDImportSelfTest.diff(ref, alt)
            print(String(format: "INFO psdfidelity:    with stored pixels for “%@”: composite mean %.2f (was %.2f) bad %.2f%%", l.name, a.mean, d.mean, a.badFraction * 100))
        }
    }

    /// Named areas of the user's banner (fractions of the canvas), for the per-region table.
    static func regions(_ w: Int, _ h: Int) -> [(String, IRect)] {
        func r(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> IRect {
            IRect(x: Int(x0 * Double(w)), y: Int(y0 * Double(h)), width: Int((x1 - x0) * Double(w)), height: Int((y1 - y0) * Double(h)))
        }
        return [("headline", r(0, 0.02, 1, 0.15)), ("sticker", r(0.04, 0.15, 0.25, 0.26)), ("left bolt", r(0.2, 0.42, 0.36, 0.5)),
                ("right bolt", r(0.56, 0.46, 0.78, 0.53)), ("right note", r(0.68, 0.325, 0.77, 0.415)), ("temuin", r(0.07, 0.715, 0.47, 0.74)),
                ("amild button", r(0.03, 0.745, 0.51, 0.815)), ("go ahead", r(0.63, 0.77, 0.88, 0.795)), ("big A", r(0.6, 0.63, 1, 0.85)),
                ("warning panel", r(0, 0.85, 1, 1))]
    }

    static func diff(_ a: PixelBuffer, _ b: PixelBuffer, _ r: IRect) -> PSDImportSelfTest.Diff {
        let x = a.data.assumingMemoryBound(to: UInt8.self), y = b.data.assumingMemoryBound(to: UInt8.self)
        var total = 0, mx = 0, bad = 0, n = 0
        for row in max(0, r.y)..<min(a.height, r.maxY) {
            for col in max(0, r.x)..<min(a.width, r.maxX) {
                var worst = 0
                for k in 0..<3 {
                    let d = abs(Int(x[row * a.bytesPerRow + col * 4 + k]) - Int(y[row * b.bytesPerRow + col * 4 + k]))
                    total += d; worst = max(worst, d)
                }
                mx = max(mx, worst); if worst > 24 { bad += 1 }; n += 1
            }
        }
        return PSDImportSelfTest.Diff(mean: Double(total) / Double(max(1, n * 3)), max: mx, badFraction: Double(bad) / Double(max(1, n)))
    }

    // MARK: Record dump (diagnostics)

    static func dumpRecords(_ url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let imp = PSDImporter(bytes: [UInt8](data), name: url.lastPathComponent, nesting: 0, baseURL: nil)
        do {
            var c = PSDCursor(imp.bytes)
            try imp.header(&c); try imp.colorModeData(&c)
            var st = DocumentState(width: imp.W, height: imp.H)
            try imp.resources(&c, &st)
            let n = try c.len(large: imp.large)
            var l = try c.sub(min(n, c.remaining))
            try imp.layerAndMaskInfo(&l)
        } catch { print("dump: \(error)") }
        for r in imp.records {
            let br = Array(imp.bytes[r.blendRanges])
            print("REC “\(r.name)” rect \(r.rect.x),\(r.rect.y) \(r.rect.width)×\(r.rect.height) blend \(r.blendKey) op \(r.opacity) clip \(r.clipping) flags \(r.flags) section \(r.section.map(String.init) ?? "-") \(r.sectionBlend ?? "") blocks \(r.blocks.map(\.key).joined(separator: ",")) ranges \(br.count > 8 && br != [0,0,255,255,0,0,255,255] + Array(br.dropFirst(8)) ? br.map(String.init).joined(separator: " ") : "")")
            for b in r.blocks {
                var bc = PSDCursor(imp.bytes, b.range)
                switch b.key {
                case "lfx2", "lmfx":
                    if let d = imp.descriptor(b.range, skip: 4) { print(dump(d, 1)) }
                case "iOpa", "infx", "clbl", "knko", "lmgm", "vmgm":
                    print("   \(b.key) = \((try? bc.u8()) ?? 255)")
                case "TySh":
                    var c = PSDCursor(imp.bytes, b.range)
                    _ = try? c.u16()
                    let m = (0..<6).map { _ in (try? c.f64()) ?? 0 }
                    _ = try? c.u16()
                    var dr = PSDDescriptorReader(c.data(c.pos..<c.end))
                    _ = try? dr.u32()
                    guard let td = try? dr.descriptor() else { break }
                    print("   TySh transform \(m)")
                    for e in td.entries where e.key != "EngineData" { print("   \(e.key): \(dump(e.value, 2))") }
                    if case .data(_, let ed)? = td["EngineData"], let eng = try? PSDEngineParser.parse([UInt8](ed)) {
                        print("   Engine: " + engine(eng, 2, maxDepth: 9))
                    }
                default: break
                }
            }
        }
    }

    static func engine(_ v: PSDEngineValue, _ depth: Int, maxDepth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        switch v {
        case .dict(let d):
            guard depth < maxDepth else { return "<<…>>" }
            return "<<" + d.keys.sorted().map { "\n\(pad)/\($0) " + engine(d[$0]!, depth + 1, maxDepth: maxDepth) }.joined() + " >>"
        case .array(let a):
            guard depth < maxDepth else { return "[…\(a.count)]" }
            if a.allSatisfy({ $0.double != nil }) { return "[" + a.map { engine($0, depth, maxDepth: maxDepth) }.joined(separator: " ") + "]" }
            return "[" + a.prefix(12).map { "\n\(pad)" + engine($0, depth + 1, maxDepth: maxDepth) }.joined() + "]"
        case .number(let n): return String(format: "%g", n)
        case .bool(let b): return "\(b)"
        case .string(let s): return "(\(s.prefix(60)))"
        case .name(let n): return "/" + n
        }
    }

    static func dump(_ d: PSDDescriptor, _ depth: Int) -> String {
        let pad = String(repeating: "   ", count: depth)
        var out = "\(pad)<\(d.classID)>"
        for e in d.entries { out += "\n\(pad)\(e.key): " + dump(e.value, depth + 1) }
        return out
    }

    static func dump(_ v: PSDDescriptorValue, _ depth: Int) -> String {
        switch v {
        case .object(let o), .globalObject(let o): return "\n" + dump(o, depth)
        case .list(let l): return "[" + l.map { dump($0, depth + 1) }.joined(separator: ", ") + "]"
        case .double(let x): return String(format: "%.4g", x)
        case .unitFloat(let u, let x): return String(format: "%.4g", x) + u
        case .unitFloats(let u, let xs): return "\(xs.count) \(u)"
        case .integer(let i): return "\(i)"
        case .largeInteger(let i): return "\(i)"
        case .bool(let b): return "\(b)"
        case .enumerated(let t, let x): return "\(t).\(x)"
        case .string(let s): return "“\(s)”"
        case .classType(_, _, let c): return "class \(c)"
        case .objectArray(let n, _): return "objArray \(n)"
        case .data(let t, let d): return "data \(t) \(d.count)"
        case .reference: return "ref"
        }
    }
}
