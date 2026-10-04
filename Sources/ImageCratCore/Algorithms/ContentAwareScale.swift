import Foundation

/// Photoshop-style "Content-Aware Scale" built on seam carving (Avidan & Shamir 2007) with
/// forward energy (Rubinstein, Shamir & Avidan 2008).
///
/// Pipeline per axis (width first, then height via transpose):
/// 1. Area-downsample the image (and protection mask) to at most `workingMaxSide` px on the long side.
/// 2. Carve `k` seams on that working copy (removal for shrinking; for enlarging the k lowest-energy
///    seams are found by removal on a copy and later duplicated).
/// 3. Turn the per-row seam pattern into a per-row column *density* (0 = removed, 1 = kept, 2 = duplicated),
///    soften it slightly (never touching protected columns), blend with uniform scaling by `amount`,
///    and integrate it into a smooth monotone x-mapping.
/// 4. Resample every full-resolution row through that mapping (box filter where compressed, linear where
///    stretched), interpolating the mapping between working rows.
package enum ContentAwareScale {
    /// Long-side size of the working copy used for seam computation.
    package static var workingMaxSide = 800

    /// Resizes an .rgba buffer to `newWidth`×`newHeight` while preserving important content (Photoshop "Content-Aware Scale").
    /// `protect` (optional .gray, same size as input): pixels > 127 must not be distorted. `amount` 0...1 blends between plain scaling (0) and content-aware (1).
    package static func scale(_ src: PixelBuffer, newWidth: Int, newHeight: Int, protect: PixelBuffer? = nil, amount: Double = 1) -> PixelBuffer {
        let nw = max(1, newWidth), nh = max(1, newHeight)
        let amt = amount.isFinite ? min(1, max(0, amount)) : 1
        var img = src.format == .rgba ? src : src.toRGBA()
        var mask = protect.map { preparedMask($0, width: src.width, height: src.height) }

        if nw != img.width {
            let r = scaleWidth(img, mask: mask, newWidth: nw, amount: amt)
            img = r.0; mask = r.1
        }
        if nh != img.height {
            let t = transpose(img)
            let tm = mask.map { transpose($0) }
            let r = scaleWidth(t, mask: tm, newWidth: nh, amount: amt)
            img = transpose(r.0)
        }
        if img === src { return src.copy() }
        img.markDirty()
        return img
    }

    // MARK: - Mask preparation

    /// Returns a .gray mask of exactly width×height (nearest-resampled if the supplied mask differs).
    private static func preparedMask(_ m: PixelBuffer, width: Int, height: Int) -> PixelBuffer {
        let g = m.format == .gray ? m : m.toGray(useAlpha: true)
        if g.width == width && g.height == height { return g }
        let out = PixelBuffer(width: width, height: height, format: .gray)
        let s = g.data.assumingMemoryBound(to: UInt8.self)
        let d = out.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let sy = min(g.height - 1, y * g.height / height)
            for x in 0..<width {
                let sx = min(g.width - 1, x * g.width / width)
                d[y * out.bytesPerRow + x] = s[sy * g.bytesPerRow + sx]
            }
        }
        return out
    }

    // MARK: - One axis

    /// Largest per-step enlargement ratio; bigger enlargements are split into several insertion rounds so
    /// that the k duplicated seams don't have to run through important content.
    private static let maxInsertStep = 1.3

    private static func scaleWidth(_ img: PixelBuffer, mask: PixelBuffer?, newWidth nw: Int, amount: Double) -> (PixelBuffer, PixelBuffer?) {
        let W = img.width, H = img.height
        let s = min(1.0, Double(workingMaxSide) / Double(max(W, H)))
        let sw = max(1, Int((Double(W) * s).rounded()))
        let sh = max(1, Int((Double(H) * s).rounded()))

        // Working copy.
        var cur = downsample(img, mask: mask, sw: sw, sh: sh)

        // Rounds of carving. Each round yields, per working row, the cumulative output position of every
        // source column edge (a monotone piecewise-linear forward map).
        let T = Double(nw) * Double(sw) / Double(W)        // final width in working units
        let rTotal = T / Double(sw)
        let rounds = (amount > 0 && rTotal > maxInsertStep) ? max(1, Int(ceil(log(rTotal) / log(maxInsertStep) - 1e-9))) : 1
        var cums: [[Double]] = []
        var widths: [Int] = []
        for round in 0..<rounds {
            let wi = cur.w
            let last = round == rounds - 1
            let target = last ? T : (Double(sw) * pow(rTotal, Double(round + 1) / Double(rounds))).rounded()
            var counts = [UInt16](repeating: 0, count: wi * sh)
            let k = min(wi - 1, Int(abs(target - Double(wi)).rounded()))
            if amount > 0 && k > 0 {
                let energy = staticEnergy(cur, w: wi, h: sh)
                carve(lum: cur.lum, energy: energy, w: wi, h: sh, k: k, counts: &counts)
            }
            let cum = cumulativeMap(counts: counts, prot: cur.prot, w: wi, h: sh, shrinking: target < Double(wi),
                                    target: target, amount: amount)
            cums.append(cum); widths.append(wi)
            if !last { cur = resampleWork(cur, cum: cum, newWidth: Int(target)) }
        }

        // Compose the inverse maps: for each full-res output edge, the full-res source edge.
        let edgeCount = nw + 1
        var edges = [Float](repeating: 0, count: sh * edgeCount)
        edges.withUnsafeMutableBufferPointer { eb in
            let ep = eb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: sh) { y in
                let toSmall = Double(sw) / Double(W), toFull = Double(W) / Double(sw)
                var v = [Double](repeating: 0, count: edgeCount)
                for X in 0..<edgeCount { v[X] = Double(X) * toSmall }
                for r in stride(from: rounds - 1, through: 0, by: -1) {
                    let wi = widths[r]
                    cums[r].withUnsafeBufferPointer { cb in invert(cb.baseAddress! + y * (wi + 1), width: wi, values: &v) }
                }
                let erow = ep + y * edgeCount
                for X in 0..<edgeCount { erow[X] = Float(min(Double(W), max(0, v[X] * toFull))) }
                erow[0] = 0; erow[edgeCount - 1] = Float(W)
                for X in 1..<edgeCount where erow[X] < erow[X - 1] { erow[X] = erow[X - 1] }
            }
        }

        let out = PixelBuffer(width: nw, height: H, format: .rgba)
        let outMask: PixelBuffer? = mask.map { _ in PixelBuffer(width: nw, height: H, format: .gray) }
        resampleRows(src: img, dst: out, srcMask: mask, dstMask: outMask, edges: edges, edgeCount: edgeCount, sh: sh)
        return (out, outMask)
    }

    /// Per row: column densities from the seam pattern (0 removed / 1 kept / 1+n duplicated), softened
    /// without touching protected columns, normalised to `target`, blended with uniform scaling by `amount`,
    /// then integrated. Returns h × (w + 1) cumulative output positions.
    private static func cumulativeMap(counts: [UInt16], prot: [UInt8], w: Int, h: Int, shrinking: Bool,
                                      target: Double, amount: Double) -> [Double] {
        var cum = [Double](repeating: 0, count: h * (w + 1))
        let r = target / Double(w)
        cum.withUnsafeMutableBufferPointer { ob in
            let op = ob.baseAddress!
            counts.withUnsafeBufferPointer { cb in
                prot.withUnsafeBufferPointer { pb in
                    let cp = cb.baseAddress!, pp = pb.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        var d = [Double](repeating: 1, count: w)
                        var dens = [Double](repeating: 0, count: w)
                        let crow = cp + y * w, prow = pp + y * w
                        for x in 0..<w {
                            let c = Double(crow[x])
                            d[x] = shrinking ? max(0, 1 - c) : 1 + c
                        }
                        // Mass-conserving [1 2 1]/4 softening that never moves density into/out of protected columns.
                        for x in 0..<w {
                            let v = d[x]
                            if prow[x] != 0 { dens[x] += v; continue }
                            var own = v * 0.5
                            if x > 0 && prow[x - 1] == 0 { dens[x - 1] += v * 0.25 } else { own += v * 0.25 }
                            if x < w - 1 && prow[x + 1] == 0 { dens[x + 1] += v * 0.25 } else { own += v * 0.25 }
                            dens[x] += own
                        }
                        var sum = 0.0
                        for x in 0..<w { sum += dens[x] }
                        let f = sum > 1e-9 ? target / sum : 0
                        let orow = op + y * (w + 1)
                        var acc = 0.0
                        orow[0] = 0
                        for x in 0..<w {
                            let dv = sum > 1e-9 ? amount * dens[x] * f + (1 - amount) * r : r
                            acc += dv
                            orow[x + 1] = acc
                        }
                        orow[w] = target
                    }
                }
            }
        }
        return cum
    }

    /// Replaces each (ascending) output position in `values` by its source position under the forward map `cum`.
    private static func invert(_ cum: UnsafePointer<Double>, width w: Int, values v: inout [Double]) {
        var xi = 0
        for i in 0..<v.count {
            let c = v[i]
            while xi < w - 1 && cum[xi + 1] <= c { xi += 1 }
            let d = cum[xi + 1] - cum[xi]
            let u = d > 1e-12 ? Double(xi) + min(1, max(0, (c - cum[xi]) / d)) : Double(xi + 1)
            v[i] = min(Double(w), max(0, u))
        }
    }

    /// Applies a round's map to the working copy (box filter where compressed, linear where stretched).
    private static func resampleWork(_ s: Small, cum: [Double], newWidth nwi: Int) -> Small {
        let w = s.w, h = s.lum.count / max(1, s.w), n = max(1, nwi)
        var out = Small(w: n, lum: [Float](repeating: 0, count: n * h), rgb: [Float](repeating: 0, count: n * h * 3),
                        prot: [UInt8](repeating: 0, count: n * h))
        for y in 0..<h {
            var e = [Double](repeating: 0, count: n + 1)
            for X in 0...n { e[X] = Double(X) }
            cum.withUnsafeBufferPointer { invert($0.baseAddress! + y * (w + 1), width: w, values: &e) }
            for X in 0..<n {
                let a = e[X], b = max(a, e[X + 1])
                var c = [Float](repeating: 0, count: 3)
                var p: UInt8 = 0
                if b - a >= 1 {
                    let i0 = min(w - 1, Int(a)), i1 = min(w - 1, max(i0, Int(ceil(b)) - 1))
                    var tw = 0.0
                    for i in i0...i1 {
                        let wgt = min(b, Double(i + 1)) - max(a, Double(i))
                        if wgt <= 0 { continue }
                        tw += wgt
                        for ch in 0..<3 { c[ch] += s.rgb[(y * w + i) * 3 + ch] * Float(wgt) }
                        p = max(p, s.prot[y * w + i])
                    }
                    if tw > 0 { for ch in 0..<3 { c[ch] /= Float(tw) } }
                } else {
                    let cc = min(Double(w - 1), max(0, (a + b) * 0.5 - 0.5))
                    let i0 = Int(cc), i1 = min(w - 1, i0 + 1)
                    let t = Float(cc - Double(i0))
                    for ch in 0..<3 {
                        let v0 = s.rgb[(y * w + i0) * 3 + ch], v1 = s.rgb[(y * w + i1) * 3 + ch]
                        c[ch] = v0 + (v1 - v0) * t
                    }
                    p = max(s.prot[y * w + i0], t > 0 ? s.prot[y * w + i1] : 0)
                }
                let o = y * n + X
                out.rgb[o * 3] = c[0]; out.rgb[o * 3 + 1] = c[1]; out.rgb[o * 3 + 2] = c[2]
                out.lum[o] = 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]
                out.prot[o] = p
            }
        }
        return out
    }

    // MARK: - Working copy

    private struct Small {
        package var w: Int
        package var lum: [Float]
        package var rgb: [Float]      // interleaved premultiplied r,g,b
        package var prot: [UInt8]     // 1 = protected
    }

    private static func downsample(_ img: PixelBuffer, mask: PixelBuffer?, sw: Int, sh: Int) -> Small {
        let W = img.width, H = img.height
        var lum = [Float](repeating: 0, count: sw * sh)
        var rgb = [Float](repeating: 0, count: sw * sh * 3)
        var prot = [UInt8](repeating: 0, count: sw * sh)
        var x0s = [Int](repeating: 0, count: sw), x1s = [Int](repeating: 0, count: sw)
        for sx in 0..<sw {
            let a = sx * W / sw
            x0s[sx] = min(W - 1, a)
            x1s[sx] = max(x0s[sx] + 1, min(W, (sx + 1) * W / sw))
        }
        let src = img.data.assumingMemoryBound(to: UInt8.self)
        let sbpr = img.bytesPerRow
        let mp = mask?.data.assumingMemoryBound(to: UInt8.self)
        let mbpr = mask?.bytesPerRow ?? 0
        lum.withUnsafeMutableBufferPointer { lb in
            rgb.withUnsafeMutableBufferPointer { rb in
                prot.withUnsafeMutableBufferPointer { pb in
                    let lp = lb.baseAddress!, rp = rb.baseAddress!, pp = pb.baseAddress!
                    DispatchQueue.concurrentPerform(iterations: sh) { sy in
                        let y0 = min(H - 1, sy * H / sh)
                        let y1 = max(y0 + 1, min(H, (sy + 1) * H / sh))
                        for sx in 0..<sw {
                            let xa = x0s[sx], xb = x1s[sx]
                            var r: UInt32 = 0, g: UInt32 = 0, b: UInt32 = 0
                            var pmax: UInt8 = 0
                            for y in y0..<y1 {
                                let row = src + y * sbpr
                                for x in xa..<xb {
                                    let p = row + x * 4
                                    r &+= UInt32(p[0]); g &+= UInt32(p[1]); b &+= UInt32(p[2])
                                }
                                if let mp = mp {
                                    let mrow = mp + y * mbpr
                                    for x in xa..<xb where mrow[x] > pmax { pmax = mrow[x] }
                                }
                            }
                            let n = Float((y1 - y0) * (xb - xa))
                            let fr = Float(r) / n, fg = Float(g) / n, fb = Float(b) / n
                            let i = sy * sw + sx
                            rp[i * 3] = fr; rp[i * 3 + 1] = fg; rp[i * 3 + 2] = fb
                            lp[i] = 0.299 * fr + 0.587 * fg + 0.114 * fb
                            pp[i] = pmax > 127 ? 1 : 0
                        }
                    }
                }
            }
        }
        return Small(w: sw, lum: lum, rgb: rgb, prot: prot)
    }

    /// Static (carried) energy: colour gradient + a blurred "saliency" term so that compact objects
    /// with flat interiors are also expensive to cut through; protected pixels get a huge cost.
    private static func staticEnergy(_ s: Small, w: Int, h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        s.rgb.withUnsafeBufferPointer { cb in
            let c = cb.baseAddress!
            for y in 0..<h {
                let ym = max(0, y - 1), yp = min(h - 1, y + 1)
                for x in 0..<w {
                    let xm = max(0, x - 1), xp = min(w - 1, x + 1)
                    var sum: Float = 0
                    for ch in 0..<3 {
                        sum += abs(c[(y * w + xp) * 3 + ch] - c[(y * w + xm) * 3 + ch])
                        sum += abs(c[(yp * w + x) * 3 + ch] - c[(ym * w + x) * 3 + ch])
                    }
                    g[y * w + x] = sum / 6
                }
            }
        }
        let radius = max(2, max(w, h) / 40)
        var blurred = g
        for _ in 0..<3 { boxBlur(&blurred, w: w, h: h, r: radius) }
        var e = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            e[i] = 0.6 * g[i] + 2.0 * blurred[i] + (s.prot[i] != 0 ? 1e5 : 0)
        }
        return e
    }

    private static func boxBlur(_ a: inout [Float], w: Int, h: Int, r: Int) {
        var tmp = [Float](repeating: 0, count: w * h)
        let norm = 1 / Float(2 * r + 1)
        // horizontal
        for y in 0..<h {
            let base = y * w
            var acc: Float = 0
            for i in -r...r { acc += a[base + min(w - 1, max(0, i))] }
            for x in 0..<w {
                tmp[base + x] = acc * norm
                acc += a[base + min(w - 1, x + r + 1)] - a[base + max(0, x - r)]
            }
        }
        // vertical
        for x in 0..<w {
            var acc: Float = 0
            for i in -r...r { acc += tmp[min(h - 1, max(0, i)) * w + x] }
            for y in 0..<h {
                a[y * w + x] = acc * norm
                acc += tmp[min(h - 1, y + r + 1) * w + x] - tmp[max(0, y - r) * w + x]
            }
        }
    }

    // MARK: - Seam carving (forward energy)

    /// Removes `k` vertical seams from a working copy; `counts[y*w + origX]` is incremented for every
    /// original column a seam passed through.
    private static func carve(lum lumIn: [Float], energy enIn: [Float], w: Int, h: Int, k: Int, counts: inout [UInt16]) {
        var lum = lumIn, en = enIn
        var idx = [Int32](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { idx[y * w + x] = Int32(x) } }
        var back = [Int8](repeating: 0, count: w * h)
        var mA = [Float](repeating: 0, count: w), mB = [Float](repeating: 0, count: w)
        var seam = [Int](repeating: 0, count: h)
        var cw = w

        lum.withUnsafeMutableBufferPointer { lb in
        en.withUnsafeMutableBufferPointer { eb in
        idx.withUnsafeMutableBufferPointer { ib in
        back.withUnsafeMutableBufferPointer { bb in
        mA.withUnsafeMutableBufferPointer { ab in
        mB.withUnsafeMutableBufferPointer { b2 in
        counts.withUnsafeMutableBufferPointer { cb in
            let L = lb.baseAddress!, E = eb.baseAddress!, I = ib.baseAddress!, B = bb.baseAddress!, C = cb.baseAddress!
            var prev = ab.baseAddress!, cur = b2.baseAddress!
            for _ in 0..<k where cw > 1 {
                // Row 0.
                for j in 0..<cw { prev[j] = E[j] }
                if h > 1 {
                    for i in 1..<h {
                        let Lr = L + i * w, Ur = L + (i - 1) * w, Er = E + i * w, Br = B + i * w
                        // j = 0
                        do {
                            let mU = prev[0]
                            let mR = prev[1] + abs(Ur[0] - Lr[1])
                            if mR < mU { cur[0] = mR + Er[0]; Br[0] = 1 } else { cur[0] = mU + Er[0]; Br[0] = 0 }
                        }
                        var j = 1
                        let last = cw - 1
                        while j < last {
                            let l = Lr[j - 1], r = Lr[j + 1], u = Ur[j]
                            let cU = abs(r - l)
                            var best = prev[j] + cU
                            var d: Int8 = 0
                            let mL = prev[j - 1] + cU + abs(u - l)
                            let mR = prev[j + 1] + cU + abs(u - r)
                            if mL < best { best = mL; d = -1 }
                            if mR < best { best = mR; d = 1 }
                            cur[j] = best + Er[j]
                            Br[j] = d
                            j += 1
                        }
                        // j = last
                        do {
                            let mU = prev[last]
                            let mL = prev[last - 1] + abs(Ur[last] - Lr[last - 1])
                            if mL < mU { cur[last] = mL + Er[last]; Br[last] = -1 } else { cur[last] = mU + Er[last]; Br[last] = 0 }
                        }
                        swap(&prev, &cur)
                    }
                }
                // Best end point.
                var bj = 0
                var bv = prev[0]
                for j in 1..<cw where prev[j] < bv { bv = prev[j]; bj = j }
                // Backtrack.
                var j = bj
                var i = h - 1
                while i >= 0 {
                    seam[i] = j
                    if i > 0 { j = min(cw - 1, max(0, j + Int(B[i * w + j]))) }
                    i -= 1
                }
                // Remove.
                for i in 0..<h {
                    let sj = seam[i]
                    let base = i * w
                    let o = Int(I[base + sj])
                    let ci = i * w + o
                    if C[ci] < UInt16.max { C[ci] += 1 }
                    let n = cw - sj - 1
                    if n > 0 {
                        memmove(L + base + sj, L + base + sj + 1, n * MemoryLayout<Float>.size)
                        memmove(E + base + sj, E + base + sj + 1, n * MemoryLayout<Float>.size)
                        memmove(I + base + sj, I + base + sj + 1, n * MemoryLayout<Int32>.size)
                    }
                }
                cw -= 1
            }
        }}}}}}}
    }

    // MARK: - Full-resolution resampling

    private static func resampleRows(src: PixelBuffer, dst: PixelBuffer, srcMask: PixelBuffer?, dstMask: PixelBuffer?,
                                     edges: [Float], edgeCount: Int, sh: Int) {
        let W = src.width, H = src.height, nw = dst.width
        let sp = src.data.assumingMemoryBound(to: UInt8.self)
        let dp = dst.data.assumingMemoryBound(to: UInt8.self)
        let sbpr = src.bytesPerRow, dbpr = dst.bytesPerRow
        let smp = srcMask?.data.assumingMemoryBound(to: UInt8.self)
        let dmp = dstMask?.data.assumingMemoryBound(to: UInt8.self)
        let smbpr = srcMask?.bytesPerRow ?? 0, dmbpr = dstMask?.bytesPerRow ?? 0
        let chunk = 16
        let chunks = (H + chunk - 1) / chunk
        let maxX = Float(W)
        edges.withUnsafeBufferPointer { eb in
            let ep = eb.baseAddress!
            DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                var e = [Float](repeating: 0, count: edgeCount)
                for y in (ci * chunk)..<min(H, (ci + 1) * chunk) {
                    // Interpolate the mapping between working rows.
                    let fy = (Double(y) + 0.5) * Double(sh) / Double(H) - 0.5
                    let y0 = min(sh - 1, max(0, Int(fy.rounded(.down))))
                    let y1 = min(sh - 1, y0 + 1)
                    let t = Float(min(1, max(0, fy - Double(y0))))
                    let r0 = ep + y0 * edgeCount, r1 = ep + y1 * edgeCount
                    for X in 0..<edgeCount { e[X] = r0[X] + (r1[X] - r0[X]) * t }
                    e[0] = 0; e[edgeCount - 1] = maxX
                    let srow = sp + y * sbpr, drow = dp + y * dbpr
                    let smrow = smp.map { $0 + y * smbpr }, dmrow = dmp.map { $0 + y * dmbpr }
                    for X in 0..<nw {
                        let a = min(maxX, max(0, e[X]))
                        let b = min(maxX, max(a, e[X + 1]))
                        let len = b - a
                        if len >= 1 {
                            // Box filter over [a, b).
                            let i0 = Int(a), i1 = min(W - 1, Int((b - 1e-4).rounded(.down)))
                            var c0: Float = 0, c1: Float = 0, c2: Float = 0, c3: Float = 0, cm: Float = 0
                            var i = i0
                            while i <= i1 {
                                let wgt = min(b, Float(i + 1)) - max(a, Float(i))
                                if wgt > 0 {
                                    let p = srow + i * 4
                                    c0 += Float(p[0]) * wgt; c1 += Float(p[1]) * wgt; c2 += Float(p[2]) * wgt; c3 += Float(p[3]) * wgt
                                    if let m = smrow { cm += Float(m[i]) * wgt }
                                }
                                i += 1
                            }
                            let inv = 1 / len
                            let q = drow + X * 4
                            let av = min(255, c3 * inv + 0.5)
                            q[3] = UInt8(av)
                            q[0] = UInt8(min(av, c0 * inv + 0.5)); q[1] = UInt8(min(av, c1 * inv + 0.5)); q[2] = UInt8(min(av, c2 * inv + 0.5))
                            if let dm = dmrow { dm[X] = UInt8(min(255, cm * inv + 0.5)) }
                        } else {
                            // Linear interpolation at the interval centre.
                            let c = (a + b) * 0.5 - 0.5
                            let cc = min(Float(W - 1), max(0, c))
                            let i0 = Int(cc), i1 = min(W - 1, i0 + 1)
                            let t = cc - Float(i0)
                            let p0 = srow + i0 * 4, p1 = srow + i1 * 4
                            let q = drow + X * 4
                            let av = Float(p0[3]) + (Float(p1[3]) - Float(p0[3])) * t
                            q[3] = UInt8(min(255, av + 0.5))
                            for ch in 0..<3 {
                                let v = Float(p0[ch]) + (Float(p1[ch]) - Float(p0[ch])) * t
                                q[ch] = UInt8(min(Float(q[3]), v + 0.5))
                            }
                            if let m = smrow, let dm = dmrow {
                                let v = Float(m[i0]) + (Float(m[i1]) - Float(m[i0])) * t
                                dm[X] = UInt8(min(255, v + 0.5))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Transpose

    package static func transpose(_ b: PixelBuffer) -> PixelBuffer {
        let W = b.width, H = b.height
        let out = PixelBuffer(width: H, height: W, format: b.format)
        let tile = 64
        let tilesY = (H + tile - 1) / tile
        let sbpr = b.bytesPerRow, dbpr = out.bytesPerRow
        if b.format == .rgba {
            let sp = b.data, dp = out.data
            DispatchQueue.concurrentPerform(iterations: tilesY) { ty in
                let y0 = ty * tile, y1 = min(H, y0 + tile)
                var x0 = 0
                while x0 < W {
                    let x1 = min(W, x0 + tile)
                    for y in y0..<y1 {
                        let srow = (sp + y * sbpr).assumingMemoryBound(to: UInt32.self)
                        for x in x0..<x1 {
                            (dp + x * dbpr).assumingMemoryBound(to: UInt32.self)[y] = srow[x]
                        }
                    }
                    x0 = x1
                }
            }
        } else {
            let sp = b.data.assumingMemoryBound(to: UInt8.self), dp = out.data.assumingMemoryBound(to: UInt8.self)
            DispatchQueue.concurrentPerform(iterations: tilesY) { ty in
                let y0 = ty * tile, y1 = min(H, y0 + tile)
                for y in y0..<y1 {
                    let srow = sp + y * sbpr
                    for x in 0..<W { dp[x * dbpr + y] = srow[x] }
                }
            }
        }
        return out
    }
}
