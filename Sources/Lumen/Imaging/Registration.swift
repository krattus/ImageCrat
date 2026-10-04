import Foundation
import CoreImage
import Accelerate
import Vision
import simd
import ImageCratCore

/// Gray feature image + keypoints / descriptors (Harris corners, 8×8 normalised patch descriptors).
struct FeatureSet {
    var w: Int, h: Int
    /// feature-image px per original px
    var scale: Double
    var fullW: Int, fullH: Int
    var gray: [Float]
    var alpha: [Float]
    /// High-pass (gray − blur) used for photometric verification (textureless areas carry no weight).
    var detail: [Float] = []
    var pts: [SIMD2<Float>] = []
    var desc: [Float] = []
    static let D = 64
}

/// Pairwise image registration: own feature matching + RANSAC, cross-checked against Vision's
/// homographic / translational registration by photometric (NCC) scoring.
enum Registration {
    enum Model: Int { case translation, similarity, affine, homography }

    struct Pair {
        var H: Homography            // floating (full-res doc px) → reference (full-res doc px)
        var inliers: Int
        var score: Double            // NCC over the overlap
        var overlap: Double          // fraction of the floating image inside the reference
        var method: String
        var matches: [(SIMD2<Double>, SIMD2<Double>)]   // (floating, reference) inlier points, full-res
    }

    // MARK: Feature image

    static func prepare(_ img: CIImage, maxSide: Int = 1000, upright: Bool = true, maxFeatures: Int = 1500) -> FeatureSet {
        let ext = img.extent.integral
        let fullW = Int(ext.width), fullH = Int(ext.height)
        let s = min(1.0, Double(maxSide) / Double(max(fullW, fullH)))
        let w = max(8, Int((Double(fullW) * s).rounded())), h = max(8, Int((Double(fullH) * s).rounded()))
        let sx = Double(w) / Double(fullW)
        let small = img.translated(-ext.minX, -ext.minY).transformed(by: CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(Double(h) / Double(fullH))), highQualityDownsample: true)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let r = CGRect(x: 0, y: 0, width: w, height: h)
        RenderEngine.readbackContext.render(small.composited(over: CIImage.clearImage.cropped(to: r)), toBitmap: &rgba, rowBytes: w * 4, bounds: r, format: .RGBA8, colorSpace: sRGBSpace)
        var gray = [Float](repeating: 0, count: w * h), alpha = [Float](repeating: 0, count: w * h)
        rgba.withUnsafeBufferPointer { p in
            for i in 0..<(w * h) {
                let a = Float(p[i * 4 + 3])
                alpha[i] = a / 255
                gray[i] = a > 0 ? (0.299 * Float(p[i * 4]) + 0.587 * Float(p[i * 4 + 1]) + 0.114 * Float(p[i * 4 + 2])) / a : 0.5
            }
        }
        var fs = FeatureSet(w: w, h: h, scale: sx, fullW: fullW, fullH: fullH, gray: gray, alpha: alpha)
        let low = blur(gray, w, h, sigma: 3)
        fs.detail = zip(gray, low).map { $0 - $1 }
        detect(&fs, upright: upright, maxFeatures: maxFeatures)
        return fs
    }

    static func blur(_ a: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] {
        let rad = max(1, Int(ceil(sigma * 3)))
        var k = (-rad...rad).map { expf(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = k.reduce(0, +); k = k.map { $0 / sum }
        return sepConvolve(a, w, h, kx: k, ky: k)
    }

    static func sepConvolve(_ a: [Float], _ w: Int, _ h: Int, kx: [Float], ky: [Float]) -> [Float] {
        var src = a
        var dst = [Float](repeating: 0, count: w * h)
        src.withUnsafeMutableBytes { sp in
            dst.withUnsafeMutableBytes { dp in
                var s = vImage_Buffer(data: sp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var d = vImage_Buffer(data: dp.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                _ = vImageSepConvolve_PlanarF(&s, &d, nil, 0, 0, kx, UInt32(kx.count), ky, UInt32(ky.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return dst
    }

    /// Harris corners on a grid (even spatial distribution), orientation, descriptors.
    static func detect(_ fs: inout FeatureSet, upright: Bool, maxFeatures: Int) {
        let w = fs.w, h = fs.h
        let g1 = blur(fs.gray, w, h, sigma: 1.0)
        let ix = sepConvolve(g1, w, h, kx: [-0.5, 0, 0.5], ky: [0.25, 0.5, 0.25])
        let iy = sepConvolve(g1, w, h, kx: [0.25, 0.5, 0.25], ky: [-0.5, 0, 0.5])
        var ixx = [Float](repeating: 0, count: w * h), iyy = ixx, ixy = ixx
        vDSP_vmul(ix, 1, ix, 1, &ixx, 1, vDSP_Length(w * h))
        vDSP_vmul(iy, 1, iy, 1, &iyy, 1, vDSP_Length(w * h))
        vDSP_vmul(ix, 1, iy, 1, &ixy, 1, vDSP_Length(w * h))
        let sxx = blur(ixx, w, h, sigma: 1.6), syy = blur(iyy, w, h, sigma: 1.6), sxy = blur(ixy, w, h, sigma: 1.6)
        // R = det - 0.04 tr²
        var det = [Float](repeating: 0, count: w * h), tmp = det, tr = det
        vDSP_vmul(sxx, 1, syy, 1, &det, 1, vDSP_Length(w * h))
        vDSP_vmul(sxy, 1, sxy, 1, &tmp, 1, vDSP_Length(w * h))
        vDSP_vsub(tmp, 1, det, 1, &det, 1, vDSP_Length(w * h))
        vDSP_vadd(sxx, 1, syy, 1, &tr, 1, vDSP_Length(w * h))
        vDSP_vmul(tr, 1, tr, 1, &tmp, 1, vDSP_Length(w * h))
        var k: Float = -0.04
        var resp = [Float](repeating: 0, count: w * h)
        vDSP_vsma(tmp, 1, &k, det, 1, &resp, 1, vDSP_Length(w * h))
        var maxR: Float = 0
        vDSP_maxv(resp, 1, &maxR, vDSP_Length(w * h))
        let thresh = maxR * 1e-4
        let border = 14
        let cell = max(6, Int(sqrt(Double(w * h) / Double(maxFeatures * 2))))
        var cands: [(Float, Int, Int)] = []
        resp.withUnsafeBufferPointer { R in
            fs.alpha.withUnsafeBufferPointer { A in
                var cy = border
                while cy < h - border {
                    var cx = border
                    while cx < w - border {
                        var best: Float = thresh, bx = -1, by = -1
                        for y in cy..<min(cy + cell, h - border) {
                            let row = y * w
                            for x in cx..<min(cx + cell, w - border) where R[row + x] > best {
                                best = R[row + x]; bx = x; by = y
                            }
                        }
                        if bx >= 0 {
                            let i = by * w + bx
                            let v = R[i]
                            let isMax = v >= R[i - 1] && v >= R[i + 1] && v >= R[i - w] && v >= R[i + w] && v >= R[i - w - 1] && v >= R[i - w + 1] && v >= R[i + w - 1] && v >= R[i + w + 1]
                            // reject corners near transparency (edges of warped / partial layers)
                            let r = 12
                            let opaque = A[(by - r) * w + bx - r] > 0.99 && A[(by - r) * w + bx + r] > 0.99 && A[(by + r) * w + bx - r] > 0.99 && A[(by + r) * w + bx + r] > 0.99 && A[i] > 0.99
                            if isMax && opaque { cands.append((v, bx, by)) }
                        }
                        cx += cell
                    }
                    cy += cell
                }
            }
        }
        cands.sort { $0.0 > $1.0 }
        if cands.count > maxFeatures { cands = Array(cands.prefix(maxFeatures)) }
        let g2 = blur(fs.gray, w, h, sigma: 2.0)
        var pts: [SIMD2<Float>] = []
        var desc: [Float] = []
        pts.reserveCapacity(cands.count); desc.reserveCapacity(cands.count * FeatureSet.D)
        resp.withUnsafeBufferPointer { R in
            for (_, x, y) in cands {
                // sub-pixel refinement (parabola)
                let i = y * w + x
                let dx = 0.5 * (R[i + 1] - R[i - 1]) / min(-1e-12, R[i + 1] - 2 * R[i] + R[i - 1])
                let dy = 0.5 * (R[i + w] - R[i - w]) / min(-1e-12, R[i + w] - 2 * R[i] + R[i - w])
                let p = SIMD2<Float>(Float(x) - clamp(dx, -0.5, 0.5), Float(y) - clamp(dy, -0.5, 0.5))
                var angle: Float = 0
                if !upright { angle = orientation(ix, iy, w, h, x, y) }
                if let d = descriptor(g2, w, h, p, angle) { pts.append(p); desc.append(contentsOf: d) }
            }
        }
        fs.pts = pts
        fs.desc = desc
    }

    static func orientation(_ ix: [Float], _ iy: [Float], _ w: Int, _ h: Int, _ x: Int, _ y: Int) -> Float {
        var hist = [Float](repeating: 0, count: 36)
        let r = 8
        for yy in max(1, y - r)...min(h - 2, y + r) {
            for xx in max(1, x - r)...min(w - 2, x + r) {
                let dx = Float(xx - x), dy = Float(yy - y)
                let wt = expf(-(dx * dx + dy * dy) / Float(2 * 16))
                let gx = ix[yy * w + xx], gy = iy[yy * w + xx]
                let m = sqrtf(gx * gx + gy * gy) * wt
                var a = atan2f(gy, gx); if a < 0 { a += 2 * .pi }
                hist[min(35, Int(a / (2 * .pi) * 36))] += m
            }
        }
        var best = 0
        for i in 1..<36 where hist[i] > hist[best] { best = i }
        return (Float(best) + 0.5) / 36 * 2 * .pi
    }

    @inline(__always) static func bilinear(_ a: [Float], _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float? {
        if x < 0 || y < 0 || x > Float(w - 1) || y > Float(h - 1) { return nil }
        let x0 = min(w - 2, Int(x)), y0 = min(h - 2, Int(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let i = y0 * w + x0
        return (a[i] * (1 - fx) + a[i + 1] * fx) * (1 - fy) + (a[i + w] * (1 - fx) + a[i + w + 1] * fx) * fy
    }

    static func descriptor(_ g: [Float], _ w: Int, _ h: Int, _ p: SIMD2<Float>, _ angle: Float) -> [Float]? {
        let step: Float = 2.6
        let c = cosf(angle), s = sinf(angle)
        var d = [Float](repeating: 0, count: FeatureSet.D)
        var k = 0
        for j in 0..<8 {
            for i in 0..<8 {
                let u = (Float(i) - 3.5) * step, v = (Float(j) - 3.5) * step
                let x = p.x + c * u - s * v, y = p.y + s * u + c * v
                guard let val = bilinear(g, w, h, x, y) else { return nil }
                d[k] = val; k += 1
            }
        }
        var mean: Float = 0; vDSP_meanv(d, 1, &mean, vDSP_Length(d.count))
        var neg = -mean
        vDSP_vsadd(d, 1, &neg, &d, 1, vDSP_Length(d.count))
        var ss: Float = 0; vDSP_svesq(d, 1, &ss, vDSP_Length(d.count))
        if ss < 1e-4 { return nil }   // flat patch
        var inv = 1 / sqrtf(ss)
        vDSP_vsmul(d, 1, &inv, &d, 1, vDSP_Length(d.count))
        return d
    }

    // MARK: Matching

    /// Ratio-tested mutual nearest neighbours: (index in a, index in b).
    static func match(_ a: FeatureSet, _ b: FeatureSet, ratio: Float = 0.82) -> [(Int, Int)] {
        let na = a.pts.count, nb = b.pts.count
        guard na >= 4, nb >= 4 else { return [] }
        let D = FeatureSet.D
        var sim = [Float](repeating: 0, count: na * nb)
        a.desc.withUnsafeBufferPointer { A in
            b.desc.withUnsafeBufferPointer { B in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(na), Int32(nb), Int32(D), 1, A.baseAddress, Int32(D), B.baseAddress, Int32(D), 0, &sim, Int32(nb))
            }
        }
        var bestA = [Int](repeating: -1, count: na), bestB = [Int](repeating: -1, count: nb)
        var okA = [Bool](repeating: false, count: na)
        var colBest = [Float](repeating: -2, count: nb)
        sim.withUnsafeBufferPointer { S in
            for i in 0..<na {
                var b1: Float = -2, b2: Float = -2, j1 = -1
                let row = i * nb
                for j in 0..<nb {
                    let v = S[row + j]
                    if v > b1 { b2 = b1; b1 = v; j1 = j } else if v > b2 { b2 = v }
                    if v > colBest[j] { colBest[j] = v; bestB[j] = i }
                }
                bestA[i] = j1
                // distances on unit vectors: d² = 2 - 2s
                let d1 = 2 - 2 * b1, d2 = 2 - 2 * b2
                okA[i] = b1 > 0.55 && d1 < ratio * ratio * d2
            }
        }
        var out: [(Int, Int)] = []
        for i in 0..<na where okA[i] && bestA[i] >= 0 && bestB[bestA[i]] == i { out.append((i, bestA[i])) }
        return out
    }

    // MARK: Model fitting

    /// Least-squares model from point pairs (src → dst).
    static func fit(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>], model: Model) -> Homography? {
        let n = src.count
        switch model {
        case .translation:
            guard n >= 1 else { return nil }
            var t = SIMD2<Double>.zero
            for i in 0..<n { t += dst[i] - src[i] }
            t /= Double(n)
            return Homography(m: [1, 0, t.x, 0, 1, t.y, 0, 0, 1])
        case .similarity:
            guard n >= 2 else { return nil }
            // x' = a x - b y + tx ; y' = b x + a y + ty
            var ms = SIMD2<Double>.zero, md = SIMD2<Double>.zero
            for i in 0..<n { ms += src[i]; md += dst[i] }
            ms /= Double(n); md /= Double(n)
            var sxx = 0.0, sab = 0.0, sba = 0.0
            for i in 0..<n {
                let s = src[i] - ms, d = dst[i] - md
                sxx += s.x * s.x + s.y * s.y
                sab += s.x * d.x + s.y * d.y
                sba += s.x * d.y - s.y * d.x
            }
            guard sxx > 1e-9 else { return nil }
            let a = sab / sxx, b = sba / sxx
            return Homography(m: [a, -b, md.x - a * ms.x + b * ms.y, b, a, md.y - b * ms.x - a * ms.y, 0, 0, 1])
        case .affine:
            guard n >= 3 else { return nil }
            var ata = [Double](repeating: 0, count: 9), atx = [Double](repeating: 0, count: 3), aty = [Double](repeating: 0, count: 3)
            for i in 0..<n {
                let r = [src[i].x, src[i].y, 1]
                for p in 0..<3 { for q in 0..<3 { ata[p * 3 + q] += r[p] * r[q] }; atx[p] += r[p] * dst[i].x; aty[p] += r[p] * dst[i].y }
            }
            guard let x = solve(ata, atx, 3), let y = solve(ata, aty, 3) else { return nil }
            return Homography(m: [x[0], x[1], x[2], y[0], y[1], y[2], 0, 0, 1])
        case .homography:
            guard n >= 4 else { return nil }
            // Hartley normalisation
            func norm(_ p: [SIMD2<Double>]) -> (Homography, [SIMD2<Double>]) {
                var c = SIMD2<Double>.zero; for q in p { c += q }; c /= Double(p.count)
                var d = 0.0; for q in p { d += simd_length(q - c) }; d /= Double(p.count)
                let s = d > 1e-9 ? sqrt(2) / d : 1
                let T = Homography(m: [s, 0, -s * c.x, 0, s, -s * c.y, 0, 0, 1])
                return (T, p.map { ($0 - c) * s })
            }
            let (Ts, ps) = norm(src), (Td, pd) = norm(dst)
            var ata = [Double](repeating: 0, count: 64), atb = [Double](repeating: 0, count: 8)
            for i in 0..<n {
                let x = ps[i].x, y = ps[i].y, u = pd[i].x, v = pd[i].y
                let r1: [Double] = [x, y, 1, 0, 0, 0, -u * x, -u * y]
                let r2: [Double] = [0, 0, 0, x, y, 1, -v * x, -v * y]
                for p in 0..<8 {
                    for q in 0..<8 { ata[p * 8 + q] += r1[p] * r1[q] + r2[p] * r2[q] }
                    atb[p] += r1[p] * u + r2[p] * v
                }
            }
            guard let h = solve(ata, atb, 8) else { return nil }
            let Hn = Homography(m: h + [1])
            guard let Tdi = Td.inverted else { return nil }
            return normalized(Tdi.concat(Hn).concat(Ts))
        }
    }

    /// Scales H so that det > 0 and |H| is moderate (keeps the projective sign meaningful).
    static func normalized(_ H: Homography) -> Homography {
        let a = H.m
        let det = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        let s = det < 0 ? -1.0 : 1.0
        let mag = pow(abs(det), 1.0 / 3)
        return Homography(m: a.map { $0 * s / max(1e-12, mag) })
    }

    /// Gaussian elimination with partial pivoting (n×n).
    static func solve(_ A0: [Double], _ b0: [Double], _ n: Int) -> [Double]? {
        var A = A0, b = b0
        for c in 0..<n {
            var p = c
            for r in (c + 1)..<max(c + 1, n) where abs(A[r * n + c]) > abs(A[p * n + c]) { p = r }
            if abs(A[p * n + c]) < 1e-12 { return nil }
            if p != c { for k in 0..<n { A.swapAt(c * n + k, p * n + k) }; b.swapAt(c, p) }
            for r in 0..<n where r != c {
                let f = A[r * n + c] / A[c * n + c]
                if f == 0 { continue }
                for k in c..<n { A[r * n + k] -= f * A[c * n + k] }
                b[r] -= f * b[c]
            }
        }
        return (0..<n).map { b[$0] / A[$0 * n + $0] }
    }

    static func apply(_ H: Homography, _ p: SIMD2<Double>) -> SIMD2<Double> {
        let m = H.m
        let w = m[6] * p.x + m[7] * p.y + m[8]
        let iw = abs(w) < 1e-12 ? 1e12 : 1 / w
        return SIMD2((m[0] * p.x + m[1] * p.y + m[2]) * iw, (m[3] * p.x + m[4] * p.y + m[5]) * iw)
    }

    static func ransac(_ src: [SIMD2<Double>], _ dst: [SIMD2<Double>], model: Model, threshold: Double, seed: UInt64 = 1) -> (Homography, [Int])? {
        let n = src.count
        let k: Int
        switch model { case .translation: k = 1; case .similarity: k = 2; case .affine: k = 3; case .homography: k = 4 }
        guard n >= max(k, 4) else { return nil }
        var rng = RegRNG(seed: seed)
        var bestInl: [Int] = []
        var iters = 0, maxIters = model == .homography ? 2000 : 600
        let t2 = threshold * threshold
        while iters < maxIters {
            iters += 1
            var idx: [Int] = []
            while idx.count < k { let r = Int(rng.next() % UInt64(n)); if !idx.contains(r) { idx.append(r) } }
            guard let H = fit(idx.map { src[$0] }, idx.map { dst[$0] }, model: model) else { continue }
            if model == .homography {
                // reject degenerate / mirrored hypotheses
                let m = H.m
                if m[0] * m[4] - m[1] * m[3] <= 0.05 { continue }
            }
            var inl: [Int] = []
            inl.reserveCapacity(n)
            for i in 0..<n {
                let q = apply(H, src[i]) - dst[i]
                if q.x * q.x + q.y * q.y < t2 { inl.append(i) }
            }
            if inl.count > bestInl.count {
                bestInl = inl
                let wr = Double(inl.count) / Double(n)
                let need = log(1 - 0.999) / log(max(1e-9, 1 - pow(wr, Double(k))))
                maxIters = min(maxIters, max(50, Int(need.rounded(.up))))
            }
        }
        guard bestInl.count >= k else { return nil }
        // refine: refit on inliers, recollect twice
        var inl = bestInl
        var H = fit(inl.map { src[$0] }, inl.map { dst[$0] }, model: model)!
        for _ in 0..<2 {
            let next = (0..<n).filter { let q = apply(H, src[$0]) - dst[$0]; return q.x * q.x + q.y * q.y < t2 }
            if next.count < k { break }
            inl = next
            if let h2 = fit(inl.map { src[$0] }, inl.map { dst[$0] }, model: model) { H = h2 }
        }
        return (H, inl)
    }

    // MARK: Photometric verification

    /// NCC of gray values over the overlap when mapping floating → reference with `Hf` (feature-image coordinates).
    static func ncc(ref: FeatureSet, flt: FeatureSet, Hf: Homography) -> (Double, Double) {
        var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0, n = 0.0, total = 0.0
        let step = max(1, min(flt.w, flt.h) / 240)
        var y = 0
        while y < flt.h {
            var x = 0
            while x < flt.w {
                let i = y * flt.w + x
                if flt.alpha[i] > 0.5 {
                    total += 1
                    let q = apply(Hf, SIMD2(Double(x), Double(y)))
                    if let b = bilinear(ref.detail, ref.w, ref.h, Float(q.x), Float(q.y)), let ab = bilinear(ref.alpha, ref.w, ref.h, Float(q.x), Float(q.y)), ab > 0.5 {
                        let a = Double(flt.detail[i]), bb = Double(b)
                        sa += a; sb += bb; saa += a * a; sbb += bb * bb; sab += a * bb; n += 1
                    }
                }
                x += step
            }
            y += step
        }
        guard n > 30 else { return (-1, 0) }
        let cov = sab / n - sa / n * sb / n
        let va = saa / n - sa * sa / n / n, vb = sbb / n - sb * sb / n / n
        guard va > 1e-6, vb > 1e-6 else { return (-1, n / max(1, total)) }
        return (cov / sqrt(va * vb), n / max(1, total))
    }

    // MARK: Pair registration

    static func featureToFull(_ fs: FeatureSet) -> Homography {
        // full = (feat + 0.5)/s - 0.5
        let s = fs.scale, sy = Double(fs.h) / Double(fs.fullH)
        return Homography(m: [1 / s, 0, 0.5 / s - 0.5, 0, 1 / sy, 0.5 / sy - 0.5, 0, 0, 1])
    }

    static func fullToFeature(_ fs: FeatureSet) -> Homography { featureToFull(fs).inverted! }

    /// Registers `flt` onto `ref`. `useVision` adds Vision's homographic / translational estimates as candidates.
    static func register(ref: FeatureSet, flt: FeatureSet, model: Model, refCG: CGImage? = nil, fltCG: CGImage? = nil, useVision: Bool = true) -> Pair? {
        var cands: [(Homography, Int, String, [(SIMD2<Double>, SIMD2<Double>)])] = []   // feature-space H
        let m = match(flt, ref)
        if m.count >= 6 {
            let src = m.map { SIMD2(Double(flt.pts[$0.0].x), Double(flt.pts[$0.0].y)) }
            let dst = m.map { SIMD2(Double(ref.pts[$0.1].x), Double(ref.pts[$0.1].y)) }
            let thr = max(1.5, 3.0 * max(ref.scale, 0.3))
            if let (H, inl) = ransac(src, dst, model: model, threshold: thr), inl.count >= 8 {
                cands.append((H, inl.count, "features", inl.map { (src[$0], dst[$0]) }))
            }
        }
        if useVision, let rc = refCG ?? cgImage(ref), let fc = fltCG ?? cgImage(flt) {
            for v in visionCandidates(ref: rc, flt: fc, refH: ref.h, fltH: flt.h, model: model) { cands.append((v.0, 0, v.1, [])) }
        }
        var best: (Homography, Int, String, [(SIMD2<Double>, SIMD2<Double>)], Double, Double)?
        for c in cands {
            let (score, ov) = ncc(ref: ref, flt: flt, Hf: c.0)
            // feature estimates need decent detail correlation; unsupported (Vision) estimates must be convincing
            if ov < 0.04 || score < (c.2 == "features" ? 0.2 : 0.45) { continue }
            // Prefer the feature estimate (sub-pixel) unless another candidate is clearly better.
            let adj = score + (c.2 == "features" ? 0.03 : 0)
            if best == nil || adj > best!.4 + (best!.2 == "features" ? 0.03 : 0) { best = (c.0, c.1, c.2, c.3, score, ov) }
        }
        guard let b = best else { return nil }
        let Hfull = featureToFull(ref).concat(b.0).concat(fullToFeature(flt))
        let f2f = featureToFull(flt), r2f = featureToFull(ref)
        let matches = b.3.map { (apply(f2f, $0.0), apply(r2f, $0.1)) }
        return Pair(H: normalized(Hfull), inliers: b.1, score: b.4, overlap: b.5, method: b.2, matches: matches)
    }

    static func cgImage(_ fs: FeatureSet) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: fs.w * fs.h * 4)
        for i in 0..<(fs.w * fs.h) {
            let v = UInt8(clamp(fs.gray[i] * 255, 0, 255))
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v
        }
        guard let prov = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: fs.w, height: fs.h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: fs.w * 4, space: sRGBSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Vision estimates converted to y-down feature coordinates (floating → reference).
    static func visionCandidates(ref: CGImage, flt: CGImage, refH: Int, fltH: Int, model: Model) -> [(Homography, String)] {
        var out: [(Homography, String)] = []
        let handler = VNImageRequestHandler(cgImage: ref, options: [:])
        let Fr = Homography(m: [1, 0, 0, 0, -1, Double(refH), 0, 0, 1])
        let Ff = Homography(m: [1, 0, 0, 0, -1, Double(fltH), 0, 0, 1])
        let tr = VNTranslationalImageRegistrationRequest(targetedCGImage: flt, options: [:])
        var reqs: [VNRequest] = [tr]
        let hr = VNHomographicImageRegistrationRequest(targetedCGImage: flt, options: [:])
        if model == .homography { reqs.append(hr) }
        try? handler.perform(reqs)
        if let o = tr.results?.first as? VNImageTranslationAlignmentObservation {
            let t = o.alignmentTransform
            let M = Homography(m: [Double(t.a), Double(t.c), Double(t.tx), Double(t.b), Double(t.d), Double(t.ty), 0, 0, 1])
            out.append((Fr.concat(M).concat(Ff), "vision-translation"))
        }
        if model == .homography, let o = hr.results?.first as? VNImageHomographicAlignmentObservation {
            let w = o.warpTransform   // column-major
            let M = Homography(m: [Double(w.columns.0.x), Double(w.columns.1.x), Double(w.columns.2.x),
                                   Double(w.columns.0.y), Double(w.columns.1.y), Double(w.columns.2.y),
                                   Double(w.columns.0.z), Double(w.columns.1.z), Double(w.columns.2.z)])
            out.append((normalized(Fr.concat(M).concat(Ff)), "vision-homography"))
        }
        return out
    }

    // MARK: Global alignment

    struct Alignment {
        var reference: Int
        /// image i (full-res doc px) → reference (full-res doc px); nil = not connected
        var H: [Homography?]
        var pairs: [(Int, Int, Pair)]    // (floating, reference) pairwise results used
    }

    /// Registers all pairs and chains them to a reference through a maximum spanning tree (weights = inliers × NCC).
    static func alignAll(_ sets: [FeatureSet], model: Model, reference fixedRef: Int? = nil, useVision: Bool = true, progress: ((Double) -> Void)? = nil) -> Alignment {
        let n = sets.count
        var pair: [[Pair?]] = Array(repeating: Array(repeating: nil, count: n), count: n)   // pair[i][j]: i → j
        let cgs = sets.map { cgImage($0) }
        var done = 0, total = max(1, n * (n - 1) / 2)
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) {
                if let p = register(ref: sets[j], flt: sets[i], model: model, refCG: cgs[j], fltCG: cgs[i], useVision: useVision), let inv = p.H.inverted {
                    pair[i][j] = p
                    pair[j][i] = Pair(H: normalized(inv), inliers: p.inliers, score: p.score, overlap: p.overlap, method: p.method, matches: p.matches.map { ($0.1, $0.0) })
                }
                done += 1; progress?(Double(done) / Double(total))
            }
        }
        func weight(_ p: Pair) -> Double { Double(max(p.inliers, 10)) * max(0.05, p.score) }
        var ref = fixedRef ?? 0
        if fixedRef == nil {
            var bestW = -1.0
            for i in 0..<n {
                let w = (0..<n).reduce(0.0) { $0 + (pair[i][$1].map(weight) ?? 0) }
                // tie-break towards the middle of the list
                let adj = w - abs(Double(i) - Double(n - 1) / 2) * 1e-6
                if adj > bestW { bestW = adj; ref = i }
            }
        }
        var H = [Homography?](repeating: nil, count: n)
        H[ref] = .identity
        var used: [(Int, Int, Pair)] = []
        var inTree = Set([ref])
        while inTree.count < n {
            var best: (Int, Int, Double)?
            for a in inTree { for b in 0..<n where !inTree.contains(b) {
                if let p = pair[b][a] { let w = weight(p); if best == nil || w > best!.2 { best = (b, a, w) } }
            } }
            guard let (b, a, _) = best, let p = pair[b][a], let Ha = H[a] else { break }
            H[b] = normalized(Ha.concat(p.H))
            used.append((b, a, p))
            inTree.insert(b)
        }
        return Alignment(reference: ref, H: H, pairs: used)
    }

    // MARK: Focal length (Szeliski / OpenCV focalsFromHomography)

    static func focal(from Hc: Homography) -> Double? {
        let h = Hc.m.map { $0 / Hc.m[8] }
        var f0: Double?, f1: Double?
        var d1 = h[6] * h[7], d2 = (h[7] - h[6]) * (h[7] + h[6])
        var v1 = -(h[0] * h[1] + h[3] * h[4]) / d1
        var v2 = (h[0] * h[0] + h[3] * h[3] - h[1] * h[1] - h[4] * h[4]) / d2
        if v1 < v2 { swap(&v1, &v2) }
        if v1 > 0 && v2 > 0 { f1 = sqrt(abs(d1) > abs(d2) ? v1 : v2) } else if v1 > 0 { f1 = sqrt(v1) }
        d1 = h[0] * h[3] + h[1] * h[4]
        d2 = h[0] * h[0] + h[1] * h[1] - h[3] * h[3] - h[4] * h[4]
        v1 = -h[2] * h[5] / d1
        v2 = (h[5] * h[5] - h[2] * h[2]) / d2
        if v1 < v2 { swap(&v1, &v2) }
        if v1 > 0 && v2 > 0 { f0 = sqrt(abs(d1) > abs(d2) ? v1 : v2) } else if v1 > 0 { f0 = sqrt(v1) }
        if let a = f0, let b = f1, a.isFinite, b.isFinite { return sqrt(a * b) }
        return nil
    }
}

struct RegRNG {
    var s: UInt64
    init(seed: UInt64) { s = seed &* 0x9E3779B97F4A7C15 &+ 1 }
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
