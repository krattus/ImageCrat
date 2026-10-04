import Foundation

/// Content-aware fill: multi-scale PatchMatch + EM voting (Wexler et al. 2007, Barnes et al. 2009).
///
/// The work is restricted to the hole's bounding box expanded by a margin, so small holes in large images stay fast.
/// Colors are matched un-premultiplied (plus alpha as a fourth channel); the result keeps the sources' alpha.
package enum Inpainter {
    /// Fills pixels where `hole` > 127 using multi-scale PatchMatch (Wexler/Barnes "content-aware fill").
    /// `image`: .rgba buffer; `hole`: .gray buffer of identical size. `sourceMask` (optional .gray, same size): pixels > 127 are
    /// allowed as patch sources (default: everything outside the hole).
    /// Returns a new .rgba buffer the same size as `image` with the hole filled; pixels outside the hole are unchanged.
    package static func inpaint(_ image: PixelBuffer, hole: PixelBuffer, sourceMask: PixelBuffer? = nil, patchSize: Int = 7,
                        progress: ((Double) -> Void)? = nil) -> PixelBuffer {
        let out = image.copy()
        guard image.format == .rgba else { return out }
        let holeReader = MaskReader(hole, width: image.width, height: image.height)
        guard let holeBox = holeReader.bounds(in: image.bounds) else { progress?(1); return out }

        let r = max(1, min(10, (patchSize | 1) / 2))
        let full = image.bounds
        let holeMax = max(holeBox.width, holeBox.height)
        // Thickness (2 x largest inscribed radius) drives the pyramid depth; thin scratches need no coarse levels.
        let thickness = min(holeMax, holeReader.thickness(in: holeBox))
        let holeSize = min(holeMax, max(thickness, Int(Double(holeBox.width * holeBox.height).squareRoot())))
        let margin = max(40, Int((1.5 * Double(holeSize)).rounded(.up))) + r
        var roi = expand(holeBox, margin).intersection(full)

        let srcReader = sourceMask.map { MaskReader($0, width: image.width, height: image.height) }
        var srcBox: IRect?
        if let sr = srcReader {
            srcBox = sr.bounds(in: full)
            // Allow the sampling area to reach a little further than the default margin when the user asks for it.
            if let sb = srcBox { roi = roi.union(sb.intersection(expand(holeBox, 2 * margin)).intersection(full)) }
        }

        var level0 = makeLevel0(image, holeReader, srcReader, roi: roi)
        level0.prepare(r: r)
        if level0.centers.count < 16, let sb = srcBox, roi.union(sb) != roi {
            // The sampling area lies mostly outside the working rect: include all of it.
            roi = roi.union(sb).intersection(full)
            level0 = makeLevel0(image, holeReader, srcReader, roi: roi)
            level0.prepare(r: r)
        }
        guard level0.holeCount > 0 else { progress?(1); return out }
        guard !level0.centers.isEmpty else { progress?(1); return out }

        // Pyramid: coarsest level has the hole at most ~16 px across.
        var levels = [level0]
        var holeExtent = thickness
        while holeExtent > coarsestHoleSize {
            let prev = levels[levels.count - 1]
            if (prev.w + 1) / 2 < 4 * r + 4 || (prev.h + 1) / 2 < 4 * r + 4 { break }
            let next = prev.downsampled()
            next.prepare(r: r)
            if next.centers.count < 24 || next.holeCount == 0 { break }
            levels.append(next)
            holeExtent = (holeExtent + 1) / 2
        }

        // Work estimate for progress reporting.
        let nLevels = levels.count
        func emIterations(_ li: Int) -> Int { li == nLevels - 1 ? 6 : (li == 0 ? 4 : 5) }
        var totalWork = 0.0
        for (li, l) in levels.enumerated() { totalWork += Double(l.targetCount * emIterations(li)) }
        var doneWork = 0.0
        progress?(0)

        var prevNNF: NNF?
        for li in stride(from: nLevels - 1, through: 0, by: -1) {
            let L = levels[li]
            let nnf = NNF(L)
            let seed = 0x5EED_1234_ABCD_0000 &+ UInt64(li) &* 0x1_0000
            if let coarse = prevNNF {
                L.initFromCoarse(levels[li + 1])
                nnf.upsample(from: coarse, r: r, seed: seed &+ 7)
                // Reconstruct the hole from the upsampled field so the finer level starts with full detail.
                nnf.computeDistances(r: r)
                nnf.vote(r: r)
            } else {
                L.onionPeelPatchFill(r: r)
                nnf.randomInit(seed: seed &+ 3)
            }
            let iters = emIterations(li)
            for em in 0..<iters {
                nnf.computeDistances(r: r)
                let passes = (li == nLevels - 1 && em == 0) ? 6 : 4
                for pass in 0..<passes {
                    nnf.patchMatchPass(r: r, pass: pass, seed: seed &+ UInt64(em * 16 + pass + 100))
                }
                nnf.vote(r: r)
                doneWork += Double(L.targetCount)
                progress?(min(1, doneWork / max(1, totalWork)))
            }
            prevNNF = nnf
        }

        // Write the finest level's hole pixels back (premultiplied).
        let L = levels[0]
        let op = out.data.assumingMemoryBound(to: UInt8.self)
        let img = L.img.p, holeP = L.hole.p
        for y in L.hy0...L.hy1 {
            let row = op + (roi.y + y) * out.bytesPerRow + roi.x * 4
            for x in L.hx0...L.hx1 where holeP[y * L.w + x] != 0 {
                let c = img[y * L.w + x]
                let a = max(0, min(255, c.w.rounded()))
                let pm = premultiplied(c)
                row[x * 4 + 0] = UInt8(max(0, min(a, pm.x.rounded())))
                row[x * 4 + 1] = UInt8(max(0, min(a, pm.y.rounded())))
                row[x * 4 + 2] = UInt8(max(0, min(a, pm.z.rounded())))
                row[x * 4 + 3] = UInt8(a)
            }
        }
        out.markDirty()
        progress?(1)
        return out
    }

    /// The pyramid stops once the hole is at most this thick (2 x inscribed radius) at the coarsest level, which puts
    /// a typical hole's extent at roughly 8-16 px there.
    private static let coarsestHoleSize = 8

    // MARK: - Setup

    private static func expand(_ r: IRect, _ m: Int) -> IRect {
        IRect(x: r.x - m, y: r.y - m, width: r.width + 2 * m, height: r.height + 2 * m)
    }

    private static func makeLevel0(_ image: PixelBuffer, _ hole: MaskReader, _ src: MaskReader?, roi: IRect) -> Level {
        let L = Level(w: roi.width, h: roi.height)
        let base = image.data.assumingMemoryBound(to: UInt8.self)
        let img = L.img.p, hp = L.hole.p, sp = L.src.p
        for y in 0..<roi.height {
            let row = base + (roi.y + y) * image.bytesPerRow + roi.x * 4
            let gy = roi.y + y
            for x in 0..<roi.width {
                let i = y * roi.width + x
                img[i] = fromPremultiplied(SIMD4(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]), Float(row[x * 4 + 3])))
                let gx = roi.x + x
                let isHole = hole.value(gx, gy) > 127
                hp[i] = isHole ? 1 : 0
                sp[i] = (!isHole && (src.map { $0.value(gx, gy) > 127 } ?? true)) ? 1 : 0
            }
        }
        return L
    }
}

// MARK: - Color representation

/// Pixels are stored as (r·m, g·m, b·m, a) with straight (un-premultiplied) 0...255 color, m = min(1, a / alphaKnee).
/// Opaque and mostly-opaque pixels are therefore matched on their true color, while the meaningless color of
/// (nearly) transparent pixels fades out so transparency matches transparency.
private let alphaKnee: Float = 64

/// Stored -> premultiplied (0...255 channels).
@inline(__always) private func premultiplied(_ c: SIMD4<Float>) -> SIMD4<Float> {
    let k = max(c.w, alphaKnee) / 255
    return SIMD4(c.x * k, c.y * k, c.z * k, c.w)
}

/// Premultiplied (0...255 channels) -> stored.
@inline(__always) private func fromPremultiplied(_ p: SIMD4<Float>) -> SIMD4<Float> {
    let k = 255 / max(p.w, alphaKnee)
    return SIMD4(p.x * k, p.y * k, p.z * k, p.w)
}

// MARK: - Mask access

private struct MaskReader {
    package let base: UnsafeMutablePointer<UInt8>
    package let bpr: Int, bpp: Int, off: Int, w: Int, h: Int

    package init(_ b: PixelBuffer, width: Int, height: Int) {
        base = b.data.assumingMemoryBound(to: UInt8.self)
        bpr = b.bytesPerRow
        bpp = b.bytesPerPixel
        off = b.format == .rgba ? 3 : 0   // RGBA masks: use alpha
        w = min(width, b.width)
        h = min(height, b.height)
    }

    @inline(__always) package func value(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < w, y < h else { return 0 }
        return base[y * bpr + x * bpp + off]
    }

    /// 2 x the largest chamfer distance from a hole pixel to the nearest non-hole pixel, within `box` (the hole bbox).
    package func thickness(in box: IRect) -> Int {
        let bw = box.width + 2, bh = box.height + 2
        var d = [Float](repeating: 0, count: bw * bh)
        for y in 0..<box.height {
            for x in 0..<box.width where value(box.x + x, box.y + y) > 127 { d[(y + 1) * bw + x + 1] = 1e9 }
        }
        let diag: Float = 1.41421356
        for y in 1..<(bh - 1) {
            for x in 1..<(bw - 1) where d[y * bw + x] > 0 {
                d[y * bw + x] = min(d[y * bw + x], d[y * bw + x - 1] + 1, d[(y - 1) * bw + x] + 1,
                                    d[(y - 1) * bw + x - 1] + diag, d[(y - 1) * bw + x + 1] + diag)
            }
        }
        var m: Float = 0
        for y in stride(from: bh - 2, through: 1, by: -1) {
            for x in stride(from: bw - 2, through: 1, by: -1) where d[y * bw + x] > 0 {
                let v = min(d[y * bw + x], d[y * bw + x + 1] + 1, d[(y + 1) * bw + x] + 1,
                            d[(y + 1) * bw + x + 1] + diag, d[(y + 1) * bw + x - 1] + diag)
                d[y * bw + x] = v
                m = max(m, v)
            }
        }
        return max(1, Int((2 * m).rounded()))
    }

    /// Bounding box of pixels > 127.
    package func bounds(in rect: IRect) -> IRect? {
        let r = rect.intersection(IRect(x: 0, y: 0, width: w, height: h))
        if r.isEmpty { return nil }
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for y in r.minY..<r.maxY {
            let row = base + y * bpr + off
            var first = -1, last = -1
            var x = r.minX
            while x < r.maxX { if row[x * bpp] > 127 { first = x; break }; x += 1 }
            if first < 0 { continue }
            x = r.maxX - 1
            while x >= first { if row[x * bpp] > 127 { last = x; break }; x -= 1 }
            if y0 == Int.max { y0 = y }
            y1 = y
            x0 = min(x0, first); x1 = max(x1, last)
        }
        if x1 < 0 { return nil }
        return IRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }
}

// MARK: - Storage

private final class Buf<T> {
    package let p: UnsafeMutablePointer<T>
    package let n: Int
    package init(_ n: Int, _ v: T) {
        self.n = max(1, n)
        p = .allocate(capacity: self.n)
        p.initialize(repeating: v, count: self.n)
    }
    deinit { p.deallocate() }   // only trivial element types are stored
}

private struct SplitMix {
    package var s: UInt64
    package init(_ seed: UInt64) { s = seed ^ 0x9E37_79B9_7F4A_7C15 }
    @inline(__always) package mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in 0..<n (n > 0).
    @inline(__always) package mutating func below(_ n: Int) -> Int { Int((next() >> 11) % UInt64(n)) }
    /// Uniform in -r...r.
    @inline(__always) package mutating func around(_ r: Int) -> Int { below(2 * r + 1) - r }
}

private let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)

/// Runs `body(lo, hi)` over [0, n) split into chunks, concurrently.
private func parallelChunks(_ n: Int, minChunk: Int = 8, _ body: (Int, Int) -> Void) {
    if n <= 0 { return }
    let chunks = max(1, min(workerCount * 4, n / max(1, minChunk)))
    if chunks == 1 { body(0, n); return }
    DispatchQueue.concurrentPerform(iterations: chunks) { c in
        body(n * c / chunks, n * (c + 1) / chunks)
    }
}

// MARK: - Pyramid level

private final class Level {
    package let w: Int, h: Int
    /// Straight (un-premultiplied) RGB + alpha, 0...255.
    package let img: Buf<SIMD4<Float>>
    /// 1 = pixel must be synthesized.
    package let hole: Buf<UInt8>
    /// 1 = pixel may be copied from (known and inside the sampling area).
    package let src: Buf<UInt8>

    // Derived by prepare(r:)
    package var valid: Buf<UInt8>!      // patch centred here lies fully in the source area
    package var centers: [Int32] = []   // indices of valid centers
    package var target: Buf<UInt8>!     // patch centred here overlaps the hole
    package var conf: Buf<Float>!       // voting confidence (decays with distance to known pixels)
    package var holeCount = 0, targetCount = 0
    package var hx0 = 0, hy0 = 0, hx1 = -1, hy1 = -1   // hole bbox (inclusive)
    package var tx0 = 0, ty0 = 0, tx1 = -1, ty1 = -1   // target bbox (inclusive)

    package init(w: Int, h: Int) {
        self.w = w; self.h = h
        img = Buf(w * h, .zero)
        hole = Buf(w * h, 0)
        src = Buf(w * h, 0)
    }

    package func prepare(r: Int) {
        let n = w * h, W1 = w + 1
        // Summed-area tables of "not a source" and "hole".
        var satBad = [Int32](repeating: 0, count: W1 * (h + 1))
        var satHole = [Int32](repeating: 0, count: W1 * (h + 1))
        hx0 = w; hy0 = h; hx1 = -1; hy1 = -1
        holeCount = 0
        let hp = hole.p, sp = src.p
        satBad.withUnsafeMutableBufferPointer { sb in
            satHole.withUnsafeMutableBufferPointer { sh in
                for y in 0..<h {
                    var rb: Int32 = 0, rh: Int32 = 0
                    for x in 0..<w {
                        let i = y * w + x
                        rb += sp[i] == 0 ? 1 : 0
                        let hv = hp[i]
                        rh += Int32(hv)
                        if hv != 0 {
                            holeCount += 1
                            if x < hx0 { hx0 = x }; if x > hx1 { hx1 = x }
                            if y < hy0 { hy0 = y }; hy1 = y
                        }
                        sb[(y + 1) * W1 + x + 1] = sb[y * W1 + x + 1] + rb
                        sh[(y + 1) * W1 + x + 1] = sh[y * W1 + x + 1] + rh
                    }
                }
            }
        }
        let valid = Buf<UInt8>(n, 0)
        let target = Buf<UInt8>(n, 0)
        var centers: [Int32] = []
        centers.reserveCapacity(n / 2)
        if w > 2 * r && h > 2 * r {
            for y in r..<(h - r) {
                for x in r..<(w - r) {
                    let a = (y - r) * W1 + (x - r), b = (y - r) * W1 + (x + r + 1)
                    let c = (y + r + 1) * W1 + (x - r), d = (y + r + 1) * W1 + (x + r + 1)
                    if satBad[d] - satBad[b] - satBad[c] + satBad[a] == 0 {
                        valid.p[y * w + x] = 1
                        centers.append(Int32(y * w + x))
                    }
                }
            }
        }
        targetCount = 0
        if holeCount > 0 {
            tx0 = max(0, hx0 - r); tx1 = min(w - 1, hx1 + r)
            ty0 = max(0, hy0 - r); ty1 = min(h - 1, hy1 + r)
            for y in ty0...ty1 {
                let ya = max(0, y - r), yb = min(h - 1, y + r) + 1
                for x in tx0...tx1 {
                    let xa = max(0, x - r), xb = min(w - 1, x + r) + 1
                    if satHole[yb * W1 + xb] - satHole[ya * W1 + xb] - satHole[yb * W1 + xa] + satHole[ya * W1 + xa] > 0 {
                        target.p[y * w + x] = 1
                        targetCount += 1
                    }
                }
            }
        }
        self.valid = valid
        self.centers = centers
        self.target = target
        computeConfidence()
    }

    /// Chamfer distance to the nearest known pixel -> gamma^-d (Wexler's boundary-favouring weight).
    private func computeConfidence() {
        let conf = Buf<Float>(w * h, 1)
        guard holeCount > 0 else { self.conf = conf; return }
        let x0 = max(0, hx0 - 1), x1 = min(w - 1, hx1 + 1), y0 = max(0, hy0 - 1), y1 = min(h - 1, hy1 + 1)
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1
        var d = [Float](repeating: 0, count: bw * bh)
        let big: Float = 1e9, diag: Float = 1.41421356
        for y in 0..<bh { for x in 0..<bw where hole.p[(y + y0) * w + x + x0] != 0 { d[y * bw + x] = big } }
        for y in 0..<bh {
            for x in 0..<bw {
                var v = d[y * bw + x]
                if v == 0 { continue }
                if x > 0 { v = min(v, d[y * bw + x - 1] + 1) }
                if y > 0 {
                    v = min(v, d[(y - 1) * bw + x] + 1)
                    if x > 0 { v = min(v, d[(y - 1) * bw + x - 1] + diag) }
                    if x < bw - 1 { v = min(v, d[(y - 1) * bw + x + 1] + diag) }
                }
                d[y * bw + x] = v
            }
        }
        for y in stride(from: bh - 1, through: 0, by: -1) {
            for x in stride(from: bw - 1, through: 0, by: -1) {
                var v = d[y * bw + x]
                if v == 0 { continue }
                if x < bw - 1 { v = min(v, d[y * bw + x + 1] + 1) }
                if y < bh - 1 {
                    v = min(v, d[(y + 1) * bw + x] + 1)
                    if x < bw - 1 { v = min(v, d[(y + 1) * bw + x + 1] + diag) }
                    if x > 0 { v = min(v, d[(y + 1) * bw + x - 1] + diag) }
                }
                d[y * bw + x] = v
            }
        }
        let lg = log(Float(1.3))
        for y in 0..<bh {
            for x in 0..<bw {
                let v = d[y * bw + x]
                if v > 0 { conf.p[(y + y0) * w + x + x0] = exp(-lg * min(v, 200)) }
            }
        }
        self.conf = conf
    }

    /// 2x box downsample; a coarse pixel is a hole if any child is, a source only if all children are.
    package func downsampled() -> Level {
        let nw = (w + 1) / 2, nh = (h + 1) / 2
        let L = Level(w: nw, h: nh)
        let si = img.p, sh = hole.p, ss = src.p
        let di = L.img.p, dh = L.hole.p, ds = L.src.p
        let w = self.w, h = self.h
        parallelChunks(nh) { lo, hi in
            for y in lo..<hi {
                for x in 0..<nw {
                    var acc = SIMD4<Float>.zero
                    var cnt: Float = 0
                    var anyHole = false, allSrc = true
                    for yy in (2 * y)..<min(h, 2 * y + 2) {
                        for xx in (2 * x)..<min(w, 2 * x + 2) {
                            let i = yy * w + xx
                            if sh[i] != 0 { anyHole = true } else {
                                acc += premultiplied(si[i])
                                cnt += 1
                            }
                            if ss[i] == 0 { allSrc = false }
                        }
                    }
                    let o = y * nw + x
                    dh[o] = anyHole ? 1 : 0
                    ds[o] = (allSrc && !anyHole) ? 1 : 0
                    di[o] = cnt > 0 ? fromPremultiplied(acc / cnt) : .zero
                }
            }
        }
        return L
    }

    /// Initial guess at the coarsest level: fill the hole inwards from its border with averages of known neighbours.
    package func onionPeelFill() {
        guard holeCount > 0 else { return }
        var known = [UInt8](repeating: 1, count: w * h)
        for i in 0..<(w * h) where hole.p[i] != 0 { known[i] = 0 }
        var pending: [Int] = []
        for y in hy0...hy1 { for x in hx0...hx1 where known[y * w + x] == 0 { pending.append(y * w + x) } }
        let img = self.img.p
        while !pending.isEmpty {
            var layer: [(Int, SIMD4<Float>)] = []
            var rest: [Int] = []
            for i in pending {
                let x = i % w, y = i / w
                var acc = SIMD4<Float>.zero, cnt: Float = 0
                for dy in -1...1 {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx < 0 || xx >= w || known[yy * w + xx] == 0 { continue }
                        let c = img[yy * w + xx]
                        acc += premultiplied(c)
                        cnt += 1
                    }
                }
                if cnt > 0 {
                    let v = fromPremultiplied(acc / cnt)
                    layer.append((i, v))
                } else {
                    rest.append(i)
                }
            }
            if layer.isEmpty { break }   // no known pixels at all
            for (i, v) in layer { img[i] = v; known[i] = 1 }
            pending = rest
        }
    }

    /// Initial guess at the coarsest level: peel the hole from its border inwards; each pixel of a layer copies the centre of the
    /// source patch that best matches its already-known neighbourhood (masked SSD). Gives structure-aware starting points
    /// instead of a smooth diffusion that would bias the EM towards blurry or leaked content.
    package func onionPeelPatchFill(r: Int) {
        guard holeCount > 0 else { return }
        guard !centers.isEmpty else { onionPeelFill(); return }
        let w = self.w, h = self.h, img = self.img.p
        var known = [UInt8](repeating: 1, count: w * h)
        var srcOf = [Int32](repeating: -1, count: w * h)
        var pending: [Int] = []
        for y in hy0...hy1 { for x in hx0...hx1 where hole.p[y * w + x] != 0 { known[y * w + x] = 0; pending.append(y * w + x) } }
        // Candidate sources: all valid centres, or an even subsample when that would be too slow.
        let nCand = min(centers.count, max(256, 1_500_000 / max(1, holeCount)))
        var cands = [Int32](repeating: 0, count: nCand)
        for k in 0..<nCand { cands[k] = centers[k * centers.count / nCand] }

        while !pending.isEmpty {
            var layer: [Int] = [], rest: [Int] = []
            for i in pending {
                let x = i % w, y = i / w
                var touches = false
                for dy in -1...1 where !touches {
                    let yy = y + dy
                    if yy < 0 || yy >= h { continue }
                    for dx in -1...1 {
                        let xx = x + dx
                        if xx >= 0 && xx < w && known[yy * w + xx] != 0 { touches = true; break }
                    }
                }
                if touches { layer.append(i) } else { rest.append(i) }
            }
            if layer.isEmpty { break }
            var chosen = [Int32](repeating: -1, count: layer.count)
            known.withUnsafeBufferPointer { kn in
                srcOf.withUnsafeBufferPointer { so in
                    cands.withUnsafeBufferPointer { cd in
                        chosen.withUnsafeMutableBufferPointer { ch in
                            let kp = kn.baseAddress!, sp = so.baseAddress!, cp = cd.baseAddress!, chp = ch.baseAddress!
                            let valid = self.valid.p
                            parallelChunks(layer.count, minChunk: 4) { lo, hi in
                                for li in lo..<hi {
                                    let p = layer[li], x = p % w, y = p / w
                                    let ya = max(-r, -y), yb = min(r, h - 1 - y)
                                    let xa = max(-r, -x), xb = min(r, w - 1 - x)
                                    var best: Float = .greatestFiniteMagnitude
                                    var bestS = -1
                                    @inline(__always) func test(_ s: Int) {
                                        let sx = s % w, sy = s / w
                                        var sum: Float = 0
                                        var dy = ya
                                        while dy <= yb {
                                            let tRow = (y + dy) * w + x, sRow = (sy + dy) * w + sx
                                            var acc = SIMD4<Float>.zero
                                            var dx = xa
                                            while dx <= xb {
                                                if kp[tRow + dx] != 0 { let d = img[tRow + dx] - img[sRow + dx]; acc += d * d }
                                                dx += 1
                                            }
                                            sum += acc.sum()
                                            if sum >= best { return }
                                            dy += 1
                                        }
                                        best = sum; bestS = s
                                    }
                                    // Coherent candidates first: continue the matches of already-filled neighbours.
                                    for dy in -1...1 {
                                        for dx in -1...1 where dx != 0 || dy != 0 {
                                            let xx = x + dx, yy = y + dy
                                            if xx < 0 || yy < 0 || xx >= w || yy >= h { continue }
                                            let q = sp[yy * w + xx]
                                            if q < 0 { continue }
                                            let cx = Int(q) % w - dx, cy = Int(q) / w - dy
                                            if cx >= 0 && cy >= 0 && cx < w && cy < h && valid[cy * w + cx] != 0 { test(cy * w + cx) }
                                        }
                                    }
                                    for k in 0..<nCand { test(Int(cp[k])) }
                                    chp[li] = Int32(bestS)
                                }
                            }
                        }
                    }
                }
            }
            for (li, p) in layer.enumerated() {
                let s = Int(chosen[li])
                if s >= 0 { img[p] = img[s]; srcOf[p] = Int32(s) }
                known[p] = 1
            }
            pending = rest
        }
    }

    /// Initial guess from the (already filled) coarser level: bilinear upsample into the hole.
    package func initFromCoarse(_ c: Level) {
        guard holeCount > 0 else { return }
        let ci = c.img.p, cw = c.w, ch = c.h
        let img = self.img.p, hp = hole.p, w = self.w
        let x0 = hx0, x1 = hx1
        let y0 = hy0
        parallelChunks(hy1 - hy0 + 1) { lo, hi in
            for y in (y0 + lo)..<(y0 + hi) {
                let fy = max(0, min(Float(ch - 1), (Float(y) + 0.5) * 0.5 - 0.5))
                let iy = min(ch - 2, Int(fy)), ty = fy - Float(max(0, iy))
                let yA = max(0, iy), yB = min(ch - 1, yA + 1)
                for x in x0...x1 where hp[y * w + x] != 0 {
                    let fx = max(0, min(Float(cw - 1), (Float(x) + 0.5) * 0.5 - 0.5))
                    let ix = min(cw - 2, Int(fx)), tx = fx - Float(max(0, ix))
                    let xA = max(0, ix), xB = min(cw - 1, xA + 1)
                    let a = ci[yA * cw + xA], b = ci[yA * cw + xB], cc = ci[yB * cw + xA], d = ci[yB * cw + xB]
                    let top = a + (b - a) * tx, bot = cc + (d - cc) * tx
                    img[y * w + x] = top + (bot - top) * ty
                }
            }
        }
    }
}

// MARK: - Nearest-neighbour field

private final class NNF {
    package let L: Level
    package let nx: Buf<Int32>, ny: Buf<Int32>
    package let nd: Buf<Float>
    package let wt: Buf<Float>

    package init(_ L: Level) {
        self.L = L
        nx = Buf(L.w * L.h, 0)
        ny = Buf(L.w * L.h, 0)
        nd = Buf(L.w * L.h, .greatestFiniteMagnitude)
        wt = Buf(L.w * L.h, 0)
    }

    /// Sum of squared differences between the target patch at (tx,ty) and the source patch at (sx,sy); stops early past `limit`.
    @inline(__always)
    package static func distance(_ img: UnsafeMutablePointer<SIMD4<Float>>, _ w: Int, _ h: Int, _ r: Int,
                         _ tx: Int, _ ty: Int, _ sx: Int, _ sy: Int, _ limit: Float) -> Float {
        let ya = max(-r, -ty), yb = min(r, h - 1 - ty)
        let xa = max(-r, -tx), xb = min(r, w - 1 - tx)
        var s: Float = 0
        var dy = ya
        while dy <= yb {
            let tRow = img + (ty + dy) * w + tx
            let sRow = img + (sy + dy) * w + sx
            var acc = SIMD4<Float>.zero
            var dx = xa
            while dx <= xb {
                let d = tRow[dx] - sRow[dx]
                acc += d * d
                dx += 1
            }
            s += acc.sum()
            if s >= limit { return s }
            dy += 1
        }
        return s
    }

    /// SSD over a (2R+1)² window sampled every 2 pixels, clipped so both windows stay inside the level.
    @inline(__always)
    package static func wideDistance(_ img: UnsafeMutablePointer<SIMD4<Float>>, _ w: Int, _ h: Int, _ R: Int,
                             _ tx: Int, _ ty: Int, _ sx: Int, _ sy: Int, _ limit: Float) -> Float {
        let ya = max(-R, -ty, -sy), yb = min(R, h - 1 - ty, h - 1 - sy)
        let xa = max(-R, -tx, -sx), xb = min(R, w - 1 - tx, w - 1 - sx)
        if yb < ya || xb < xa { return .greatestFiniteMagnitude }
        var s: Float = 0
        var n: Float = 0
        var dy = ya
        while dy <= yb {
            let tRow = img + (ty + dy) * w + tx
            let sRow = img + (sy + dy) * w + sx
            var acc = SIMD4<Float>.zero
            var dx = xa
            while dx <= xb {
                let d = tRow[dx] - sRow[dx]
                acc += d * d
                n += 1
                dx += 2
            }
            s += acc.sum()
            dy += 2
        }
        return n > 0 ? s / n : .greatestFiniteMagnitude
    }

    /// Rows of the target bbox, processed in parallel; `body(y)`.
    private func forTargetRows(_ body: (Int) -> Void) {
        let y0 = L.ty0, n = L.ty1 - L.ty0 + 1
        guard n > 0 else { return }
        parallelChunks(n, minChunk: max(1, 2048 / max(1, L.tx1 - L.tx0 + 1))) { lo, hi in for y in lo..<hi { body(y0 + y) } }
    }

    package func randomInit(seed: UInt64) {
        let L = self.L, w = L.w
        let target = L.target.p, centers = L.centers
        guard !centers.isEmpty else { return }
        var rng = SplitMix(seed)
        for y in L.ty0...L.ty1 {
            for x in L.tx0...L.tx1 where target[y * w + x] != 0 {
                let c = Int(centers[rng.below(centers.count)])
                nx.p[y * w + x] = Int32(c % w)
                ny.p[y * w + x] = Int32(c / w)
            }
        }
    }

    /// Initialize from the coarser level's field (offsets doubled), repairing invalid entries.
    package func upsample(from c: NNF, r: Int, seed: UInt64) {
        let L = self.L, w = L.w, h = L.h
        let cw = c.L.w, ch = c.L.h
        let target = L.target.p, valid = L.valid.p, centers = L.centers
        let cnx = c.nx.p, cny = c.ny.p, ctarget = c.L.target.p
        let nx = self.nx.p, ny = self.ny.p, img = L.img.p
        let sr = 2, pr = 6
        forTargetRows { y in
            var rng = SplitMix(seed &+ UInt64(y) &* 0x9E3779B1)
            for x in L.tx0...L.tx1 where target[y * w + x] != 0 {
                let cx = min(cw - 1, x / 2), cy = min(ch - 1, y / 2)
                let ci = cy * cw + cx
                var sx = -1, sy = -1
                if ctarget[ci] != 0 {
                    sx = Int(cnx[ci]) * 2 + (x - cx * 2)
                    sy = Int(cny[ci]) * 2 + (y - cy * 2)
                    sx = max(r, min(w - 1 - r, sx)); sy = max(r, min(h - 1 - r, sy))
                    if valid[sy * w + sx] == 0 {
                        // Look for a valid centre nearby.
                        var found = false
                        search: for rad in 1...3 {
                            for dy in -rad...rad {
                                for dx in -rad...rad where abs(dx) == rad || abs(dy) == rad {
                                    let xx = sx + dx, yy = sy + dy
                                    if xx >= 0 && yy >= 0 && xx < w && yy < h && valid[yy * w + xx] != 0 {
                                        sx = xx; sy = yy; found = true
                                        break search
                                    }
                                }
                            }
                        }
                        if !found { sx = -1 }
                    }
                }
                if sx < 0 {
                    let p = Int(centers[rng.below(centers.count)])
                    sx = p % w; sy = p / w
                }
                // Sub-pixel phase correction: the coarse match is only accurate to half a coarse pixel, so pick the
                // best of the 3x3 neighbouring sources against the upsampled estimate.
                if sr > 0 {
                    // Judge the shift on a wide, sparsely sampled window so neighbouring pixels agree (a per-pixel
                    // choice would make the field incoherent in flat areas).
                    var bd = NNF.wideDistance(img, w, h, pr, x, y, sx, sy, .greatestFiniteMagnitude)
                    var bx = sx, by = sy
                    for dy in -sr...sr {
                        for dx in -sr...sr where dx != 0 || dy != 0 {
                            let cx = sx + dx, cy = sy + dy
                            if cx < 0 || cy < 0 || cx >= w || cy >= h || valid[cy * w + cx] == 0 { continue }
                            let d = NNF.wideDistance(img, w, h, pr, x, y, cx, cy, bd)
                            if d < bd { bd = d; bx = cx; by = cy }
                        }
                    }
                    sx = bx; sy = by
                }
                nx[y * w + x] = Int32(sx)
                ny[y * w + x] = Int32(sy)
            }
        }
    }

    package func computeDistances(r: Int) {
        let L = self.L, w = L.w, h = L.h
        let img = L.img.p, target = L.target.p
        let nx = self.nx.p, ny = self.ny.p, nd = self.nd.p
        forTargetRows { y in
            for x in L.tx0...L.tx1 where target[y * w + x] != 0 {
                let i = y * w + x
                nd[i] = NNF.distance(img, w, h, r, x, y, Int(nx[i]), Int(ny[i]), .greatestFiniteMagnitude)
            }
        }
    }

    /// One PatchMatch sweep (propagation + random search). Rows are split into bands processed concurrently;
    /// propagation never crosses a band edge so results are deterministic.
    package func patchMatchPass(r: Int, pass: Int, seed: UInt64) {
        let L = self.L, w = L.w, h = L.h
        let img = L.img.p, target = L.target.p, valid = L.valid.p
        let nx = self.nx.p, ny = self.ny.p, nd = self.nd.p
        let rows = L.ty1 - L.ty0 + 1, cols = L.tx1 - L.tx0 + 1
        guard rows > 0, cols > 0 else { return }
        // Split along the longer axis; odd passes shift the band edges by half a band so propagation crosses them.
        let splitRows = rows >= cols
        let span = splitRows ? rows : cols
        let bands = max(1, min(workerCount * 2, span / 12))
        let shift = (pass & 2) != 0 ? span / (2 * bands) : 0
        let fwd = pass % 2 == 0
        let dir = fwd ? 1 : -1
        let maxRad = max(w, h)
        let tx0 = L.tx0, tx1 = L.tx1, ty0 = L.ty0, ty1 = L.ty1

        let work: (Int) -> Void = { b in
            var lo = span * b / bands + shift, hi = span * (b + 1) / bands + shift - 1
            if b == 0 { lo = 0 }
            if b == bands - 1 { hi = span - 1 }
            if hi < lo { return }
            let xa = splitRows ? tx0 : tx0 + lo, xb = splitRows ? tx1 : tx0 + hi
            let ya = splitRows ? ty0 + lo : ty0, yb = splitRows ? ty0 + hi : ty1
            var rng = SplitMix(seed &+ UInt64(b) &* 0x2545F4914F6CDD1D)
            let ncols = xb - xa + 1
            var y = fwd ? ya : yb
            for _ in 0...(yb - ya) {
                var x = fwd ? xa : xb
                for _ in 0..<ncols {
                    let i = y * w + x
                    if target[i] != 0 {
                        var bx = Int(nx[i]), by = Int(ny[i]), bd = nd[i]
                        // Propagation (horizontal neighbour, same band only).
                        let xn = x - dir
                        if xn >= xa && xn <= xb {
                            let j = i - dir
                            if target[j] != 0 {
                                let cx = Int(nx[j]) + dir, cy = Int(ny[j])
                                if cx >= 0 && cx < w && valid[cy * w + cx] != 0 && (cx != bx || cy != by) {
                                    let d = NNF.distance(img, w, h, r, x, y, cx, cy, bd)
                                    if d < bd { bd = d; bx = cx; by = cy }
                                }
                            }
                        }
                        // Propagation (vertical neighbour, same band only).
                        let yn = y - dir
                        if yn >= ya && yn <= yb {
                            let j = i - dir * w
                            if target[j] != 0 {
                                let cx = Int(nx[j]), cy = Int(ny[j]) + dir
                                if cy >= 0 && cy < h && valid[cy * w + cx] != 0 && (cx != bx || cy != by) {
                                    let d = NNF.distance(img, w, h, r, x, y, cx, cy, bd)
                                    if d < bd { bd = d; bx = cx; by = cy }
                                }
                            }
                        }
                        // Random search with exponentially shrinking radius.
                        var rad = maxRad
                        while rad >= 1 {
                            let cx = bx + rng.around(rad), cy = by + rng.around(rad)
                            if cx >= 0 && cy >= 0 && cx < w && cy < h && valid[cy * w + cx] != 0 && (cx != bx || cy != by) {
                                let d = NNF.distance(img, w, h, r, x, y, cx, cy, bd)
                                if d < bd { bd = d; bx = cx; by = cy }
                            }
                            rad >>= 1
                        }
                        nx[i] = Int32(bx); ny[i] = Int32(by); nd[i] = bd
                    }
                    x += dir
                }
                y += dir
            }
        }
        if bands == 1 { work(0) } else { DispatchQueue.concurrentPerform(iterations: bands, execute: work) }
    }

    /// EM "M" step: every hole pixel becomes the weighted average of the source pixels that overlapping patches map onto it.
    package func vote(r: Int) {
        let L = self.L, w = L.w, h = L.h
        guard L.holeCount > 0 else { return }
        let target = L.target.p, conf = L.conf.p, hole = L.hole.p, img = L.img.p
        let nx = self.nx.p, ny = self.ny.p, nd = self.nd.p, wt = self.wt.p

        // Similarity weights: exp(-d / 2σ²), σ² = 75th percentile of mean per-pixel distances.
        var samples: [Float] = []
        samples.reserveCapacity(4096)
        let step = max(1, L.targetCount / 4096)
        var k = 0
        for y in L.ty0...L.ty1 {
            for x in L.tx0...L.tx1 where target[y * w + x] != 0 {
                k += 1
                if k % step != 0 { continue }
                let cnt = Float((min(r, h - 1 - y) + min(r, y) + 1) * (min(r, w - 1 - x) + min(r, x) + 1))
                samples.append(nd[y * w + x] / cnt)
            }
        }
        var sigma2: Float = 1
        if !samples.isEmpty {
            samples.sort()
            sigma2 = max(4, samples[min(samples.count - 1, samples.count * 3 / 4)])
        }
        let inv = 1 / (2 * sigma2)
        forTargetRows { y in
            for x in L.tx0...L.tx1 where target[y * w + x] != 0 {
                let i = y * w + x
                let cnt = Float((min(r, h - 1 - y) + min(r, y) + 1) * (min(r, w - 1 - x) + min(r, x) + 1))
                let e = max(-40, -(nd[i] / cnt) * inv)
                wt[i] = conf[i] * exp(e)
            }
        }

        let hx0 = L.hx0, hx1 = L.hx1, hy0 = L.hy0
        parallelChunks(L.hy1 - L.hy0 + 1, minChunk: max(1, 1024 / max(1, L.hx1 - L.hx0 + 1))) { lo, hi in
            for y in (hy0 + lo)..<(hy0 + hi) {
                for x in hx0...hx1 where hole[y * w + x] != 0 {
                    var acc = SIMD4<Float>.zero
                    var ws: Float = 0
                    var bestW: Float = -1
                    var bestC = SIMD4<Float>.zero
                    for dy in -r...r {
                        let ty = y - dy
                        if ty < 0 || ty >= h { continue }
                        for dx in -r...r {
                            let tx = x - dx
                            if tx < 0 || tx >= w { continue }
                            let t = ty * w + tx
                            let c = img[(Int(ny[t]) + dy) * w + Int(nx[t]) + dx]
                            let wv = wt[t]
                            acc += premultiplied(c) * wv
                            ws += wv
                            if wv > bestW { bestW = wv; bestC = c }
                        }
                    }
                    if ws > 1e-30 {
                        img[y * w + x] = fromPremultiplied(acc / ws)
                    } else {
                        img[y * w + x] = bestC
                    }
                }
            }
        }
    }
}
