import AppKit
import CoreImage
import ImageCratCore

/// Self-test cases for per-range Hue/Saturation, Replace Color, Match Color, HDR Toning and Levels/Curves eyedroppers.
enum AdjustSelfTest {
    static func buffer(_ w: Int, _ h: Int, _ f: (Int, Int) -> RGBA) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let c = f(x, y)
                let o = y * b.bytesPerRow + x * 4
                let a = clamp(c.a, 0, 1)
                p[o] = UInt8(clamp(c.r, 0, 1) * a * 255 + 0.5); p[o + 1] = UInt8(clamp(c.g, 0, 1) * a * 255 + 0.5)
                p[o + 2] = UInt8(clamp(c.b, 0, 1) * a * 255 + 0.5); p[o + 3] = UInt8(a * 255 + 0.5)
            }
        }
        b.markDirty()
        return b
    }

    static func state(_ b: PixelBuffer) -> DocumentState {
        var st = DocumentState(width: b.width, height: b.height)
        st.layers = [Layer.raster(name: "Background", buffer: b)]
        return st
    }

    static func applied(_ b: PixelBuffer, _ f: (CIImage) -> CIImage) -> PixelBuffer {
        let sp = CanvasSpace(width: b.width, height: b.height)
        return RenderEngine.renderBuffer(f(sp.place(b, at: .zero)), docRect: IRect(x: 0, y: 0, width: b.width, height: b.height), space: sp)
    }

    static func px(_ b: PixelBuffer, _ x: Int, _ y: Int) -> String {
        let p = b.pixel(x, y)
        return "(\(p.0),\(p.1),\(p.2))"
    }

    static func save(_ b: PixelBuffer, _ name: String, _ out: URL) { SelfTest.save(state(b), name, out) }

    static func noise(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        return Double(h & 0xFFFF) / 65535
    }

    static func run(_ out: URL) {
        hueSatRanges(out)
        replaceColor(out)
        matchColor(out)
        hdrToning(out)
        eyedroppers(out)
        codable()
    }

    // MARK: Hue/Saturation per range

    static func hueSatRanges(_ out: URL) {
        let W = 480, H = 300
        let src = buffer(W, H) { x, y in
            if y < 200 { return RGBA(h: Double(x) / Double(W), s: 1 - Double(y) / 200 * 0.8, v: 1) }
            return RGBA(gray: Double(x) / Double(W - 1))
        }
        save(src, "hsr_source", out)
        var s = AdjustmentSettings(kind: .hueSaturation)
        s.hsRanges[0].hue = 120          // reds → greens only
        let reds = applied(src) { AdjustmentEngine.apply(s, to: $0) }
        save(reds, "hsr_reds_hue120", out)
        print("hsr reds: red \(px(src, 0, 10))→\(px(reds, 0, 10)) yellow \(px(src, 80, 10))→\(px(reds, 80, 10)) blue \(px(src, 320, 10))→\(px(reds, 320, 10)) gray \(px(src, 240, 250))→\(px(reds, 240, 250))")
        var s2 = AdjustmentSettings(kind: .hueSaturation)
        s2.hsRanges[4].saturation = -100  // blues desaturated
        s2.hsRanges[2].lightness = 60     // greens lighter
        save(applied(src) { AdjustmentEngine.apply(s2, to: $0) }, "hsr_blues_desat_greens_light", out)
        var s3 = AdjustmentSettings(kind: .hueSaturation)
        s3.hsRanges[0].hue = 120
        s3.hsRanges[0].range = [330, 350, 10, 30]   // narrower red range
        save(applied(src) { AdjustmentEngine.apply(s3, to: $0) }, "hsr_reds_narrow", out)
        // master path unchanged vs. legacy look
        var m = AdjustmentSettings(kind: .hueSaturation)
        m.hue = 60; m.hsSaturation = 40
        save(applied(src) { AdjustmentEngine.apply(m, to: $0) }, "hsr_master_hue60_sat40", out)
        var cz = AdjustmentSettings(kind: .hueSaturation)
        cz.colorize = true; cz.hue = 30; cz.hsSaturation = 20
        save(applied(src) { AdjustmentEngine.apply(cz, to: $0) }, "hsr_colorize", out)
    }

    // MARK: Replace Color

    static func replaceColor(_ out: URL) {
        let W = 480, H = 300
        let red = RGBA(hex: "D62828")!, blue = RGBA(hex: "1D4E89")!, orange = RGBA(hex: "F77F00")!
        func inCircle(_ x: Int, _ y: Int, _ cx: Int, _ cy: Int, _ r: Int) -> Bool { (x - cx) * (x - cx) + (y - cy) * (y - cy) < r * r }
        let src = buffer(W, H) { x, y in
            if inCircle(x, y, 90, 100, 60) || inCircle(x, y, 390, 210, 50) {
                let shade = 0.75 + 0.25 * Double(y % 60) / 60
                return RGBA(r: red.r * shade, g: red.g * shade, b: red.b * shade)
            }
            if inCircle(x, y, 240, 100, 55) { return blue }
            if inCircle(x, y, 240, 230, 50) { return orange }
            return RGBA(gray: 0.35 + 0.4 * Double(x) / Double(W))
        }
        save(src, "rc_source", out)
        let sp = CanvasSpace(width: W, height: H)
        let d = Document(state: state(src), name: "rc")
        guard let c = AdjustmentSampling.layerColor(d, at: CGPoint(x: 90, y: 100)) else { print("rc FAIL sample"); return }
        var r = ReplaceColorSettings()
        r.colors = [c]; r.points = [sp.ciPoint(CGPoint(x: 90, y: 100))]; r.canvasSize = Double(W)
        r.fuzziness = 60; r.hue = 180
        let img = sp.place(src, at: .zero)
        save(RenderEngine.renderBuffer(AdjustmentEngine.replaceColorMask(r, img), docRect: IRect(x: 0, y: 0, width: W, height: H), space: sp), "rc_mask", out)
        var s = AdjustmentSettings(kind: .replaceColor); s.replace = r
        let res = applied(src) { AdjustmentEngine.apply(s, to: $0) }
        save(res, "rc_red_to_cyan", out)
        print("rc sampled \(c) red \(px(src, 90, 100))→\(px(res, 90, 100)) blue \(px(res, 240, 100)) orange \(px(src, 240, 230))→\(px(res, 240, 230)) bg \(px(src, 20, 280))→\(px(res, 20, 280))")
        // localized: only the left red circle
        s.replace.localized = true; s.replace.rangePercent = 40
        let loc = applied(src) { AdjustmentEngine.apply(s, to: $0) }
        save(loc, "rc_localized", out)
        print("rc localized left \(px(loc, 90, 100)) right \(px(loc, 390, 210))")
        // add + subtract: add orange, subtract nothing; lightness down
        var s2 = AdjustmentSettings(kind: .replaceColor)
        s2.replace = r; s2.replace.hue = 0; s2.replace.saturation = -100; s2.replace.lightness = -30
        if let o = AdjustmentSampling.layerColor(d, at: CGPoint(x: 240, y: 230)) { s2.replace.colors.append(o) }
        save(applied(src) { AdjustmentEngine.apply(s2, to: $0) }, "rc_add_desat", out)
    }

    // MARK: Match Color

    static func matchColor(_ out: URL) {
        let W = 480, H = 300
        // target: cool bluish daylight scene
        let target = buffer(W, H) { x, y in
            let n = noise(x / 6, y / 6) * 0.08
            if y < 150 { let t = Double(y) / 150; return RGBA(r: 0.35 + 0.3 * t + n, g: 0.55 + 0.25 * t + n, b: 0.9 - 0.05 * t + n) }
            let t = Double(y - 150) / 150
            if (x / 40 + y / 40) % 3 == 0 { return RGBA(r: 0.5 + n, g: 0.5 + n, b: 0.55 + n) }
            return RGBA(r: 0.2 + 0.1 * t + n, g: 0.45 - 0.15 * t + n, b: 0.3 - 0.1 * t + n)
        }
        // source: warm sunset
        let source = buffer(W, H) { x, y in
            let t = Double(y) / Double(H)
            let n = noise(x / 5, y / 5) * 0.06
            return RGBA(r: 0.95 - 0.4 * t + n, g: 0.55 - 0.35 * t + n, b: 0.25 + 0.2 * t + n)
        }
        save(target, "mc_target", out)
        save(source, "mc_source", out)
        let sp = CanvasSpace(width: W, height: H)
        guard let ts = ColorStats.lab(sp.place(target, at: .zero)), let ss = ColorStats.lab(sp.place(source, at: .zero)) else { print("mc FAIL stats"); return }
        print("mc target stats \(ts.mean.map { Int($0) }) ± \(ts.std.map { Int($0) }); source \(ss.mean.map { Int($0) }) ± \(ss.std.map { Int($0) })")
        var s = AdjustmentSettings(kind: .matchColor)
        s.match.target = ts; s.match.source = ss
        let res = applied(target) { AdjustmentEngine.apply(s, to: $0) }
        save(res, "mc_result", out)
        if let rs = ColorStats.lab(sp.place(res, at: .zero)) { print("mc result stats \(rs.mean.map { Int($0) }) ± \(rs.std.map { Int($0) })") }
        s.match.fade = 50
        save(applied(target) { AdjustmentEngine.apply(s, to: $0) }, "mc_result_fade50", out)
        s.match.fade = 0; s.match.intensity = 160; s.match.luminance = 120
        save(applied(target) { AdjustmentEngine.apply(s, to: $0) }, "mc_result_int160_lum120", out)
        // neutralize with no source: removes the cast of the target
        var n = AdjustmentSettings(kind: .matchColor)
        n.match.target = ts; n.match.neutralize = true
        let neu = applied(target) { AdjustmentEngine.apply(n, to: $0) }
        save(neu, "mc_neutralize", out)
        if let ns = ColorStats.lab(sp.place(neu, at: .zero)) { print("mc neutralized mean \(ns.mean.map { Int($0) })") }
    }

    // MARK: HDR Toning

    static func hdrToning(_ out: URL) {
        let W = 480, H = 300
        let src = buffer(W, H) { x, y in
            let n = noise(x / 3, y / 3)
            if y < 130 {
                // bright sky with faint clouds
                let cloud = 0.04 * sin(Double(x) / 23 + Double(y) / 17) + 0.02 * n
                return RGBA(r: 0.86 + cloud, g: 0.9 + cloud, b: 0.97 + cloud * 0.5)
            }
            // dark foreground with low-contrast texture (bricks)
            let brick = ((y / 16) % 2 == 0 ? x : x + 20) % 40 < 38 && y % 16 < 14
            let base = brick ? 0.09 : 0.05
            let v = base + 0.03 * n
            return RGBA(r: v * 1.2, g: v, b: v * 0.8)
        }
        save(src, "hdr_source", out)
        var s = AdjustmentSettings(kind: .hdrToning)
        let a = applied(src) { AdjustmentEngine.apply(s, to: $0) }
        save(a, "hdr_default", out)
        print("hdr default: sky \(px(src, 200, 60))→\(px(a, 200, 60)) brick \(px(src, 10, 200))→\(px(a, 10, 200)) mortar \(px(src, 10, 190))→\(px(a, 10, 190))")
        s.hdr.detail = 150; s.hdr.radius = 60; s.hdr.shadow = 40; s.hdr.highlight = -30; s.hdr.saturation = 40
        save(applied(src) { AdjustmentEngine.apply(s, to: $0) }, "hdr_strong", out)
        s.hdr.useCurve = true; s.hdr.curve.points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.85), CGPoint(x: 1, y: 1)]
        save(applied(src) { AdjustmentEngine.apply(s, to: $0) }, "hdr_strong_curve", out)
        var e = AdjustmentSettings(kind: .hdrToning)
        e.hdr.method = .exposureGamma; e.hdr.exposure = 1.5; e.hdr.gamma = 1.3
        save(applied(src) { AdjustmentEngine.apply(e, to: $0) }, "hdr_exposure_gamma", out)
        e.hdr.method = .highlightCompression
        save(applied(src) { AdjustmentEngine.apply(e, to: $0) }, "hdr_highlight_compression", out)
    }

    // MARK: Eyedroppers

    static func eyedroppers(_ out: URL) {
        let W = 480, H = 300
        // warm cast + lifted blacks + dimmed whites
        func cast(_ v: Double) -> RGBA { RGBA(r: 0.12 + pow(v, 0.75) * 0.8, g: 0.07 + v * 0.72, b: 0.03 + pow(v, 1.35) * 0.55) }
        let src = buffer(W, H) { x, y in
            if y > 220 { return cast(Double(x) / Double(W - 1)) }
            if x >= 40 && x < 120 && y >= 60 && y < 160 { return cast(0) }        // black patch
            if x >= 200 && x < 280 && y >= 60 && y < 160 { return cast(0.5) }     // gray patch
            if x >= 360 && x < 440 && y >= 60 && y < 160 { return cast(1) }       // white patch
            let n = noise(x / 8, y / 8)
            return cast(0.25 + 0.5 * n)
        }
        save(src, "dropper_source", out)
        let d = Document(state: state(src), name: "drop")
        guard let bk = AdjustmentSampling.compositeColor(d, at: CGPoint(x: 80, y: 100)),
              let gr = AdjustmentSampling.compositeColor(d, at: CGPoint(x: 240, y: 100)),
              let wh = AdjustmentSampling.compositeColor(d, at: CGPoint(x: 400, y: 100)) else { print("dropper FAIL sample"); return }
        var s = AdjustmentSettings(kind: .levels)
        AdjustmentDroppers.applyLevels(.black, color: bk, to: &s)
        AdjustmentDroppers.applyLevels(.white, color: wh, to: &s)
        AdjustmentDroppers.applyLevels(.gray, color: gr, to: &s)
        print("levels droppers: " + (1...3).map { "ch\($0) in \(Int(s.levels[$0].inBlack))-\(Int(s.levels[$0].inWhite)) γ\(String(format: "%.2f", s.levels[$0].gamma))" }.joined(separator: ", "))
        let lv = applied(src) { AdjustmentEngine.apply(s, to: $0) }
        save(lv, "dropper_levels", out)
        print("levels result black \(px(lv, 80, 100)) gray \(px(lv, 240, 100)) white \(px(lv, 400, 100))")
        var c = AdjustmentSettings(kind: .curves)
        AdjustmentDroppers.applyCurves(.black, color: bk, to: &c)
        AdjustmentDroppers.applyCurves(.white, color: wh, to: &c)
        AdjustmentDroppers.applyCurves(.gray, color: gr, to: &c)
        let cv = applied(src) { AdjustmentEngine.apply(c, to: $0) }
        save(cv, "dropper_curves", out)
        print("curves result black \(px(cv, 80, 100)) gray \(px(cv, 240, 100)) white \(px(cv, 400, 100))")
        // Adjustment layer: sampling must ignore the (active) adjustment layer itself
        var st = state(src)
        var adj = Layer(name: "Inv", content: .adjustment(AdjustmentSettings(kind: .invert)))
        adj.opacity = 1
        st.layers.append(adj)
        let d2 = Document(state: st, name: "drop2")
        d2.activeLayerID = adj.id
        if let c2 = AdjustmentSampling.compositeColor(d2, at: CGPoint(x: 400, y: 100)) { print("under-adjustment sample (expect ≈ white patch, not inverted): \(c2)") }
        var ac = AdjustmentSettings(kind: .curves)
        AdjustmentDroppers.autoCurves(Histogram.compute(src), &ac)
        save(applied(src) { AdjustmentEngine.apply(ac, to: $0) }, "dropper_curves_auto", out)
    }

    // MARK: Codable tolerance

    static func codable() {
        // An "old" adjustment payload without any of the new keys must still decode.
        let old = #"{"kind":"hueSaturation","hue":30,"hsSaturation":10,"lightness":0,"colorize":false}"#
        do {
            let s = try JSONDecoder().decode(AdjustmentSettings.self, from: Data(old.utf8))
            print("codable old ok: hue \(s.hue) ranges \(s.hsRanges.count) levels \(s.levels.count) fuzz \(s.replace.fuzziness)")
            var n = AdjustmentSettings(kind: .replaceColor)
            n.replace.colors = [.red]; n.hsRanges[1].hue = 12; n.hdr.method = .exposureGamma; n.match.source = LabStats()
            let back = try JSONDecoder().decode(AdjustmentSettings.self, from: try JSONEncoder().encode(n))
            print("codable roundtrip \(back == n ? "ok" : "MISMATCH")")
        } catch { print("codable FAIL \(error)") }
    }
}
