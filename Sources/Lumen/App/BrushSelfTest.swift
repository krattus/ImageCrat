import AppKit
import SwiftUI
import ImageCratCore

/// Headless brush-dynamics renders (part of `--selftest`) and brush timings (part of `--perftest`).
enum BrushSelfTest {
    // MARK: Helpers

    static func makeDoc(_ w: Int = 600, _ h: Int = 360) -> (Document, UUID) {
        var st = DocumentState(width: w, height: h)
        let bg = PixelBuffer(width: w, height: h)
        bg.context.setFillColor(RGBA.white.cgColor)
        bg.context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        bg.markDirty()
        let paint = Layer.raster(name: "Paint", width: w, height: h)
        st.layers = [Layer.raster(name: "Background", buffer: bg), paint]
        return (Document(state: st, name: "brush"), paint.id)
    }

    /// Horizontal wavy path with a pressure profile (0...1 along the path).
    static func path(y: Double, x0: Double = 40, x1: Double = 560, wave: Double = 18, steps: Int = 90,
                     pressure: (Double) -> Double = { _ in 1 }, tilt: CGPoint = .zero) -> [PenSample] {
        (0...steps).map { i in
            let t = Double(i) / Double(steps)
            let x = x0 + (x1 - x0) * t
            return PenSample(p: CGPoint(x: x, y: y + sin(t * .pi * 3) * wave), pressure: pressure(t), tilt: tilt, rotation: t * 360, wheel: 1 - t)
        }
    }

    static let taper: (Double) -> Double = { t in max(0.05, sin(t * .pi)) }

    /// Paints one stroke through the real PaintStroke + dynamics engine path (flushing every few samples).
    static func stroke(_ d: Document, _ layerID: UUID, _ s: BrushSettings, _ pts: [PenSample], fg: RGBA = .black, bg: RGBA = .white,
                       aliased: Bool = false, blend: CGBlendMode = .normal, paint: BrushDynamicsEngine.Paint? = nil, seed: UInt64 = 42) {
        guard let st = PaintStroke(doc: d, layerID: layerID, target: .content, opacity: s.opacity, blend: blend) else { print("stroke FAIL"); return }
        let eng = BrushDynamicsEngine(settings: s, target: st.strokeBuf, origin: st.origin, paint: paint ?? .dynamic(fg: fg, bg: bg), aliased: aliased, seed: seed)
        st.dynamics = eng
        eng.begin(pts[0])
        st.flush()
        for (i, p) in pts.dropFirst().enumerated() {
            eng.move(p, final: i == pts.count - 2)
            if i % 4 == 0 { st.flush() }
        }
        st.finish(name: "Brush")
    }

    static func brush(size: Double, hardness: Double = 1, spacing: Double = 0.1, tip: String = "round", _ f: (inout BrushSettings) -> Void = { _ in }) -> BrushSettings {
        var s = BrushSettings(size: size, hardness: hardness, spacing: spacing, smoothing: 0)
        s.pressureSize = false
        s.tipID = tip
        f(&s)
        return s
    }

    /// A tiny version-2 ABR file with one sampled 8-bit tip (a crescent leaf with dots), big-endian like Photoshop.
    static func syntheticABR() -> Data {
        let w = 80, h = 60
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fillEllipse(in: CGRect(x: 4, y: 8, width: 60, height: 44))
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fillEllipse(in: CGRect(x: 20, y: 14, width: 52, height: 40))
        ctx.setFillColor(gray: 0.8, alpha: 1)
        for i in 0..<5 { ctx.fillEllipse(in: CGRect(x: 60 + (i % 2) * 8, y: 6 + i * 10, width: 7, height: 7)) }
        let px = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var body = Data()
        func u8(_ v: Int, _ d: inout Data) { d.append(UInt8(truncatingIfNeeded: v)) }
        func u16(_ v: Int, _ d: inout Data) { u8(v >> 8, &d); u8(v, &d) }
        func u32(_ v: Int, _ d: inout Data) { u16(v >> 16, &d); u16(v, &d) }
        u32(0, &body)                      // misc
        u16(15, &body)                     // spacing %
        let name = Array("Synthetic Leaf".utf16)
        u32(name.count + 1, &body); for c in name { u16(Int(c), &body) }; u16(0, &body)
        u8(1, &body)                       // anti-aliasing
        u16(0, &body); u16(0, &body); u16(h, &body); u16(w, &body)   // short bounds
        u32(0, &body); u32(0, &body); u32(h, &body); u32(w, &body)   // long bounds: top left bottom right
        u16(8, &body)                      // depth
        u8(0, &body)                       // raw
        for y in 0..<h { for x in 0..<w { body.append(px[y * w + x]) } }
        var d = Data()
        u16(2, &d); u16(1, &d)             // version, count
        u16(2, &d); u32(body.count, &d)    // sampled brush, length
        d.append(body)
        return d
    }

    // MARK: Self test

    /// BrushSettings JSON: dynamics roundtrip, and settings saved before `dynamics` existed still decode.
    static func codableCheck() {
        var s = BrushSettings()
        s.dynamics.wetEdges = true; s.dynamics.angleControl.source = .direction; s.dynamics.textureMode = .height; s.dynamics.hueJitter = 0.3
        do {
            let data = try JSONEncoder().encode(s)
            let back = try JSONDecoder().decode(BrushSettings.self, from: data)
            var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            obj.removeValue(forKey: "dynamics")
            let old = try JSONDecoder().decode(BrushSettings.self, from: JSONSerialization.data(withJSONObject: obj))
            var partial = obj; partial["dynamics"] = ["noise": true, "angleControl": ["source": "bogus"]]
            let part = try JSONDecoder().decode(BrushSettings.self, from: JSONSerialization.data(withJSONObject: partial))
            print("BrushSettings codable: roundtrip \(back == s), legacy decodes \(old.dynamics == BrushDynamics()), partial \(part.dynamics.noise && part.dynamics.angleControl.source == .off)")
        } catch { print("BrushSettings codable FAIL \(error)") }
    }

    static func run(_ out: URL) {
        codableCheck()
        func save(_ d: Document, _ name: String) { SelfTest.save(d.state, name, out) }
        let red = RGBA(hex: "C0392B")!, blue = RGBA(hex: "2E86DE")!, green = RGBA(hex: "27AE60")!

        // Basic tips: hard, soft, pressure taper, pencil (aliased)
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 30, hardness: 1), path(y: 50))
            stroke(d, id, brush(size: 40, hardness: 0), path(y: 130), fg: blue)
            stroke(d, id, brush(size: 36, hardness: 0.8) { $0.pressureSize = true }, path(y: 210, pressure: taper), fg: red)
            stroke(d, id, brush(size: 5, hardness: 1, spacing: 0.05), path(y: 300, wave: 30), aliased: true)
            save(d, "brush_basic")
        }
        // Shape dynamics
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 36, spacing: 0.25, tip: "round") { s in
                s.roundness = 0.25; s.dynamics.shapeEnabled = true; s.dynamics.angleJitter = 1 }, path(y: 50))
            stroke(d, id, brush(size: 34, spacing: 0.04) { s in
                s.roundness = 0.2; s.angle = 90; s.dynamics.shapeEnabled = true; s.dynamics.angleControl.source = .direction }, path(y: 130, wave: 30), fg: blue)
            stroke(d, id, brush(size: 50, spacing: 0.15) { s in
                s.dynamics.shapeEnabled = true; s.dynamics.sizeControl.source = .pressure; s.dynamics.minDiameter = 0.1 }, path(y: 215, pressure: taper), fg: red)
            stroke(d, id, brush(size: 44, spacing: 0.5, tip: "star") { s in
                s.sizeJitter = 0.6; s.dynamics.shapeEnabled = true; s.dynamics.minDiameter = 0.2; s.dynamics.roundnessJitter = 0.7
                s.dynamics.flipXJitter = true; s.dynamics.sizeControl.source = .fade; s.dynamics.sizeControl.fadeSteps = 30 }, path(y: 300), fg: green)
            save(d, "brush_shape_dynamics")
        }
        // Scattering
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 16, spacing: 0.6) { s in
                s.scatter = 2.5; s.dynamics.scatterEnabled = true; s.dynamics.count = 3 }, path(y: 90), fg: blue)
            stroke(d, id, brush(size: 16, spacing: 0.6) { s in
                s.scatter = 2.5; s.dynamics.scatterEnabled = true; s.dynamics.scatterBothAxes = false; s.dynamics.count = 2; s.dynamics.countJitter = 0.5 }, path(y: 260), fg: red)
            save(d, "brush_scattering")
        }
        // Texture (per tip, stroke-level, modes)
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 60, hardness: 0.9) { s in
                s.dynamics.textureEnabled = true; s.flow = 0.5
                s.dynamics.texturePatternID = "stripes"; s.dynamics.textureScale = 2
                s.dynamics.textureMode = .multiply; s.dynamics.textureDepth = 1 }, path(y: 50))
            stroke(d, id, brush(size: 60, hardness: 0.9) { s in
                s.dynamics.textureEnabled = true; s.dynamics.texturePatternID = "bricks"; s.dynamics.textureMode = .height; s.dynamics.textureDepth = 0.6 }, path(y: 135), fg: red)
            stroke(d, id, brush(size: 60, hardness: 0.5, spacing: 0.05) { s in
                s.flow = 0.3
                s.dynamics.textureEnabled = true; s.dynamics.textureEachTip = false; s.dynamics.texturePatternID = "noise"; s.dynamics.textureScale = 3
                s.dynamics.textureContrast = 80; s.dynamics.textureMode = .subtract; s.dynamics.textureDepth = 1 }, path(y: 220), fg: blue)
            stroke(d, id, brush(size: 60, hardness: 1) { s in
                s.dynamics.textureEnabled = true; s.dynamics.texturePatternID = "dots"; s.dynamics.textureScale = 1.5; s.dynamics.textureInvert = true; s.dynamics.textureMode = .linearHeight; s.dynamics.textureDepth = 0.7 }, path(y: 305), fg: green)
            save(d, "brush_texture")
        }
        // Dual brush
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 70, hardness: 0.8) { s in
                s.dynamics.dualEnabled = true; s.dynamics.dualTipID = "chalk"; s.dynamics.dualSize = 40; s.dynamics.dualScatter = 0.6; s.dynamics.dualBothAxes = true; s.dynamics.dualCount = 2 }, path(y: 60))
            stroke(d, id, brush(size: 70, hardness: 1) { s in
                s.dynamics.dualEnabled = true; s.dynamics.dualTipID = "round"; s.dynamics.dualSize = 12; s.dynamics.dualSpacing = 0.9
                s.dynamics.dualScatter = 2; s.dynamics.dualBothAxes = true; s.dynamics.dualCount = 3; s.dynamics.dualMode = .hardMix }, path(y: 180), fg: red)
            stroke(d, id, brush(size: 70, hardness: 0.3) { s in
                s.dynamics.dualEnabled = true; s.dynamics.dualTipID = "bristle"; s.dynamics.dualSize = 60; s.dynamics.dualSpacing = 0.1; s.dynamics.dualMode = .colorBurn }, path(y: 295), fg: blue)
            save(d, "brush_dual")
        }
        // Color dynamics
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 40, spacing: 0.3) { s in
                s.dynamics.colorEnabled = true; s.dynamics.hueJitter = 1 }, path(y: 60), fg: red)
            stroke(d, id, brush(size: 40, spacing: 0.3) { s in
                s.dynamics.colorEnabled = true; s.dynamics.fgBgJitter = 1 }, path(y: 150), fg: blue, bg: RGBA(hex: "F1C40F")!)
            stroke(d, id, brush(size: 40, spacing: 0.1) { s in
                s.dynamics.colorEnabled = true; s.dynamics.fgBgControl.source = .fade; s.dynamics.fgBgControl.fadeSteps = 120 }, path(y: 235), fg: red, bg: blue)
            stroke(d, id, brush(size: 40, spacing: 0.3) { s in
                s.dynamics.colorEnabled = true; s.dynamics.saturationJitter = 0.6; s.dynamics.brightnessJitter = 0.5; s.dynamics.colorPerTip = true }, path(y: 315), fg: green)
            save(d, "brush_color_dynamics")
        }
        // Transfer
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 40, hardness: 0.5, spacing: 0.25) { s in s.opacityJitter = 1; s.dynamics.transferEnabled = true }, path(y: 70))
            stroke(d, id, brush(size: 40, hardness: 0.5, spacing: 0.05) { s in
                s.dynamics.transferEnabled = true; s.dynamics.flowControl.source = .pressure }, path(y: 180, pressure: taper), fg: blue)
            stroke(d, id, brush(size: 40, hardness: 0.5, spacing: 0.05) { s in
                s.dynamics.transferEnabled = true; s.dynamics.opacityControl.source = .fade; s.dynamics.opacityControl.fadeSteps = 150 }, path(y: 290), fg: red)
            save(d, "brush_transfer")
        }
        // Wet edges, noise
        do {
            let (d, id) = makeDoc()
            stroke(d, id, brush(size: 50, hardness: 1, spacing: 0.08) { s in s.dynamics.wetEdges = true }, path(y: 60), fg: blue)
            stroke(d, id, brush(size: 60, hardness: 0.4, spacing: 0.08) { s in s.dynamics.wetEdges = true }, path(y: 150), fg: red)
            stroke(d, id, brush(size: 70, hardness: 0, spacing: 0.08) { s in s.dynamics.noise = true }, path(y: 250))
            stroke(d, id, brush(size: 40, hardness: 1, spacing: 0.08) { s in s.dynamics.wetEdges = true; s.dynamics.noise = true }, path(y: 320, wave: 5), fg: green)
            save(d, "brush_wet_noise")
        }
        // Built-in dynamic presets
        do {
            let (d, id) = makeDoc(600, 90 * BrushPreset.dynamicPresets.count / 2 + 40)
            for (i, p) in BrushPreset.dynamicPresets.enumerated() {
                var s = BrushSettings(); s.pressureSize = false
                p.apply(to: &s)
                s.size = min(s.size, 40)
                let x0 = i % 2 == 0 ? 40.0 : 330.0
                stroke(d, id, s, path(y: 50 + Double(i / 2) * 90, x0: x0, x1: x0 + 230, wave: 12, pressure: taper), fg: [red, blue, green][i % 3], bg: RGBA(hex: "F1C40F")!)
            }
            save(d, "brush_presets_dynamic")
        }
        // ABR import → sampled tip
        do {
            let (d, id) = makeDoc()
            do {
                let tips = try ABRImporter.load(data: syntheticABR())
                let presets = BrushLibrary.shared.add(tips, persist: false)
                print("ABR imported \(tips.count) tip(s): \(tips.map { "\($0.name) \(Int($0.diameter))px spacing \($0.spacing)" })")
                if let p = presets.first {
                    var s = BrushSettings(); s.pressureSize = false
                    p.apply(to: &s)
                    s.size = 60
                    stroke(d, id, s, path(y: 60), fg: green)
                    s.spacing = 0.6
                    s.dynamics.shapeEnabled = true; s.dynamics.angleJitter = 1; s.sizeJitter = 0.5; s.dynamics.flipYJitter = true
                    s.dynamics.scatterEnabled = true; s.scatter = 0.8
                    s.dynamics.colorEnabled = true; s.dynamics.fgBgJitter = 1
                    stroke(d, id, s, path(y: 190), fg: green, bg: RGBA(hex: "8E6E1D")!)
                    s = BrushSettings(); s.pressureSize = false
                    p.apply(to: &s)
                    s.size = 30; s.dynamics.shapeEnabled = true; s.dynamics.angleControl.source = .direction; s.spacing = 0.3
                    stroke(d, id, s, path(y: 300, wave: 30), fg: red)
                    // the tip itself, big
                    s = BrushSettings(); s.pressureSize = false; p.apply(to: &s); s.size = 120
                    stroke(d, id, s, [PenSample(p: CGPoint(x: 520, y: 290))], fg: .black)
                }
            } catch { print("ABR FAIL \(error)") }
            save(d, "brush_abr_import")
            // Persistence roundtrip in a scratch directory (never the user's Application Support).
            let dir = out.appendingPathComponent("brushlib", isDirectory: true)
            try? FileManager.default.removeItem(at: dir)
            if let tips = try? ABRImporter.load(data: syntheticABR()) {
                let lib = BrushLibrary(directory: dir)
                let added = lib.add(tips)
                let reloaded = BrushLibrary(directory: dir)
                let same = reloaded.presets.map(\.name) == added.map(\.name)
                    && reloaded.presets.first.flatMap { reloaded.tipBuffer($0.tipID) }?.pngData() == tips[0].tip.pngData()
                print("Brush library roundtrip: \(reloaded.presets.count) preset(s), identical: \(same)")
                if let id = reloaded.presets.first?.id { reloaded.remove(id) }
                print("Brush library after delete: \(BrushLibrary(directory: dir).presets.count) preset(s)")
            }
        }
        // Eraser with dynamics on a filled layer (destination-out)
        do {
            let (d, id) = makeDoc()
            if let l = d.state.layer(id), let r = l.raster {
                r.buffer.context.setFillColor(blue.cgColor); r.buffer.context.fill(CGRect(x: 0, y: 0, width: 600, height: 360)); r.buffer.markDirty()
            }
            stroke(d, id, brush(size: 50, hardness: 0.7, spacing: 0.4, tip: "chalk") { s in
                s.dynamics.shapeEnabled = true; s.dynamics.angleJitter = 1; s.dynamics.scatterEnabled = true; s.scatter = 0.5; s.dynamics.count = 2 },
                   path(y: 120), blend: .destinationOut, paint: .fixed(.black))
            stroke(d, id, brush(size: 50, hardness: 1, spacing: 0.08) { s in s.dynamics.wetEdges = true }, path(y: 250), blend: .destinationOut, paint: .fixed(.black))
            save(d, "brush_eraser_dynamics")
        }
        // Brush Settings panel stroke preview
        do {
            var s = BrushSettings(); s.pressureSize = false
            BrushPreset.dynamicPresets[2].apply(to: &s)
            let img = BrushStrokePreview.render(s, width: 300, height: 80, scale: 2)
            let st = DocumentState(width: img.width, height: img.height)
            var st2 = st
            st2.layers = [Layer.raster(name: "p", buffer: PixelBuffer(cgImage: img))]
            SelfTest.save(st2, "brush_panel_preview", out)
        }
        renderPanels(out)
    }

    /// Renders the Brush Settings panel sections offscreen (AppKit-backed controls may render as placeholders).
    static func renderPanels(_ out: URL) {
        MainActor.assumeIsolated {
            var s = BrushSettings()
            BrushPreset.dynamicPresets[2].apply(to: &s)
            s.dynamics.textureEnabled = true; s.dynamics.dualEnabled = true; s.dynamics.transferEnabled = true
            for sec in [BrushSettingsSection.tipShape, .shape, .texture, .dual, .color] {
                let view = BrushSettingsEditor(settings: .constant(s), section: sec)
                    .padding(10).frame(width: 280).background(Theme.panelBG).environment(\.colorScheme, .dark)
                let r = ImageRenderer(content: view)
                r.scale = 2
                guard let img = r.cgImage else { print("panel render FAIL \(sec)"); continue }
                var st = DocumentState(width: img.width, height: img.height)
                st.layers = [Layer.raster(name: "p", buffer: PixelBuffer(cgImage: img))]
                SelfTest.save(st, "brush_panel_\(sec.rawValue.replacingOccurrences(of: " ", with: "_").lowercased())", out)
            }
        }
    }

    // MARK: Perf

    /// Dab + flush timings on a large layer (release builds are ~10x faster than debug).
    static func perf() {
        let W = 4000, H = 3000
        var st = DocumentState(width: W, height: H)
        let layer = Layer.raster(name: "Paint", width: W, height: H)
        st.layers = [layer]
        let d = Document(state: st, name: "brushperf")
        func t(_ label: String, _ f: () -> Void) {
            let s = CFAbsoluteTimeGetCurrent(); f(); print(label, String(format: "%.1f ms", (CFAbsoluteTimeGetCurrent() - s) * 1000))
        }
        func run(_ label: String, _ s: BrushSettings, events: Int = 60) {
            guard let stroke = PaintStroke(doc: d, layerID: layer.id, target: .content, opacity: 1, blend: .normal) else { return }
            let eng = BrushDynamicsEngine(settings: s, target: stroke.strokeBuf, origin: stroke.origin, paint: .dynamic(fg: .red, bg: .white), seed: 1)
            stroke.dynamics = eng
            eng.begin(PenSample(p: CGPoint(x: 500, y: 1500)))
            var dabs = 0
            t(label) {
                for i in 1...events {
                    // ~40px per event, like a fast drag
                    eng.move(PenSample(p: CGPoint(x: 500 + Double(i) * 40, y: 1500 + sin(Double(i) / 6) * 300), pressure: 0.8))
                    stroke.flush()
                    dabs += 1
                }
            }
            stroke.finish(name: "Brush")
            d.undo()
        }
        // Reference: the previous CoreGraphics path (cached colored dab image drawn per dab) on the same path.
        func legacy(_ label: String, size: Double, hardness: Double, spacing: Double) {
            guard let stroke = PaintStroke(doc: d, layerID: layer.id, target: .content, opacity: 1, blend: .normal) else { return }
            var placer = DabPlacer(spacing: max(1, size * spacing), smoothing: 0)
            let m = BrushTips.mask(diameter: size, hardness: hardness, roundness: 1, angle: 0, tipID: "round")!
            let dab = BrushTips.colored(m, color: .red)!
            for (p, _) in placer.begin(CGPoint(x: 500, y: 1500), pressure: 1) { stroke.dab(dab, at: p, alpha: 1) }
            t(label) {
                for i in 1...60 {
                    for (p, _) in placer.move(CGPoint(x: 500 + Double(i) * 40, y: 1500 + sin(Double(i) / 6) * 300), pressure: 0.8) { stroke.dab(dab, at: p, alpha: 1) }
                    stroke.flush()
                }
            }
            stroke.finish(name: "Brush")
            d.undo()
        }
        legacy("legacy CG 60px soft, 60 events", size: 60, hardness: 0.5, spacing: 0.12)
        legacy("legacy CG 300px soft, 60 events", size: 300, hardness: 0, spacing: 0.1)
        run("brush 60px soft, 60 events", brush(size: 60, hardness: 0.5, spacing: 0.12))
        run("brush 60px all per-dab dynamics", brush(size: 60, hardness: 0.5, spacing: 0.12) { s in
            s.sizeJitter = 0.5; s.scatter = 0.5; s.opacityJitter = 0.5
            s.dynamics.shapeEnabled = true; s.dynamics.angleJitter = 1; s.dynamics.roundnessJitter = 0.5
            s.dynamics.scatterEnabled = true; s.dynamics.count = 2
            s.dynamics.colorEnabled = true; s.dynamics.hueJitter = 0.5; s.dynamics.transferEnabled = true
            s.dynamics.textureEnabled = true })
        run("brush 60px chalk tip + angle jitter", brush(size: 60, spacing: 0.12, tip: "chalk") { s in s.dynamics.shapeEnabled = true; s.dynamics.angleJitter = 1 })
        run("brush 60px wet+dual+noise (stroke pass)", brush(size: 60, hardness: 0.5, spacing: 0.12) { s in
            s.dynamics.wetEdges = true; s.dynamics.noise = true; s.dynamics.dualEnabled = true })
        run("brush 300px soft, 60 events", brush(size: 300, hardness: 0, spacing: 0.1))
        run("brush 300px wet edges", brush(size: 300, hardness: 0.8, spacing: 0.1) { s in s.dynamics.wetEdges = true })
    }
}
