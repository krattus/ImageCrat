import Foundation

// Pure math behind drawing-tablet input: the pen pressure response curve and the pulled-string ("lazy mouse")
// stroke smoother. Portable (Foundation only); the app feeds them NSEvent samples.

/// Pen pressure response: a monotone curve through user control points, then an output clamp.
///
/// `map(0) == minOutput`, `map(1) == maxOutput`; with no interior points the curve is linear.
package struct PressureCurve: Codable, Equatable {
    /// Interior control points (x and y in 0...1), sorted by x. Empty = linear.
    package var points: [CGPoint]
    /// Output for the lightest touch (0...1).
    package var minOutput: Double
    /// Output for the firmest press (0...1).
    package var maxOutput: Double

    package init(points: [CGPoint] = [], minOutput: Double = 0, maxOutput: Double = 1) {
        self.points = PressureCurve.sanitized(points)
        self.minOutput = minOutput
        self.maxOutput = maxOutput
    }

    private enum CodingKeys: String, CodingKey { case points, minOutput, maxOutput }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        points = PressureCurve.sanitized((try? c.decodeIfPresent([CGPoint].self, forKey: .points)) ?? [])
        minOutput = (try? c.decodeIfPresent(Double.self, forKey: .minOutput)) ?? 0
        maxOutput = (try? c.decodeIfPresent(Double.self, forKey: .maxOutput)) ?? 1
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
        try c.encode(minOutput, forKey: .minOutput)
        try c.encode(maxOutput, forKey: .maxOutput)
    }

    /// Clamps points into the unit square, sorts them and drops ones too close to a neighbour or the ends.
    package static func sanitized(_ pts: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in pts.sorted(by: { $0.x < $1.x }) {
            let q = CGPoint(x: min(0.98, max(0.02, p.x)), y: min(1, max(0, p.y)))
            if let l = out.last, q.x - l.x < 0.02 { continue }
            out.append(q)
        }
        return out
    }

    /// A gamma-shaped curve: softness +1 = soft (a light touch already paints strongly), 0 = linear, -1 = firm.
    package static func preset(softness: Double, minOutput: Double = 0, maxOutput: Double = 1) -> PressureCurve {
        let s = min(1, max(-1, softness))
        if abs(s) < 0.001 { return PressureCurve(minOutput: minOutput, maxOutput: maxOutput) }
        let gamma = pow(3, -s)
        let pts = [0.25, 0.5, 0.75].map { x in CGPoint(x: x, y: pow(x, gamma)) }
        return PressureCurve(points: pts, minOutput: minOutput, maxOutput: maxOutput)
    }

    /// Softness of the curve (inverse of `preset`), estimated from its middle: +1 soft … -1 firm.
    package var softness: Double {
        let y = curve(0.5)
        guard y > 0.0001, y < 0.9999 else { return y >= 0.9999 ? 1 : -1 }
        let gamma = log(y) / log(0.5)
        return min(1, max(-1, -log(gamma) / log(3)))
    }

    /// The pressure delivered to the brush for a raw pen pressure (0...1).
    package func map(_ p: Double) -> Double {
        let y = curve(p)
        let lo = min(1, max(0, minOutput)), hi = min(1, max(lo, maxOutput))
        return lo + (hi - lo) * y
    }

    /// The curve part (0...1 → 0...1) without the output clamp.
    package func curve(_ p0: Double) -> Double {
        let p = p0.isFinite ? min(1, max(0, p0)) : 0
        if points.isEmpty { return p }
        let xs = [0.0] + points.map { Double($0.x) } + [1.0]
        let ys = [0.0] + points.map { Double($0.y) } + [1.0]
        let m = PressureCurve.tangents(xs, ys)
        var i = 0
        while i < xs.count - 2 && p > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i]
        guard h > 1e-9 else { return ys[i] }
        let t = (p - xs[i]) / h
        let t2 = t * t, t3 = t2 * t
        let v = (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1]
        return min(1, max(0, v))
    }

    /// Fritsch–Carlson tangents: the interpolant never overshoots and stays monotone when the points are.
    private static func tangents(_ x: [Double], _ y: [Double]) -> [Double] {
        let n = x.count
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { d[i] = (y[i + 1] - y[i]) / max(1e-9, x[i + 1] - x[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        if n > 2 { for i in 1..<(n - 1) { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 } }
        for i in 0..<(n - 1) {
            if abs(d[i]) < 1e-12 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / s.squareRoot()
                m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]
            }
        }
        return m
    }
}

/// Photoshop-style stroke smoothing: the paint ("tip") is pulled behind the pen on a string of `radius`.
///
/// Pulled-string mode: the tip only moves while the string is taut (the pen is more than `radius` away), so small
/// wobbles never reach the canvas. Otherwise the tip also eases towards the pen inside the radius, which keeps curves
/// round without a dead zone. `catchUp` steps (the pen rests) and the stroke end can let the tip reach the pen.
package struct StrokeSmoother {
    package var radius: Double
    package var pulledString: Bool
    package private(set) var tip: CGPoint?

    package init(radius: Double, pulledString: Bool = false) {
        self.radius = max(0, radius)
        self.pulledString = pulledString
    }

    /// String length (document px) for a Smoothing amount (0...1) at a view zoom. The response is gentle at the low
    /// end (10% ≈ 2.5 screen px) and reaches 100 screen px at 100%.
    package static func radius(smoothing: Double, zoom: Double, adjustForZoom: Bool = true) -> Double {
        let s = min(1, max(0, smoothing))
        let screen = 100 * pow(s, 1.6)
        return adjustForZoom ? screen / max(0.01, zoom) : screen
    }

    package var isActive: Bool { radius > 0.001 }

    package mutating func begin(_ p: CGPoint) { tip = p }

    /// Moves the tip for a new pen position and returns it.
    package mutating func step(_ pen: CGPoint, catchUp: Bool = false) -> CGPoint {
        guard let t = tip, isActive else { tip = pen; return pen }
        let v = CGPoint(x: pen.x - t.x, y: pen.y - t.y)
        let d = Double((v.x * v.x + v.y * v.y).squareRoot())
        var n = t
        if catchUp {
            // the pen rests: glide towards it (a fraction per tick), then land on it
            let k: CGFloat = d < 0.75 ? 1 : 0.35
            n = CGPoint(x: t.x + v.x * k, y: t.y + v.y * k)
        } else if d > radius {
            let k = CGFloat((d - radius) / d)
            n = CGPoint(x: t.x + v.x * k, y: t.y + v.y * k)
        } else if !pulledString, d > 1e-9 {
            let k = CGFloat(0.25 * d / radius)
            n = CGPoint(x: t.x + v.x * k, y: t.y + v.y * k)
        }
        tip = n
        return n
    }

    /// The last tip position of a stroke: the pen itself with catch-up, else wherever the string leaves it.
    package mutating func finish(_ pen: CGPoint, catchUp: Bool) -> CGPoint {
        if catchUp || !isActive { tip = pen; return pen }
        return step(pen)
    }
}
