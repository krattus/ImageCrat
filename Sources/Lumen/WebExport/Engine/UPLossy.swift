import Foundation
import zlib

// Lumen Ultra PNG — "Perceptual Ultra" orchestration: importance maps → smallest palette / RD setting that meets the
// quality target → (fallback) true-colour near-lossless → lossless Ultra encoding of the winner.

enum UPLossyTools {
    /// Quick PNG-8 size (filter none, zlib) used while searching; the final file goes through the full lossless pipeline.
    static func quickSize(_ ix: UPIndexed, level: Int32 = 6) -> Int {
        let k = ix.palette.count
        let bits = k <= 2 ? 1 : (k <= 4 ? 2 : (k <= 16 ? 4 : 8))
        let raw = UPReduce.pack(ix.indices, ix.width, ix.height, bits)
        let rep = UPRep(width: ix.width, height: ix.height, colorType: 3, bitDepth: UInt8(bits), palette: ix.palette.colors, raw: raw)
        let f = UPFilter.choose(rep, strategy: .fixed(0), cleanAlpha: false)
        let z = f.stream.withUnsafeBufferPointer { UPZlib.deflatedSize($0, level: level) }
        let translucent = ix.palette.colors.filter { $0 >> 24 != 255 }.count
        return 57 + 12 + k * 3 + (translucent > 0 ? 12 + translucent : 0) + z
    }
}

struct UPLossyOptions {
    var target: UPQualityTarget = .high
    /// Upper bound for the palette size (2…256); the encoder picks the smallest count that meets the target.
    var maxColors = 256
    var effort: UPEffort = .thorough
    var importance = UPImportanceOptions()
    var allowPalette = true
    var allowTrueColor = true
    var dithering = true
    var ancillary = UPAncillary()
    /// Precomputed maps (the dialog computes them once and reuses them while the sliders move).
    var maps: UPPerceptualMaps? = nil
    /// Search only, skip the final heavy lossless pass (used for live previews).
    var previewOnly = false
    /// Called as soon as the search has chosen the pixels, before the final lossless packing: (image, quality,
    /// estimated bytes, mode, colours, target met).
    var onPreview: ((UPImage, UPQuality, Int, String, Int, Bool) -> Void)? = nil
}

struct UPLossyResult {
    var data: Data
    /// What the file decodes to.
    var image: UPImage
    var quality: UPQuality
    var mode: String
    var colors: Int
    var targetMet: Bool
    var maps: UPPerceptualMaps
    var seconds: Double
    var detail: String
    var encoder: UPEncodeResult?
}

enum UPLossy {
    static let ladder = [2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256]

    private struct Candidate {
        var indexed: UPIndexed
        var quality: UPQuality
        var size: Int
        var label: String
        var colors = 0
        var params = UPDitherParams()
    }

    /// Images above this pixel count are searched on a mosaic of representative tiles (then encoded in full).
    static let proxyThreshold = 3_000_000

    /// A mosaic of the most informative 384-px tiles (salient ones first, then an even spread) with its maps.
    static func proxy(_ img: UPImage, _ maps: UPPerceptualMaps) -> (UPImage, UPPerceptualMaps) {
        let t = 384, cols = 4, rows = 3
        let w = img.width, h = img.height
        guard w >= t * 2, h >= t * 2 else { return (img, maps) }
        let gx = w / t, gy = h / t
        var scored: [(Float, Int, Int)] = []
        for ty in 0..<gy {
            for tx in 0..<gx {
                var s: Float = 0
                for y in stride(from: ty * t, to: ty * t + t, by: 8) { for x in stride(from: tx * t, to: tx * t + t, by: 8) { s += maps.importance[y * w + x] } }
                scored.append((s, tx, ty))
            }
        }
        var chosen: [(Int, Int)] = []
        func add(_ tx: Int, _ ty: Int) { if !chosen.contains(where: { $0.0 == tx && $0.1 == ty }) && chosen.count < cols * rows { chosen.append((tx, ty)) } }
        for e in scored.sorted(by: { $0.0 > $1.0 }).prefix(cols * rows / 2) { add(e.1, e.2) }
        // even spread over the rest of the picture
        var k = 0
        while chosen.count < min(cols * rows, scored.count) && k < scored.count * 4 {
            let i = (k * 7919 + 3) % scored.count
            add(scored[i].1, scored[i].2)
            k += 1
        }
        let pw = cols * t, ph = ((chosen.count + cols - 1) / cols) * t
        var out = UPImage(width: pw, height: ph, px: [UInt8](repeating: 255, count: pw * ph * 4))
        var m = UPPerceptualMaps(width: pw, height: ph, importance: [Float](repeating: 0, count: pw * ph), texture: [Float](repeating: 0, count: pw * ph),
                                 edge: [Float](repeating: 0, count: pw * ph), protect: [Float](repeating: 0, count: pw * ph), notes: maps.notes)
        for (ci, c) in chosen.enumerated() {
            let ox = (ci % cols) * t, oy = (ci / cols) * t
            for y in 0..<t {
                let sy = c.1 * t + y
                for x in 0..<t {
                    let si = sy * w + c.0 * t + x, di = (oy + y) * pw + ox + x
                    out.px[di * 4] = img.px[si * 4]; out.px[di * 4 + 1] = img.px[si * 4 + 1]; out.px[di * 4 + 2] = img.px[si * 4 + 2]; out.px[di * 4 + 3] = img.px[si * 4 + 3]
                    m.importance[di] = maps.importance[si]; m.texture[di] = maps.texture[si]; m.edge[di] = maps.edge[si]; m.protect[di] = maps.protect[si]
                }
            }
        }
        return (out, m)
    }

    static func encode(_ source: UPImage, options o: UPLossyOptions = UPLossyOptions(), progress: UPProgress? = nil) -> UPLossyResult? {
        let t0 = Date()
        let img = UPReduce.canonical(source, keepHiddenRGB: false)
        guard img.px16 == nil else {
            // deep images: fold to 8 bits first (the lossy paths are 8-bit); the fold itself is below any visibility threshold
            var eight = UPImage(width: img.width, height: img.height, px: img.px)
            eight.iccProfile = img.iccProfile; eight.dpi = img.dpi
            return encode(eight, options: o, progress: progress)
        }
        let n = img.width * img.height
        progress?.report(0.01, "Importance map")
        let maps = o.maps ?? UPImportance.maps(img, options: o.importance)
        // big images: the parameter search runs on a mosaic of representative tiles, the result is applied to the whole image
        let big = n > proxyThreshold
        let (sImg, sMaps) = big ? proxy(img, maps) : (img, maps)
        let ref = UPMetricReference(sImg, importance: sMaps.importance)
        if progress?.cancelled == true { return nil }
        let baseTol = Float(max(0.3, 1.25 * o.target.banding))
        var lo = UPLosslessOptions()
        lo.effort = o.effort
        lo.ancillary = o.ancillary

        func finishLossless(_ note: String) -> UPLossyResult? {
            guard let r = UPLossless.encode(img, options: lo, progress: progress?.child(from: 0.6, to: 1)) else { return nil }
            return UPLossyResult(data: r.data, image: img, quality: UPQuality(), mode: "lossless", colors: 0, targetMet: true, maps: maps,
                                 seconds: Date().timeIntervalSince(t0), detail: note, encoder: r)
        }
        if n < 64 { return finishLossless("image too small for lossy coding to pay off") }

        func pristineIntact(_ out: UPImage) -> Bool {
            for i in maps.pristine {
                let k = Int(i) * 4
                if out.px[k] != img.px[k] || out.px[k + 1] != img.px[k + 1] || out.px[k + 2] != img.px[k + 2] || out.px[k + 3] != img.px[k + 3] { return false }
            }
            return true
        }

        // ---- palette search
        var bestPal: Candidate? = nil
        var bestEffort: Candidate? = nil       // closest to the target when nothing meets it
        if o.allowPalette {
            let ctx = UPQuantContext(sImg, maps: sMaps)
            var top = max(2, min(256, o.maxColors))
            if let u = ctx.uniqueColorCount, u <= top, !big { top = u }
            var rungs = ladder.filter { $0 < top }
            rungs.append(top)
            let strengths: [Float] = o.dithering ? (o.effort == .fast ? [0, 0.5, 1] : [0, 0.35, 0.7, 1]) : [0]
            var rds: [(Float, Float)] = [(0, baseTol), (1, 0.5 * baseTol), (1.5, baseTol)]
            if o.effort != .fast { rds += [(1, 0.75 * baseTol), (2.5, 1.5 * baseTol)] }
            if o.effort == .maximum { rds += [(0.5, 0.35 * baseTol), (3, baseTol), (4, 2 * baseTol)] }
            var combos: [UPDitherParams] = []
            for s in strengths { for (lam, tol) in rds { combos.append(UPDitherParams(strength: s, lambda: lam, baseTolerance: tol, modulate: true)) } }
            if o.dithering && o.effort != .fast { combos.append(UPDitherParams(strength: 1, lambda: 0, baseTolerance: baseTol, modulate: false)) }     // plain Floyd–Steinberg
            let lock = NSLock()
            var done = 0
            DispatchQueue.concurrentPerform(iterations: combos.count) { ci in
                if progress?.cancelled == true { return }
                let prm = combos[ci]
                var cache: [Int: Candidate] = [:]
                func eval(_ ri: Int) -> Candidate {
                    if let c = cache[ri] { return c }
                    let pal = ctx.cachedPalette(rungs[ri])
                    let ix = UPRemap.compact(UPRemap.remap(ctx, pal, prm))
                    let rendered = ix.image()
                    var q = ref.compare(rendered)
                    // user-protected pixels must come out exactly; a palette that cannot do that is disqualified
                    if !big && !pristineIntact(rendered) { q.q = 0; q.ssim = min(q.ssim, 0) }
                    let c = Candidate(indexed: ix, quality: q, size: UPLossyTools.quickSize(ix),
                                      label: String(format: "K%d dither %.2f λ%.1f tol %.2f", ix.palette.count, prm.strength, prm.lambda, prm.baseTolerance), colors: rungs[ri], params: prm)
                    cache[ri] = c
                    return c
                }
                // smallest rung that meets the target (quality grows with the colour count)
                var a = 0, b = rungs.count - 1
                let topC = eval(b)
                var found: Candidate? = nil
                if o.target.met(by: topC.quality) {
                    found = topC
                    while a < b {
                        let m = (a + b) / 2
                        let c = eval(m)
                        if o.target.met(by: c.quality) { b = m; if c.size < found!.size { found = c } } else { a = m + 1 }
                    }
                    let c = eval(b)
                    if o.target.met(by: c.quality) && c.size < found!.size { found = c }
                    // with rate–distortion on, one rung more can come out smaller
                    if b + 1 < rungs.count { let c2 = eval(b + 1); if o.target.met(by: c2.quality) && c2.size < found!.size { found = c2 } }
                }
                lock.lock()
                if let f = found, bestPal == nil || f.size < bestPal!.size { bestPal = f }
                if found == nil, bestEffort == nil || topC.quality.q > bestEffort!.quality.q { bestEffort = topC }
                done += 1
                let d = done
                lock.unlock()
                progress?.report(0.05 + 0.4 * Double(d) / Double(combos.count), "Palette search")
            }
            if progress?.cancelled == true { return nil }
            // apply the chosen settings to the whole image
            if big {
                func full(_ c: Candidate) -> Candidate {
                    let fctx = UPQuantContext(img, maps: maps)
                    let ix = UPRemap.compact(UPRemap.remap(fctx, fctx.palette(c.colors), c.params))
                    var q = c.quality
                    let out = ix.image()
                    if n <= 16_000_000 { q = UPMetricReference(img, importance: maps.importance).compare(out) }
                    if !pristineIntact(out) { q.q = 0 }
                    return Candidate(indexed: ix, quality: q, size: UPLossyTools.quickSize(ix), label: c.label + (n > 16_000_000 ? " (quality measured on sample tiles)" : ""), colors: c.colors, params: c.params)
                }
                if let c = bestPal {
                    let f = full(c)
                    // the sample can be a little optimistic: accept a small shortfall rather than jumping to a 5× larger file
                    var relaxed = o.target
                    relaxed.q -= 0.0015; relaxed.smoothDE *= 1.25; relaxed.banding = relaxed.banding * 1.25 + 0.1; relaxed.edgeDE *= 1.25
                    bestPal = f.quality.q > 0 && relaxed.met(by: f.quality) ? f : nil
                    if bestPal == nil { bestEffort = f }
                } else if let c = bestEffort, !o.allowTrueColor { bestEffort = full(c) }
            }
        }
        if progress?.cancelled == true { return nil }

        // ---- true-colour near-lossless when the palette cannot reach the target
        var bestTrue: (nl: UPNearLossless, quality: UPQuality, scale: Float)? = nil
        if bestPal == nil && o.allowTrueColor {
            progress?.report(0.46, "True-colour search")
            let scales: [Float] = [0.25, 0.4, 0.6, 0.85, 1.2, 1.7, 2.4, 3.4]
            var a = 0, b = scales.count - 1
            func eval(_ si: Int) -> (UPNearLossless, UPQuality) {
                let nl = UPLossyTrue.encode(sImg, tolerance: UPImportance.tolerance(sMaps, base: baseTol * scales[si]), progress: progress)
                return (nl, ref.compare(nl.image))
            }
            // largest tolerance scale that still meets the target
            let first = eval(0)
            if o.target.met(by: first.1) {
                bestTrue = (first.0, first.1, scales[0])
                while a < b {
                    let m = (a + b + 1) / 2
                    let e = eval(m)
                    if o.target.met(by: e.1) { a = m; bestTrue = (e.0, e.1, scales[m]) } else { b = m - 1 }
                    if progress?.cancelled == true { return nil }
                }
            }
            if big, let t = bestTrue {
                let nl = UPLossyTrue.encode(img, tolerance: UPImportance.tolerance(maps, base: baseTol * t.scale), progress: progress)
                bestTrue = (nl, n <= 16_000_000 ? UPMetricReference(img, importance: maps.importance).compare(nl.image) : t.quality, t.scale)
            }
        }
        if progress?.cancelled == true { return nil }

        // ---- encode the winner with the lossless pipeline
        let sub = progress?.child(from: 0.6, to: 1)
        if let c = bestPal ?? (bestTrue == nil && !o.allowTrueColor ? bestEffort : nil) {
            let out = c.indexed.image()
            o.onPreview?(out, c.quality, c.size, "palette", c.indexed.palette.count, bestPal != nil)
            if o.previewOnly {
                return UPLossyResult(data: Data(count: c.size), image: out, quality: c.quality, mode: "palette", colors: c.indexed.palette.count, targetMet: bestPal != nil,
                                     maps: maps, seconds: Date().timeIntervalSince(t0), detail: c.label, encoder: nil)
            }
            guard let r = UPLossless.encode(out, options: lo, progress: sub) else { return nil }
            // a lossless encoding of the original that is no bigger makes the loss pointless
            if n <= 1 << 20 || o.effort != .fast {
                var quick = lo; quick.verify = false
                if n > 1 << 18 { quick.effort = .fast }
                if let l = UPLossless.encode(img, options: quick), l.data.count <= r.data.count { return finishLossless("lossless is already as small as the perceptual result") }
            }
            return UPLossyResult(data: r.data, image: out, quality: c.quality, mode: "palette", colors: c.indexed.palette.count, targetMet: bestPal != nil, maps: maps,
                                 seconds: Date().timeIntervalSince(t0), detail: c.label, encoder: r)
        }
        if let t = bestTrue {
            o.onPreview?(t.nl.image, t.quality, t.nl.estimatedBytes, "true colour", 0, true)
            if o.previewOnly {
                return UPLossyResult(data: Data(count: t.nl.estimatedBytes), image: t.nl.image, quality: t.quality, mode: "true colour", colors: 0, targetMet: true, maps: maps,
                                     seconds: Date().timeIntervalSince(t0), detail: String(format: "near-lossless, tolerance ×%.2f", t.scale), encoder: nil)
            }
            var lt = lo
            lt.seedFilters = t.nl.filters
            guard let r = UPLossless.encode(t.nl.image, options: lt, progress: sub) else { return nil }
            if n <= 1 << 20 || o.effort != .fast {
                var quick = lo; quick.verify = false
                if n > 1 << 20 { quick.effort = .fast }
                if let l = UPLossless.encode(img, options: quick), l.data.count <= r.data.count { return finishLossless("lossless is already as small as the perceptual result") }
            }
            return UPLossyResult(data: r.data, image: t.nl.image, quality: t.quality, mode: "true colour", colors: 0, targetMet: true, maps: maps,
                                 seconds: Date().timeIntervalSince(t0), detail: String(format: "near-lossless, tolerance ×%.2f", t.scale), encoder: r)
        }
        if o.previewOnly {
            return UPLossyResult(data: Data(), image: img, quality: UPQuality(), mode: "lossless", colors: 0, targetMet: true, maps: maps,
                                 seconds: Date().timeIntervalSince(t0), detail: "target needs lossless", encoder: nil)
        }
        return finishLossless("the quality target can only be met losslessly")
    }
}
