import Foundation

// MARK: - Moving least squares (rigid)

/// Moving-least-squares rigid deformation (Schaefer et al. 2006) for Puppet Warp.
package enum MLSDeformer {
    /// Deforms each vertex of `grid` given control pins moved from `src[i]` to `dst[i]`.
    /// With 0 pins returns grid unchanged; with 1 pin translates.
    package static func deform(_ grid: MeshGrid, src: [CGPoint], dst: [CGPoint], alpha: Double = 1.0) -> MeshGrid {
        let n = min(src.count, dst.count)
        if n == 0 { return grid }
        if n == 1 {
            let d = dst[0] - src[0]
            var g = grid
            g.positions = grid.positions.map { $0 + d }
            return g
        }
        let px = src.prefix(n).map { Double($0.x) }, py = src.prefix(n).map { Double($0.y) }
        let qx = dst.prefix(n).map { Double($0.x) }, qy = dst.prefix(n).map { Double($0.y) }
        var w = [Double](repeating: 0, count: n)
        var g = grid
        for (k, v) in grid.positions.enumerated() {
            let vx = Double(v.x), vy = Double(v.y)
            var hit = -1
            var ws = 0.0, psx = 0.0, psy = 0.0, qsx = 0.0, qsy = 0.0
            for i in 0..<n {
                let dx = px[i] - vx, dy = py[i] - vy
                let d2 = dx * dx + dy * dy
                if d2 < 1e-12 { hit = i; break }
                let wi = alpha == 1 ? 1 / d2 : 1 / pow(d2, alpha)
                w[i] = wi
                ws += wi
                psx += wi * px[i]; psy += wi * py[i]
                qsx += wi * qx[i]; qsy += wi * qy[i]
            }
            if hit >= 0 {
                g.positions[k] = CGPoint(x: qx[hit], y: qy[hit])
                continue
            }
            psx /= ws; psy /= ws; qsx /= ws; qsy /= ws
            // Optimal rotation: θ = atan2(Σ w (p̂ × q̂), Σ w (p̂ · q̂)).
            var sDot = 0.0, sCross = 0.0
            for i in 0..<n {
                let ax = px[i] - psx, ay = py[i] - psy
                let bx = qx[i] - qsx, by = qy[i] - qsy
                sDot += w[i] * (ax * bx + ay * by)
                sCross += w[i] * (ax * by - ay * bx)
            }
            let norm = (sDot * sDot + sCross * sCross).squareRoot()
            let cs: Double, sn: Double
            if norm > 1e-12 { cs = sDot / norm; sn = sCross / norm } else { cs = 1; sn = 0 }
            let dx = vx - psx, dy = vy - psy
            g.positions[k] = CGPoint(x: cs * dx - sn * dy + qsx, y: sn * dx + cs * dy + qsy)
        }
        return g
    }
}
