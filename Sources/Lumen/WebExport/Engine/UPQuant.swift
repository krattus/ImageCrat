import Foundation

// Lumen Ultra PNG — "Perceptual Ultra" palette path.
//
//  * palette: importance-weighted k-means in the alpha-aware Oklab feature space (weighted median-cut start);
//  * index selection: error diffusion whose strength follows the masking model, combined with a rate–distortion
//    choice per pixel — among the dithered colour, the plain nearest colour and the indices that would extend the
//    current run or repeat the pixel above (what PNG's LZ77 stage turns into almost-free matches), the encoder takes
//    the one with the lowest  distortion + λ(x) · bits,  where λ(x) follows the local visibility tolerance.

struct UPPalette {
    /// r | g << 8 | b << 16 | a << 24
    var colors: [UInt32]
    var feats: [SIMD4<Float>]
    var count: Int { colors.count }
}

/// Everything about one source image that palette search and remapping reuse.
final class UPQuantContext {
    let image: UPImage
    let w: Int, h: Int
    let maps: UPPerceptualMaps
    /// Per-pixel colour feature (see `UPOklab.feature`).
    let feat: [SIMD4<Float>]
    // colour histogram (exact colours, or posterised bins when there are very many)
    private(set) var histFeat: [SIMD4<Float>] = []
    private(set) var histWeight: [Float] = []
    /// 0 transparent, 1 translucent, 2 opaque — never mixed inside one histogram entry.
    private(set) var histClass: [UInt8] = []
    /// Squared visibility threshold of each entry (ΔE²): small for colours living in smooth areas, larger inside texture.
    private(set) var histTau2: [Float] = []
    private(set) var histExact = true
    private(set) var exactColors: [UInt32] = []
    let hasTransparent: Bool
    let hasTranslucent: Bool
    let hasOpaque: Bool

    init(_ img: UPImage, maps: UPPerceptualMaps) {
        let image = UPReduce.canonical(img, keepHiddenRGB: false)
        let w = img.width, h = img.height
        self.image = image
        self.w = w; self.h = h
        self.maps = maps
        let n = w * h
        var f = [SIMD4<Float>](repeating: .zero, count: n)
        var t = false, tl = false, op = false
        image.px.withUnsafeBufferPointer { p in
            f.withUnsafeMutableBufferPointer { fp in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = y * w + x
                        fp[i] = UPOklab.feature(p[i * 4], p[i * 4 + 1], p[i * 4 + 2], p[i * 4 + 3])
                    }
                }
            }
            for i in 0..<n {
                let a = p[i * 4 + 3]
                if a == 0 { t = true } else if a == 255 { op = true } else { tl = true }
            }
        }
        feat = f
        hasTransparent = t; hasTranslucent = tl; hasOpaque = op
        buildHistogram()
    }

    /// Pixel weight for palette design: salient pixels count more, and so do smooth areas (where palette error shows as banding).
    @inline(__always) private func weight(_ i: Int) -> Float {
        let smooth = 1 / (1 + maps.texture[i] / 2)
        return (0.5 + 0.5 * maps.importance[i]) * (0.6 + 0.8 * smooth)
    }

    private func buildHistogram() {
        let n = w * h
        for bits in [8, 6, 5, 4] {
            let limit = bits == 4 ? Int.max : 1 << 17
            var index = [UInt32: Int32]()
            index.reserveCapacity(min(n, 1 << 16))
            var sums: [SIMD4<Float>] = [], ws: [Float] = [], cols: [UInt32] = [], classes: [UInt8] = [], tex: [Float] = []
            var over = false
            let drop = UInt32(8 - bits)
            image.px.withUnsafeBufferPointer { p in
                var lastKey: UInt32 = 0xFFFF_FFFF, lastIdx: Int32 = -1
                for i in 0..<n {
                    let c = UInt32(p[i * 4]) | UInt32(p[i * 4 + 1]) << 8 | UInt32(p[i * 4 + 2]) << 16 | UInt32(p[i * 4 + 3]) << 24
                    let key = bits == 8 ? c : ((c >> drop) & (0x0101_0101 * ((1 << UInt32(bits)) - 1)))
                        | (UInt32(p[i * 4 + 3] == 0 ? 1 : (p[i * 4 + 3] == 255 ? 2 : 0)) << 30)
                    var k: Int32
                    if key == lastKey && lastIdx >= 0 { k = lastIdx } else if let e = index[key] { k = e } else {
                        if sums.count >= limit { over = true; break }
                        k = Int32(sums.count); index[key] = k
                        sums.append(.zero); ws.append(0); cols.append(c); tex.append(0)
                        classes.append(p[i * 4 + 3] == 0 ? 0 : (p[i * 4 + 3] == 255 ? 2 : 1))
                    }
                    lastKey = key; lastIdx = k
                    let wt = weight(i)
                    sums[Int(k)] += feat[i] * wt
                    ws[Int(k)] += wt
                    tex[Int(k)] += maps.texture[i] * wt
                }
            }
            if over { continue }
            for k in 0..<sums.count { sums[k] /= max(1e-9, ws[k]) }
            histFeat = sums; histWeight = ws; histClass = classes
            histTau2 = (0..<sums.count).map { let t = 0.3 * (1 + min(3, tex[$0] / max(1e-9, ws[$0]) / 2.5)); return t * t }
            histExact = bits == 8
            exactColors = bits == 8 ? cols : []
            return
        }
    }

    var uniqueColorCount: Int? { histExact ? histFeat.count : nil }

    // MARK: palette design

    private var paletteCache: [Int: UPPalette] = [:]
    private let cacheLock = NSLock()

    /// Cached `palette(k)` (thread-safe).
    func cachedPalette(_ k: Int) -> UPPalette {
        cacheLock.lock()
        if let p = paletteCache[k] { cacheLock.unlock(); return p }
        cacheLock.unlock()
        let p = palette(k)
        cacheLock.lock(); paletteCache[k] = p; cacheLock.unlock()
        return p
    }

    /// Importance-weighted palette of at most `k` colours.
    func palette(_ k: Int, iterations: Int = 8) -> UPPalette {
        let n = histFeat.count
        if histExact && n <= k {
            return UPPalette(colors: exactColors, feats: exactColors.map { UPOklab.feature(UInt8($0 & 255), UInt8($0 >> 8 & 255), UInt8($0 >> 16 & 255), UInt8($0 >> 24)) })
        }
        var cent = medianCut(k)
        let kk = cent.count
        var assign = [Int32](repeating: 0, count: n)
        var weights = histWeight
        let chunk = 2048
        let chunks = (n + chunk - 1) / chunk
        func assignAll() {
            let c = cent
            histFeat.withUnsafeBufferPointer { hf in
                assign.withUnsafeMutableBufferPointer { ap in
                    c.withUnsafeBufferPointer { cp in
                        DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                            for i in (ci * chunk)..<min(n, (ci + 1) * chunk) {
                                var best = 0
                                var bd = Float.greatestFiniteMagnitude
                                let f = hf[i]
                                for j in 0..<kk {
                                    let d = f - cp[j]
                                    let dd = (d * d).sum()
                                    if dd < bd { bd = dd; best = j }
                                }
                                ap[i] = Int32(best)
                            }
                        }
                    }
                }
            }
        }
        for it in 0..<(iterations + 4) {
            assignAll()
            if it == iterations - 1 || it == iterations + 1 {
                // visibility feedback: colours whose error is above their visibility threshold (thin anti-aliased edges,
                // rare accents, flat areas that landed between two entries) gain weight; invisible error loses it
                for i in 0..<n {
                    let d = histFeat[i] - cent[Int(assign[i])]
                    let e = (d * d).sum()
                    weights[i] = histWeight[i] * min(40, max(0.2, e / histTau2[i]))
                }
            }
            var sums = [SIMD4<Float>](repeating: .zero, count: kk), ws = [Float](repeating: 0, count: kk)
            for i in 0..<n { let a = Int(assign[i]); sums[a] += histFeat[i] * weights[i]; ws[a] += weights[i] }
            var moved: Float = 0
            for j in 0..<kk where ws[j] > 0 {
                let nc = sums[j] / ws[j]
                let d = nc - cent[j]
                moved = max(moved, (d * d).sum())
                cent[j] = nc
            }
            // re-seed empty clusters at the entry that is worst represented
            for j in 0..<kk where ws[j] == 0 {
                var worst = 0
                var wd: Float = -1
                for i in stride(from: 0, to: n, by: max(1, n / 4096)) {
                    let d = histFeat[i] - cent[Int(assign[i])]
                    let e = (d * d).sum() * weights[i]
                    if e > wd { wd = e; worst = i }
                }
                cent[j] = histFeat[worst]
                moved = 1
            }
            if moved < 0.0004 && it >= iterations + 2 { break }
        }
        // split–merge refinement: k-means can never give a rare colour its own entry (its weight cannot pull a centroid
        // away from a big neighbour). Where an entry's *visible* error would shrink by more than it costs to merge the two
        // closest clusters, move that centroid onto the badly represented colour and re-settle.
        func update(_ passes: Int) {
            for _ in 0..<passes {
                assignAll()
                var sums = [SIMD4<Float>](repeating: .zero, count: kk), ws = [Float](repeating: 0, count: kk)
                for i in 0..<n { let a = Int(assign[i]); sums[a] += histFeat[i] * histWeight[i]; ws[a] += histWeight[i] }
                for j in 0..<kk where ws[j] > 0 { cent[j] = sums[j] / ws[j] }
            }
        }
        if kk >= 4 && n > kk {
            for _ in 0..<10 {
                assignAll()
                var cw = [Float](repeating: 0, count: kk)
                var gain = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let a = Int(assign[i])
                    cw[a] += histWeight[i]
                    let d = histFeat[i] - cent[a]
                    gain[i] = histWeight[i] * max(0, (d * d).sum() - histTau2[i])
                }
                // Ward cost of merging each cluster into its nearest neighbour (visible part only)
                var cost = [Float](repeating: .greatestFiniteMagnitude, count: kk)
                for j in 0..<kk {
                    for l in 0..<kk where l != j {
                        let d = cent[j] - cent[l]
                        let c = cw[j] * cw[l] / max(1e-9, cw[j] + cw[l]) * max(0, (d * d).sum() - 0.09)
                        if c < cost[j] { cost[j] = c }
                    }
                }
                let byGain = (0..<n).sorted { gain[$0] > gain[$1] }
                let byCost = (0..<kk).sorted { cost[$0] < cost[$1] }
                var moved = 0
                var usedClusters = Set<Int>()
                let batch = max(1, kk / 12)
                var gi = 0
                for ci in 0..<batch {
                    guard gi < n else { break }
                    let j = byCost[ci]
                    // the entry must not sit in the cluster we are about to dissolve, nor in one already re-seeded this round
                    while gi < n && (Int(assign[byGain[gi]]) == j || usedClusters.contains(Int(assign[byGain[gi]]))) { gi += 1 }
                    guard gi < n else { break }
                    let i = byGain[gi]
                    if gain[i] <= cost[j] * 1.5 + 1e-6 { break }
                    usedClusters.insert(Int(assign[i])); usedClusters.insert(j)
                    cent[j] = histFeat[i]
                    moved += 1
                    gi += 1
                }
                if moved == 0 { break }
                update(2)
            }
        }
        // clusters that mostly hold opaque colours become exactly opaque (centroid of their opaque members):
        // an opaque pixel must never turn translucent
        if hasOpaque && (hasTranslucent || hasTransparent) {
            assignAll()
            var sums = [SIMD4<Float>](repeating: .zero, count: kk), wo = [Float](repeating: 0, count: kk), wt = [Float](repeating: 0, count: kk)
            for i in 0..<n {
                let a = Int(assign[i])
                wt[a] += histWeight[i]
                if histClass[i] == 2 { sums[a] += histFeat[i] * histWeight[i]; wo[a] += histWeight[i] }
            }
            for j in 0..<kk where wo[j] > 0 && wo[j] >= 0.35 * wt[j] { cent[j] = sums[j] / wo[j] }
        }
        return finish(cent)
    }

    /// Rounds centroids to RGBA8, removes duplicates and guarantees exact transparent / opaque entries where the image needs them.
    private func finish(_ cent: [SIMD4<Float>]) -> UPPalette {
        var cols: [UInt32] = []
        var seen = Set<UInt32>()
        for c in cent {
            var (r, g, b, a) = UPOklab.rgba(fromFeature: c)
            if a >= 253 { a = 255 }
            if a <= 2 { r = 0; g = 0; b = 0; a = 0 }
            let v = UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24
            if seen.insert(v).inserted { cols.append(v) }
        }
        if hasTransparent && !cols.contains(0) {
            // replace the entry closest to transparency, or add one
            if let i = cols.indices.min(by: { cols[$0] >> 24 < cols[$1] >> 24 }), cols[i] >> 24 < 40 { cols[i] = 0 } else { cols.append(0) }
        }
        if hasOpaque && !cols.contains(where: { $0 >> 24 == 255 }) {
            if let i = cols.indices.max(by: { cols[$0] >> 24 < cols[$1] >> 24 }) { cols[i] |= 0xFF00_0000 }
        }
        if cols.isEmpty { cols = [0xFF00_0000] }
        return UPPalette(colors: cols, feats: cols.map { UPOklab.feature(UInt8($0 & 255), UInt8($0 >> 8 & 255), UInt8($0 >> 16 & 255), UInt8($0 >> 24)) })
    }

    /// Weighted median cut: repeatedly split the box with the largest weighted variance along its widest axis.
    private func medianCut(_ k: Int) -> [SIMD4<Float>] {
        let n = histFeat.count
        var order = Array(0..<n)
        struct Box { var lo: Int; var hi: Int; var score: Float; var axis: Int; var mean: SIMD4<Float> }
        func measure(_ lo: Int, _ hi: Int) -> Box {
            var sum = SIMD4<Float>.zero
            var wsum: Float = 0
            for i in lo..<hi { let wt = histWeight[order[i]]; sum += histFeat[order[i]] * wt; wsum += wt }
            let mean = sum / max(1e-9, wsum)
            var v = SIMD4<Float>.zero                 // weighted sum of squared deviations per axis (two passes: no cancellation)
            for i in lo..<hi { let d = histFeat[order[i]] - mean; v += d * d * histWeight[order[i]] }
            var axis = 0
            for a in 1..<4 where v[a] > v[axis] { axis = a }
            // a spread far below one sRGB step (σ ≈ 0.12 ΔE) is not worth a palette entry, however many pixels share it
            return Box(lo: lo, hi: hi, score: hi - lo > 1 ? v.sum() - wsum * 0.015 : -1, axis: axis, mean: mean)
        }
        var boxes = [measure(0, n)]
        while boxes.count < k {
            guard let bi = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }), boxes[bi].score > 1e-6 else { break }
            let b = boxes[bi]
            let axis = b.axis
            order[b.lo..<b.hi].sort { histFeat[$0][axis] < histFeat[$1][axis] }
            // cut where the two halves are best separated (maximum between-class variance, all four dimensions)
            var total: Float = 0
            var totalSum = SIMD4<Float>.zero
            for i in b.lo..<b.hi { let wt = histWeight[order[i]]; total += wt; totalSum += histFeat[order[i]] * wt }
            var acc: Float = 0
            var accSum = SIMD4<Float>.zero
            var cut = b.lo + 1
            var bestGain: Float = -1
            for i in b.lo..<(b.hi - 1) {
                let wt = histWeight[order[i]]
                acc += wt; accSum += histFeat[order[i]] * wt
                let rest = total - acc
                if acc <= 0 || rest <= 0 { continue }
                let d = accSum / acc - (totalSum - accSum) / rest
                let gain = acc * rest / total * (d * d).sum()
                if gain > bestGain { bestGain = gain; cut = i + 1 }
            }
            boxes[bi] = measure(b.lo, cut)
            boxes.append(measure(cut, b.hi))
        }
        return boxes.map(\.mean)
    }
}

struct UPDitherParams {
    /// Global error-diffusion amount (0 = none, 1 = full Floyd–Steinberg).
    var strength: Float = 1
    /// Rate–distortion weight (0 = ignore rate: plain modulated dithering).
    var lambda: Float = 1
    /// Base visibility tolerance in ΔE × 100 before masking / importance scaling.
    var baseTolerance: Float = 1
    /// Reduce dithering on edges and in texture (masking-modulated) instead of uniform diffusion.
    var modulate = true
    /// How many palette neighbours of the dithered choice take part in the entropy-constrained selection.
    var neighbours = 4
    /// Rate–distortion strength kept in perfectly smooth areas (1 = same as elsewhere).
    var smoothDamping: Float = 0.3
}

struct UPIndexed {
    var width: Int
    var height: Int
    var palette: UPPalette
    var indices: [UInt8]

    func image() -> UPImage {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let n = width * height
        px.withUnsafeMutableBufferPointer { p in
            indices.withUnsafeBufferPointer { ip in
                palette.colors.withUnsafeBufferPointer { cp in
                    for i in 0..<n {
                        let c = cp[Int(ip[i])]
                        p[i * 4] = UInt8(c & 255); p[i * 4 + 1] = UInt8(c >> 8 & 255); p[i * 4 + 2] = UInt8(c >> 16 & 255); p[i * 4 + 3] = UInt8(c >> 24)
                    }
                }
            }
        }
        return UPImage(width: width, height: height, px: px)
    }
}

enum UPRemap {
    /// Nearest-palette search accelerated with per-entry neighbour lists (triangle-inequality pruning).
    struct Searcher {
        let feats: [SIMD4<Float>]
        let opaque: [Bool]
        let k: Int
        /// For entry g: other entries sorted by distance, with a quarter of the squared distance for the pruning test.
        let neighbours: [[(Int32, Float)]]
        let nearestOpaque: [Int32]
        let transparentIndex: Int

        init(_ p: UPPalette) {
            feats = p.feats; k = p.count
            opaque = p.colors.map { $0 >> 24 == 255 }
            var nb: [[(Int32, Float)]] = []
            nb.reserveCapacity(k)
            for i in 0..<k {
                var row: [(Int32, Float)] = []
                row.reserveCapacity(k - 1)
                for j in 0..<k where j != i { let d = p.feats[i] - p.feats[j]; row.append((Int32(j), (d * d).sum() / 4)) }
                row.sort { $0.1 < $1.1 }
                nb.append(row)
            }
            neighbours = nb
            var no = [Int32](repeating: -1, count: p.count)
            let op = p.colors.map { $0 >> 24 == 255 }
            for i in 0..<p.count {
                if op[i] { no[i] = Int32(i); continue }
                if let f = nb[i].first(where: { op[Int($0.0)] }) { no[i] = f.0 }
            }
            nearestOpaque = no
            transparentIndex = p.colors.firstIndex(of: 0) ?? -1
        }

        /// Nearest entry to `t`, starting from `guess`. With `opaqueOnly`, translucent entries are never returned (when an opaque one exists).
        @inline(__always)
        func nearest(_ t: SIMD4<Float>, guess: Int, opaqueOnly: Bool) -> (Int, Float) {
            var g = guess
            if opaqueOnly && !opaque[g] { let o = Int(nearestOpaque[g]); if o >= 0 { g = o } }
            var d = t - feats[g]
            let d0 = (d * d).sum()
            var best = g, bd = d0
            let restrict = opaqueOnly && opaque[g]
            for (j, quarter) in neighbours[g] {
                if quarter >= d0 { break }
                if restrict && !opaque[Int(j)] { continue }
                d = t - feats[Int(j)]
                let dd = (d * d).sum()
                if dd < bd { bd = dd; best = Int(j) }
            }
            return (best, bd)
        }
    }

    /// Maps the image to the palette with masking-modulated error diffusion and rate–distortion optimised index choice.
    static func remap(_ ctx: UPQuantContext, _ pal: UPPalette, _ prm: UPDitherParams) -> UPIndexed {
        let w = ctx.w, h = ctx.h, n = w * h
        let s = Searcher(pal)
        let k = pal.count
        var idx = [UInt8](repeating: 0, count: n)
        guard k > 1 else { return UPIndexed(width: w, height: h, palette: pal, indices: idx) }
        let tol = UPImportance.tolerance(ctx.maps, base: prm.baseTolerance)
        // entropy-constrained choice needs the (order-0) cost of each index: estimate it from a plain nearest mapping
        var bits = [Float](repeating: 8, count: k)
        if prm.lambda > 0 {
            var counts = [Float](repeating: 1, count: k)
            ctx.feat.withUnsafeBufferPointer { feat in
                ctx.image.px.withUnsafeBufferPointer { px in
                    var g = 0
                    let opaqueRule = ctx.hasOpaque && (ctx.hasTranslucent || ctx.hasTransparent)
                    var i = 0
                    let stepI = n > 400_000 ? 2 : 1
                    while i < n {
                        if px[i * 4 + 3] == 0 && s.transparentIndex >= 0 { counts[s.transparentIndex] += 1 } else {
                            let (c, _) = s.nearest(feat[i], guess: g, opaqueOnly: opaqueRule && px[i * 4 + 3] == 255)
                            g = c
                            counts[c] += 1
                        }
                        i += stepI
                    }
                }
            }
            var total: Float = 0
            for c in counts { total += c }
            for j in 0..<k { bits[j] = min(14, -log2f(counts[j] / total)) }
        }
        let mixedAlpha = ctx.hasOpaque && (ctx.hasTranslucent || ctx.hasTransparent)
        var errCur = [SIMD4<Float>](repeating: .zero, count: w + 2)
        var errNext = [SIMD4<Float>](repeating: .zero, count: w + 2)
        let useDither = prm.strength > 0
        let useRD = prm.lambda > 0
        let maxErr: Float = 24          // clamp of the accumulated diffusion error per channel (ΔE units)
        ctx.feat.withUnsafeBufferPointer { feat in
            ctx.image.px.withUnsafeBufferPointer { px in
                idx.withUnsafeMutableBufferPointer { ip in
                    var guess = 0
                    for y in 0..<h {
                        let ltr = y & 1 == 0 || !useDither
                        for i in 0..<(w + 2) { errNext[i] = .zero }
                        var runLen = 0, upLen = 0
                        var prev = -1
                        var x = ltr ? 0 : w - 1
                        let step = ltr ? 1 : -1
                        while x >= 0 && x < w {
                            let i = y * w + x
                            let alpha = px[i * 4 + 3]
                            if alpha == 0 && s.transparentIndex >= 0 {
                                let c = s.transparentIndex
                                ip[i] = UInt8(c)
                                runLen = c == prev ? runLen + 1 : 0
                                upLen = (y > 0 && Int(ip[i - w]) == c) ? upLen + 1 : 0
                                prev = c
                                x += step
                                continue
                            }
                            let orig = feat[i]
                            let opq = mixedAlpha && alpha == 255
                            // plain nearest colour
                            let (c1, e1) = s.nearest(orig, guess: guess, opaqueOnly: opq)
                            guess = c1
                            var target = orig
                            var strength: Float = 0
                            if useDither {
                                strength = prm.strength
                                if prm.modulate {
                                    // no dithering where the palette is already finer than the eye, less on edges and in texture
                                    let need = min(1, max(0, (e1 - 0.02) / 0.35))
                                    let edge = max(0.2, 1 - ctx.maps.edge[i] / 9)
                                    let tex = 1 / (1 + ctx.maps.texture[i] / 4)
                                    strength *= need * edge * (0.35 + 0.65 * tex)
                                }
                                var e = errCur[x + 1]
                                e = e.clamped(lowerBound: SIMD4(repeating: -maxErr), upperBound: SIMD4(repeating: maxErr))
                                target = orig + e
                            }
                            var (best, bestD) = target == orig ? (c1, e1) : s.nearest(target, guess: c1, opaqueOnly: opq)
                            if useRD {
                                let t = tol[i]
                                if t > 0 {
                                    // in smooth areas run-hunting makes band edges ragged (visible streaks) for little gain: damp it there
                                    let smoothness = max(0, 1 - ctx.maps.texture[i] / 1.2)
                                    let damp = 1 - (1 - prm.smoothDamping) * smoothness
                                    let lam = prm.lambda * t * t * 0.25 * damp
                                    let limit = t * t * damp + e1
                                    let up = y > 0 ? Int(ip[i - w]) : -1
                                    @inline(__always) func rate(_ c: Int) -> Float {
                                        // literal cost, discounted when the index continues a run or a copy of the row above
                                        var f: Float = 1
                                        if c == prev { f = runLen >= 2 ? 0.1 : (runLen == 1 ? 0.6 : 0.9) }
                                        if c == up { f = min(f, upLen >= 2 ? 0.1 : (upLen == 1 ? 0.6 : 1)) }
                                        return bits[c] * f
                                    }
                                    let best0 = best
                                    var bestJ = bestD + lam * rate(best)
                                    // the undithered colour is always admissible
                                    if c1 != best {
                                        let d = target - s.feats[c1]
                                        let j = (d * d).sum() + lam * rate(c1)
                                        if j < bestJ { bestJ = j; best = c1; bestD = (d * d).sum() }
                                    }
                                    var cand = prev
                                    for pass in 0..<2 {
                                        if pass == 1 { cand = up }
                                        let c = cand
                                        if c < 0 || c == best || c == c1 { continue }
                                        if opq && !s.opaque[c] { continue }
                                        let do_ = orig - s.feats[c]
                                        if (do_ * do_).sum() > limit { continue }      // must stay within the local visibility tolerance
                                        let d = target - s.feats[c]
                                        let dd = (d * d).sum()
                                        let j = dd + lam * rate(c)
                                        if j < bestJ { bestJ = j; best = c; bestD = dd }
                                    }
                                    // entropy-constrained alternatives: the closest few entries to the dithered choice
                                    let nbr = s.neighbours[best0]
                                    for q in 0..<min(prm.neighbours, nbr.count) {
                                        let c = Int(nbr[q].0)
                                        if c == best || c == c1 || c == prev || c == up { continue }
                                        if opq && !s.opaque[c] { continue }
                                        let do_ = orig - s.feats[c]
                                        if (do_ * do_).sum() > limit { continue }
                                        let d = target - s.feats[c]
                                        let dd = (d * d).sum()
                                        let j = dd + lam * bits[c]
                                        if j < bestJ { bestJ = j; best = c; bestD = dd }
                                    }
                                }
                            }
                            ip[i] = UInt8(best)
                            runLen = best == prev ? runLen + 1 : 0
                            upLen = (y > 0 && Int(ip[i - w]) == best) ? upLen + 1 : 0
                            prev = best
                            if useDither && strength > 0 {
                                let e = (target - s.feats[best]) * strength
                                errCur[x + 1 + step] += e * (7.0 / 16)
                                errNext[x + 1 - step] += e * (3.0 / 16)
                                errNext[x + 1] += e * (5.0 / 16)
                                errNext[x + 1 + step] += e * (1.0 / 16)
                            }
                            x += step
                        }
                        swap(&errCur, &errNext)
                    }
                }
            }
        }
        return UPIndexed(width: w, height: h, palette: pal, indices: idx)
    }

    /// Drops palette entries no pixel uses and renumbers.
    static func compact(_ ix: UPIndexed) -> UPIndexed {
        var used = [Bool](repeating: false, count: ix.palette.count)
        for v in ix.indices { used[Int(v)] = true }
        if !used.contains(false) { return ix }
        var map = [UInt8](repeating: 0, count: ix.palette.count)
        var cols: [UInt32] = [], feats: [SIMD4<Float>] = []
        for i in 0..<ix.palette.count where used[i] { map[i] = UInt8(cols.count); cols.append(ix.palette.colors[i]); feats.append(ix.palette.feats[i]) }
        return UPIndexed(width: ix.width, height: ix.height, palette: UPPalette(colors: cols, feats: feats), indices: ix.indices.map { map[Int($0)] })
    }
}
