import Foundation

/// Deterministic per-particle random numbers (SplitMix64).
package struct PRNG {
    package var state: UInt64

    @inlinable package init(_ a: UInt64, _ b: UInt64 = 0, _ c: UInt64 = 0) {
        state = PRNG.mix(a &* 0x9E3779B97F4A7C15 &+ PRNG.mix(b &+ 0xD1B54A32D192ED03 &+ PRNG.mix(c &+ 0x8CB92BA72F3D8DD7)))
    }

    @inlinable @inline(__always) package static func mix(_ v: UInt64) -> UInt64 {
        var z = v &+ 0x9E3779B97F4A7C15
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    @inlinable @inline(__always) package mutating func nextU64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    @inlinable @inline(__always) package mutating func next() -> Double {
        Double(nextU64() >> 11) * (1.0 / 9007199254740992.0)
    }

    @inlinable @inline(__always) package mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
    /// Uniform in [-1, 1).
    @inlinable @inline(__always) package mutating func signed() -> Double { next() * 2 - 1 }
}

/// Simplex noise (Gustavson) with analytic derivatives, plus curl noise built on it.
package enum PNoise {
    /// Permutation table (512 entries) and gradient components; allocated once and never freed.
    private static let perm: UnsafeMutablePointer<Int32> = {
        // fixed permutation (deterministic across runs); seeds are folded in by offsetting the coordinates
        var p = Array(0..<256)
        var r = PRNG(0x5EED, 17, 3)
        for i in stride(from: 255, to: 0, by: -1) {
            let j = Int(r.nextU64() % UInt64(i + 1))
            p.swapAt(i, j)
        }
        let m = UnsafeMutablePointer<Int32>.allocate(capacity: 512)
        for i in 0..<512 { m[i] = Int32(p[i & 255]) }
        return m
    }()

    private static let grad: UnsafeMutablePointer<Double> = {
        let g: [(Double, Double, Double)] = [
            (1, 1, 0), (-1, 1, 0), (1, -1, 0), (-1, -1, 0),
            (1, 0, 1), (-1, 0, 1), (1, 0, -1), (-1, 0, -1),
            (0, 1, 1), (0, -1, 1), (0, 1, -1), (0, -1, -1),
            (1, 1, 0), (-1, 1, 0), (0, -1, 1), (0, -1, -1),
        ]
        let m = UnsafeMutablePointer<Double>.allocate(capacity: 48)
        for i in 0..<16 { m[i * 3] = g[i].0; m[i * 3 + 1] = g[i].1; m[i * 3 + 2] = g[i].2 }
        return m
    }()

    /// 3D simplex noise in about [-1, 1] with its x / y derivatives.
    @inlinable package static func simplex(_ x: Double, _ y: Double, _ z: Double) -> (n: Double, dx: Double, dy: Double) {
        let F3 = 1.0 / 3.0, G3 = 1.0 / 6.0
        let s = (x + y + z) * F3
        let fi = (x + s).rounded(.down), fj = (y + s).rounded(.down), fk = (z + s).rounded(.down)
        let t = (fi + fj + fk) * G3
        let x0 = x - (fi - t), y0 = y - (fj - t), z0 = z - (fk - t)
        var i1 = 0, j1 = 0, k1 = 0, i2 = 0, j2 = 0, k2 = 0
        if x0 >= y0 {
            if y0 >= z0 { i1 = 1; i2 = 1; j2 = 1 }
            else if x0 >= z0 { i1 = 1; i2 = 1; k2 = 1 }
            else { k1 = 1; i2 = 1; k2 = 1 }
        } else {
            if y0 < z0 { k1 = 1; j2 = 1; k2 = 1 }
            else if x0 < z0 { j1 = 1; j2 = 1; k2 = 1 }
            else { j1 = 1; i2 = 1; j2 = 1 }
        }
        let x1 = x0 - Double(i1) + G3, y1 = y0 - Double(j1) + G3, z1 = z0 - Double(k1) + G3
        let x2 = x0 - Double(i2) + 2 * G3, y2 = y0 - Double(j2) + 2 * G3, z2 = z0 - Double(k2) + 2 * G3
        let x3 = x0 - 1 + 3 * G3, y3 = y0 - 1 + 3 * G3, z3 = z0 - 1 + 3 * G3
        let ii = Int(fi) & 255, jj = Int(fj) & 255, kk = Int(fk) & 255
        let p = perm, g = grad
        let g0 = Int(p[ii + Int(p[jj + Int(p[kk])])]) & 15
        let g1 = Int(p[ii + i1 + Int(p[jj + j1 + Int(p[kk + k1])])]) & 15
        let g2 = Int(p[ii + i2 + Int(p[jj + j2 + Int(p[kk + k2])])]) & 15
        let g3 = Int(p[ii + 1 + Int(p[jj + 1 + Int(p[kk + 1])])]) & 15
        var n = 0.0, dx = 0.0, dy = 0.0
        var tt = 0.6 - x0 * x0 - y0 * y0 - z0 * z0
        if tt > 0 {
            let gx = g[g0 * 3], gy = g[g0 * 3 + 1], gz = g[g0 * 3 + 2]
            let t2 = tt * tt, t4 = t2 * t2, gd = gx * x0 + gy * y0 + gz * z0, tmp = t2 * tt * gd
            n += t4 * gd; dx += -8 * tmp * x0 + t4 * gx; dy += -8 * tmp * y0 + t4 * gy
        }
        tt = 0.6 - x1 * x1 - y1 * y1 - z1 * z1
        if tt > 0 {
            let gx = g[g1 * 3], gy = g[g1 * 3 + 1], gz = g[g1 * 3 + 2]
            let t2 = tt * tt, t4 = t2 * t2, gd = gx * x1 + gy * y1 + gz * z1, tmp = t2 * tt * gd
            n += t4 * gd; dx += -8 * tmp * x1 + t4 * gx; dy += -8 * tmp * y1 + t4 * gy
        }
        tt = 0.6 - x2 * x2 - y2 * y2 - z2 * z2
        if tt > 0 {
            let gx = g[g2 * 3], gy = g[g2 * 3 + 1], gz = g[g2 * 3 + 2]
            let t2 = tt * tt, t4 = t2 * t2, gd = gx * x2 + gy * y2 + gz * z2, tmp = t2 * tt * gd
            n += t4 * gd; dx += -8 * tmp * x2 + t4 * gx; dy += -8 * tmp * y2 + t4 * gy
        }
        tt = 0.6 - x3 * x3 - y3 * y3 - z3 * z3
        if tt > 0 {
            let gx = g[g3 * 3], gy = g[g3 * 3 + 1], gz = g[g3 * 3 + 2]
            let t2 = tt * tt, t4 = t2 * t2, gd = gx * x3 + gy * y3 + gz * z3, tmp = t2 * tt * gd
            n += t4 * gd; dx += -8 * tmp * x3 + t4 * gx; dy += -8 * tmp * y3 + t4 * gy
        }
        return (28 * n, 28 * dx, 28 * dy)
    }

    @inlinable @inline(__always) package static func value(_ x: Double, _ y: Double, _ z: Double = 0) -> Double { simplex(x, y, z).n }

    /// Fractal noise in about [-1, 1].
    @inlinable package static func fbm(_ x: Double, _ y: Double, _ z: Double = 0, octaves: Int = 4) -> Double {
        var amp = 0.5, f = 1.0, sum = 0.0, norm = 0.0
        for o in 0..<octaves {
            sum += amp * simplex(x * f + Double(o) * 17.3, y * f - Double(o) * 9.1, z).n
            norm += amp
            amp *= 0.5; f *= 2
        }
        return sum / norm
    }

    /// Divergence-free 2D velocity (curl of a scalar potential made of two octaves), roughly unit magnitude.
    @inlinable @inline(__always) package static func curl(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double) {
        let a = simplex(x, y, z)
        let b = simplex(x * 2.03 + 31.4, y * 2.03 - 12.7, z * 1.3 + 5.2)
        let dx = a.dx + b.dx * 0.5 * 2.03, dy = a.dy + b.dy * 0.5 * 2.03
        return (dy * 0.5, -dx * 0.5)
    }
}
