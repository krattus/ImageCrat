import Foundation

// Lumen Ultra PNG — true-colour "Perceptual Ultra" path (for images that do not palettise well).
//
// Saliency-adaptive near-lossless coding aimed at PNG's own predictors: every sample may move by at most d(x)
// levels, where d(x) comes from the visibility tolerance map (0 on faces / text / protected pixels, larger inside
// texture). For each row and each PNG filter the encoder simulates the decoder: it predicts the sample from the
// already-written neighbours and replaces it by  prediction + q · round((original − prediction) / q),  q = 2d + 1.
// Residuals collapse onto a few multiples of q (mostly 0), which is exactly what the Huffman stage wants, and the
// error can never exceed d because each sample is bounded against the original, not against its neighbours.
// The row keeps the filter whose residuals are cheapest under the running residual statistics.

struct UPNearLossless {
    var image: UPImage
    /// Row filters the image was shaped for (hand these to the lossless encoder as a seed).
    var filters: [UInt8]
    /// Rough entropy estimate of the residual stream in bytes.
    var estimatedBytes: Int
}

enum UPLossyTrue {
    /// `tolerance`: per-pixel visibility tolerance in ΔE × 100 (0 = keep the pixel exactly).
    static func encode(_ source: UPImage, tolerance: [Float], progress: UPProgress? = nil) -> UPNearLossless {
        let img = UPReduce.canonical(source, keepHiddenRGB: false)
        let w = img.width, h = img.height
        let hasAlpha = img.hasAlpha
        let ch = hasAlpha ? 4 : 3
        let rb = w * ch
        // working copy in PNG layout
        var work = [UInt8](repeating: 0, count: rb * h)
        for i in 0..<(w * h) {
            work[i * ch] = img.px[i * 4]; work[i * ch + 1] = img.px[i * 4 + 1]; work[i * ch + 2] = img.px[i * 4 + 2]
            if hasAlpha { work[i * ch + 3] = img.px[i * 4 + 3] }
        }
        let orig = work
        // per-sample limits
        var dmax = [UInt8](repeating: 0, count: rb * h)
        for i in 0..<(w * h) {
            let a = hasAlpha ? Int(img.px[i * 4 + 3]) : 255
            var d = Int((tolerance[i] * 1.6).rounded(.down))
            d = max(0, min(24, d))
            if a == 0 { dmax[i * ch] = 255; dmax[i * ch + 1] = 255; dmax[i * ch + 2] = 255; dmax[i * ch + 3] = 0; continue }
            // colour under low alpha is proportionally less visible
            let dc = a == 255 ? d : min(48, d * 255 / max(48, a))
            dmax[i * ch] = UInt8(dc); dmax[i * ch + 1] = UInt8(dc); dmax[i * ch + 2] = UInt8(dc)
            // alpha: fully opaque stays opaque; soft edges get a small tolerance
            if hasAlpha { dmax[i * ch + 3] = a == 255 ? 0 : UInt8(min(d, 3)) }
        }
        var filters = [UInt8](repeating: 0, count: h)
        var counts = [Float](repeating: 0, count: 256)
        // Laplacian-like prior so the first rows already prefer small residuals
        for r in 0..<256 { let m = r < 128 ? r : 256 - r; counts[r] = 40 * powf(0.75, Float(m)) + 0.05 }
        var total: Float = counts.reduce(0, +)
        var cost = [Float](repeating: 0, count: 256)
        var cand = [UInt8](repeating: 0, count: 5 * rb)       // reconstructed row per filter
        var res = [UInt8](repeating: 0, count: 5 * rb)        // residuals per filter
        var bits = 0.0
        work.withUnsafeMutableBufferPointer { wp in
            orig.withUnsafeBufferPointer { op in
                dmax.withUnsafeBufferPointer { dp in
                    cand.withUnsafeMutableBufferPointer { cp in
                        res.withUnsafeMutableBufferPointer { rp in
                            for y in 0..<h {
                                if y & 31 == 0 {
                                    if progress?.cancelled == true { return }
                                    for r in 0..<256 { cost[r] = -log2f(counts[r] / total) }
                                }
                                let o = op.baseAddress! + y * rb
                                let dm = dp.baseAddress! + y * rb
                                let prev: UnsafeMutablePointer<UInt8>? = y > 0 ? wp.baseAddress! + (y - 1) * rb : nil
                                var bestF = 0
                                var bestCost = Float.greatestFiniteMagnitude
                                for f in 0..<5 {
                                    let out = cp.baseAddress! + f * rb
                                    let rr = rp.baseAddress! + f * rb
                                    var c: Float = cost[f]
                                    for i in 0..<rb {
                                        let a = i >= ch ? Int(out[i - ch]) : 0
                                        let b = prev != nil ? Int(prev![i]) : 0
                                        let cc = (i >= ch && prev != nil) ? Int(prev![i - ch]) : 0
                                        let pred: Int
                                        switch f {
                                        case 0: pred = 0
                                        case 1: pred = a
                                        case 2: pred = b
                                        case 3: pred = (a + b) >> 1
                                        default:
                                            let pa = abs(b - cc), pb = abs(a - cc), pc = abs(a + b - cc - cc)
                                            pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : cc)
                                        }
                                        let ov = Int(o[i])
                                        let d = Int(dm[i])
                                        var v = ov
                                        if d == 255 { v = pred } else if d > 0 {
                                            let q = 2 * d + 1
                                            let diff = ov - pred
                                            // nearest multiple of q (ties toward zero keeps residuals small)
                                            let k = diff >= 0 ? (diff + d) / q : -((-diff + d) / q)
                                            v = pred + k * q
                                            if v < 0 || v > 255 { v = min(255, max(0, v)); if abs(v - ov) > d { v = ov } }
                                        }
                                        out[i] = UInt8(v)
                                        let r = UInt8(truncatingIfNeeded: v - pred)
                                        rr[i] = r
                                        c += cost[Int(r)]
                                    }
                                    if c < bestCost { bestCost = c; bestF = f }
                                }
                                filters[y] = UInt8(bestF)
                                (wp.baseAddress! + y * rb).update(from: cp.baseAddress! + bestF * rb, count: rb)
                                let rr = rp.baseAddress! + bestF * rb
                                for i in 0..<rb { counts[Int(rr[i])] += 1 }
                                total += Float(rb)
                                bits += Double(bestCost)
                            }
                        }
                    }
                }
            }
        }
        var out = img
        for i in 0..<(w * h) {
            out.px[i * 4] = work[i * ch]; out.px[i * 4 + 1] = work[i * ch + 1]; out.px[i * 4 + 2] = work[i * ch + 2]
            if hasAlpha { out.px[i * 4 + 3] = work[i * ch + 3] }
        }
        // transparent pixels carry predictor colours in `work`; canonicalise for comparisons
        out = UPReduce.canonical(out, keepHiddenRGB: false)
        return UPNearLossless(image: out, filters: filters, estimatedBytes: Int(bits / 8))
    }
}
