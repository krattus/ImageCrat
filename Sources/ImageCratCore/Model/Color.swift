import Foundation

/// Non-premultiplied sRGB color, components 0...1.
package struct RGBA: Codable, Equatable, Hashable {
    package var r: Double
    package var g: Double
    package var b: Double
    package var a: Double = 1

    package static let black = RGBA(r: 0, g: 0, b: 0)
    package static let white = RGBA(r: 1, g: 1, b: 1)
    package static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
    package static let red = RGBA(r: 1, g: 0, b: 0)

    @inlinable package init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    @inlinable package init(gray: Double, a: Double = 1) { self.init(r: gray, g: gray, b: gray, a: a) }

    @inlinable package init(r8: UInt8, g8: UInt8, b8: UInt8, a8: UInt8 = 255) {
        self.init(r: Double(r8) / 255, g: Double(g8) / 255, b: Double(b8) / 255, a: Double(a8) / 255)
    }

    @inlinable package init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(r8: UInt8((v >> 16) & 0xff), g8: UInt8((v >> 8) & 0xff), b8: UInt8(v & 0xff))
        } else {
            self.init(r8: UInt8((v >> 24) & 0xff), g8: UInt8((v >> 16) & 0xff), b8: UInt8((v >> 8) & 0xff), a8: UInt8(v & 0xff))
        }
    }

    @inlinable package var hex: String {
        String(format: "%02X%02X%02X", r8, g8, b8)
    }

    @inlinable package var r8: Int { Int((clamp(r, 0, 1) * 255).rounded()) }
    @inlinable package var g8: Int { Int((clamp(g, 0, 1) * 255).rounded()) }
    @inlinable package var b8: Int { Int((clamp(b, 0, 1) * 255).rounded()) }
    @inlinable package var a8: Int { Int((clamp(a, 0, 1) * 255).rounded()) }

    @inlinable package func withAlpha(_ a: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: a) }

    @inlinable package var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }

    @inlinable package var inverted: RGBA { RGBA(r: 1 - r, g: 1 - g, b: 1 - b, a: a) }

    @inlinable package func mix(_ o: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t)
    }

    // MARK: HSB
    @inlinable package var hsb: (h: Double, s: Double, b: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let d = mx - mn
        var h = 0.0
        if d > 1e-9 {
            if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
        }
        let s = mx <= 0 ? 0 : d / mx
        return (h, s, mx)
    }

    @inlinable package init(h: Double, s: Double, v: Double, a: Double = 1) {
        let hh = (h - floor(h)) * 6
        let i = Int(hh) % 6
        let f = hh - floor(hh)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: self.init(r: v, g: t, b: p, a: a)
        case 1: self.init(r: q, g: v, b: p, a: a)
        case 2: self.init(r: p, g: v, b: t, a: a)
        case 3: self.init(r: p, g: q, b: v, a: a)
        case 4: self.init(r: t, g: p, b: v, a: a)
        default: self.init(r: v, g: p, b: q, a: a)
        }
    }

    // MARK: HSL helpers
    @inlinable package var hsl: (h: Double, s: Double, l: Double) {
        let mx = max(r, g, b), mn = min(r, g, b)
        let l = (mx + mn) / 2
        let d = mx - mn
        if d < 1e-9 { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h / 6, s, l)
    }

    @inlinable package init(h: Double, s: Double, l: Double, a: Double = 1) {
        if s <= 0 { self.init(r: l, g: l, b: l, a: a); return }
        func hue2rgb(_ p: Double, _ q: Double, _ tt: Double) -> Double {
            var t = tt
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        let hh = h - floor(h)
        self.init(r: hue2rgb(p, q, hh + 1.0 / 3), g: hue2rgb(p, q, hh), b: hue2rgb(p, q, hh - 1.0 / 3), a: a)
    }

    // MARK: Lab (approximate, D65)
    @inlinable package var lab: (l: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let R = lin(r), G = lin(g), B = lin(b)
        var X = R * 0.4124 + G * 0.3576 + B * 0.1805
        var Y = R * 0.2126 + G * 0.7152 + B * 0.0722
        var Z = R * 0.0193 + G * 0.1192 + B * 0.9505
        X /= 0.95047; Z /= 1.08883
        func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16.0 / 116 }
        let fx = f(X), fy = f(Y), fz = f(Z)
        Y = 0
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    @inlinable package var cmyk: (c: Double, m: Double, y: Double, k: Double) {
        let k = 1 - max(r, g, b)
        if k >= 1 { return (0, 0, 0, 1) }
        return ((1 - r - k) / (1 - k), (1 - g - k) / (1 - k), (1 - b - k) / (1 - k), k)
    }
}
