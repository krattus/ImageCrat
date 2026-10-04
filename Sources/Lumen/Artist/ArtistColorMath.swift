import Foundation
import CoreGraphics
import CoreImage
import ImageCratCore

// Colour maths of the Artist module: Oklab, harmony schemes, k-means palette extraction, WCAG contrast and
// colour-vision-deficiency simulation. Everything here is pure and headless-testable.

// MARK: - Oklab

struct Oklab: Equatable {
    var L: Double, a: Double, b: Double

    static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gam(_ c: Double) -> Double { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    init(L: Double, a: Double, b: Double) { self.L = L; self.a = a; self.b = b }

    init(_ c: RGBA) { self.init(r: c.r, g: c.g, b: c.b) }

    init(r: Double, g: Double, b: Double) {
        let R = Oklab.lin(clamp(r, 0, 1)), G = Oklab.lin(clamp(g, 0, 1)), B = Oklab.lin(clamp(b, 0, 1))
        let l = cbrt(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B)
        let m = cbrt(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B)
        let s = cbrt(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
        self.L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    /// Linear sRGB (may be out of gamut).
    var linear: (Double, Double, Double) {
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    var inGamut: Bool {
        let (r, g, b) = linear
        let e = 1e-4
        return r >= -e && g >= -e && b >= -e && r <= 1 + e && g <= 1 + e && b <= 1 + e
    }

    /// sRGB colour; out-of-gamut colours keep lightness and hue and lose chroma until they fit.
    var rgba: RGBA {
        var c = self
        c.L = clamp(c.L, 0, 1)
        if !c.inGamut {
            var lo = 0.0, hi = 1.0
            for _ in 0..<18 {
                let mid = (lo + hi) / 2
                if Oklab(L: c.L, a: a * mid, b: b * mid).inGamut { lo = mid } else { hi = mid }
            }
            c = Oklab(L: c.L, a: a * lo, b: b * lo)
        }
        let (r, g, b) = c.linear
        return RGBA(r: clamp(Oklab.gam(clamp(r, 0, 1)), 0, 1), g: clamp(Oklab.gam(clamp(g, 0, 1)), 0, 1), b: clamp(Oklab.gam(clamp(b, 0, 1)), 0, 1))
    }

    var chroma: Double { (a * a + b * b).squareRoot() }
    /// Hue angle in degrees 0..<360.
    var hue: Double { var h = atan2(b, a) * 180 / .pi; if h < 0 { h += 360 }; return h }

    func distance(_ o: Oklab) -> Double {
        let dl = L - o.L, da = a - o.a, db = b - o.b
        return (dl * dl + da * da + db * db).squareRoot()
    }
}

// MARK: - Harmony

enum HarmonyScheme: String, CaseIterable, Identifiable, Codable {
    case complementary, analogous, triadic, tetradic, square, split, monochrome
    var id: String { rawValue }
    var title: String {
        switch self {
        case .complementary: return "Complementary"
        case .analogous: return "Analogous"
        case .triadic: return "Triadic"
        case .tetradic: return "Tetradic"
        case .square: return "Square"
        case .split: return "Split Complementary"
        case .monochrome: return "Monochrome"
        }
    }

    /// Hue offsets in degrees from the base hue (the base, 0, is always first).
    var hueOffsets: [Double] {
        switch self {
        case .complementary: return [0, 180]
        case .analogous: return [0, -30, 30]
        case .triadic: return [0, 120, 240]
        case .tetradic: return [0, 60, 180, 240]
        case .square: return [0, 90, 180, 270]
        case .split: return [0, 150, 210]
        case .monochrome: return [0]
        }
    }
}

enum ColorHarmony {
    static func normHue(_ deg: Double) -> Double { let h = deg.truncatingRemainder(dividingBy: 360); return h < 0 ? h + 360 : h }

    /// Hues (degrees on the HSB wheel) of a scheme for a base hue.
    static func hues(_ scheme: HarmonyScheme, baseHue: Double) -> [Double] { scheme.hueOffsets.map { normHue(baseHue + $0) } }

    /// The key colours of a scheme (base first). Saturation and brightness follow the base colour.
    static func colors(_ scheme: HarmonyScheme, base: RGBA) -> [RGBA] {
        let (h, s, v) = base.hsb
        if scheme == .monochrome {
            // same hue: from a dark, saturated shade to a light tint, the base itself included
            let steps: [(Double, Double)] = [(min(1, s * 1.1 + 0.05), max(0.12, v * 0.45)), (s, max(0.2, v * 0.72)), (s, v),
                                             (s * 0.62, min(1, v * 1.12 + 0.08)), (s * 0.3, min(1, v * 1.2 + 0.18))]
            return steps.map { RGBA(h: h, s: clamp($0.0, 0, 1), v: clamp($0.1, 0, 1)) }
        }
        return hues(scheme, baseHue: h * 360).enumerated().map { i, hue in i == 0 ? base.withAlpha(1) : RGBA(h: hue / 360, s: s, v: v) }
    }

    /// A swatch set: the scheme colours plus a darker and a lighter variation of each (at most 12).
    static func swatchSet(_ scheme: HarmonyScheme, base: RGBA) -> [RGBA] {
        let keys = colors(scheme, base: base)
        if scheme == .monochrome { return keys }
        var out = keys
        for c in keys {
            let (h, s, v) = c.hsb
            out.append(RGBA(h: h, s: clamp(s * 1.05, 0, 1), v: clamp(v * 0.62, 0, 1)))
        }
        for c in keys {
            let (h, s, v) = c.hsb
            out.append(RGBA(h: h, s: clamp(s * 0.5, 0, 1), v: clamp(v * 1.1 + 0.12, 0, 1)))
        }
        return Array(out.prefix(12))
    }
}

// MARK: - Palette extraction (k-means in Oklab)

struct PaletteEntry: Equatable {
    var color: RGBA
    /// Fraction of the sampled pixels assigned to this colour.
    var weight: Double
}

enum PaletteExtractor {
    /// Opaque pixels of `buf` (optionally only where `mask` > 127), subsampled to at most `maxSamples`.
    static func samples(_ buf: PixelBuffer, mask: PixelBuffer? = nil, maxSamples: Int = 20000) -> [Oklab] {
        guard buf.format == .rgba else { return [] }
        let w = buf.width, h = buf.height
        let step = max(1, Int((Double(w * h) / Double(maxSamples)).squareRoot().rounded(.up)))
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        let mp = mask?.data.assumingMemoryBound(to: UInt8.self)
        var out: [Oklab] = []
        out.reserveCapacity(min(maxSamples * 2, w * h / (step * step) + 16))
        var y = step / 2
        while y < h {
            var x = step / 2
            while x < w {
                let i = y * buf.bytesPerRow + x * 4
                let a = Double(p[i + 3])
                var ok = a >= 128
                if ok, let mp, let m = mask {
                    ok = x < m.width && y < m.height && mp[y * m.bytesPerRow + x * m.bytesPerPixel] > 127
                }
                if ok { out.append(Oklab(r: Double(p[i]) / a, g: Double(p[i + 1]) / a, b: Double(p[i + 2]) / a)) }
                x += step
            }
            y += step
        }
        return out
    }

    /// k-means (k-means++ seeding, deterministic) in Oklab. Returns `k` or fewer colours sorted dark → light.
    static func kMeans(_ pts: [Oklab], k: Int, iterations: Int = 24, seed: UInt64 = 0xC0FFEE) -> [PaletteEntry] {
        guard !pts.isEmpty else { return [] }
        let k = max(1, min(k, pts.count))
        var rng = SeededRandom(seed: seed)
        var centers: [Oklab] = [pts[Int(rng.next() * Double(pts.count)) % pts.count]]
        var d2 = pts.map { let d = $0.distance(centers[0]); return d * d }
        while centers.count < k {
            let total = d2.reduce(0, +)
            if total <= 1e-12 { break }          // fewer distinct colours than k
            var r = rng.next() * total
            var pick = pts.count - 1
            for (i, d) in d2.enumerated() { r -= d; if r <= 0 { pick = i; break } }
            centers.append(pts[pick])
            for i in pts.indices { let d = pts[i].distance(pts[pick]); d2[i] = min(d2[i], d * d) }
        }
        var assign = [Int](repeating: 0, count: pts.count)
        var counts = [Int](repeating: 0, count: centers.count)
        for it in 0..<iterations {
            var changed = false
            for i in pts.indices {
                var best = 0, bd = Double.infinity
                for (j, c) in centers.enumerated() {
                    let dl = pts[i].L - c.L, da = pts[i].a - c.a, db = pts[i].b - c.b
                    let d = dl * dl + da * da + db * db
                    if d < bd { bd = d; best = j }
                }
                if assign[i] != best { assign[i] = best; changed = true }
            }
            var sum = [(Double, Double, Double)](repeating: (0, 0, 0), count: centers.count)
            counts = [Int](repeating: 0, count: centers.count)
            for i in pts.indices {
                let j = assign[i]
                sum[j].0 += pts[i].L; sum[j].1 += pts[i].a; sum[j].2 += pts[i].b; counts[j] += 1
            }
            for j in centers.indices where counts[j] > 0 {
                let n = Double(counts[j])
                centers[j] = Oklab(L: sum[j].0 / n, a: sum[j].1 / n, b: sum[j].2 / n)
            }
            if !changed && it > 0 { break }
        }
        let n = Double(pts.count)
        var out: [(Oklab, Double)] = []
        for j in centers.indices where counts[j] > 0 { out.append((centers[j], Double(counts[j]) / n)) }
        out.sort { $0.0.L < $1.0.L }
        return out.map { PaletteEntry(color: $0.0.rgba, weight: $0.1) }
    }

    static func palette(_ buf: PixelBuffer, mask: PixelBuffer? = nil, count: Int) -> [PaletteEntry] {
        kMeans(samples(buf, mask: mask), k: clamp(count, 1, 32))
    }

    /// Gradient through the palette (dark → light) with stops spread by lightness rank.
    static func gradient(_ colors: [RGBA], name: String = "Palette") -> ColorGradient {
        let sorted = colors.sorted { Oklab($0).L < Oklab($1).L }
        guard sorted.count > 1 else { return .twoColor(sorted.first ?? .black, sorted.first ?? .white, name: name) }
        return ColorGradient(name: name, stops: sorted.enumerated().map { GradientStop(location: Double($0.offset) / Double(sorted.count - 1), color: $0.element.withAlpha(1)) })
    }
}

// MARK: - WCAG contrast

enum WCAG {
    /// Relative luminance (WCAG 2.x definition, sRGB).
    static func luminance(_ c: RGBA) -> Double {
        func f(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(clamp(c.r, 0, 1)) + 0.7152 * f(clamp(c.g, 0, 1)) + 0.0722 * f(clamp(c.b, 0, 1))
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    enum Level: String { case fail = "Fail", aaLarge = "AA Large", aa = "AA", aaa = "AAA" }

    /// Badge for a ratio. Large text (≥ 24 px, or ≥ 18.66 px bold) has lower thresholds.
    static func level(_ ratio: Double, largeText: Bool) -> Level {
        // compare on the two-decimal value people read, without rounding a 4.48 up to a pass
        let r = (ratio * 100).rounded(.down) / 100
        if r >= (largeText ? 4.5 : 7) { return .aaa }
        if r >= (largeText ? 3 : 4.5) { return .aa }
        if !largeText && r >= 3 { return .aaLarge }
        return .fail
    }

    static func isLarge(fontSize: Double, bold: Bool) -> Bool { fontSize >= 24 || (bold && fontSize >= 18.66) }

    /// The colour closest to `text` (same hue and chroma where the gamut allows, lightness moved as little as possible)
    /// whose contrast against every colour in `backgrounds` is at least `target`. nil when no lightness passes.
    static func nearestPassing(_ text: RGBA, on backgrounds: [RGBA], target: Double) -> RGBA? {
        guard !backgrounds.isEmpty else { return text }
        func worst(_ c: RGBA) -> Double { backgrounds.map { contrast(c, $0) }.min() ?? 0 }
        if worst(text) >= target { return text }
        let base = Oklab(text)
        func at(_ L: Double) -> RGBA { Oklab(L: L, a: base.a, b: base.b).rgba }
        var best: (RGBA, Double)?
        // scan both directions for the first lightness that passes, then refine by bisection
        for dir in [-1.0, 1.0] {
            var prev = base.L
            var step = 1
            while step <= 200 {
                let L = base.L + dir * Double(step) / 200
                if L < 0 || L > 1 { break }
                if worst(at(L)) >= target {
                    var lo = prev, hi = L
                    for _ in 0..<16 {
                        let mid = (lo + hi) / 2
                        if worst(at(mid)) >= target { hi = mid } else { lo = mid }
                    }
                    let d = abs(hi - base.L)
                    if best == nil || d < best!.1 { best = (at(hi), d) }
                    break
                }
                prev = L
                step += 1
            }
        }
        if let b = best { return b.0 }
        // fall back to pure black / white when chroma gets in the way
        for c in [RGBA.black, RGBA.white] where worst(c) >= target { return c }
        return nil
    }
}

// MARK: - Colour-vision-deficiency simulation

enum VisionSimulation: String, CaseIterable, Identifiable, Codable {
    case none, protanopia, deuteranopia, tritanopia, achromatopsia, lowContrast, blur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Off"
        case .protanopia: return "Protanopia"
        case .deuteranopia: return "Deuteranopia"
        case .tritanopia: return "Tritanopia"
        case .achromatopsia: return "Achromatopsia"
        case .lowContrast: return "Low Contrast"
        case .blur: return "Blur (Squint Test)"
        }
    }

    /// 3×3 matrix applied to linear RGB (Machado, Oliveira & Fernandes 2009, severity 1.0; Rec. 709 luma for achromatopsia).
    var matrix: [Double]? {
        switch self {
        case .protanopia: return [0.152286, 1.052583, -0.204868, 0.114503, 0.786281, 0.099216, -0.003882, -0.048116, 1.051998]
        case .deuteranopia: return [0.367322, 0.860646, -0.227968, 0.280085, 0.672501, 0.047413, -0.011820, 0.042940, 0.968881]
        case .tritanopia: return [1.255528, -0.076749, -0.178779, -0.078411, 0.930809, 0.147602, 0.004733, 0.691367, 0.303900]
        case .achromatopsia: return [0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722, 0.2126, 0.7152, 0.0722]
        default: return nil
        }
    }

    /// Low contrast: tones are compressed towards mid grey (scale, bias) in gamma space.
    static let lowContrastScale = 0.45

    /// CPU reference of the simulation for one sRGB colour (blur has no per-colour effect).
    func simulate(_ c: RGBA) -> RGBA {
        if self == .lowContrast {
            let k = VisionSimulation.lowContrastScale, b = (1 - k) / 2
            return RGBA(r: c.r * k + b, g: c.g * k + b, b: c.b * k + b, a: c.a)
        }
        guard let m = matrix else { return c }
        let r = Oklab.lin(c.r), g = Oklab.lin(c.g), b = Oklab.lin(c.b)
        func row(_ i: Int) -> Double { Oklab.gam(clamp(m[i * 3] * r + m[i * 3 + 1] * g + m[i * 3 + 2] * b, 0, 1)) }
        return RGBA(r: row(0), g: row(1), b: row(2), a: c.a)
    }

    /// Core Image version for the canvas view pipeline (working space is gamma sRGB, so the matrix is wrapped in
    /// linearise / delinearise steps). `longSide` sizes the squint blur.
    func apply(_ img: CIImage, extent: CGRect) -> CIImage {
        switch self {
        case .none: return img
        case .lowContrast:
            let k = CGFloat(VisionSimulation.lowContrastScale), b = (1 - k) / 2
            return img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0), "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0)]).cropped(to: extent)
        case .blur:
            let sigma = max(2, max(extent.width, extent.height) / 110)
            return img.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        default:
            guard let m = matrix else { return img }
            func v(_ i: Int) -> CIVector { CIVector(x: CGFloat(m[i * 3]), y: CGFloat(m[i * 3 + 1]), z: CGFloat(m[i * 3 + 2]), w: 0) }
            return img.applyingFilter("CISRGBToneCurveToLinear")
                .applyingFilter("CIColorMatrix", parameters: ["inputRVector": v(0), "inputGVector": v(1), "inputBVector": v(2)])
                .applyingFilter("CIColorClamp", parameters: ["inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0), "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])
                .applyingFilter("CILinearToSRGBToneCurve").cropped(to: extent)
        }
    }
}
