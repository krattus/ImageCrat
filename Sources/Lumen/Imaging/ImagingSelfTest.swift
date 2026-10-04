import Foundation
import CoreImage
import AppKit
import SwiftUI
import ImageCratCore

/// `LUMEN_SELFTEST_ONLY=imaging` runs these. Sub-filter with `LUMEN_IMAGING_ONLY=modes|swatch|pano|align|stack|hdr`.
enum ImagingSelfTest {
    static func want(_ n: String) -> Bool {
        guard let o = ProcessInfo.processInfo.environment["LUMEN_IMAGING_ONLY"] else { return true }
        return o.split(separator: ",").contains { n.hasPrefix($0) }
    }

    static func run(_ out: URL) {
        if want("modes") { modes(out) }
        if want("swatch") { swatches(out) }
        if want("pattern") { patternPreview(out) }
        if want("stack") { stackModes(out) }
        if want("pano") { MergeSelfTest.panorama(out) }
        if want("align") { MergeSelfTest.autoAlign(out) }
        if want("focus") { MergeSelfTest.focusStack(out) }
        if want("hdr") { MergeSelfTest.hdr(out) }
        if want("loadstack") { MergeSelfTest.loadStack(out) }
        let only = ProcessInfo.processInfo.environment["LUMEN_IMAGING_ONLY"] ?? ""
        if ProcessInfo.processInfo.environment["LUMEN_SELFTEST_UI"] == "1" || only.contains("ui") { uiSnapshots(out) }
    }

    /// Dialog / panel snapshots (LUMEN_SELFTEST_UI=1 or LUMEN_IMAGING_ONLY=ui).
    static func uiSnapshots(_ out: URL) {
        var st = state(photo())
        let d = Document(state: st, name: "ui")
        let app = AppModel.shared
        app.add(d)
        defer { app.close(d) }
        func snap<V: View>(_ v: V, _ name: String, _ size: CGSize) {
            let host = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Theme.panelBG).environment(\.colorScheme, .dark))
            host.frame = CGRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.appearance = NSAppearance(named: .darkAqua)
            win.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
            print("wrote \(name)")
        }
        snap(DraggableCard { BitmapDialog() }, "imaging_ui_bitmap", CGSize(width: 480, height: 340))
        snap(DraggableCard { IndexedColorDialog() }, "imaging_ui_indexed", CGSize(width: 480, height: 420))
        snap(DraggableCard { DuotoneDialog() }, "imaging_ui_duotone", CGSize(width: 500, height: 380))
        snap(DraggableCard { SpotChannelDialog() }, "imaging_ui_spot", CGSize(width: 400, height: 240))
        snap(DraggableCard { PhotomergeDialog() }, "imaging_ui_photomerge", CGSize(width: 600, height: 420))
        snap(DraggableCard { AutoAlignDialog() }, "imaging_ui_autoalign", CGSize(width: 400, height: 380))
        snap(DraggableCard { AutoBlendDialog() }, "imaging_ui_autoblend", CGSize(width: 380, height: 240))
        snap(DraggableCard { LoadStackDialog() }, "imaging_ui_loadstack", CGSize(width: 480, height: 360))
        snap(DraggableCard { HDRProDialog() }, "imaging_ui_hdrpro", CGSize(width: 600, height: 560))
        snap(DraggableCard { Pano360Dialog() }, "imaging_ui_pano360", CGSize(width: 460, height: 260))
        snap(SwatchesPanel(), "imaging_ui_swatches_panel", CGSize(width: 300, height: 360))
        // Indexed document: channels panel + colour table
        st = ColorModes.indexed(st, IndexedOptions())
        d.state = st
        snap(DraggableCard { ColorTableDialog() }, "imaging_ui_colortable", CGSize(width: 440, height: 440))
        ColorModes.addSpotChannel(d, name: "Gold Ink", ink: RGBA(hex: "D4AF37")!, solidity: 0.3)
        snap(ChannelsPanel(), "imaging_ui_channels_indexed_spot", CGSize(width: 300, height: 220))
    }

    static func check(_ ok: Bool, _ msg: String) { print(ok ? "PASS imaging: \(msg)" : "FAIL imaging: \(msg)") }

    /// Colourful synthetic "photo": sky gradient, sun, hills, coloured discs, soft noise.
    static func photo(_ w: Int = 360, _ h: Int = 240, seed: UInt64 = 7) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        let sky = CGGradient(colorsSpace: sRGBSpace, colors: [RGBA(hex: "2B5EA8")!.cgColor, RGBA(hex: "F2B880")!.cgColor] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: Double(h) * 0.7), options: [.drawsAfterEndLocation])
        c.setFillColor(RGBA(hex: "FFE680")!.cgColor)
        c.fillEllipse(in: CGRect(x: Double(w) * 0.68, y: Double(h) * 0.12, width: Double(h) * 0.22, height: Double(h) * 0.22))
        for (i, col) in ["3E6B35", "2F5230", "56803E"].enumerated() {
            c.setFillColor(RGBA(hex: col)!.cgColor)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: h))
            for x in stride(from: 0, through: w, by: 6) {
                let y = Double(h) * (0.55 + 0.08 * Double(i)) + 18 * sin(Double(x) / (40 + Double(i) * 15) + Double(i))
                p.addLine(to: CGPoint(x: Double(x), y: y))
            }
            p.addLine(to: CGPoint(x: w, y: h)); p.closeSubpath()
            c.addPath(p); c.fillPath()
        }
        var rng = ImgRNG(seed: seed)
        for _ in 0..<14 {
            let hue = rng.next01(), r = 8 + rng.next01() * 22
            c.setFillColor(RGBA(h: hue, s: 0.8, v: 0.95).cgColor)
            c.fillEllipse(in: CGRect(x: rng.next01() * Double(w), y: Double(h) * (0.6 + rng.next01() * 0.35), width: r, height: r))
        }
        b.markDirty()
        return b
    }

    static func state(_ buf: PixelBuffer) -> DocumentState {
        var st = DocumentState(width: buf.width, height: buf.height)
        st.layers = [Layer.raster(name: "Background", buffer: buf)]
        return st
    }

    static func save(_ st: DocumentState, _ name: String, _ out: URL, format: ExportFormat = .png) -> URL {
        let url = out.appendingPathComponent(name + "." + format.ext)
        do { try DocumentIO.export(st, to: url, format: format, quality: 1, scale: 1) } catch { print("FAIL imaging \(name): \(error)") }
        print("wrote \(name)")
        return url
    }

    static func saveImage(_ img: CIImage, _ rect: CGRect, _ name: String, _ out: URL) {
        var st = DocumentState(width: Int(rect.width), height: Int(rect.height))
        let sp = CanvasSpace(width: st.width, height: st.height)
        st.layers = [Layer.raster(name: "L", buffer: RenderEngine.renderBuffer(img.translated(-rect.minX, -rect.minY).cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp))]
        _ = save(st, name, out)
    }

    // MARK: Colour modes

    static func modes(_ out: URL) {
        let base = state(photo())
        _ = save(base, "imaging_mode_source", out)

        for m in BitmapMethod.allCases {
            var o = BitmapOptions(outputResolution: 72, method: m)
            o.frequency = 18; o.angle = 45
            let st = ColorModes.bitmap(base, o)
            let url = save(st, "imaging_mode_bitmap_\(m.rawValue.replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "%", with: "pct"))", out)
            if m == .diffusion { check(IndexedExport.declaredPaletteSize(url) == 2, "bitmap PNG is 1-bit palette (\(IndexedExport.declaredPaletteSize(url) ?? -1))") }
        }
        var hi = BitmapOptions(outputResolution: 144, method: .halftone); hi.frequency = 20; hi.shape = .ellipse; hi.angle = 30
        let hst = ColorModes.bitmap(base, hi)
        check(hst.width == base.width * 2 && hst.resolution == 144, "bitmap output resolution doubles size (\(hst.width)×\(hst.height))")
        _ = save(hst, "imaging_mode_bitmap_halftone_144ppi", out)

        let palettes: [(PaletteKind, DitherKind, Int)] = [(.adaptive, .none, 16), (.perceptual, .diffusion, 16), (.selective, .diffusion, 32), (.selective, .pattern, 8),
                                                          (.web, .noise, 256), (.systemMac, .diffusion, 256), (.uniform, .none, 27), (.selective, .none, 256)]
        for (p, dth, n) in palettes {
            var o = IndexedOptions(); o.palette = p; o.dither = dth; o.colors = n; o.amount = 0.8
            let t0 = CFAbsoluteTimeGetCurrent()
            let st = ColorModes.indexed(base, o)
            let name = "imaging_mode_indexed_\(p.rawValue.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: ""))_\(dth.rawValue)_\(n)"
            let png = save(st, name, out)
            let gif = save(st, name, out, format: .gif)
            let tableCount = st.imaging?.colorTable?.count ?? 0
            let gp = IndexedExport.declaredPaletteSize(gif) ?? -1, pp = IndexedExport.declaredPaletteSize(png) ?? -1
            var pow2 = 2; while pow2 < tableCount { pow2 *= 2 }
            check(tableCount <= max(n, 2) || !p.usesCount, "\(name): table \(tableCount) colours (\(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t0))s)")
            check(gp == pow2 && pp == tableCount, "\(name): GIF palette \(gp) (expect \(pow2)), PNG-8 PLTE \(pp)")
            // decoded GIF must contain only table colours
            if let src = CGImageSourceCreateWithURL(gif as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let b = PixelBuffer(cgImage: cg)
                let set = Set((st.imaging?.colorTable ?? []).map { $0.hex })
                var bad = 0
                for y in stride(from: 0, to: b.height, by: 7) { for x in stride(from: 0, to: b.width, by: 7) {
                    let p = b.pixel(x, y); if !set.contains(RGBA(r8: p.0, g8: p.1, b8: p.2).hex) { bad += 1 }
                } }
                check(bad == 0, "\(name): decoded GIF uses only table colours (\(bad) mismatches)")
            }
        }
        // Exact palette on a flat image + transparency
        do {
            let b = PixelBuffer(width: 120, height: 80)
            b.context.setFillColor(RGBA(hex: "FF0000")!.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            b.context.setFillColor(RGBA(hex: "00AA55")!.cgColor); b.context.fill(CGRect(x: 60, y: 0, width: 40, height: 40))
            b.markDirty()
            var o = IndexedOptions(); o.palette = .exact; o.transparency = true
            let st = ColorModes.indexed(state(b), o)
            let gif = save(st, "imaging_mode_indexed_exact_transparent", out, format: .gif)
            let tbl = st.imaging?.colorTable ?? []
            check(tbl.count == 3 && st.imaging?.transparentIndex == 2, "exact palette: \(tbl.count) entries incl. transparent (index \(st.imaging?.transparentIndex ?? -1))")
            if let src = CGImageSourceCreateWithURL(gif as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let pb = PixelBuffer(cgImage: cg)
                check(pb.alpha(110, 70) == 0 && pb.alpha(10, 10) == 255, "GIF transparency round trip")
            }
        }
        // Duotone presets
        for (i, (name, s)) in DuotoneSettings.presets.enumerated() {
            let st = ColorModes.duotone(base, s)
            _ = save(st, "imaging_mode_duotone_\(i)_\(name.replacingOccurrences(of: " ", with: "_"))", out)
        }
        // Multichannel from RGB and CMYK
        let mc = ColorModes.multichannel(base)
        check(mc.spotChannels.count == 3, "multichannel RGB → 3 ink channels")
        _ = save(mc, "imaging_mode_multichannel_from_rgb", out)
        var cm = base; cm.colorMode = .cmyk
        let mc2 = ColorModes.multichannel(cm)
        check(mc2.spotChannels.count == 4, "multichannel CMYK → 4 ink channels")
        _ = save(mc2, "imaging_mode_multichannel_from_cmyk", out)
        // Leave multichannel → RGB bakes the inks
        var back = mc
        ColorModes.leave(&back); back.colorMode = .rgb
        _ = save(back, "imaging_mode_multichannel_back_to_rgb", out)

        // Spot channel on an RGB document (disc of opaque orange ink + 50 % solidity blue band)
        do {
            let d = Document(state: base, name: "spot")
            let sel = PixelBuffer(width: base.width, height: base.height, format: .gray)
            sel.context.setFillColor(CGColor(gray: 1, alpha: 1)); sel.context.fillEllipse(in: CGRect(x: 30, y: 30, width: 120, height: 120)); sel.markDirty()
            d.state.selection = sel
            ColorModes.addSpotChannel(d, name: "Orange Ink", ink: RGBA(hex: "FF7A00")!, solidity: 1)
            let sel2 = PixelBuffer(width: base.width, height: base.height, format: .gray)
            sel2.context.setFillColor(CGColor(gray: 1, alpha: 1)); sel2.context.fill(CGRect(x: 0, y: 170, width: base.width, height: 30)); sel2.markDirty()
            d.state.selection = sel2
            ColorModes.addSpotChannel(d, name: "Blue Ink", ink: RGBA(hex: "0050FF")!, solidity: 0)
            check(d.state.spotChannels.count == 2, "two spot channels added")
            _ = save(d.state, "imaging_spot_channels_rgb", out)
            d.undo()
            check(d.state.spotChannels.count == 1, "spot channel add is undoable")
        }
        // Mode conversion undo through Document history
        do {
            let d = Document(state: base, name: "undo")
            let st = ColorModes.indexed(d.state, IndexedOptions())
            ColorModes.finish(d, st, "Indexed Color")
            check(d.state.colorMode == .indexed, "document converted to indexed")
            d.undo()
            check(d.state.colorMode == .rgb && d.state.imaging?.colorTable == nil, "indexed conversion undo restores RGB")
            d.redo()
            check(d.state.colorMode == .indexed, "redo restores indexed")
        }
    }

    // MARK: Swatches

    static func swatches(_ out: URL) {
        let colors = SwatchLibraries.material.colors.prefix(40).map { $0 } + [SwatchColor(name: "Ünïcode ✓", color: RGBA(hex: "123456")!)]
        let aco = SwatchIO.writeACO(Array(colors))
        let ase = SwatchIO.writeASE(Array(colors), groupName: "Test")
        let acoURL = out.appendingPathComponent("imaging_swatches.aco"), aseURL = out.appendingPathComponent("imaging_swatches.ase")
        try? aco.write(to: acoURL); try? ase.write(to: aseURL)
        func same(_ a: [SwatchColor], _ b: [SwatchColor]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.name == $1.name && $0.color.hex == $1.color.hex }
        }
        let a1 = (try? SwatchIO.load(url: acoURL))?.colors ?? []
        let a2 = (try? SwatchIO.load(url: aseURL))?.colors ?? []
        check(same(a1, Array(colors)), ".aco round trip (\(a1.count) swatches, names + colours)")
        check(same(a2, Array(colors)), ".ase round trip (\(a2.count) swatches, names + colours)")
        // hand-built ACO v1 with HSB / CMYK / Lab / Gray entries
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8((v >> 8) & 255)); d.append(UInt8(v & 255)) }
        u16(1); u16(4)
        u16(1); u16(0); u16(65535); u16(65535); u16(0)          // HSB red
        u16(2); u16(65535); u16(0); u16(65535); u16(65535)      // CMYK: magenta ink only (0 = 100 %)
        u16(7); u16(5000); u16(0); u16(0); u16(0)               // Lab L50 gray
        u16(8); u16(10000); u16(0); u16(0); u16(0)              // Gray 100 % = black
        let parsed = (try? SwatchIO.parseACO(d)) ?? []
        let desc = parsed.map { "#" + $0.color.hex }.joined(separator: " ")
        check(parsed.count == 4 && parsed[0].color.hex == "FF0000" && parsed[3].color.hex == "000000" && parsed[1].color.g < 0.3 && abs(parsed[2].color.r - 0.47) < 0.03,
              "ACO colour spaces HSB/CMYK/Lab/Gray → \(desc)")
        // ASE with CMYK / LAB / Gray blocks
        var e = Data("ASEF".utf8)
        func be16(_ v: Int, _ x: inout Data) { x.append(UInt8((v >> 8) & 255)); x.append(UInt8(v & 255)) }
        func be32(_ v: UInt32, _ x: inout Data) { be16(Int(v >> 16), &x); be16(Int(v & 0xFFFF), &x) }
        be16(1, &e); be16(0, &e); be32(3, &e)
        for (model, vals) in [("CMYK", [0.0, 1.0, 1.0, 0.0]), ("LAB ", [0.5, 0.0, 0.0]), ("Gray", [0.25])] {
            var b = Data(); be16(2, &b); be16(Int("X".utf16.first!), &b); be16(0, &b); b.append(Data(model.utf8))
            for v in vals { be32(Float(v).bitPattern, &b) }
            be16(2, &b)
            be16(1, &e); be32(UInt32(b.count), &e); e.append(b)
        }
        let pe = (try? SwatchIO.parseASE(e)) ?? []
        check(pe.count == 3 && pe[0].color.r > 0.8 && pe[0].color.g < 0.3 && abs(pe[2].color.r - 0.25) < 0.01, "ASE CMYK/LAB/Gray → \(pe.map { "#" + $0.color.hex }.joined(separator: " "))")
        check(SwatchLibraries.html.colors.count >= 140 && SwatchLibraries.material.colors.count == 190 && SwatchLibraries.ral.colors.count > 150,
              "built-in libraries: HTML \(SwatchLibraries.html.colors.count), Material \(SwatchLibraries.material.colors.count), RAL \(SwatchLibraries.ral.colors.count)")
        // swatch sheet image of the libraries
        let libs = [SwatchLibraries.html, SwatchLibraries.material, SwatchLibraries.ral]
        let cell = 12, cols = 40
        let rows = libs.map { ($0.colors.count + cols - 1) / cols }
        let H = rows.reduce(0, +) * cell + libs.count * 6
        let b = PixelBuffer(width: cols * cell, height: H)
        var y0 = 0
        for (li, l) in libs.enumerated() {
            for (i, c) in l.colors.enumerated() {
                b.context.setFillColor(c.color.cgColor)
                b.context.fill(CGRect(x: (i % cols) * cell, y: y0 + (i / cols) * cell, width: cell - 1, height: cell - 1))
            }
            y0 += rows[li] * cell + 6
        }
        b.markDirty()
        _ = save(state(b), "imaging_swatch_libraries", out)
    }

    // MARK: Pattern preview

    static func patternPreview(_ out: URL) {
        let w = 120, h = 90
        let b = PixelBuffer(width: w, height: h)
        b.context.setFillColor(RGBA(hex: "F3E9D2")!.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        b.context.setFillColor(RGBA(hex: "C84C3C")!.cgColor)
        // a disc that crosses the right / bottom edges and its wrapped counterpart: seamless when tiled
        for (dx, dy) in [(0, 0), (-w, 0), (0, -h), (-w, -h)] { b.context.fillEllipse(in: CGRect(x: 90 + dx, y: 60 + dy, width: 50, height: 50)) }
        b.context.setFillColor(RGBA(hex: "2E6F95")!.cgColor); b.context.fill(CGRect(x: 20, y: 20, width: 30, height: 10))
        b.markDirty()
        let st = state(b)
        let img = PatternPreview.tiledImage(st)
        saveImage(img, CGRect(x: 0, y: 0, width: w * 3, height: h * 3), "imaging_pattern_preview", out)
    }

    // MARK: Stack modes

    static func stackModes(_ out: URL) {
        let w = 200, h = 140
        var inner = DocumentState(width: w, height: h)
        var rng = ImgRNG(seed: 3)
        let base = photo(w, h, seed: 11)
        for i in 0..<5 {
            let b = base.copy()
            let c = b.context
            // noise + a moving "tourist" occluder: median removes it
            c.setFillColor(RGBA(hex: "D02020")!.cgColor)
            c.fill(CGRect(x: 20 + i * 34, y: 40, width: 22, height: 60))
            let p = b.data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let o = y * b.bytesPerRow + x * 4
                for k in 0..<3 { p[o + k] = UInt8(clamp(Int(p[o + k]) + Int((rng.next01() - 0.5) * 50), 0, 255)) }
            } }
            b.markDirty()
            inner.layers.append(Layer.raster(name: "Frame \(i + 1)", buffer: b))
        }
        let so = SmartObjectContent(source: .document(inner), quad: Quad(rect: CGRect(x: 0, y: 0, width: w, height: h)), sourceName: "Stack")
        var st = DocumentState(width: w, height: h)
        st.layers = [Layer(name: "Stack", content: .smartObject(so))]
        let modes: [StackMode] = [.mean, .median, .maximum, .minimum, .range, .summation, .variance, .stdDev, .entropy, .skewness, .kurtosis]
        for m in modes {
            var s2 = st
            s2.updateLayer(st.layers[0].id) { l in var x = l.smart!; x.stack = m; x.sourceRevision = m.hashValue & 0xffff; l.smart = x }
            Compositor.shared.clearCaches()
            let url = save(s2, "imaging_stackmode_\(m.rawValue.replacingOccurrences(of: " ", with: "_"))", out)
            if m == .median, let img = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let pb = PixelBuffer(cgImage: img)
                let px = pb.pixel(31, 70)     // occluder in frame 1 only → median shows background
                check(!(px.0 > 180 && px.1 < 80), "median removes transient occluder (px \(px.0),\(px.1),\(px.2))")
            }
        }
        // tolerant decoding: old smart objects without the key still decode
        if let data = try? PropertyListEncoder().encode(st), let back = try? PropertyListDecoder().decode(DocumentState.self, from: data) {
            check(back.layers.first?.smart?.stack == StackMode.none, "smart object without stackMode decodes (none)")
        }
    }
}

struct ImgRNG {
    var s: UInt64
    init(seed: UInt64) { s = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func next01() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
