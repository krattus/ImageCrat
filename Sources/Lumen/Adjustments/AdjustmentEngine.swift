import Foundation
import CoreImage
import ImageCratCore

enum AdjustmentEngine {
    private static var cubeCache: [(AdjustmentSettings, Data)] = []
    private static var curveCache: [(AdjustmentSettings, Data)] = []
    private static let cubeSize = 33

    static func apply(_ s: AdjustmentSettings, to img: CIImage) -> CIImage {
        let ext = img.extent
        let out: CIImage
        switch s.kind {
        case .brightnessContrast, .levels, .curves:
            out = applyCurves(s, img)
        case .exposure:
            let e = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: s.exposure])
            out = applyCurves(s, e)
        case .vibrance:
            var v = img.applyingFilter("CIVibrance", parameters: ["inputAmount": s.vibrance / 100])
            if s.saturation != 0 {
                v = v.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + s.saturation / 100])
            }
            out = v
        case .channelMixer:
            func row(_ r: [Double]) -> CIVector { CIVector(x: CGFloat(r[0] / 100), y: CGFloat(r[1] / 100), z: CGFloat(r[2] / 100), w: 0) }
            let R = s.mixRed, G = s.monochrome ? s.mixRed : s.mixGreen, B = s.monochrome ? s.mixRed : s.mixBlue
            out = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": row(R), "inputGVector": row(G), "inputBVector": row(B),
                "inputBiasVector": CIVector(x: CGFloat(R[3] / 100), y: CGFloat(G[3] / 100), z: CGFloat(B[3] / 100), w: 0),
            ])
        case .invert:
            out = img.applyingFilter("CIColorInvert")
        case .posterize:
            out = img.applyingFilter("CIColorPosterize", parameters: ["inputLevels": max(2, s.posterizeLevels)])
        case .threshold:
            out = Kernels.thresholdKernel?.apply(extent: ext, arguments: [img, Float(s.thresholdLevel / 255)]) ?? img
        case .gradientMap:
            let lut = Kernels.gradientLUT(s.gradient, reverse: s.gradientReverse)
            let mapped = img.applyingFilter("CIColorMap", parameters: ["inputGradientImage": lut])
            out = mapped.masked(byAlphaOf: img)
        case .shadowsHighlights:
            out = img.clampedToExtent().applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputShadowAmount": s.shAmountShadows / 100, "inputHighlightAmount": 1 - s.shAmountHighlights / 100,
                kCIInputRadiusKey: s.shRadius / 10,
            ])
        case .desaturate:
            out = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        case .hueSaturation:
            out = applyHueSaturation(s, img) ?? applyCube(s, img)
        case .replaceColor:
            out = applyReplaceColor(s.replace, img)
        case .matchColor:
            out = applyMatchColor(s.match, img)
        case .hdrToning:
            out = applyHDRToning(s.hdr, img)
        case .colorWB, .clarity, .dehaze, .grain, .light:
            out = EditsAdjustments.apply(s, img)
        default:
            out = applyCube(s, img)
        }
        return out.cropped(to: ext)
    }

    // MARK: 1D curves (exact per-channel)

    private static func applyCurves(_ s: AdjustmentSettings, _ img: CIImage) -> CIImage {
        let data: Data
        if let c = curveCache.first(where: { $0.0 == s }) {
            data = c.1
        } else {
            let n = 256
            var floats = [Float](repeating: 0, count: n * 3)
            var masterLUT: [Double]? = nil
            var chLUT: [[Double]?] = [nil, nil, nil]
            if s.kind == .curves {
                masterLUT = s.curves[0].lut(n)
                for c in 0..<3 where !s.curves[c + 1].isIdentity { chLUT[c] = s.curves[c + 1].lut(n) }
            }
            for i in 0..<n {
                let v = Double(i) / Double(n - 1)
                for c in 0..<3 {
                    var x = v
                    switch s.kind {
                    case .brightnessContrast:
                        // Photoshop-like: brightness shifts midtones, contrast pivots around mid-gray.
                        let b = s.brightness / 150
                        if b >= 0 { x = pow(x, 1 / (1 + b * 1.2)) } else { x = pow(x, 1 - b * 1.2) }
                        let cf = s.contrast >= 0 ? 1 + s.contrast / 100 * 1.6 : 1 + s.contrast / 100
                        x = (x - 0.5) * cf + 0.5
                    case .levels:
                        x = s.levels[c + 1].apply(s.levels[0].apply(x))
                    case .curves:
                        let idx = Int((clamp(x, 0, 1) * Double(n - 1)).rounded())
                        x = masterLUT![idx]
                        if let l = chLUT[c] { x = l[Int((clamp(x, 0, 1) * Double(n - 1)).rounded())] }
                    case .exposure:
                        x = pow(clamp(x + s.offset, 0, 1), 1 / max(0.01, s.gamma))
                    default: break
                    }
                    floats[i * 3 + c] = Float(clamp(x, 0, 1))
                }
            }
            data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            curveCache.insert((s, data), at: 0)
            if curveCache.count > 24 { curveCache.removeLast() }
        }
        return img.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": data,
            "inputCurvesDomain": CIVector(x: 0, y: 1),
            "inputColorSpace": sRGBSpace,
        ])
    }

    // MARK: 3D LUT

    private static func applyCube(_ s: AdjustmentSettings, _ img: CIImage) -> CIImage {
        let data: Data
        if let c = cubeCache.first(where: { $0.0 == s }) {
            data = c.1
        } else {
            data = makeCube(size: cubeSize) { r, g, b in colorFunction(s, r, g, b) }
            cubeCache.insert((s, data), at: 0)
            if cubeCache.count > 16 { cubeCache.removeLast() }
        }
        return img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": cubeSize, "inputCubeData": data])
    }

    static func makeCube(size n: Int, _ f: (Double, Double, Double) -> (Double, Double, Double)) -> Data {
        var floats = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        let d = Double(n - 1)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let (r, g, b) = f(Double(ri) / d, Double(gi) / d, Double(bi) / d)
                    floats[i] = Float(clamp(r, 0, 1)); floats[i + 1] = Float(clamp(g, 0, 1)); floats[i + 2] = Float(clamp(b, 0, 1)); floats[i + 3] = 1
                    i += 4
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func lum(_ r: Double, _ g: Double, _ b: Double) -> Double { 0.299 * r + 0.587 * g + 0.114 * b }

    static func setLum(_ c: (Double, Double, Double), _ l: Double) -> (Double, Double, Double) {
        let d = l - lum(c.0, c.1, c.2)
        var r = c.0 + d, g = c.1 + d, b = c.2 + d
        let L = lum(r, g, b)
        let mn = min(r, g, b), mx = max(r, g, b)
        if mn < 0 { let k = L / max(1e-9, L - mn); r = L + (r - L) * k; g = L + (g - L) * k; b = L + (b - L) * k }
        if mx > 1 { let k = (1 - L) / max(1e-9, mx - L); r = L + (r - L) * k; g = L + (g - L) * k; b = L + (b - L) * k }
        return (r, g, b)
    }

    /// Hue-range weights for reds, yellows, greens, cyans, blues, magentas.
    static func hueWeights(_ h: Double) -> [Double] {
        (0..<6).map { i in
            let center = Double(i) / 6
            var d = abs(h - center)
            d = min(d, 1 - d)
            return max(0, 1 - d * 6)
        }
    }

    static func colorFunction(_ s: AdjustmentSettings, _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        switch s.kind {
        case .hueSaturation:
            let c = RGBA(r: r, g: g, b: b)
            var (h, sat, l) = c.hsl
            if s.colorize {
                h = (s.hue < 0 ? s.hue + 360 : s.hue) / 360
                sat = clamp((s.hsSaturation + 100) / 200 * 0.5 + 0.0, 0, 1)
                if s.hsSaturation == 0 { sat = 0.25 }
            } else {
                h += s.hue / 360
                let sv = s.hsSaturation / 100
                sat = sv >= 0 ? sat + (1 - sat) * sv * sat.squareRoot() : sat * (1 + sv)
            }
            let lv = s.lightness / 100
            l = lv >= 0 ? l + (1 - l) * lv : l * (1 + lv)
            let o = RGBA(h: h, s: clamp(sat, 0, 1), l: clamp(l, 0, 1))
            return (o.r, o.g, o.b)
        case .colorBalance:
            let L = lum(r, g, b)
            // tonal weights
            let shW = clamp(1 - L * 2.5, 0, 1)
            let hiW = clamp((L - 0.6) * 2.5, 0, 1)
            let midW = clamp(1 - abs(L - 0.5) * 2.2, 0, 1)
            func shift(_ t: ToneTriple, _ w: Double) -> (Double, Double, Double) {
                (t.cyanRed / 100 * w * 0.5, t.magentaGreen / 100 * w * 0.5, t.yellowBlue / 100 * w * 0.5)
            }
            let a = shift(s.shadows, shW), m = shift(s.midtones, midW), h = shift(s.highlights, hiW)
            var o = (r + a.0 + m.0 + h.0, g + a.1 + m.1 + h.1, b + a.2 + m.2 + h.2)
            if s.preserveLuminosity { o = setLum(o, L) }
            return o
        case .blackWhite:
            let c = RGBA(r: r, g: g, b: b)
            let (h, sat, _) = c.hsb
            let w = hueWeights(h)
            let weights = [s.bwReds, s.bwYellows, s.bwGreens, s.bwCyans, s.bwBlues, s.bwMagentas]
            var factor = 0.0, tw = 0.0
            for i in 0..<6 { factor += w[i] * weights[i] / 100; tw += w[i] }
            let f = tw > 0 ? factor / tw : 0.5
            let base = lum(r, g, b)
            var v = base + (f - 0.5) * sat * 1.2 * max(r, g, b)
            v = clamp(v, 0, 1)
            if s.bwTint {
                let t = s.bwTintColor
                let o = setLum((t.r, t.g, t.b), v)
                return (o.0 * 0.6 + v * 0.4, o.1 * 0.6 + v * 0.4, o.2 * 0.6 + v * 0.4)
            }
            return (v, v, v)
        case .photoFilter:
            let d = s.density / 100
            let fc = s.filterColor
            var o = (r * (1 - d) + r * fc.r * d * 2, g * (1 - d) + g * fc.g * d * 2, b * (1 - d) + b * fc.b * d * 2)
            if s.preserveLuminosity { o = setLum(o, lum(r, g, b)) }
            return o
        case .selectiveColor:
            let c = RGBA(r: r, g: g, b: b)
            let (h, sat, v) = c.hsb
            var w = hueWeights(h).map { $0 * sat }
            let L = lum(r, g, b)
            w.append(clamp((L - 0.75) * 4, 0, 1) * (1 - sat))          // whites
            w.append(clamp(1 - abs(L - 0.5) * 2.5, 0, 1) * (1 - sat * 0.5)) // neutrals
            w.append(clamp((0.25 - L) * 4, 0, 1))                      // blacks
            var (cc, mm, yy, kk) = c.cmyk
            _ = v
            for i in 0..<9 where w[i] > 0 {
                let e = s.selective[i]
                let wi = w[i]
                if s.selectiveAbsolute {
                    cc += e.cyan / 100 * wi; mm += e.magenta / 100 * wi; yy += e.yellow / 100 * wi; kk += e.black / 100 * wi
                } else {
                    cc += cc * e.cyan / 100 * wi; mm += mm * e.magenta / 100 * wi; yy += yy * e.yellow / 100 * wi; kk += kk * e.black / 100 * wi
                    if e.cyan > 0 && cc == 0 { cc += e.cyan / 100 * wi * 0.3 }
                }
            }
            cc = clamp(cc, 0, 1); mm = clamp(mm, 0, 1); yy = clamp(yy, 0, 1); kk = clamp(kk, 0, 1)
            return ((1 - cc) * (1 - kk), (1 - mm) * (1 - kk), (1 - yy) * (1 - kk))
        case .colorLookup:
            return look(s.lookName, r, g, b)
        default:
            return (r, g, b)
        }
    }

    static func look(_ name: String, _ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        func sCurve(_ x: Double, _ k: Double) -> Double { let t = x - 0.5; return 0.5 + t * (1 + k) - 4 * k * t * t * t }
        let L = lum(r, g, b)
        if name.hasPrefix(RecolorMap.lookPrefix) { return RecolorMap.look(name, r, g, b) }   // Recolour Artwork (Artist module)
        switch name {
        case "Warm Film":
            return (sCurve(r * 1.06 + 0.02, 0.2), sCurve(g * 1.0 + 0.01, 0.2), sCurve(b * 0.88, 0.2))
        case "Cool Teal":
            return (sCurve(r * 0.9, 0.15), sCurve(g * 1.02 + 0.02, 0.15), sCurve(b * 1.1 + 0.03, 0.15))
        case "Teal & Orange":
            let w = clamp((L - 0.35) * 2, 0, 1)
            let sh = (r * 0.85, g * 1.02 + 0.03, b * 1.15 + 0.05)
            let hi = (r * 1.12 + 0.03, g * 1.0, b * 0.82)
            return (sCurve(sh.0 * (1 - w) + hi.0 * w, 0.25), sCurve(sh.1 * (1 - w) + hi.1 * w, 0.25), sCurve(sh.2 * (1 - w) + hi.2 * w, 0.25))
        case "Faded":
            return (0.08 + r * 0.84, 0.08 + g * 0.82, 0.1 + b * 0.8)
        case "Bleach Bypass":
            let o = setLum((r * 0.5 + L * 0.5, g * 0.5 + L * 0.5, b * 0.5 + L * 0.5), sCurve(L, 0.45))
            return o
        case "Crisp Winter":
            return (sCurve(r * 0.95, 0.3), sCurve(g * 1.0 + 0.01, 0.3), sCurve(b * 1.08 + 0.04, 0.3))
        case "Golden Hour":
            return (sCurve(r * 1.1 + 0.05, 0.15), sCurve(g * 1.02 + 0.03, 0.15), sCurve(b * 0.8, 0.15))
        case "Moonlight":
            let o = setLum((L * 0.7, L * 0.85, L * 1.2), L * 0.85)
            return o
        case "Vintage":
            return (0.1 + sCurve(r, 0.1) * 0.85, 0.06 + sCurve(g, 0.1) * 0.8, 0.12 + sCurve(b, 0.1) * 0.65)
        case "Cross Process":
            return (sCurve(r, 0.5), sCurve(g * 1.05, 0.25), clamp(b * 0.7 + 0.15, 0, 1))
        default:
            return (r, g, b)
        }
    }
}
