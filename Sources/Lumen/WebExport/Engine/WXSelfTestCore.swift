import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

// Engine-level self tests for the web-export module (no app types): unit tests for the deflate / PNG code,
// the lossless and perceptual comparison tables on the generated corpus, and inspection images
// (results, amplified difference maps, importance maps, magnified crops).

enum WXSelfTestCore {
    static var passed = 0
    static var failed = 0
    static var report: [String] = []

    static func check(_ ok: Bool, _ msg: String) {
        if ok { passed += 1 } else { failed += 1; say("FAIL webexport: \(msg)") }
    }

    static func say(_ s: String) { print(s); report.append(s) }

    static func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
        let c = s.count
        if c >= n { return s }
        let p = String(repeating: " ", count: n - c)
        return left ? p + s : s + p
    }

    static func num(_ v: Int, _ n: Int = 9) -> String { pad("\(v)", n, left: true) }
    static func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "   —  " : pad(String(format: "%+.1f%%", 100 * Double(a - b) / Double(b)), 7, left: true) }

    static func fmtQ(_ q: UPQuality) -> String {
        String(format: "SSIM %.4f  Q %.4f  maxΔE %4.1f  smoothΔE %4.2f  band %4.2f  edgeΔE %4.2f", q.ssim, q.q, q.maxDE, q.smoothDE, q.banding, q.edgeDE)
    }

    static func writePNG(_ img: UPImage, _ url: URL) {
        if let d = UPBridge.imageIOPNG(img) { try? d.write(to: url) }
    }

    // MARK: unit tests

    static func unitTests() {
        say("— unit tests: deflate, Huffman, validator")
        var seed: UInt64 = 88172645463325252
        func rnd() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        var cases: [(String, [UInt8])] = [("empty", []), ("one byte", [42]), ("two bytes", [1, 2]), ("1000 zeros", [UInt8](repeating: 0, count: 1000)),
                                         ("300k zeros", [UInt8](repeating: 0, count: 300_000))]
        cases.append(("random 70k", (0..<70_000).map { _ in UInt8(truncatingIfNeeded: rnd() >> 20) }))
        var text = [UInt8]()
        let words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "lumen", "ultra", "png", "deflate", "optimal"]
        while text.count < 120_000 { text.append(contentsOf: Array(words[Int(rnd() % UInt64(words.count))].utf8)); text.append(32) }
        cases.append(("text 120k", text))
        cases.append(("4 symbols 100k", (0..<100_000).map { _ in UInt8(rnd() % 4) }))
        cases.append(("period 300", (0..<90_000).map { UInt8(($0 % 300) & 255) }))
        cases.append(("70k then stored-size edge", (0..<65_536).map { _ in UInt8(truncatingIfNeeded: rnd() >> 24) }))
        for (name, d) in cases {
            let z9 = UPZlib.deflate(d, level: 9, strategy: Z_DEFAULT_STRATEGY)
            var o = UPUltraDeflateOptions(); o.iterations = 8
            let raw = d.withUnsafeBufferPointer { UPUltraDeflate.compress($0, options: o) }
            let z = d.withUnsafeBufferPointer { UPZlib.wrap(rawDeflate: raw, of: $0) }
            let back = UPZlib.inflate(z, expected: d.count)
            check(back == d, "ultra deflate round trip (\(name))")
            check(z.count <= z9.count + 1, "ultra deflate not larger than zlib -9 (\(name)): \(z.count) vs \(z9.count)")
        }
        // package-merge: Kraft sum must be exactly 1 and lengths within the limit
        let huff = UPHuffman()
        for trial in 0..<40 {
            let n = 2 + Int(rnd() % 286)
            var counts = [UInt32](repeating: 0, count: 288)
            for i in 0..<n { counts[i] = trial % 3 == 0 ? UInt32(1 + rnd() % 3) : UInt32(rnd() % (1 << (rnd() % 20))) }
            var len = [UInt8](repeating: 0, count: 288)
            let limit = trial % 2 == 0 ? 15 : 9
            if limit == 9 && counts.filter({ $0 > 0 }).count > 512 { continue }
            counts.withUnsafeBufferPointer { c in len.withUnsafeMutableBufferPointer { l in huff.lengths(c.baseAddress!, 288, maxBits: limit, out: l.baseAddress!) } }
            let used = (0..<288).filter { counts[$0] > 0 }
            var kraft = 0.0
            var ok = true
            for i in used { if len[i] == 0 || Int(len[i]) > limit { ok = false }; kraft += pow(2, -Double(len[i])) }
            if used.count >= 2 { check(ok && abs(kraft - 1) < 1e-9, "package-merge Kraft equality (n=\(used.count), limit \(limit), sum \(kraft))") }
        }
        // validator must reject damaged files
        let img = WXCorpus.nColors(40, 30, count: 50)
        if let r = UPLossless.encode(img) {
            check(UPValidator.validate(r.data).ok, "validator accepts a good file")
            var bad = [UInt8](r.data); bad[bad.count - 20] ^= 0x55
            check(!UPValidator.validate(Data(bad)).ok, "validator rejects a flipped byte (CRC)")
            var trunc = [UInt8](r.data); trunc.removeLast(12)
            check(!UPValidator.validate(Data(trunc)).ok, "validator rejects a missing IEND")
            var sig = [UInt8](r.data); sig[1] = 0x51
            check(!UPValidator.validate(Data(sig)).ok, "validator rejects a bad signature")
        } else { check(false, "encode for validator test") }
        // hidden RGB preserved on request
        var hidden = WXCorpus.nColors(24, 16, count: 40)
        for k in stride(from: 3, to: hidden.px.count, by: 12) { hidden.px[k] = 0 }
        var ko = UPLosslessOptions(); ko.reduce.keepHiddenRGB = true
        if let r = UPLossless.encode(hidden, options: ko), let d = UPValidator.validate(r.data).image {
            check(d.exactlyEqual(to: hidden), "keep-hidden-RGB option is bit exact under alpha 0")
        } else { check(false, "keep-hidden-RGB encode") }
        // ancillary chunks
        var ao = UPLosslessOptions()
        ao.ancillary = UPAncillary(icc: nil, srgbIntent: 0, gamma: nil, dpi: 144, text: [("Copyright", "© Lumen test")])
        if let r = UPLossless.encode(img, options: ao) {
            let v = UPValidator.validate(r.data)
            check(v.ok && v.chunks.contains("sRGB") && v.chunks.contains("pHYs") && v.chunks.contains("tEXt"), "ancillary chunks written in a valid order: \(v.chunks) \(v.errors)")
            if let src = CGImageSourceCreateWithData(r.data as CFData, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                check((p[kCGImagePropertyDPIWidth] as? Double).map { abs($0 - 144) < 0.5 } ?? false, "DPI survives (ImageIO reads \(p[kCGImagePropertyDPIWidth] ?? "nil"))")
            }
        }
    }

    // MARK: lossless table

    static func losslessTable(_ items: [WXCorpusItem], effort: UPEffort, out: URL) {
        say("")
        say("— LOSSLESS (effort: \(effort.title)) — sizes in bytes; (a) macOS ImageIO PNG, (b) zlib-9 best filter (OptiPNG-like), (c) Lumen Ultra lossless")
        say(pad("image", 26) + pad("size", 11) + pad("(a) ImageIO", 12, left: true) + pad("(b) zlib9", 10, left: true) + pad("(c) Ultra", 10, left: true) + pad("vs (a)", 8, left: true)
            + pad("vs (b)", 8, left: true) + pad("sec", 7, left: true) + "  representation | filter | deflate")
        var ta = 0, tb = 0, tc = 0
        for it in items {
            let want = UPReduce.canonical(it.image, keepHiddenRGB: false)
            let io = UPBridge.imageIOPNG(it.image)?.count ?? 0
            let opti = UPLossless.optiLikeBaseline(it.image)
            var o = UPLosslessOptions(); o.effort = effort
            guard let r = UPLossless.encode(it.image, options: o) else { check(false, "lossless encode \(it.name)"); continue }
            try? r.data.write(to: out.appendingPathComponent("lossless_\(it.name).png"))
            let v = UPValidator.validate(r.data)
            check(v.ok, "PNG structure valid (\(it.name)): \(v.errors)")
            check(v.width == it.image.width && v.height == it.image.height, "dimensions (\(it.name))")
            check(v.image?.visuallyIdentical(to: want) ?? false, "own decoder: bit-identical pixels (\(it.name))")
            check(r.verified, "encoder self-verification (\(it.name))")
            if let d = UPBridge.decode(r.data) {
                check(d.image.width == it.image.width && d.image.height == it.image.height, "ImageIO dimensions (\(it.name))")
                check(d.image.visuallyIdentical(to: want), "ImageIO decode: bit-identical pixels (\(it.name))\(d.exact ? "" : " [via premultiplied]")")
            } else { check(false, "ImageIO can decode (\(it.name))") }
            if let ob = opti {
                let ov = UPValidator.validate(ob)
                check(ov.ok && (ov.image?.visuallyIdentical(to: want) ?? false), "baseline (b) is itself valid and lossless (\(it.name))")
                check(r.data.count <= ob.count, "Ultra lossless ≤ zlib-9 baseline (\(it.name)): \(r.data.count) vs \(ob.count)")
            }
            check(r.data.count <= io || io == 0, "Ultra lossless ≤ ImageIO (\(it.name))")
            let oc = opti?.count ?? 0
            ta += io; tb += oc; tc += r.data.count
            say(pad(it.name, 26) + pad("\(it.image.width)×\(it.image.height)", 11) + num(io, 12) + num(oc, 10) + num(r.data.count, 10) + " " + pct(r.data.count, io) + " " + pct(r.data.count, oc)
                + pad(String(format: "%.2f", r.seconds), 7, left: true) + "  \(r.representation) | \(r.filter) | \(r.deflater)")
            if it.kind != .edge {
                say("      stages: " + r.stages.map { "\($0.name) \($0.bytes)" }.joined(separator: " → "))
            }
        }
        say(pad("TOTAL", 37) + num(ta, 12) + num(tb, 10) + num(tc, 10) + " " + pct(tc, ta) + " " + pct(tc, tb))
    }

    // MARK: perceptual table

    static func slug(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }) }

    /// Amplified per-pixel error (ΔE × 100 mapped through a heat ramp; 0 = black, ≥ 12 = white-hot).
    static func heatMap(_ err: [Float], _ w: Int, _ h: Int) -> UPImage {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let t = min(1, err[i] / 12)
            let r = min(1, t * 3), g = min(1, max(0, t * 3 - 1)), b = min(1, max(0, t * 3 - 2))
            px[i * 4] = UInt8(r * 255); px[i * 4 + 1] = UInt8(g * 255); px[i * 4 + 2] = UInt8(b * 255)
        }
        return UPImage(width: w, height: h, px: px)
    }

    static func importanceImage(_ m: UPPerceptualMaps) -> UPImage {
        var px = [UInt8](repeating: 255, count: m.width * m.height * 4)
        for i in 0..<(m.width * m.height) {
            px[i * 4] = UInt8(max(0, min(255, m.importance[i] * 255)))
            px[i * 4 + 1] = UInt8(max(0, min(255, m.texture[i] * 28)))
            px[i * 4 + 2] = UInt8(max(0, min(255, m.protect[i] * 255)))
        }
        return UPImage(width: m.width, height: m.height, px: px)
    }

    /// Side-by-side crops at `zoom`× (nearest neighbour) with labels; alpha shown over a checkerboard.
    static func montage(_ images: [(String, UPImage)], crop: (Int, Int, Int, Int), zoom: Int) -> UPImage {
        let (cx, cy, cw, ch) = crop
        let pad = 6, labelH = 16
        let W = images.count * (cw * zoom + pad) + pad, H = ch * zoom + pad * 2 + labelH
        let c = WXCorpus.context(W, H)
        c.setFillColor(WXCorpus.color(0x202020)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        for (k, (label, im)) in images.enumerated() {
            let ox = pad + k * (cw * zoom + pad), oy = pad + labelH
            for y in 0..<ch {
                for x in 0..<cw {
                    let sx = min(im.width - 1, cx + x), sy = min(im.height - 1, cy + y)
                    let o = (sy * im.width + sx) * 4
                    let a = CGFloat(im.px[o + 3]) / 255
                    let chk: CGFloat = ((x / 4 + y / 4) & 1) == 0 ? 0.62 : 0.85
                    c.setFillColor(CGColor(srgbRed: CGFloat(im.px[o]) / 255 * a + chk * (1 - a), green: CGFloat(im.px[o + 1]) / 255 * a + chk * (1 - a),
                                           blue: CGFloat(im.px[o + 2]) / 255 * a + chk * (1 - a), alpha: 1))
                    c.fill(CGRect(x: ox + x * zoom, y: oy + y * zoom, width: zoom, height: zoom))
                }
            }
            WXCorpus.text(c, label, x: CGFloat(ox), y: CGFloat(pad + 11), size: 11, color: WXCorpus.color(0xFFFFFF))
        }
        var out = WXCorpus.image(c)
        for i in stride(from: 3, to: out.px.count, by: 4) { out.px[i] = 255 }
        return out
    }

    /// The target "same measured quality as `q`" with a small, stated slack for measurement noise.
    static func matched(_ q: UPQuality, label: String) -> UPQualityTarget {
        UPQualityTarget(q: q.q - 0.0003, ssim: q.ssim - 0.003, smoothDE: q.smoothDE * 1.1 + 0.15, banding: q.banding * 1.1 + 0.15, edgeDE: q.edgeDE * 1.1 + 0.15, label: label)
    }

    static func perceptualTable(_ items: [WXCorpusItem], effort: UPEffort, out: URL, crops: [String: (Int, Int, Int, Int)] = [:]) {
        say("")
        say("— PERCEPTUAL ULTRA (effort: \(effort.title)) — (d) classic median-cut 256 + Floyd–Steinberg, zlib 9; (d+) the same with variance cut, k-means and serpentine (pngquant-like);")
        say("  (e) Lumen Perceptual Ultra at its presets and at the measured quality of (d+) [slack: Q −0.0003, SSIM −0.003; smoothΔE, band, edgeΔE ×1.1+0.15]")
        say("  Q = importance-weighted SSIM after a viewing-distance prefilter; smoothΔE = low-frequency colour error (99.8th pct.); band = false-contour step in smooth areas; edgeΔE = error on strong edges (95th pct.).")
        for it in items {
            let io = UPBridge.imageIOPNG(it.image)?.count ?? 0
            say("")
            say("\(it.name)  \(it.image.width)×\(it.image.height)   (a) ImageIO PNG \(io) B")
            let t0 = Date()
            let maps = UPImportance.maps(it.image)
            let tMaps = Date().timeIntervalSince(t0)
            let ref = UPMetricReference(it.image, importance: maps.importance)
            writePNG(importanceImage(maps), out.appendingPathComponent("maps_\(it.name).png"))
            var lo = UPLosslessOptions(); lo.effort = effort
            let lossless = UPLossless.encode(it.image, options: lo)
            say("  " + pad("(c) Ultra lossless", 30) + num(lossless?.data.count ?? 0) + "  " + pct(lossless?.data.count ?? 0, io) + String(format: "  %.2fs", lossless?.seconds ?? 0)
                + "   [maps \(String(format: "%.2fs", tMaps)): \(maps.notes.joined(separator: ", "))]")
            var tiles: [(String, UPImage)] = [("original", it.image)]
            var qd = UPQuality()
            var dPlusSize = 0
            if let b = UPBaseline.medianCutFS(it.image) {
                let v = UPValidator.validate(b.data)
                check(v.ok && (v.image?.visuallyIdentical(to: b.image) ?? false), "baseline (d) file valid (\(it.name))")
                say("  " + pad("(d) median-cut 256 + FS", 30) + num(b.data.count) + "  " + pct(b.data.count, io) + "  " + fmtQ(ref.compare(b.image)))
            }
            if let b = UPBaseline.medianCutFS(it.image, refined: true) {
                qd = ref.compare(b.image)
                dPlusSize = b.data.count
                say("  " + pad("(d+) + k-means (pngquant-like)", 30) + num(b.data.count) + "  " + pct(b.data.count, io) + "  " + fmtQ(qd))
                if let bu = UPLossless.encode(b.image, options: lo) {
                    say("  " + pad("(d+) re-packed by Ultra", 30) + num(bu.data.count) + "  " + pct(bu.data.count, io) + "  (same pixels as (d+); shows the encoder's share)")
                }
                try? b.data.write(to: out.appendingPathComponent("lossy_\(it.name)_baseline.png"))
                tiles.append(("(d+) \(b.data.count) B", b.image))
            }
            var targets = UPQualityTarget.presets
            targets.append(matched(qd, label: "= (d+) quality"))
            for t in targets {
                var o = UPLossyOptions(); o.target = t; o.effort = effort; o.maps = maps
                guard let r = UPLossy.encode(it.image, options: o) else { check(false, "perceptual encode \(it.name) \(t.label)"); continue }
                let v = UPValidator.validate(r.data)
                check(v.ok, "PNG structure valid (\(it.name), \(t.label)): \(v.errors)")
                check(v.width == it.image.width && v.height == it.image.height, "dimensions (\(it.name), \(t.label))")
                check(v.image?.visuallyIdentical(to: r.image) ?? false, "file decodes to the intended pixels (\(it.name), \(t.label))")
                var ioOK = false
                if let d = UPBridge.decode(r.data) { ioOK = d.image.visuallyIdentical(to: r.image) }
                check(ioOK, "ImageIO decodes the same pixels (\(it.name), \(t.label))")
                var emap: [Float] = []
                let q = r.mode == "lossless" ? UPQuality() : ref.compare(v.image ?? r.image, errorMap: &emap)
                check(t.met(by: q) || !r.targetMet, "quality target met (\(it.name), \(t.label)): \(fmtQ(q))")
                // alpha invariants: fully transparent stays transparent, fully opaque stays opaque
                if let dec = v.image {
                    var alphaOK = true
                    let src = UPReduce.canonical(it.image, keepHiddenRGB: false)
                    for i in stride(from: 3, to: src.px.count, by: 4) {
                        if src.px[i] == 0 && dec.px[i] != 0 { alphaOK = false; break }
                        if src.px[i] == 255 && dec.px[i] != 255 { alphaOK = false; break }
                    }
                    check(alphaOK, "transparent stays transparent / opaque stays opaque (\(it.name), \(t.label))")
                }
                let name = "(e) Ultra " + t.label
                let mode = r.mode == "palette" ? "palette \(r.colors)" : r.mode
                var line = "  " + pad(name, 30) + num(r.data.count) + "  " + pct(r.data.count, io) + "  " + fmtQ(q) + "  " + mode + String(format: "  %.2fs", r.seconds)
                if t.label.hasPrefix("=") { line += "   → vs (d+): " + pct(r.data.count, dPlusSize).trimmingCharacters(in: .whitespaces) + (r.targetMet ? "" : "  (target NOT reachable)") }
                say(line)
                try? r.data.write(to: out.appendingPathComponent("lossy_\(it.name)_\(slug(t.label)).png"))
                if !emap.isEmpty, t.label == "high" || t.label == "small" {
                    writePNG(heatMap(emap, it.image.width, it.image.height), out.appendingPathComponent("diff_\(it.name)_\(slug(t.label)).png"))
                }
                if t.label == "high" || t.label == "small" || t.label == "visually lossless" { tiles.append(("\(t.label) \(r.data.count) B", v.image ?? r.image)) }
            }
            if it.image.width >= 100 && it.image.height >= 80 {
                let crop = crops[it.name] ?? (it.image.width / 4, it.image.height / 4, min(110, it.image.width / 2), min(90, it.image.height / 2))
                writePNG(montage(tiles, crop: crop, zoom: 3), out.appendingPathComponent("zoom_\(it.name).png"))
            }
        }
    }

    // MARK: large image (tile-sampled search)

    static func bigImageTest(_ out: URL) {
        let path = "\(WXCorpus.picturesDir)/Sonoma.heic"
        guard FileManager.default.fileExists(atPath: path), let img = WXCorpus.systemPicture(path, maxSide: 2400) else { say("  (no large system picture available — big-image test skipped)"); return }
        say("")
        say("— LARGE IMAGE \(img.width)×\(img.height) (\(String(format: "%.1f", Double(img.width * img.height) / 1e6)) MP): settings searched on sample tiles, applied to the whole image")
        let io = UPBridge.imageIOPNG(img)?.count ?? 0
        var lf = UPLosslessOptions(); lf.effort = .fast
        if let l = UPLossless.encode(img, options: lf) {
            check(UPValidator.validate(l.data).image?.visuallyIdentical(to: img) ?? false, "large image lossless (fast) is bit-identical")
            say("  " + pad("(a) ImageIO PNG", 30) + num(io))
            say("  " + pad("(c) Ultra lossless, fast", 30) + num(l.data.count) + "  " + pct(l.data.count, io) + String(format: "  %.1fs", l.seconds) + "  \(l.representation) | \(l.filter) | \(l.deflater)")
        }
        for t in [UPQualityTarget.high, .medium] {
            var o = UPLossyOptions(); o.target = t; o.effort = .fast
            guard let r = UPLossy.encode(img, options: o) else { check(false, "large image perceptual encode"); continue }
            let v = UPValidator.validate(r.data)
            check(v.ok && (v.image?.visuallyIdentical(to: r.image) ?? false), "large image file valid and decodes to the intended pixels (\(t.label))")
            say("  " + pad("(e) Ultra " + t.label + ", fast", 30) + num(r.data.count) + "  " + pct(r.data.count, io) + "  " + fmtQ(r.quality) + "  " + (r.mode == "palette" ? "palette \(r.colors)" : r.mode) + String(format: "  %.1fs", r.seconds))
            try? r.data.write(to: out.appendingPathComponent("lossy_big_\(slug(t.label)).png"))
        }
    }

    // MARK: other formats

    static func formatsTests(_ items: [WXCorpusItem], effort: UPEffort, out: URL) {
        say("")
        say("— OTHER WEB FORMATS — encoders on this Mac: " + WXFormatKind.allCases.filter { WXEncoders.available($0) }.map(\.rawValue).joined(separator: ", "))
        for n in WXEncoders.unavailableNotes { say("  not available: " + n) }
        // own JPEG encoder: must decode with ImageIO, in all four modes and on awkward sizes
        for (w, h) in [(1, 1), (7, 5), (16, 16), (17, 33), (64, 48), (129, 67)] {
            var im = WXCorpus.syntheticPhoto(max(8, w), max(8, h))
            if w < 8 || h < 8 { im = WXResample.scaled(WXCorpus.syntheticPhoto(64, 64 * h / max(1, w) + 8), width: w); im = UPImage(width: w, height: h, px: Array(im.px[0..<(w * h * 4)])) }
            for sub in [WXJPEG.Subsampling.s444, .s420] {
                for prog in [false, true] {
                    guard let d = WXJPEG.encode(im, quality: 85, subsampling: sub, progressive: prog), let dec = WXEncoders.decode(d) else {
                        check(false, "JPEG \(w)×\(h) \(sub) progressive \(prog) decodes with ImageIO"); continue
                    }
                    check(dec.width == w && dec.height == h, "JPEG dimensions \(w)×\(h) \(sub) progressive \(prog)")
                    if w >= 16 && h >= 16 {
                        let q = UPMetricReference(im).compare(dec)
                        check(q.psnr > 30, "JPEG \(w)×\(h) \(sub) progressive \(prog) PSNR \(String(format: "%.1f", q.psnr)) dB")
                    }
                }
            }
        }
        let gray = WXCorpus.grayRamp(120, 60, alpha: false)
        if let d = WXJPEG.encode(gray, quality: 90, subsampling: .s420, progressive: true), let dec = WXEncoders.decode(d) {
            check(UPMetricReference(gray).compare(dec).psnr > 34, "grayscale JPEG (single component) decodes correctly")
        } else { check(false, "grayscale JPEG") }
        // assistant table
        for it in items {
            say("")
            say("\(it.name)  \(it.image.width)×\(it.image.height) — every format tuned to the “high” target")
            let maps = UPImportance.maps(it.image)
            let ref = UPMetricReference(it.image, importance: maps.importance)
            var o = WXAssistantOptions(); o.effort = effort; o.maps = maps; o.target = .high
            let list = WXAssistant.run(it.image, options: o)
            let win = WXAssistant.winner(list, hasAlpha: it.image.hasAlpha)
            for c in list {
                let okDims = c.decoded.map { $0.width == it.image.width && $0.height == it.image.height } ?? false
                check(okDims, "\(c.kind.rawValue) decodes at the right size (\(it.name))")
                if let dec = WXEncoders.decode(c.data) { check(dec.width == it.image.width, "\(c.kind.rawValue) file readable by ImageIO (\(it.name))") }
                else { check(false, "\(c.kind.rawValue) file readable by ImageIO (\(it.name))") }
                let t = WXTransfer.estimate(c.data, mime: c.kind.mime)
                say("  " + (c.id == win?.id ? "★ " : "  ") + pad(c.kind.rawValue, 24) + num(c.totalBytes) + "  " + (c.lossless ? pad("lossless", 70) : pad(String(format: "SSIM %.4f  Q %.4f  smoothΔE %4.2f  band %4.2f  edgeΔE %4.2f", c.quality.ssim, c.quality.q, c.quality.smoothDE, c.quality.banding, c.quality.edgeDE), 70))
                    + (c.targetMet ? "  " : " ✗") + pad(c.setting, 44) + String(format: "%5.2fs", c.seconds) + "  data-URI \(t.dataURI) B")
                try? c.data.write(to: out.appendingPathComponent("fmt_\(it.name)_\(slug(c.kind.rawValue)).\(c.kind.ext)"))
                for e in c.extra { try? e.data.write(to: out.appendingPathComponent("fmt_\(it.name)_\(slug(c.kind.rawValue))\(e.suffix)")) }
            }
            // ImageIO's own JPEG at the same target, to show what the custom encoder buys
            let flat = WXEncoders.flatten(it.image)
            let refFlat = it.image.hasAlpha ? UPMetricReference(flat, importance: maps.importance) : ref
            if let io = WXAssistant.searchQuality(.high, ref: refFlat, encode: { WXEncoders.imageIO(flat, type: UTType.jpeg.identifier, q: $0) }),
               let mine = list.first(where: { $0.kind == .jpeg }) {
                say("    JPEG by ImageIO at the same target: \(io.data.count) B (\(WXJPEG.describe(io.data)), quality \(Int(io.q * 100)))  → Lumen JPEG " + pct(mine.data.count, io.data.count).trimmingCharacters(in: .whitespaces))
            }
        }
        // transfer estimates
        let sample = Data((0..<3000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let te = WXTransfer.estimate(sample, mime: "image/png")
        check(te.dataURI == 22 + 4 * ((3000 + 2) / 3), "data-URI length formula")
        check(te.gzip > 0 && te.brotli > 0 && te.dataURIGzip > 0 && te.dataURIBrotli > 0, "gzip / Brotli estimates")
        // gradient detector
        if let g = WXGradientDetector.detect(WXCorpus.cssGradient()) {
            check(g.css.contains("linear-gradient(to bottom") && g.maxError <= 4, "CSS gradient detected: \(g.css)")
            say("  gradient detector: \(g.css)   (max error \(String(format: "%.1f", g.maxError)) levels)")
        } else { check(false, "linear gradient detected") }
        if let g = WXGradientDetector.detect(WXCorpus.solid(40, 30, 36, 120, 200, 255)) { check(g.css == "background: #2478c8;", "flat colour detected: \(g.css)") } else { check(false, "flat colour detected") }
        check(WXGradientDetector.detect(WXCorpus.screenshot(200, 120)) == nil, "screenshot is not reported as a gradient")
        check(WXGradientDetector.detect(WXCorpus.syntheticPhoto(96, 64)) == nil, "photo is not reported as a gradient")
        check(WXGradientDetector.detect(WXCorpus.gradient(200, 120)) == nil, "gradient + radial glow is not reported as a plain linear gradient")
        // responsive set + <picture>
        var ro = WXResponsiveOptions()
        ro.displayWidth = 160; ro.densities = [1, 2]; ro.formats = [.avif, .jpeg, .ultraPNG]; ro.baseName = "hero"; ro.effort = .fast
        let set = WXResponsive.build(WXCorpus.screenshot(400, 250), options: ro)
        check(set.files.count >= 4 && set.html.contains("<picture>") && set.html.contains("hero-160.") && set.html.contains("hero-320.") && set.html.contains(" 2x"), "responsive set + <picture> markup")
        for f in set.files { check(WXEncoders.decode(f.data)?.width == f.width, "responsive variant \(f.name) has width \(f.width)") }
        say("  responsive set (\(set.files.count) files, \(set.totalBytes) B):")
        for l in set.html.split(separator: "\n") { say("    " + l) }
        try? set.html.write(to: out.appendingPathComponent("picture_snippet.html"), atomically: true, encoding: .utf8)
        check(WXResponsive.downscaleSuggestion(sourceWidth: 4000, displayWidth: 800) == 1600 && WXResponsive.downscaleSuggestion(sourceWidth: 1500, displayWidth: 800) == nil, "downscale suggestion")
    }

    static func run(_ out: URL, large: Bool, effort: UPEffort, only: String? = nil) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let t0 = Date()
        var items = WXCorpus.build(large: large)
        if let f = only { items = items.filter { $0.name.contains(f) } }
        if only == nil { unitTests() }
        losslessTable(items, effort: effort, out: out)
        let crops: [String: (Int, Int, Int, Int)] = ["logo_alpha": (30, 40, 120, 90), "shadow_alpha": (60, 170, 120, 90), "screenshot": (150, 36, 120, 90),
                                                     "gradient": (60, 40, 120, 90), "photo_text": (0, 270, 120, 86)]
        perceptualTable(items.filter { $0.lossy && $0.image.width * $0.image.height >= 64 }, effort: effort, out: out, crops: crops)
        if large && only == nil { bigImageTest(out) }
        formatsTests(items.filter { ["logo_alpha", "screenshot", "photo_big_sur_coastline", "photo_synthetic", "photo_text"].contains($0.name) }, effort: effort == .maximum ? .thorough : effort, out: out)
        say("")
        say(String(format: "webexport engine: %d passed, %d failed (%.1fs)", passed, failed, Date().timeIntervalSince(t0)))
    }
}
