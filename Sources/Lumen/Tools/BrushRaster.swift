import Foundation
import CoreGraphics
import ImageCratCore

// MARK: - Tip sources

/// An unrotated brush tip used by the software dab rasterizer.
/// Round tips are evaluated analytically (hardness LUT); sampled tips keep a gray mip pyramid so
/// any size / angle / roundness / flip can be stamped without generating a new bitmap per dab.
final class TipSource {
    struct Level {
        let w: Int
        let h: Int
        let px: [UInt8]
    }

    let id: String
    let isRound: Bool
    let levels: [Level]
    /// Half extents of the tip bitmap relative to its longer side (1 = the longer side).
    let aspectX: Double
    let aspectY: Double

    private init(round id: String) {
        self.id = id; isRound = true; levels = []; aspectX = 1; aspectY = 1
    }

    init(id: String, gray: [UInt8], width: Int, height: Int) {
        self.id = id
        isRound = false
        var lv = [Level(w: width, h: height, px: gray)]
        while let last = lv.last, max(last.w, last.h) > 4 {
            let nw = max(1, last.w / 2), nh = max(1, last.h / 2)
            var out = [UInt8](repeating: 0, count: nw * nh)
            last.px.withUnsafeBufferPointer { src in
                for y in 0..<nh {
                    let y0 = min(last.h - 1, y * 2), y1 = min(last.h - 1, y * 2 + 1)
                    for x in 0..<nw {
                        let x0 = min(last.w - 1, x * 2), x1 = min(last.w - 1, x * 2 + 1)
                        let s = Int(src[y0 * last.w + x0]) + Int(src[y0 * last.w + x1]) + Int(src[y1 * last.w + x0]) + Int(src[y1 * last.w + x1])
                        out[y * nw + x] = UInt8((s + 2) / 4)
                    }
                }
            }
            lv.append(Level(w: nw, h: nh, px: out))
        }
        levels = lv
        let side = Double(max(width, height))
        aspectX = Double(width) / side
        aspectY = Double(height) / side
    }

    convenience init(id: String, buffer b: PixelBuffer) {
        let g = b.format == .gray ? b : b.toGray()
        var px = [UInt8](repeating: 0, count: g.width * g.height)
        let src = g.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<g.height { for x in 0..<g.width { px[y * g.width + x] = src[y * g.bytesPerRow + x] } }
        self.init(id: id, gray: px, width: g.width, height: g.height)
    }

    /// Mip level whose resolution is closest to (but not below) the dab diameter.
    func level(forDiameter d: Double) -> Level {
        let side = Double(max(levels[0].w, levels[0].h))
        let ratio = side / max(1, d)
        var l = ratio > 1 ? Int(floor(log2(ratio))) : 0
        l = max(0, min(levels.count - 1, l))
        return levels[l]
    }

    // MARK: Cache

    private static var cache: [String: TipSource] = [:]
    private static var luts: [Int: [Float]] = [:]
    static let lutSize = 512

    static func get(_ tipID: String) -> TipSource {
        if let t = cache[tipID] { return t }
        let t: TipSource
        if tipID == "round" {
            t = TipSource(round: tipID)
        } else if let b = AppModel.shared.customBrushTips[tipID] ?? BrushLibrary.shared.tipBuffer(tipID) {
            t = TipSource(id: tipID, buffer: b)
        } else if let img = BrushTips.texture(tipID) {
            t = TipSource(id: tipID, buffer: PixelBuffer(cgImage: img, format: .gray))
        } else {
            t = TipSource(round: tipID)
        }
        cache[tipID] = t
        return t
    }

    static func invalidate(_ tipID: String? = nil) {
        if let id = tipID { cache.removeValue(forKey: id) } else { cache.removeAll() }
    }

    /// Radial profile for a round tip (index = normalized radius * lutSize), matching `BrushTips.mask`.
    static func hardnessLUT(_ hardness: Double) -> [Float] {
        let key = Int((clamp(hardness, 0, 1) * 100).rounded())
        if let l = luts[key] { return l }
        let h = Double(key) / 100
        var out = [Float](repeating: 0, count: lutSize + 1)
        for i in 0...lutSize {
            let t = Double(i) / Double(lutSize)
            var v: Double
            if h >= 0.99 || t <= h { v = 1 } else {
                let u = (t - h) / (1 - h)
                v = 1 - u * u * (3 - 2 * u)
                v = pow(max(0, v), 1.2)
            }
            out[i] = Float(v)
        }
        luts[key] = out
        return out
    }
}

// MARK: - Texture sampler

/// A gray, tiled texture in document space (pattern scaled, with brightness / contrast / invert baked in).
final class TextureSampler {
    let w: Int
    let h: Int
    /// w*h gray values, owned (stable pointer for the rasterizer's inner loops).
    let px: UnsafeMutablePointer<UInt8>

    init(w: Int, h: Int, px: [UInt8]) {
        self.w = w; self.h = h
        self.px = .allocate(capacity: w * h)
        px.withUnsafeBufferPointer { self.px.initialize(from: $0.baseAddress!, count: w * h) }
    }

    deinit { px.deallocate() }

    @inline(__always) func value(_ x: Int, _ y: Int) -> Float {
        var xx = x % w; if xx < 0 { xx += w }
        var yy = y % h; if yy < 0 { yy += h }
        return Float(px[yy * w + xx]) / 255
    }

    private static var cache: [String: TextureSampler] = [:]

    static func get(patternID: String, scale: Double, brightness: Double, contrast: Double, invert: Bool) -> TextureSampler? {
        let key = "\(patternID)|\(Int(scale * 1000))|\(Int(brightness))|\(Int(contrast))|\(invert)"
        if let c = cache[key] { return c }
        guard let pat = PatternLibrary.pattern(id: patternID, custom: AppModel.shared.customPatterns) else { return nil }
        let src = pat.image.makeCGImage()
        let sc = clamp(scale, 0.01, 10)
        let w = max(1, Int((Double(src.width) * sc).rounded())), h = max(1, Int((Double(src.height) * sc).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: graySpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        // Photoshop-like brightness (-150...150 levels) and contrast (-50...100).
        let b = brightness / 255
        let k = contrast >= 0 ? 1 + contrast / 100 * 3 : 1 + contrast / 100
        var px = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var v = Double(p[y * bpr + x]) / 255
                v = (v - 0.5) * k + 0.5 + b
                if invert { v = 1 - v }
                px[y * w + x] = UInt8(clamp(v, 0, 1) * 255 + 0.5)
            }
        }
        let s = TextureSampler(w: w, h: h, px: px)
        if cache.count > 32 { cache.removeAll() }
        cache[key] = s
        return s
    }
}

// MARK: - Mask combination

enum BrushMaskMath {
    @inline(__always) static func clamp01(_ v: Float) -> Float { v < 0 ? 0 : (v > 1 ? 1 : v) }

    /// Combines a primary tip value `m` (blend) with a secondary value `s` (base: dual brush coverage or texture
    /// strength, 1 = no masking). Every mode keeps the result inside the primary tip's footprint.
    @inline(__always) static func combine(_ m: Float, _ s: Float, _ mode: BrushMaskMode) -> Float {
        switch mode {
        case .multiply, .height, .linearHeight: return m * s
        case .subtract, .linearBurn: return max(0, m + s - 1)
        case .darken: return min(m, s)
        case .overlay:
            let o = s < 0.5 ? 2 * m * s : 1 - 2 * (1 - m) * (1 - s)
            return clamp01(o) * min(1, 2 * m)
        case .colorBurn: return m <= 0.001 ? 0 : m * clamp01(1 - (1 - s) / m)
        case .hardMix: return clamp01((m * s - 0.25) * 16 + 0.5)
        }
    }

    /// Applies a texture value `t` (1 = high / paint) with depth `d` to tip value `m`.
    @inline(__always) static func texture(_ m: Float, _ t: Float, _ d: Float, _ mode: BrushMaskMode) -> Float {
        switch mode {
        case .height: return m * clamp01((t - d) / 0.08 + 1)
        case .linearHeight: return m * clamp01((t - d) / 0.5 + 1)
        case .subtract: return max(0, m - d * (1 - t))
        default: return combine(m, 1 - d * (1 - t), mode)
        }
    }

    /// Stable per-pixel noise 0...1.
    @inline(__always) static func noise(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }
}

// MARK: - Software dab rasterizer

/// Stamps tips directly into 8-bit buffers: no per-dab image allocation, any angle / roundness / size / flip.
enum DabRaster {
    struct Dab {
        /// Center in buffer pixel coordinates (y down).
        var cx: Double
        var cy: Double
        var diameter: Double
        var roundness: Double = 1
        /// Degrees, counter-clockwise on screen.
        var angle: Double = 0
        var flipX = false
        var flipY = false
        var hardness: Double = 1
        var aliased = false
    }

    struct Texture {
        let sampler: TextureSampler
        let mode: BrushMaskMode
        let depth: Float
        /// Buffer → document offset (texture is locked to the canvas).
        let ox: Int
        let oy: Int
    }

    /// Stamps a dab. RGBA buffers (premultiplied) get source-over paint of `color` (0...1, unpremultiplied);
    /// gray buffers accumulate coverage with max (used for the dual brush). Returns the touched rect.
    @discardableResult
    static func stamp(_ d: Dab, tip: TipSource, into buf: PixelBuffer, color: (Float, Float, Float) = (0, 0, 0),
                      alpha: Float, texture: Texture? = nil) -> IRect {
        var r = d.diameter / 2
        var a = alpha
        if d.diameter < 1 { a *= Float(max(0, d.diameter * d.diameter)); r = 0.5 }
        if a <= 0.001 || !d.cx.isFinite || !d.cy.isFinite { return .zero }
        let rn = clamp(d.roundness, 0.01, 1)
        let th = d.angle * .pi / 180
        let c = cos(th), s = sin(th)
        let rx = r, ry = r * rn
        let round = tip.isRound
        let ex: Double, ey: Double
        if round {
            ex = sqrt(rx * c * rx * c + ry * s * ry * s)
            ey = sqrt(rx * s * rx * s + ry * c * ry * c)
        } else {
            let hx = rx * tip.aspectX, hy = ry * tip.aspectY
            ex = abs(hx * c) + abs(hy * s)
            ey = abs(hx * s) + abs(hy * c)
        }
        let x0 = max(0, Int(floor(d.cx - ex - 1))), x1 = min(buf.width, Int(ceil(d.cx + ex + 1)))
        let y0 = max(0, Int(floor(d.cy - ey - 1))), y1 = min(buf.height, Int(ceil(d.cy + ey + 1)))
        if x1 <= x0 || y1 <= y0 { return .zero }

        let fx = d.flipX ? -1.0 : 1.0, fy = d.flipY ? -1.0 : 1.0
        // normalized tip coords: nu along the tip's x axis, nv along its y axis (y up)
        let nuDx = c / rx * fx, nuDy = -s / rx * fx
        let nvDx = -s / ry * fy, nvDy = -c / ry * fy

        let gray = buf.format == .gray
        let bpr = buf.bytesPerRow
        let base = buf.data.assumingMemoryBound(to: UInt8.self)
        let cr = color.0 * 255, cg = color.1 * 255, cb = color.2 * 255
        let aliased = d.aliased

        // texture state
        let tex = texture
        let texPx: UnsafeMutablePointer<UInt8>? = tex?.sampler.px
        let tw = tex?.sampler.w ?? 1, thh = tex?.sampler.h ?? 1
        let tDepth = tex?.depth ?? 0
        let tMode = tex?.mode ?? .multiply

        let tox = tex?.ox ?? 0

        let bppShift = gray ? 0 : 2
        if round {
            let lut = TipSource.hardnessLUT(d.hardness)
            let aaW = max(0.5, min(rx, ry))
            let limit = 1 + 0.5 / aaW
            let limit2 = limit * limit
            let n = Double(TipSource.lutSize)
            let lutMax = TipSource.lutSize
            let cx = d.cx, cy = d.cy
            lut.withUnsafeBufferPointer { LB in
                let L = LB.baseAddress!
                for y in y0..<y1 {
                    let dy = Double(y) + 0.5 - cy
                    let dx0 = Double(x0) + 0.5 - cx
                    var nu = dx0 * nuDx + dy * nuDy
                    var nv = dx0 * nvDx + dy * nvDy
                    let row = base + y * bpr
                    var trow = 0
                    if tex != nil { var ty = (y + tex!.oy) % thh; if ty < 0 { ty += thh }; trow = ty * tw }
                    for x in x0..<x1 {
                        let r2 = nu * nu + nv * nv
                        nu += nuDx; nv += nvDx
                        if r2 >= limit2 { continue }
                        var m: Float
                        if aliased {
                            if r2 > 1 { continue }
                            m = 1
                        } else {
                            let rho = r2.squareRoot()
                            let e = (1 - rho) * aaW + 0.5
                            m = L[min(lutMax, Int(rho * n))] * Float(e >= 1 ? 1 : e)
                        }
                        if let tp = texPx {
                            var tx = (x + tox) % tw; if tx < 0 { tx += tw }
                            m = BrushMaskMath.texture(m, Float(tp[trow + tx]) / 255, tDepth, tMode)
                        }
                        let av = m * a
                        if av < 0.002 { continue }
                        let p = row + (x << bppShift)
                        if gray {
                            let v = av * 255 + 0.5
                            if v > Float(p[0]) { p[0] = UInt8(min(255, v)) }
                        } else {
                            let inv = 1 - av
                            p[0] = UInt8(min(255, cr * av + Float(p[0]) * inv + 0.5))
                            p[1] = UInt8(min(255, cg * av + Float(p[1]) * inv + 0.5))
                            p[2] = UInt8(min(255, cb * av + Float(p[2]) * inv + 0.5))
                            p[3] = UInt8(min(255, 255 * av + Float(p[3]) * inv + 0.5))
                        }
                    }
                }
            }
        } else {
            let lv = tip.level(forDiameter: 2 * r)
            let W = lv.w, H = lv.h
            let sxU = 0.5 / tip.aspectX * Double(W), syV = -0.5 / tip.aspectY * Double(H)
            lv.px.withUnsafeBufferPointer { P in
                let px = P.baseAddress!
                for y in y0..<y1 {
                    let dy = Double(y) + 0.5 - d.cy
                    let dx0 = Double(x0) + 0.5 - d.cx
                    let nu = dx0 * nuDx + dy * nuDy
                    let nv = dx0 * nvDx + dy * nvDy
                    var sx = nu * sxU + 0.5 * Double(W) - 0.5
                    var sy = nv * syV + 0.5 * Double(H) - 0.5
                    let sxDx = nuDx * sxU, syDx = nvDx * syV
                    let row = base + y * bpr
                    var trow = 0
                    if tex != nil { var ty = (y + tex!.oy) % thh; if ty < 0 { ty += thh }; trow = ty * tw }
                    for x in x0..<x1 {
                        let fsx = sx, fsy = sy
                        sx += sxDx; sy += syDx
                        if fsx <= -1 || fsy <= -1 || fsx >= Double(W) || fsy >= Double(H) { continue }
                        let ix = Int(fsx + 1) - 1, iy = Int(fsy + 1) - 1
                        let tx = Float(fsx - Double(ix)), ty = Float(fsy - Double(iy))
                        let inX0 = ix >= 0, inX1 = ix + 1 < W, inY0 = iy >= 0, inY1 = iy + 1 < H
                        let p00: Float = inX0 && inY0 ? Float(px[iy * W + ix]) : 0
                        let p10: Float = inX1 && inY0 ? Float(px[iy * W + ix + 1]) : 0
                        let p01: Float = inX0 && inY1 ? Float(px[(iy + 1) * W + ix]) : 0
                        let p11: Float = inX1 && inY1 ? Float(px[(iy + 1) * W + ix + 1]) : 0
                        let top = p00 + (p10 - p00) * tx
                        let bot = p01 + (p11 - p01) * tx
                        var m = (top + (bot - top) * ty) / 255
                        if aliased { m = m >= 0.5 ? 1 : 0 }
                        if m <= 0.002 { continue }
                        if let tp = texPx {
                            var tx = (x + tox) % tw; if tx < 0 { tx += tw }
                            m = BrushMaskMath.texture(m, Float(tp[trow + tx]) / 255, tDepth, tMode)
                        }
                        let av = m * a
                        if av < 0.002 { continue }
                        let p = row + (x << bppShift)
                        if gray {
                            let v = av * 255 + 0.5
                            if v > Float(p[0]) { p[0] = UInt8(min(255, v)) }
                        } else {
                            let inv = 1 - av
                            p[0] = UInt8(min(255, cr * av + Float(p[0]) * inv + 0.5))
                            p[1] = UInt8(min(255, cg * av + Float(p[1]) * inv + 0.5))
                            p[2] = UInt8(min(255, cb * av + Float(p[2]) * inv + 0.5))
                            p[3] = UInt8(min(255, 255 * av + Float(p[3]) * inv + 0.5))
                        }
                    }
                }
            }
        }
        return IRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
