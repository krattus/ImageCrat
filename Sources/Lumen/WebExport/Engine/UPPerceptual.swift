import Foundation
import Accelerate
import CoreGraphics
import Vision

// Lumen Ultra PNG — perceptual tools: Oklab, the alpha-aware colour feature space, SSIM / ΔE quality metrics,
// and the importance + masking maps that tell the lossy encoder where error is invisible.

enum UPOklab {
    /// sRGB byte → linear light.
    static let linear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// Viewing flare added to linear light. Plain Oklab has an infinitely steep cube root at black (sRGB 0 → 1 would
    /// count as ΔE 6.7); a 0.4 % flare makes near-black differences as small as they really look.
    static let flare: Float = 0.004

    /// Oklab × 100 (L 0…100), with viewing flare.
    @inline(__always)
    static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD3<Float> {
        let k = 1 / (1 + flare)
        let R = (linear[Int(r)] + flare) * k, G = (linear[Int(g)] + flare) * k, B = (linear[Int(b)] + flare) * k
        let l = cbrtf(0.4122214708 * R + 0.5363325363 * G + 0.0514459929 * B)
        let m = cbrtf(0.2119034982 * R + 0.6806995451 * G + 0.1073969566 * B)
        let s = cbrtf(0.0883024619 * R + 0.2817188376 * G + 0.6299787005 * B)
        return SIMD3(21.04542553 * l + 79.36177850 * m - 0.40720468 * s,
                     197.79984951 * l - 242.85922050 * m + 45.05937099 * s,
                     2.59040371 * l + 78.27717662 * m - 80.86757660 * s)
    }

    static func rgb(fromLab c: SIMD3<Float>) -> (UInt8, UInt8, UInt8) {
        let L = c.x / 100, a = c.y / 100, b = c.z / 100
        let l_ = L + 0.3963377774 * a + 0.2158037573 * b
        let m_ = L - 0.1055613458 * a - 0.0638541728 * b
        let s_ = L - 0.0894841775 * a - 1.2914855480 * b
        let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
        func enc(_ v0: Float) -> UInt8 {
            let c = max(0, min(1, v0 * (1 + flare) - flare))
            let e = c <= 0.0031308 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
            return UInt8(max(0, min(255, (e * 255).rounded())))
        }
        return (enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// L of black (≠ 0 because of the flare) and white; the alpha-aware feature is built relative to them.
    static let blackL: Float = lab(0, 0, 0).x
    static let whiteL: Float = lab(255, 255, 255).x

    static let invSqrt2: Float = 0.70710678

    /// Alpha-aware colour feature: Euclidean distance here is the RMS of the Oklab differences the pixel shows
    /// when composited over black and over white. For opaque pixels it is exactly Oklab ΔE × 100.
    @inline(__always)
    static func feature(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> SIMD4<Float> {
        let k0 = blackL, k1 = whiteL
        if a == 0 { return SIMD4(k0 * invSqrt2, k1 * invSqrt2, 0, 0) }
        let c = lab(r, g, b)
        if a == 255 { return SIMD4(c.x * invSqrt2, c.x * invSqrt2, c.y, c.z) }
        let al = Float(a) / 255
        return SIMD4((al * c.x + (1 - al) * k0) * invSqrt2, (al * c.x + (1 - al) * k1) * invSqrt2, al * c.y, al * c.z)
    }

    static func rgba(fromFeature f: SIMD4<Float>) -> (UInt8, UInt8, UInt8, UInt8) {
        let u = f.x / invSqrt2, v = f.y / invSqrt2
        let al = max(0, min(1, 1 - (v - u) / (whiteL - blackL)))
        if al < 0.5 / 255 { return (0, 0, 0, 0) }
        let c = rgb(fromLab: SIMD3((u - (1 - al) * blackL) / al, f.z / al, f.w / al))
        return (c.0, c.1, c.2, UInt8(max(1, min(255, (al * 255).rounded()))))
    }
}

/// Small float-image helpers on top of vImage.
enum UPFloatImage {
    static func gaussianKernel(sigma: Float) -> [Float] {
        let r = max(1, Int((sigma * 3).rounded(.up)))
        var k = [Float](repeating: 0, count: 2 * r + 1)
        var sum: Float = 0
        for i in -r...r { let v = expf(-Float(i * i) / (2 * sigma * sigma)); k[i + r] = v; sum += v }
        for i in 0..<k.count { k[i] /= sum }
        return k
    }

    static func blur(_ src: [Float], _ w: Int, _ h: Int, kernel k: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        guard w > 0, h > 0 else { return out }
        var input = src
        input.withUnsafeMutableBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                var sb = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var db = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                k.withUnsafeBufferPointer { kp in
                    _ = vImageSepConvolve_PlanarF(&sb, &db, nil, 0, 0, kp.baseAddress!, UInt32(k.count), kp.baseAddress!, UInt32(k.count), 0, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        return out
    }

    static func blur(_ src: [Float], _ w: Int, _ h: Int, sigma: Float) -> [Float] { blur(src, w, h, kernel: gaussianKernel(sigma: sigma)) }

    /// Bilinear resample of a small map to `w × h`.
    static func resize(_ src: [Float], _ sw: Int, _ sh: Int, to w: Int, _ h: Int) -> [Float] {
        var out = [Float](repeating: 0, count: w * h)
        guard sw > 0, sh > 0 else { return out }
        for y in 0..<h {
            let fy = (Float(y) + 0.5) * Float(sh) / Float(h) - 0.5
            let y0 = max(0, min(sh - 1, Int(floorf(fy)))), y1 = min(sh - 1, y0 + 1)
            let ty = max(0, min(1, fy - Float(y0)))
            for x in 0..<w {
                let fx = (Float(x) + 0.5) * Float(sw) / Float(w) - 0.5
                let x0 = max(0, min(sw - 1, Int(floorf(fx)))), x1 = min(sw - 1, x0 + 1)
                let tx = max(0, min(1, fx - Float(x0)))
                let a = src[y0 * sw + x0] * (1 - tx) + src[y0 * sw + x1] * tx
                let b = src[y1 * sw + x0] * (1 - tx) + src[y1 * sw + x1] * tx
                out[y * w + x] = a * (1 - ty) + b * ty
            }
        }
        return out
    }

    /// 3×3 minimum (erosion).
    static func erode(_ src: [Float], _ w: Int, _ h: Int) -> [Float] {
        var tmp = src, out = src
        for y in 0..<h { for x in 0..<w { tmp[y * w + x] = min(src[y * w + max(0, x - 1)], src[y * w + x], src[y * w + min(w - 1, x + 1)]) } }
        for y in 0..<h { for x in 0..<w { out[y * w + x] = min(tmp[max(0, y - 1) * w + x], tmp[y * w + x], tmp[min(h - 1, y + 1) * w + x]) } }
        return out
    }
}

// MARK: - Quality metrics

struct UPQuality {
    /// Standard SSIM on luma (11×11 Gaussian window), mean over the image. Alpha images: worst of black / white backgrounds.
    var ssim = 1.0
    /// Importance-weighted SSIM after a viewing-distance prefilter (dither noise averages out, banding does not).
    var q = 1.0
    /// Largest single-pixel Oklab ΔE × 100.
    var maxDE = 0.0
    /// ΔE after smoothing both images (σ = 1.5 px), 99.8th percentile: low-frequency error such as colour shifts or posterisation.
    var smoothDE = 0.0
    var meanDE = 0.0
    var psnr = 99.0
    /// False-contour strength in smooth areas ≈ height (ΔE × 100) of the steps the encoding introduced (99.5th percentile).
    var banding = 0.0
    /// 95th-percentile ΔE of the pixels that sit on strong edges (anti-aliasing, text, outlines): jagged or fringed edges show up here.
    var edgeDE = 0.0

    /// Both the plain and the perceptual score are at least as good as `o`'s (used for equal-quality comparisons).
    func atLeast(_ o: UPQuality, slack: Double = 0) -> Bool {
        ssim >= o.ssim - slack && q >= o.q - slack && smoothDE <= o.smoothDE * 1.05 + 0.05 && banding <= o.banding * 1.05 + 0.05 && edgeDE <= o.edgeDE * 1.05 + 0.05
    }
}

struct UPQualityTarget: Equatable {
    var q: Double              // minimum importance-weighted perceptual SSIM
    var ssim: Double = 0       // minimum plain SSIM (0 = don't care)
    var smoothDE: Double       // maximum smoothed ΔE (colour-shift / posterisation guard)
    var banding: Double        // maximum false-contour step in smooth areas
    var edgeDE: Double         // maximum edge error (anti-aliasing / text fidelity)
    var label: String = ""

    // smoothDE limits sit above the ≈1.6 colour-rounding floor of 8-bit 4:2:0 codecs (AVIF / HEIC), which is not a visible error
    static let visuallyLossless = UPQualityTarget(q: 0.998, smoothDE: 1.2, banding: 0.35, edgeDE: 1.5, label: "visually lossless")
    static let high = UPQualityTarget(q: 0.995, smoothDE: 2.0, banding: 0.7, edgeDE: 2.6, label: "high")
    static let medium = UPQualityTarget(q: 0.990, smoothDE: 3.0, banding: 1.2, edgeDE: 4.0, label: "medium")
    static let small = UPQualityTarget(q: 0.980, smoothDE: 4.5, banding: 2.0, edgeDE: 6.0, label: "small")
    static let presets: [UPQualityTarget] = [.visuallyLossless, .high, .medium, .small]

    func met(by m: UPQuality) -> Bool { m.q >= q && m.ssim >= ssim && m.smoothDE <= smoothDE && m.banding <= banding && m.edgeDE <= edgeDE }
}

/// Reference-side data for repeated comparisons against one original.
final class UPMetricReference {
    let w: Int, h: Int
    let hasAlpha: Bool
    private struct Side {
        var luma: [Float]          // 0…255
        var mu: [Float], sigma2: [Float]
        var lumaPF: [Float], muPF: [Float], sigma2PF: [Float]
        var lab: [SIMD3<Float>]
        var labSmooth: [[Float]]
        var grad: [Float]          // gradient magnitude of the smoothed Oklab image
        var smoothIdx: [Int32]     // pixels in smooth areas (where false contours would show)
        var edgeIdx: [Int32]       // pixels on strong edges
    }
    private var sides: [Side] = []
    private let weights: [Float]
    private let weightSum: Double
    private static let k11 = UPFloatImage.gaussianKernel(sigma: 1.5)       // 11 taps
    private static let kPF = UPFloatImage.gaussianKernel(sigma: 1.0)
    private let backgrounds: [Float]

    /// `importance` (0…1 per pixel) weights the perceptual score; nil = uniform.
    init(_ img: UPImage, importance: [Float]? = nil) {
        w = img.width; h = img.height
        hasAlpha = img.hasAlpha
        backgrounds = hasAlpha ? [0, 255] : [0]
        let n = w * h
        if let imp = importance, imp.count == n {
            weights = imp.map { 0.25 + 0.75 * $0 }
        } else { weights = [Float](repeating: 1, count: n) }
        var s = 0.0
        for v in weights { s += Double(v) }
        weightSum = max(1e-9, s)
        for bg in backgrounds { sides.append(UPMetricReference.side(img, bg, w, h)) }
    }

    private static func composite(_ img: UPImage, _ bg: Float, _ w: Int, _ h: Int) -> (luma: [Float], lab: [SIMD3<Float>]) {
        let n = w * h
        var luma = [Float](repeating: 0, count: n)
        var lab = [SIMD3<Float>](repeating: .zero, count: n)
        img.px.withUnsafeBufferPointer { p in
            luma.withUnsafeMutableBufferPointer { lp in
                lab.withUnsafeMutableBufferPointer { bp in
                    DispatchQueue.concurrentPerform(iterations: h) { y in
                        for x in 0..<w {
                            let i = y * w + x, o = i * 4
                            var r = p[o], g = p[o + 1], b = p[o + 2]
                            let a = p[o + 3]
                            if a != 255 {
                                let al = Float(a) / 255
                                r = UInt8((Float(r) * al + bg * (1 - al)).rounded())
                                g = UInt8((Float(g) * al + bg * (1 - al)).rounded())
                                b = UInt8((Float(b) * al + bg * (1 - al)).rounded())
                            }
                            lp[i] = 0.299 * Float(r) + 0.587 * Float(g) + 0.114 * Float(b)
                            bp[i] = UPOklab.lab(r, g, b)
                        }
                    }
                }
            }
        }
        return (luma, lab)
    }

    private static func side(_ img: UPImage, _ bg: Float, _ w: Int, _ h: Int) -> Side {
        let (luma, lab) = composite(img, bg, w, h)
        let mu = UPFloatImage.blur(luma, w, h, kernel: k11)
        var sq = luma
        vDSP.multiply(luma, luma, result: &sq)
        var s2 = UPFloatImage.blur(sq, w, h, kernel: k11)
        for i in 0..<s2.count { s2[i] -= mu[i] * mu[i] }
        let pf = UPFloatImage.blur(luma, w, h, kernel: kPF)
        let muPF = UPFloatImage.blur(pf, w, h, kernel: k11)
        vDSP.multiply(pf, pf, result: &sq)
        var s2PF = UPFloatImage.blur(sq, w, h, kernel: k11)
        for i in 0..<s2PF.count { s2PF[i] -= muPF[i] * muPF[i] }
        var ch = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: 3)
        for i in 0..<(w * h) { ch[0][i] = lab[i].x; ch[1][i] = lab[i].y; ch[2][i] = lab[i].z }
        let smooth = ch.map { UPFloatImage.blur($0, w, h, kernel: k11) }
        let grad = gradientMagnitude(smooth, w, h)
        // smooth = low local variance around the pixel and a gentle gradient
        var idx: [Int32] = []
        let s2max = UPFloatImage.blur(s2, w, h, sigma: 2)
        for i in 0..<(w * h) where s2max[i] < 12 && grad[i] < 0.9 { idx.append(Int32(i)) }
        // strong edges: a large step between neighbouring pixels of the unsmoothed image
        var eidx: [Int32] = []
        if w >= 3 && h >= 3 {
            let g0 = gradientMagnitude(ch, w, h)
            for i in 0..<(w * h) where g0[i] > 5 { eidx.append(Int32(i)) }
        }
        return Side(luma: luma, mu: mu, sigma2: s2, lumaPF: pf, muPF: muPF, sigma2PF: s2PF, lab: lab, labSmooth: smooth, grad: grad, smoothIdx: idx, edgeIdx: eidx)
    }

    /// |∇| of a 3-channel image (central differences).
    private static func gradientMagnitude(_ c: [[Float]], _ w: Int, _ h: Int) -> [Float] {
        var g = [Float](repeating: 0, count: w * h)
        guard w >= 3, h >= 3 else { return g }
        g.withUnsafeMutableBufferPointer { gp in
            for k in 0..<3 {
                c[k].withUnsafeBufferPointer { p in
                    for y in 1..<(h - 1) {
                        for x in 1..<(w - 1) {
                            let i = y * w + x
                            let dx = (p[i + 1] - p[i - 1]) * 0.5, dy = (p[i + w] - p[i - w]) * 0.5
                            gp[i] += dx * dx + dy * dy
                        }
                    }
                }
            }
            for i in 0..<(w * h) { gp[i] = gp[i].squareRoot() }
        }
        return g
    }

    /// Per-pixel SSIM of `y` against reference statistics.
    private func ssimMap(_ x: [Float], _ mx: [Float], _ vx: [Float], _ y: [Float]) -> [Float] {
        let n = w * h
        let my = UPFloatImage.blur(y, w, h, kernel: UPMetricReference.k11)
        var t = y
        vDSP.multiply(y, y, result: &t)
        let yy = UPFloatImage.blur(t, w, h, kernel: UPMetricReference.k11)
        vDSP.multiply(x, y, result: &t)
        let xy = UPFloatImage.blur(t, w, h, kernel: UPMetricReference.k11)
        var out = [Float](repeating: 0, count: n)
        let c1: Float = 6.5025, c2: Float = 58.5225
        for i in 0..<n {
            let vy = yy[i] - my[i] * my[i], cxy = xy[i] - mx[i] * my[i]
            out[i] = ((2 * mx[i] * my[i] + c1) * (2 * cxy + c2)) / ((mx[i] * mx[i] + my[i] * my[i] + c1) * (vx[i] + vy + c2))
        }
        return out
    }

    /// Full comparison. `errorMap` (when requested) receives the per-pixel ΔE × 100 of the worst background.
    func compare(_ test: UPImage, errorMap: UnsafeMutablePointer<[Float]>? = nil) -> UPQuality {
        var q = UPQuality()
        guard test.width == w, test.height == h else { q.ssim = 0; q.q = 0; q.maxDE = 999; q.smoothDE = 999; return q }
        let n = w * h
        var worstSSIM = 1.0, worstQ = 1.0, mse = 0.0
        var emap: [Float]? = errorMap != nil ? [Float](repeating: 0, count: n) : nil
        for (si, bg) in backgrounds.enumerated() {
            let s = sides[si]
            let (luma, lab) = UPMetricReference.composite(test, bg, w, h)
            let map = ssimMap(s.luma, s.mu, s.sigma2, luma)
            var sum = 0.0
            for v in map { sum += Double(v) }
            worstSSIM = min(worstSSIM, sum / Double(n))
            let pf = UPFloatImage.blur(luma, w, h, kernel: UPMetricReference.kPF)
            let mapPF = ssimMap(s.lumaPF, s.muPF, s.sigma2PF, pf)
            var ws = 0.0
            for i in 0..<n { ws += Double(mapPF[i] * weights[i]) }
            worstQ = min(worstQ, ws / weightSum)
            // ΔE: per pixel and smoothed
            var maxDE: Float = 0
            var sumDE = 0.0
            var ch = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
            var perPixel = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let d = lab[i] - s.lab[i]
                let e = (d * d).sum().squareRoot()
                perPixel[i] = e
                if e > maxDE { maxDE = e }
                sumDE += Double(e)
                ch[0][i] = lab[i].x; ch[1][i] = lab[i].y; ch[2][i] = lab[i].z
                if emap != nil, e > emap![i] { emap![i] = e }
                let dl = Double(luma[i] - s.luma[i])
                mse += dl * dl
            }
            if s.edgeIdx.count >= 24 {
                var eh = [Int32](repeating: 0, count: 1025)
                for i in s.edgeIdx { eh[min(1024, Int(perPixel[Int(i)] * 16))] += 1 }
                var left = max(1, s.edgeIdx.count / 20)
                var bin = 1024
                while bin > 0 { left -= Int(eh[bin]); if left <= 0 { break }; bin -= 1 }
                q.edgeDE = max(q.edgeDE, bin == 0 ? 0 : (Double(bin) + 0.5) / 16)
            }
            // 99.8th percentile (histogram in 1/32 ΔE steps): a region has to be affected, not one stray pixel
            var smoothMax: Float = 0
            let sm = ch.map { UPFloatImage.blur($0, w, h, kernel: UPMetricReference.k11) }
            var hist = [Int32](repeating: 0, count: 2049)
            for i in 0..<n {
                let a = sm[0][i] - s.labSmooth[0][i], b = sm[1][i] - s.labSmooth[1][i], c = sm[2][i] - s.labSmooth[2][i]
                let e = (a * a + b * b + c * c).squareRoot()
                hist[min(2048, Int(e * 32))] += 1
            }
            var left = max(1, n / 500)
            var bin = 2048
            while bin > 0 { left -= Int(hist[bin]); if left <= 0 { break }; bin -= 1 }
            smoothMax = bin == 0 ? 0 : (Float(bin) + 0.5) / 32
            // false contours: extra gradient in areas that were smooth, scaled to the height of the step that causes it
            if s.smoothIdx.count > max(64, n / 200) {
                let g = UPMetricReference.gradientMagnitude(sm, w, h)
                var extra = [Float](repeating: 0, count: s.smoothIdx.count)
                for (j, i) in s.smoothIdx.enumerated() { extra[j] = max(0, g[Int(i)] - s.grad[Int(i)]) }
                extra.sort()
                let p = extra[min(extra.count - 1, Int(Double(extra.count) * 0.995))]
                q.banding = max(q.banding, Double(p) * 3.76)
            }
            q.maxDE = max(q.maxDE, Double(maxDE))
            q.smoothDE = max(q.smoothDE, Double(smoothMax))
            q.meanDE = max(q.meanDE, sumDE / Double(n))
        }
        q.ssim = worstSSIM; q.q = worstQ
        mse /= Double(n * backgrounds.count)
        q.psnr = mse <= 1e-9 ? 99 : 10 * log10(255 * 255 / mse)
        if let e = emap { errorMap?.pointee = e }
        return q
    }
}

// MARK: - Importance and masking maps

struct UPPerceptualMaps {
    var width: Int
    var height: Int
    /// 0…1: how much a viewer cares about the pixel (saliency, faces, text, user-protected regions).
    var importance: [Float]
    /// Local texture activity (Oklab L std-dev of the *least* active neighbourhood around the pixel): error hides here.
    var texture: [Float]
    /// Edge strength next to smooth areas: error is conspicuous here.
    var edge: [Float]
    /// 1 where the user (or a face / text detector) asked for maximum protection.
    var protect: [Float]
    /// Pixels the user marked with the Protect tools: the lossy encoders must reproduce them exactly.
    var pristine: [Int32] = []
    var notes: [String] = []
}

struct UPImportanceOptions {
    var useVision = true
    var detectFaces = true
    var detectText = true
    /// User "Protect" mask, 0…1 per pixel (nil = none).
    var protectMask: [Float]? = nil
}

enum UPImportance {
    static func maps(_ img: UPImage, options o: UPImportanceOptions = UPImportanceOptions()) -> UPPerceptualMaps {
        let w = img.width, h = img.height, n = w * h
        var notes: [String] = []
        // --- luma in Oklab L for the masking model
        var L = [Float](repeating: 0, count: n)
        img.px.withUnsafeBufferPointer { p in
            L.withUnsafeMutableBufferPointer { lp in
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    for x in 0..<w {
                        let i = (y * w + x) * 4
                        let a = Float(p[i + 3]) / 255
                        lp[y * w + x] = UPOklab.lab(p[i], p[i + 1], p[i + 2]).x * a + 50 * (1 - a)   // transparent → mid gray
                    }
                }
            }
        }
        // local standard deviation in a ~5×5 window
        let k = UPFloatImage.gaussianKernel(sigma: 1.2)
        let mu = UPFloatImage.blur(L, w, h, kernel: k)
        var sq = L
        vDSP.multiply(L, L, result: &sq)
        var act = UPFloatImage.blur(sq, w, h, kernel: k)
        for i in 0..<n { act[i] = max(0, act[i] - mu[i] * mu[i]).squareRoot() }
        // texture = activity that persists all around the pixel (two erosions ≈ 5×5 minimum), then smoothed
        var tex = UPFloatImage.erode(UPFloatImage.erode(act, w, h), w, h)
        tex = UPFloatImage.blur(tex, w, h, sigma: 1.5)
        var edge = [Float](repeating: 0, count: n)
        for i in 0..<n { edge[i] = max(0, act[i] - tex[i]) }
        // --- saliency
        var sal = [Float](repeating: 0.5, count: n)
        var protect = [Float](repeating: 0, count: n)
        var gotVision = false
        if o.useVision, w >= 32, h >= 32, let cg = UPBridge.cgImage(img, space: UPBridge.srgb) {
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            let att = VNGenerateAttentionBasedSaliencyImageRequest()
            let obj = VNGenerateObjectnessBasedSaliencyImageRequest()
            var reqs: [VNRequest] = [att, obj]
            let faces = VNDetectFaceRectanglesRequest()
            let text = VNDetectTextRectanglesRequest()
            if o.detectFaces { reqs.append(faces) }
            if o.detectText { reqs.append(text) }
            do {
                try handler.perform(reqs)
                func heat(_ r: VNImageBasedRequest) -> [Float]? {
                    guard let ob = r.results?.first as? VNSaliencyImageObservation else { return nil }
                    let pb = ob.pixelBuffer
                    CVPixelBufferLockBaseAddress(pb, .readOnly)
                    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                    let sw = CVPixelBufferGetWidth(pb), sh = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
                    guard let base = CVPixelBufferGetBaseAddress(pb), CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent32Float else { return nil }
                    var small = [Float](repeating: 0, count: sw * sh)
                    for y in 0..<sh { for x in 0..<sw { small[y * sw + x] = base.load(fromByteOffset: y * rb + x * 4, as: Float.self) } }
                    return UPFloatImage.resize(small, sw, sh, to: w, h)
                }
                let a = heat(att), b = heat(obj)
                if a != nil || b != nil {
                    gotVision = true
                    for i in 0..<n { sal[i] = max(0, min(1, max(a?[i] ?? 0, 0.8 * (b?[i] ?? 0)))) }
                    // normalise so the most salient area reaches 1
                    let mx = sal.max() ?? 1
                    if mx > 0.05 { for i in 0..<n { sal[i] = min(1, sal[i] / mx) } }
                    notes.append("saliency: Vision attention" + (b != nil ? " + objectness" : ""))
                }
                func mark(_ box: CGRect, grow: CGFloat) {
                    // Vision boxes are normalised with a bottom-left origin
                    let r = CGRect(x: box.minX * CGFloat(w), y: (1 - box.maxY) * CGFloat(h), width: box.width * CGFloat(w), height: box.height * CGFloat(h))
                        .insetBy(dx: -box.width * CGFloat(w) * grow - 2, dy: -box.height * CGFloat(h) * grow - 2)
                    let x0 = max(0, Int(r.minX)), x1 = min(w, Int(r.maxX.rounded(.up))), y0 = max(0, Int(r.minY)), y1 = min(h, Int(r.maxY.rounded(.up)))
                    guard x1 > x0, y1 > y0 else { return }
                    for y in y0..<y1 { for x in x0..<x1 { protect[y * w + x] = 1 } }
                }
                if o.detectFaces, let fs = faces.results, !fs.isEmpty {
                    for f in fs { mark(f.boundingBox, grow: 0.12) }
                    notes.append("faces: \(fs.count)")
                }
                if o.detectText, let ts = text.results, !ts.isEmpty {
                    for t in ts { mark(t.boundingBox, grow: 0.04) }
                    notes.append("text regions: \(ts.count)")
                }
            } catch {
                notes.append("Vision unavailable (\(error.localizedDescription))")
            }
        }
        if !gotVision {
            // fallback: contrast-based saliency (local activity, heavily blurred) with a mild centre prior
            let blurred = UPFloatImage.blur(act, w, h, sigma: Float(max(4, min(w, h) / 24)))
            let mx = max(1e-3, blurred.max() ?? 1)
            for y in 0..<h {
                for x in 0..<w {
                    let dx = (Float(x) / Float(max(1, w - 1)) - 0.5) * 2, dy = (Float(y) / Float(max(1, h - 1)) - 0.5) * 2
                    sal[y * w + x] = min(1, 0.7 * blurred[y * w + x] / mx + 0.3 * max(0, 1 - 0.5 * (dx * dx + dy * dy)))
                }
            }
            if o.useVision { notes.append("saliency: contrast fallback") }
        }
        var pristine: [Int32] = []
        if let pm = o.protectMask, pm.count == n {
            for i in 0..<n where pm[i] > 0 { protect[i] = 1; pristine.append(Int32(i)) }
            notes.append("user-protected regions")
        }
        let prot = UPFloatImage.blur(protect, w, h, sigma: 1.5)
        var imp = [Float](repeating: 0, count: n)
        for i in 0..<n { imp[i] = max(min(1, protect[i] > 0 ? 1 : prot[i] * 2), sal[i]) }
        return UPPerceptualMaps(width: w, height: h, importance: imp, texture: tex, edge: edge, protect: protect, pristine: pristine, notes: notes)
    }

    /// Adds user-protected pixels (mask 0…1) to existing maps without running the detectors again.
    static func applying(protect mask: [Float]?, to base: UPPerceptualMaps) -> UPPerceptualMaps {
        guard let mask, mask.count == base.width * base.height, mask.contains(where: { $0 > 0 }) else { return base }
        var m = base
        let soft = UPFloatImage.blur(mask, m.width, m.height, sigma: 1.5)
        m.pristine = []
        for i in 0..<mask.count {
            if mask[i] > 0 { m.protect[i] = 1; m.importance[i] = 1; m.pristine.append(Int32(i)) } else { m.importance[i] = max(m.importance[i], min(1, soft[i] * 2)) }
        }
        if !m.notes.contains("user-protected regions") { m.notes.append("user-protected regions") }
        return m
    }

    /// Per-pixel error tolerance in ΔE × 100 for a base tolerance: grows in texture, shrinks with importance, 0 when protected.
    static func tolerance(_ m: UPPerceptualMaps, base: Float) -> [Float] {
        let n = m.width * m.height
        var t = [Float](repeating: 0, count: n)
        for i in 0..<n {
            if m.protect[i] >= 1 { t[i] = 0; continue }
            let masking = 1 + min(3, m.texture[i] / 2.5)             // texture of σ(L) ≈ 2.5 doubles the tolerance, capped ×4
            let care = 1.25 - 0.85 * m.importance[i]                 // 1.25 (ignored area) … 0.4 (most salient)
            t[i] = base * masking * care
        }
        return t
    }
}
