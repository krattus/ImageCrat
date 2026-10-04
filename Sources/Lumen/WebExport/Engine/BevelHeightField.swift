import Foundation

/// Bevel & Emboss height field (see `BevelHeightMap` in Render): sub-pixel signed distance to the layer's edge, the
/// style's band and the technique's profile, then a float Gaussian. Lives in this always-optimised target because it is
/// a tight per-pixel loop that is far too slow unoptimised (debug builds and self tests).
enum BevelHeightField {
    /// Height of the profile at signed distance `s` (px, + inside). Outside its band the profile continues with the slope
    /// it has at the layer's edge on the side that is masked away, so smoothing doesn't flatten the slope at the edge.
    @inline(__always) static func profile(_ s: Float, style: Int, smooth: Bool, size: Float) -> Float {
        let halfPi: Float = .pi / 2
        switch style {
        case 0:   // inner bevel
            let t = s / size
            if t <= 0 { return smooth ? halfPi * t : t }
            if t >= 1 { return 1 }
            return smooth ? sin(halfPi * t) : t
        case 1:   // outer bevel
            let t = (s + size) / size
            if t <= 0 { return 0 }
            if t >= 1 { return smooth ? 1 + halfPi * (t - 1) : t }
            return smooth ? 1 - cos(halfPi * t) : t
        default:  // emboss, pillow emboss
            let t = (s + size / 2) / size
            if t <= 0 { return 0 }
            if t >= 1 { return 1 }
            return smooth ? 0.5 - 0.5 * cos(.pi * t) : t
        }
    }

    /// Fills `out` (w × h floats, any row order) from `alpha` (same layout).
    /// `style`: 0 Inner Bevel, 1 Outer Bevel, 2 Emboss / Pillow Emboss. `cap`: distances are clamped to ±cap px.
    /// `contour`: profile contour table (0…1 → 0…1), interpolated linearly.
    static func compute(alpha: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>, w: Int, h: Int,
                        style: Int, smooth: Bool, size: Float, cap: Float, sigma: Double, contour: [Float]?) {
        let n = w * h
        guard n > 0 else { return }
        let sd = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { sd.deallocate() }
        signedDistance(alpha: alpha, out: sd, w: w, h: h)
        // A distance field is linear across the band, which a blur leaves alone; what it removes are the hairline seams
        // between neighbouring edge pixels' estimates. The profile's own creases (band end, chisel) come after it.
        for i in 0..<n { sd[i] = min(max(sd[i], -cap), cap) }
        gaussian(sd, w, h, sigma: 1.5)
        let lut = contour
        let lutMax = Float((lut?.count ?? 1) - 1)
        for i in 0..<n {
            let s = min(max(sd[i], -cap), cap)
            var v = profile(s, style: style, smooth: smooth, size: size)
            if let l = lut {
                let x = min(max(v, 0), 1) * lutMax
                let i0 = Int(x), i1 = min(i0 + 1, Int(lutMax))
                let f = x - Float(i0)
                v = l[i0] * (1 - f) + l[i1] * f
            }
            out[i] = v
        }
        gaussian(out, w, h, sigma: sigma)
    }

    /// Signed distance (px, + inside) to the edge of `alpha`'s shape (alpha ≥ 0.5), with sub-pixel accuracy.
    ///
    /// A distance measured between pixel centres jumps by up to a pixel wherever the edge's staircase steps; its direction,
    /// which is what a bevel's shading shows, then fans out in hair-like streaks. So the nearest pixel across the edge
    /// (exact Euclidean feature transform) only says *where* the edge is: the distance is measured to the edge's tangent
    /// there, placed at the 0.5 level of the slightly smoothed alpha and oriented by its gradient (exact for straight anti-aliased
    /// edges). Around corners, where the tangent no longer faces the point, it blends into the plain Euclidean distance.
    static func signedDistance(alpha: UnsafePointer<Float>, out: UnsafeMutablePointer<Float>, w: Int, h: Int) {
        let n = w * h
        let inf: Float = 1e20
        let fIn = UnsafeMutablePointer<Float>.allocate(capacity: n), fOut = UnsafeMutablePointer<Float>.allocate(capacity: n)
        let nIn = UnsafeMutablePointer<Int32>.allocate(capacity: n), nOut = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let sm = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { fIn.deallocate(); fOut.deallocate(); nIn.deallocate(); nOut.deallocate(); sm.deallocate() }
        for i in 0..<n {
            let inside = alpha[i] >= 0.5
            fIn[i] = inside ? inf : 0      // for inside pixels: the nearest outside pixel
            fOut[i] = inside ? 0 : inf     // for outside pixels: the nearest inside pixel
            sm[i] = alpha[i]
        }
        featureTransform(fIn, nIn, w, h)
        featureTransform(fOut, nOut, w, h)
        gaussian(sm, w, h, sigma: 2.0)      // position and orientation of the edge (its normal shows directly in the shading)
        for i in 0..<n {
            let inside = alpha[i] >= 0.5
            let q = Int(inside ? nIn[i] : nOut[i])
            if q < 0 { out[i] = inside ? inf : -inf; continue }
            let px = Float(i % w), py = Float(i / w), qx = Float(q % w), qy = Float(q / w)
            // outward normal at q: down the alpha gradient
            let qxi = q % w, qyi = q / w
            let gx = sm[qyi * w + min(qxi + 1, w - 1)] - sm[qyi * w + max(qxi - 1, 0)]
            let gy = sm[min(qyi + 1, h - 1) * w + qxi] - sm[max(qyi - 1, 0) * w + qxi]
            let gl = (gx * gx + gy * gy).squareRoot()
            let dEuclid: Float
            let fallback = (inside ? fIn[i] : fOut[i]).squareRoot() - 0.5
            guard gl > 1e-4 else { out[i] = inside ? fallback : -fallback; continue }
            let nx = -gx / gl, ny = -gy / gl
            // edge point near q: one Newton step along the normal to the 0.5 level of the smoothed alpha (a straight
            // anti-aliased edge keeps its 0.5 level under a symmetric blur)
            let off = min(max((sm[q] - 0.5) / (gl / 2), -1.5), 1.5)
            let ex = qx + nx * off, ey = qy + ny * off
            let vx = px - ex, vy = py - ey
            let along = (vx * nx + vy * ny) * (inside ? -1 : 1)     // distance to the tangent, + on p's own side
            dEuclid = (vx * vx + vy * vy).squareRoot()
            var d: Float
            if dEuclid < 1e-3 {
                d = 0
            } else {
                let c = max(along, 0) / dEuclid                        // how squarely the tangent faces p
                let t = min(max((c - 0.80) / 0.15, 0), 1)
                let wgt = t * t * (3 - 2 * t)
                d = wgt * max(along, 0) + (1 - wgt) * dEuclid
            }
            out[i] = inside ? d : -d
        }
    }

    // MARK: Distance transform

    /// Exact squared Euclidean distance transform with feature transform (Felzenszwalb & Huttenlocher): `f` is 0 at
    /// feature pixels and huge elsewhere; on return `f` holds squared distances and `nearest` the index (y·w + x) of the
    /// nearest feature pixel, -1 where there is none.
    static func featureTransform(_ f: UnsafeMutablePointer<Float>, _ nearest: UnsafeMutablePointer<Int32>, _ w: Int, _ h: Int) {
        let m = max(w, h), n = w * h
        let line = UnsafeMutablePointer<Float>.allocate(capacity: m), res = UnsafeMutablePointer<Float>.allocate(capacity: m)
        let v = UnsafeMutablePointer<Int>.allocate(capacity: m), z = UnsafeMutablePointer<Float>.allocate(capacity: m + 1)
        let idx = UnsafeMutablePointer<Int32>.allocate(capacity: m), colRow = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        defer { line.deallocate(); res.deallocate(); v.deallocate(); z.deallocate(); idx.deallocate(); colRow.deallocate() }
        for x in 0..<w {
            for y in 0..<h { line[y] = f[y * w + x] }
            edt1D(line, res, h, v, z, idx)
            for y in 0..<h { f[y * w + x] = res[y]; colRow[y * w + x] = idx[y] }
        }
        for y in 0..<h {
            let row = f + y * w
            for x in 0..<w { line[x] = row[x] }
            edt1D(line, res, w, v, z, idx)
            for x in 0..<w {
                row[x] = res[x]
                let c = Int(idx[x])
                nearest[y * w + x] = res[x] < 1e19 ? colRow[y * w + c] * Int32(w) + Int32(c) : -1
            }
        }
    }

    @inline(__always) private static func edt1D(_ f: UnsafeMutablePointer<Float>, _ d: UnsafeMutablePointer<Float>, _ n: Int,
                                                _ v: UnsafeMutablePointer<Int>, _ z: UnsafeMutablePointer<Float>,
                                                _ idx: UnsafeMutablePointer<Int32>) {
        let big: Float = 1e30
        var k = 0
        v[0] = 0; z[0] = -big; z[1] = big
        if n > 1 {
            for q in 1..<n {
                let fq = f[q] + Float(q * q)
                var p = v[k]
                var s = (fq - (f[p] + Float(p * p))) / Float(2 * (q - p))
                while s <= z[k] {       // (z[0] = -∞ ends the loop)
                    k -= 1
                    p = v[k]
                    s = (fq - (f[p] + Float(p * p))) / Float(2 * (q - p))
                }
                k += 1; v[k] = q; z[k] = s; z[k + 1] = big
            }
        }
        k = 0
        for q in 0..<n {
            while z[k + 1] < Float(q) { k += 1 }
            let p = v[k], dq = Float(q - p)
            d[q] = dq * dq + f[p]
            idx[q] = Int32(p)
        }
    }

    // MARK: Float Gaussian

    /// Gaussian blur in place (three box passes per axis, clamped edges, double-precision running sums).
    static func gaussian(_ img: UnsafeMutablePointer<Float>, _ w: Int, _ h: Int, sigma: Double) {
        guard sigma >= 0.3, w > 0, h > 0 else { return }
        let radii = boxRadii(sigma)
        let m = max(w, h)
        let src = UnsafeMutablePointer<Float>.allocate(capacity: m), dst = UnsafeMutablePointer<Float>.allocate(capacity: m)
        defer { src.deallocate(); dst.deallocate() }
        for y in 0..<h {
            let row = img + y * w
            for i in 0..<w { src[i] = row[i] }
            for r in radii { box(src, dst, w, r); for i in 0..<w { src[i] = dst[i] } }
            for i in 0..<w { row[i] = src[i] }
        }
        for x in 0..<w {
            for i in 0..<h { src[i] = img[i * w + x] }
            for r in radii { box(src, dst, h, r); for i in 0..<h { src[i] = dst[i] } }
            for i in 0..<h { img[i * w + x] = src[i] }
        }
    }

    /// Radii of three boxes whose sum approximates a Gaussian of `sigma`.
    static func boxRadii(_ sigma: Double) -> [Int] {
        let n = 3.0
        let wIdeal = (12 * sigma * sigma / n + 1).squareRoot()
        var wl = Int(wIdeal.rounded(.down)); if wl % 2 == 0 { wl -= 1 }
        wl = max(1, wl)
        let wu = wl + 2
        let mIdeal = (12 * sigma * sigma - n * Double(wl * wl) - 4 * n * Double(wl) - 3 * n) / (-4 * Double(wl) - 4)
        let mm = Int(mIdeal.rounded())
        return (0..<3).map { ($0 < mm ? wl : wu) / 2 }.filter { $0 > 0 }
    }

    @inline(__always) private static func box(_ s: UnsafeMutablePointer<Float>, _ d: UnsafeMutablePointer<Float>, _ n: Int, _ r: Int) {
        guard r > 0 else { for i in 0..<n { d[i] = s[i] }; return }
        let norm = 1 / Double(2 * r + 1)
        @inline(__always) func at(_ i: Int) -> Double { Double(s[min(max(i, 0), n - 1)]) }
        var acc = 0.0
        for i in -r...r { acc += at(i) }
        for i in 0..<n {
            d[i] = Float(acc * norm)
            acc += at(i + r + 1) - at(i - r)
        }
    }
}
