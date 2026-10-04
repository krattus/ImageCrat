import Foundation

/// Detection of thin, long structures (wires, cables, scratches) on single-channel planar images.
enum ThinStructures {
    /// Morphological line response: max(white top-hat, black top-hat) with a square of radius r.
    static func lineResponse(_ lum: PlanarImage, r: Int, darkWeight: Float = 1, brightWeight: Float = 1) -> PlanarImage {
        let closed = MaskMath.erode(MaskMath.dilate(lum, r), r)
        let opened = MaskMath.dilate(MaskMath.erode(lum, r), r)
        var resp = PlanarImage(width: lum.width, height: lum.height, channels: 1)
        let n = lum.data.count
        resp.data.withUnsafeMutableBufferPointer { o in
            lum.data.withUnsafeBufferPointer { l in
                closed.data.withUnsafeBufferPointer { c in
                    opened.data.withUnsafeBufferPointer { op in
                        for i in 0..<n { o[i] = max((c[i] - l[i]) * darkWeight, (l[i] - op[i]) * brightWeight) }
                    }
                }
            }
        }
        return resp
    }

    /// Hessian ridge strength (thin bright or dark lines) after light Gaussian smoothing; noise-robust.
    /// `polarity`: 1 bright lines only, -1 dark lines only, 0 both.
    static func ridgeResponse(_ lum: PlanarImage, smooth: Int = 1, polarity: Int = 0) -> PlanarImage {
        let g = MaskMath.boxBlur(MaskMath.boxBlur(lum, smooth), smooth)
        let w = g.width, h = g.height
        var o = PlanarImage(width: w, height: h, channels: 1)
        g.data.withUnsafeBufferPointer { s in
            o.data.withUnsafeMutableBufferPointer { d in
                for y in 1..<max(1, h - 1) {
                    for x in 1..<max(1, w - 1) {
                        let i = y * w + x
                        let c = s[i]
                        let xx = s[i + 1] - 2 * c + s[i - 1]
                        let yy = s[i + w] - 2 * c + s[i - w]
                        let xy = (s[i + w + 1] - s[i + w - 1] - s[i - w + 1] + s[i - w - 1]) * 0.25
                        let m = (xx + yy) * 0.5, q = ((xx - yy) * 0.5 * (xx - yy) * 0.5 + xy * xy).squareRoot()
                        let l1 = m - q, l2 = m + q          // l1 ≤ l2
                        // bright ridge: strongly negative l1, small |l2|; dark ridge: strongly positive l2, small |l1|
                        let bright = polarity >= 0 && l1 < 0 ? max(0, -l1 - 2 * abs(l2)) : 0
                        let dark = polarity <= 0 && l2 > 0 ? max(0, l2 - 2 * abs(l1)) : 0
                        d[i] = max(bright, dark)
                    }
                }
            }
        }
        return o
    }

    struct Component {
        var pixels: [Int32]
        var x0: Int, y0: Int, x1: Int, y1: Int
        var length: Double { hypot(Double(x1 - x0 + 1), Double(y1 - y0 + 1)) }
        var thickness: Double { Double(pixels.count) / max(1, length) }
    }

    /// 8-connected components of `bin > 0.5`.
    static func components(_ bin: PlanarImage) -> [Component] {
        let w = bin.width, h = bin.height
        var label = [Bool](repeating: false, count: w * h)
        var out: [Component] = []
        var stack: [Int32] = []
        bin.data.withUnsafeBufferPointer { b in
            label.withUnsafeMutableBufferPointer { lab in
                for i in 0..<(w * h) where b[i] > 0.5 && !lab[i] {
                    var c = Component(pixels: [], x0: w, y0: h, x1: 0, y1: 0)
                    stack.append(Int32(i)); lab[i] = true
                    while let j32 = stack.popLast() {
                        let j = Int(j32)
                        c.pixels.append(j32)
                        let x = j % w, y = j / w
                        if x < c.x0 { c.x0 = x }; if x > c.x1 { c.x1 = x }; if y < c.y0 { c.y0 = y }; if y > c.y1 { c.y1 = y }
                        for dy in -1...1 {
                            let ny = y + dy
                            if ny < 0 || ny >= h { continue }
                            for dx in -1...1 {
                                let nx = x + dx
                                if nx < 0 || nx >= w { continue }
                                let k = ny * w + nx
                                if !lab[k] && b[k] > 0.5 { lab[k] = true; stack.append(Int32(k)) }
                            }
                        }
                    }
                    out.append(c)
                }
            }
        }
        return out
    }

    /// Mean luminance difference between the two sides of a component (perpendicular to its principal axis),
    /// sampled `offset` px away. Wires/scratches: similar sides; object edges / horizons: different sides.
    static func sideDifference(_ c: Component, lum: PlanarImage, offset: Double) -> Float {
        let w = lum.width, h = lum.height
        let n = Double(c.pixels.count)
        var mx = 0.0, my = 0.0
        for p in c.pixels { mx += Double(Int(p) % w); my += Double(Int(p) / w) }
        mx /= n; my /= n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in c.pixels { let dx = Double(Int(p) % w) - mx, dy = Double(Int(p) / w) - my; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
        let ang = 0.5 * atan2(2 * sxy, sxx - syy)
        let nx = -sin(ang), ny = cos(ang)
        var sum: Float = 0, cnt: Float = 0
        let step = max(1, c.pixels.count / 400)
        var i = 0
        while i < c.pixels.count {
            let p = Int(c.pixels[i]); let x = Double(p % w), y = Double(p / w)
            let ax = Int((x + nx * offset).rounded()), ay = Int((y + ny * offset).rounded())
            let bx = Int((x - nx * offset).rounded()), by = Int((y - ny * offset).rounded())
            if ax >= 0, ay >= 0, ax < w, ay < h, bx >= 0, by >= 0, bx < w, by < h {
                sum += abs(lum.data[ay * w + ax] - lum.data[by * w + bx]); cnt += 1
            }
            i += step
        }
        return cnt > 0 ? sum / cnt : 1
    }
}
