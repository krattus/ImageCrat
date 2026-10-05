import Foundation

/// Shared conversions from imported images to brush-tip coverage (gray, 255 = full paint, 0 = none).
package enum BrushTipImaging {
    /// Largest tip side the importers produce.
    package static let maxTipSide = 8192

    /// Pads a tightly packed w×h gray coverage bitmap to a square with the content centred (transparent = 0 border).
    /// `side` forces a larger square (the common size of animated tip frames); it is never smaller than max(w, h).
    package static func squareGray(_ px: [UInt8], width w: Int, height h: Int, side: Int? = nil) -> PixelBuffer {
        let w = max(0, w), h = max(0, h)
        let s = max(1, max(side ?? 0, max(w, h)))
        let buf = PixelBuffer(width: s, height: s, format: .gray)
        let d = buf.data.assumingMemoryBound(to: UInt8.self)
        let ox = (s - w) / 2, oy = (s - h) / 2
        if px.count >= w * h {
            px.withUnsafeBufferPointer { src in
                for y in 0..<h {
                    guard let base = src.baseAddress else { break }
                    memcpy(d + (y + oy) * buf.bytesPerRow + ox, base + y * w, w)
                }
            }
        }
        buf.markDirty()
        return buf
    }

    /// Square-pads a .gray buffer (returned unchanged when it already is square).
    package static func squareGray(_ buf: PixelBuffer, side: Int? = nil) -> PixelBuffer {
        if buf.format == .gray, buf.width == buf.height, side == nil || side == buf.width { return buf }
        return squareGray(tightGray(buf), width: buf.width, height: buf.height, side: side)
    }

    /// The gray channel (or alpha of an RGBA buffer) as tightly packed bytes.
    package static func tightGray(_ buf: PixelBuffer) -> [UInt8] {
        let w = buf.width, h = buf.height
        var out = [UInt8](repeating: 0, count: w * h)
        let s = buf.data.assumingMemoryBound(to: UInt8.self)
        let bpp = buf.bytesPerPixel
        let off = buf.format == .gray ? 0 : 3
        for y in 0..<h {
            let row = s + y * buf.bytesPerRow
            for x in 0..<w { out[y * w + x] = row[x * bpp + off] }
        }
        return out
    }

    /// Brush coverage from an image (premultiplied RGBA; a .gray buffer counts as an opaque grayscale image).
    /// Returns a .gray buffer of the same size (not square-padded).
    ///
    /// The rule (what painters expect from "use this image as a brush"):
    /// * Image with meaningful transparency (at least 0.5% of pixels with alpha < 250):
    ///   - normally `coverage = alpha × (1 − luminance)`: dark marks on a transparent background paint, light parts
    ///     of the mark paint less (like Photoshop's Define Brush on a layer with transparency);
    ///   - but when the visible (alpha-weighted) pixels are predominantly light — mean luminance > 0.8, e.g. a white
    ///     shape on transparency — `coverage = alpha`, otherwise such a tip would paint nothing.
    /// * Fully opaque image:
    ///   - normally `coverage = 1 − luminance` (dark = paint, Photoshop "Define Brush Preset");
    ///   - but when the image is mostly dark (mean luminance < 0.35, light content on black, as Procreate / ABR-style
    ///     tips are drawn) `coverage = luminance`.
    /// Luminance is Rec. 601 (0.299 R + 0.587 G + 0.114 B) of the un-premultiplied colour.
    package static func grayCoverage(fromRGBA buf: PixelBuffer) -> PixelBuffer {
        let w = buf.width, h = buf.height
        let out = PixelBuffer(width: w, height: h, format: .gray)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        let s = buf.data.assumingMemoryBound(to: UInt8.self)
        if buf.format == .gray {
            var sum = 0
            for y in 0..<h { let r = s + y * buf.bytesPerRow; for x in 0..<w { sum += Int(r[x]) } }
            let mean = Double(sum) / Double(max(1, w * h)) / 255
            let keep = mean < 0.35
            for y in 0..<h {
                let r = s + y * buf.bytesPerRow, d = o + y * out.bytesPerRow
                for x in 0..<w { d[x] = keep ? r[x] : 255 - r[x] }
            }
            out.markDirty()
            return out
        }
        // Statistics: transparency and luminance (premultiplied luminance sums are alpha-weighted luminance sums).
        var translucent = 0
        var premulLumSum = 0, alphaSum = 0
        for y in 0..<h {
            let r = s + y * buf.bytesPerRow
            for x in 0..<w {
                let p = r + x * 4
                let a = Int(p[3])
                if a < 250 { translucent += 1 }
                premulLumSum += lum601(p)
                alphaSum += a
            }
        }
        let total = max(1, w * h)
        let hasAlpha = Double(translucent) / Double(total) >= 0.005
        let meanLum = alphaSum > 0 ? Double(premulLumSum) / Double(alphaSum) : 0
        enum Mode { case alpha, alphaTimesInvLum, invLum, lum }
        let mode: Mode = hasAlpha ? (meanLum > 0.8 ? .alpha : .alphaTimesInvLum) : (meanLum < 0.35 ? .lum : .invLum)
        for y in 0..<h {
            let r = s + y * buf.bytesPerRow, d = o + y * out.bytesPerRow
            for x in 0..<w {
                let p = r + x * 4
                let a = Int(p[3])
                let pl = min(a, lum601(p))   // premultiplied luminance ≤ alpha
                let v: Int
                switch mode {
                case .alpha: v = a
                case .alphaTimesInvLum: v = a - pl                // alpha × (1 − lum) == alpha − alpha × lum
                case .invLum: v = 255 - pl                        // opaque: pl == lum
                case .lum: v = pl
                }
                d[x] = UInt8(max(0, min(255, v)))
            }
        }
        out.markDirty()
        return out
    }

    /// Rec. 601 luma of an RGB(A) pixel, 0...255 (the weights sum to 256, so white maps to 255).
    @inline(__always) private static func lum601(_ p: UnsafeMutablePointer<UInt8>) -> Int {
        let r: Int = 77 * Int(p[0])
        let g: Int = 150 * Int(p[1])
        let b: Int = 29 * Int(p[2])
        return (r + g + b) >> 8
    }

    /// Coverage = luminance of the image composited over black (premultiplied luminance): white = paint. Procreate
    /// shape and grain sources use this convention.
    package static func luminanceOverBlack(_ buf: PixelBuffer) -> PixelBuffer {
        if buf.format == .gray { return buf }
        let w = buf.width, h = buf.height
        let out = PixelBuffer(width: w, height: h, format: .gray)
        let o = out.data.assumingMemoryBound(to: UInt8.self)
        let s = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let r = s + y * buf.bytesPerRow, d = o + y * out.bytesPerRow
            for x in 0..<w {
                let p = r + x * 4
                d[x] = UInt8(min(255, lum601(p)))
            }
        }
        out.markDirty()
        return out
    }
}
