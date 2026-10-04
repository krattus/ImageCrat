import Foundation
import zlib

// Reference point (d) for the comparison table: a plain, conventional PNG-8 path —
// median-cut palette in RGBA, full-strength Floyd–Steinberg error diffusion, filter "none", zlib level 9.
// (The classic recipe most "save as PNG-8" exporters use.) Kept deliberately independent of the Ultra code.

enum UPBaseline {
    struct Result {
        var data: Data
        var image: UPImage
        var indexed: UPIndexed
    }

    /// `refined` adds what pngquant-class quantisers do on top of the classic recipe: variance-based box selection,
    /// a few k-means (Voronoi) passes and serpentine diffusion — still without any perceptual map or rate awareness.
    static func medianCutFS(_ source: UPImage, colors: Int = 256, dither: Bool = true, refined: Bool = false) -> Result? {
        let img = UPReduce.canonical(source, keepHiddenRGB: false)
        let w = img.width, h = img.height, n = w * h
        // histogram of premultiplied-ish RGBA colours (exact)
        var index = [UInt32: Int]()
        var cols: [SIMD4<Float>] = [], counts: [Float] = []
        img.px.withUnsafeBufferPointer { p in
            for i in 0..<n {
                let c = UInt32(p[i * 4]) | UInt32(p[i * 4 + 1]) << 8 | UInt32(p[i * 4 + 2]) << 16 | UInt32(p[i * 4 + 3]) << 24
                if let e = index[c] { counts[e] += 1 } else {
                    index[c] = cols.count
                    cols.append(SIMD4(Float(p[i * 4]), Float(p[i * 4 + 1]), Float(p[i * 4 + 2]), Float(p[i * 4 + 3])))
                    counts.append(1)
                }
            }
        }
        var palette: [SIMD4<Float>]
        if cols.count <= colors { palette = cols } else {
            // classic median cut: split the box with the widest channel range at the population median
            var order = Array(0..<cols.count)
            var boxes: [(Int, Int)] = [(0, cols.count)]
            func range(_ b: (Int, Int)) -> (Float, Int) {
                if refined {
                    // weighted variance (sum of squared deviations) along the widest axis
                    var sum = SIMD4<Float>.zero
                    var ws: Float = 0
                    for i in b.0..<b.1 { sum += cols[order[i]] * counts[order[i]]; ws += counts[order[i]] }
                    let mean = sum / max(1, ws)
                    var v = SIMD4<Float>.zero
                    for i in b.0..<b.1 { let d = cols[order[i]] - mean; v += d * d * counts[order[i]] }
                    var axis = 0
                    for a in 1..<4 where v[a] > v[axis] { axis = a }
                    return (b.1 - b.0 > 1 ? v[axis] : -1, axis)
                }
                var lo = SIMD4<Float>(repeating: 255), hi = SIMD4<Float>(repeating: 0)
                for i in b.0..<b.1 { lo = pointwiseMin(lo, cols[order[i]]); hi = pointwiseMax(hi, cols[order[i]]) }
                let r = hi - lo
                var axis = 0
                for a in 1..<4 where r[a] > r[axis] { axis = a }
                return (b.1 - b.0 > 1 ? r[axis] : -1, axis)
            }
            while boxes.count < colors {
                var bi = -1, bestR: Float = 0, bestAxis = 0
                for (i, b) in boxes.enumerated() { let (r, a) = range(b); if r > bestR { bestR = r; bi = i; bestAxis = a } }
                if bi < 0 { break }
                let b = boxes[bi]
                order[b.0..<b.1].sort { cols[$0][bestAxis] < cols[$1][bestAxis] }
                var total: Float = 0
                for i in b.0..<b.1 { total += counts[order[i]] }
                var acc: Float = 0
                var cut = b.1 - 1
                for i in b.0..<(b.1 - 1) { acc += counts[order[i]]; if acc >= total / 2 { cut = i + 1; break } }
                cut = max(b.0 + 1, min(b.1 - 1, cut))
                boxes[bi] = (b.0, cut)
                boxes.append((cut, b.1))
            }
            palette = boxes.map { b in
                var sum = SIMD4<Float>.zero
                var ws: Float = 0
                for i in b.0..<b.1 { sum += cols[order[i]] * counts[order[i]]; ws += counts[order[i]] }
                return sum / max(1, ws)
            }
            if refined {
                for _ in 0..<4 {
                    var sums = [SIMD4<Float>](repeating: .zero, count: palette.count), ws = [Float](repeating: 0, count: palette.count)
                    let pal = palette
                    let assign = UnsafeMutablePointer<Int32>.allocate(capacity: cols.count)
                    defer { assign.deallocate() }
                    cols.withUnsafeBufferPointer { cp in
                        DispatchQueue.concurrentPerform(iterations: (cols.count + 1023) / 1024) { ch in
                            for i in (ch * 1024)..<min(cp.count, (ch + 1) * 1024) {
                                var best = 0
                                var bd = Float.greatestFiniteMagnitude
                                for j in 0..<pal.count { let d = cp[i] - pal[j]; let dd = (d * d).sum(); if dd < bd { bd = dd; best = j } }
                                assign[i] = Int32(best)
                            }
                        }
                    }
                    for i in 0..<cols.count { let a = Int(assign[i]); sums[a] += cols[i] * counts[i]; ws[a] += counts[i] }
                    for j in 0..<palette.count where ws[j] > 0 { palette[j] = sums[j] / ws[j] }
                }
            }
            palette = palette.map { $0.rounded(.toNearestOrEven) }
        }
        // transparent pixels need an exact transparent entry
        if img.px.indices.contains(3), (0..<n).contains(where: { img.px[$0 * 4 + 3] == 0 }) {
            if let i = palette.indices.min(by: { palette[$0].w < palette[$1].w }) { palette[i] = .zero }
        }
        var seen = Set<UInt32>()
        var pal: [UInt32] = []
        var palF: [SIMD4<Float>] = []
        for p in palette {
            let v = UInt32(p.x) | UInt32(p.y) << 8 | UInt32(p.z) << 16 | UInt32(p.w) << 24
            if seen.insert(v).inserted { pal.append(v); palF.append(p) }
        }
        let k = pal.count
        var idx = [UInt8](repeating: 0, count: n)
        var cache = [UInt32: UInt8]()
        let anyOpaque = pal.contains { $0 >> 24 == 255 }
        func nearest(_ c: SIMD4<Float>, opaque: Bool) -> Int {
            var q = c.rounded(.toNearestOrEven).clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 255))
            if opaque { q.w = 255 }
            let key = UInt32(q.x) | UInt32(q.y) << 8 | UInt32(q.z) << 16 | UInt32(q.w) << 24
            if let e = cache[key] { return Int(e) }
            var best = 0
            var bd = Float.greatestFiniteMagnitude
            for j in 0..<k {
                if opaque && anyOpaque && palF[j].w != 255 { continue }      // opaque pixels stay opaque
                let d = q - palF[j]; let dd = (d * d).sum(); if dd < bd { bd = dd; best = j }
            }
            cache[key] = UInt8(best)
            return best
        }
        var errCur = [SIMD4<Float>](repeating: .zero, count: w + 2), errNext = errCur
        let transparentIdx = pal.firstIndex(of: 0)
        for y in 0..<h {
            for i in 0..<(w + 2) { errNext[i] = .zero }
            let ltr = !refined || y & 1 == 0
            let step = ltr ? 1 : -1
            var x = ltr ? 0 : w - 1
            while x >= 0 && x < w {
                let i = y * w + x
                let o = SIMD4(Float(img.px[i * 4]), Float(img.px[i * 4 + 1]), Float(img.px[i * 4 + 2]), Float(img.px[i * 4 + 3]))
                if o.w == 0, let t = transparentIdx { idx[i] = UInt8(t); x += step; continue }
                let t = dither ? o + errCur[x + 1] : o
                let c = nearest(t, opaque: o.w == 255)
                idx[i] = UInt8(c)
                if dither {
                    var e = t.clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 255)) - palF[c]
                    if o.w == 255 { e.w = 0 }
                    errCur[x + 1 + step] += e * (7.0 / 16)
                    errNext[x + 1 - step] += e * (3.0 / 16)
                    errNext[x + 1] += e * (5.0 / 16)
                    errNext[x + 1 + step] += e * (1.0 / 16)
                }
                x += step
            }
            swap(&errCur, &errNext)
        }
        let feats = pal.map { UPOklab.feature(UInt8($0 & 255), UInt8($0 >> 8 & 255), UInt8($0 >> 16 & 255), UInt8($0 >> 24)) }
        var ix = UPIndexed(width: w, height: h, palette: UPPalette(colors: pal, feats: feats), indices: idx)
        ix = UPRemap.compact(ix)
        // non-opaque entries first so tRNS stays short (what every PNG-8 writer does), filter none, zlib 9
        let ord = ix.palette.colors.indices.sorted { a, b in
            let ta = ix.palette.colors[a] >> 24 != 255, tb = ix.palette.colors[b] >> 24 != 255
            return ta != tb ? ta : a < b
        }
        var remap = [UInt8](repeating: 0, count: ord.count)
        for (newI, oldI) in ord.enumerated() { remap[oldI] = UInt8(newI) }
        let rep = UPRep(width: w, height: h, colorType: 3, bitDepth: 8, palette: ord.map { ix.palette.colors[$0] }, raw: ix.indices.map { remap[Int($0)] })
        let f = UPFilter.choose(rep, strategy: .fixed(0), cleanAlpha: false)
        let z = UPZlib.deflate(f.stream, level: 9, strategy: Z_DEFAULT_STRATEGY)
        return Result(data: UPPNG.assemble(rep, zlibStream: z), image: ix.image(), indexed: ix)
    }
}
