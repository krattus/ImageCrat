import Foundation
import Metal
import simd
import ImageCratCore

enum PaletteKind: String, CaseIterable, Identifiable {
    case exact = "Exact", systemMac = "System (Mac OS)", systemWindows = "System (Windows)", web = "Web", uniform = "Uniform"
    case perceptual = "Perceptual", selective = "Selective", adaptive = "Adaptive", custom = "Custom"
    var id: String { rawValue }
    /// Palettes whose size follows the Colors field.
    var usesCount: Bool { [.uniform, .perceptual, .selective, .adaptive].contains(self) }
}

enum ForcedColors: String, CaseIterable, Identifiable {
    case none = "None", blackWhite = "Black and White", primaries = "Primaries", web = "Web"
    var id: String { rawValue }
    var colors: [RGBA] {
        switch self {
        case .none: return []
        case .blackWhite: return [.black, .white]
        case .primaries: return [.black, .white, RGBA(r: 1, g: 0, b: 0), RGBA(r: 0, g: 1, b: 0), RGBA(r: 0, g: 0, b: 1), RGBA(r: 0, g: 1, b: 1), RGBA(r: 1, g: 0, b: 1), RGBA(r: 1, g: 1, b: 0)]
        case .web: return Palettes.web
        }
    }
}

enum DitherKind: String, CaseIterable, Identifiable {
    case none = "None", diffusion = "Diffusion", pattern = "Pattern", noise = "Noise"
    var id: String { rawValue }
}

struct IndexedOptions: Equatable {
    var palette: PaletteKind = .selective
    var colors = 256
    var forced: ForcedColors = .blackWhite
    var transparency = true
    var matte: RGBA = .white
    var dither: DitherKind = .diffusion
    var amount: Double = 0.75
    var preserveExact = true
    var custom: [RGBA]? = nil
}

/// Fixed palettes.
enum Palettes {
    /// 216 web-safe colours.
    static let web: [RGBA] = {
        var out: [RGBA] = []
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
            out.append(RGBA(r: Double(r) / 5, g: Double(g) / 5, b: Double(b) / 5))
        } } }
        return out
    }()

    /// Classic Mac OS 8-bit system palette: 6×6×6 cube (white first) + red, green, blue and gray ramps.
    static let systemMac: [RGBA] = {
        var out: [RGBA] = []
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
            if r == 5 && g == 5 && b == 5 { continue }   // black goes last
            out.append(RGBA(r: 1 - Double(r) / 5, g: 1 - Double(g) / 5, b: 1 - Double(b) / 5))
        } } }
        let ramp: [Double] = [0xEE, 0xDD, 0xBB, 0xAA, 0x88, 0x77, 0x55, 0x44, 0x22, 0x11].map { $0 / 255 }
        for v in ramp { out.append(RGBA(r: v, g: 0, b: 0)) }
        for v in ramp { out.append(RGBA(r: 0, g: v, b: 0)) }
        for v in ramp { out.append(RGBA(r: 0, g: 0, b: v)) }
        for v in ramp { out.append(RGBA(r: v, g: v, b: v)) }
        out.append(.black)
        return out
    }()

    /// Windows 256-colour system palette: 20 static colours + 6×6×6 cube + grays.
    static let systemWindows: [RGBA] = {
        let statics: [(Int, Int, Int)] = [(0, 0, 0), (128, 0, 0), (0, 128, 0), (128, 128, 0), (0, 0, 128), (128, 0, 128), (0, 128, 128), (192, 192, 192),
                                          (192, 220, 192), (166, 202, 240), (255, 251, 240), (160, 160, 164), (128, 128, 128), (255, 0, 0), (0, 255, 0),
                                          (255, 255, 0), (0, 0, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
        var out = statics.map { RGBA(r8: UInt8($0.0), g8: UInt8($0.1), b8: UInt8($0.2)) }
        var seen = Set(out.map { $0.hex })
        for c in web where seen.insert(c.hex).inserted { out.append(c) }
        var g = 8
        while out.count < 256 { let c = RGBA(gray: Double(g) / 255); if seen.insert(c.hex).inserted { out.append(c) }; g += 8; if g > 255 { break } }
        return Array(out.prefix(256))
    }()

    /// n×n×n uniform cube with the largest n whose cube fits in `count`.
    static func uniform(_ count: Int) -> [RGBA] {
        var n = 2
        while (n + 1) * (n + 1) * (n + 1) <= count { n += 1 }
        var out: [RGBA] = []
        for r in 0..<n { for g in 0..<n { for b in 0..<n {
            out.append(RGBA(r: Double(r) / Double(n - 1), g: Double(g) / Double(n - 1), b: Double(b) / Double(n - 1)))
        } } }
        return out
    }
}

/// Colour quantisation (median cut, k-means in Lab) and palette mapping with dithering.
enum Quantizer {
    struct Histogram {
        var count = [Double](repeating: 0, count: 32768)
        var sum = [SIMD3<Double>](repeating: .zero, count: 32768)
        var total = 0.0
        var unique: [UInt32: Int] = [:]
        var uniqueOverflow = false
    }

    /// 5-bit histogram of the opaque (alpha ≥ 128) pixels, composited over `matte`.
    static func histogram(_ buf: PixelBuffer, matte: RGBA, skipTransparent: Bool) -> Histogram {
        var h = Histogram()
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        let mr = matte.r * 255, mg = matte.g * 255, mb = matte.b * 255
        h.count.withUnsafeMutableBufferPointer { cnt in
            h.sum.withUnsafeMutableBufferPointer { sum in
                for y in 0..<buf.height {
                    let row = p + y * buf.bytesPerRow
                    for x in 0..<buf.width {
                        let a = Int(row[x * 4 + 3])
                        if skipTransparent && a < 128 { continue }
                        var r = Double(row[x * 4]), g = Double(row[x * 4 + 1]), b = Double(row[x * 4 + 2])
                        if a < 255 {
                            let fa = Double(a) / 255
                            if a > 0 { r /= fa; g /= fa; b /= fa }
                            r = r * fa + mr * (1 - fa); g = g * fa + mg * (1 - fa); b = b * fa + mb * (1 - fa)
                        }
                        let ri = min(255, Int(r + 0.5)), gi = min(255, Int(g + 0.5)), bi = min(255, Int(b + 0.5))
                        let idx = (ri >> 3) << 10 | (gi >> 3) << 5 | (bi >> 3)
                        cnt[idx] += 1
                        sum[idx] += SIMD3(Double(ri), Double(gi), Double(bi))
                        if !h.uniqueOverflow {
                            let key = UInt32(ri) << 16 | UInt32(gi) << 8 | UInt32(bi)
                            h.unique[key, default: 0] += 1
                            if h.unique.count > 256 { h.uniqueOverflow = true; h.unique.removeAll() }
                        }
                    }
                }
            }
        }
        h.total = h.count.reduce(0, +)
        return h
    }

    private struct Box { var bins: [Int] }

    /// Median cut over histogram bins (Heckbert). Returns up to `k` colours (0…255 components).
    static func medianCut(_ h: Histogram, k: Int) -> [SIMD3<Double>] {
        let nonEmpty = (0..<32768).filter { h.count[$0] > 0 }
        if nonEmpty.isEmpty || k <= 0 { return [] }
        func mean(_ bins: [Int]) -> SIMD3<Double> {
            var s = SIMD3<Double>.zero, n = 0.0
            for b in bins { s += h.sum[b]; n += h.count[b] }
            return n > 0 ? s / n : .zero
        }
        func comps(_ b: Int) -> SIMD3<Double> { h.count[b] > 0 ? h.sum[b] / h.count[b] : .zero }
        var boxes = [Box(bins: nonEmpty)]
        while boxes.count < k {
            // split the box with the largest population × extent
            var bestI = -1, bestScore = 0.0, bestAxis = 0
            for (i, bx) in boxes.enumerated() where bx.bins.count > 1 {
                var lo = SIMD3<Double>(repeating: 1e9), hi = SIMD3<Double>(repeating: -1e9), n = 0.0
                for b in bx.bins { let c = comps(b); lo = pointwiseMin(lo, c); hi = pointwiseMax(hi, c); n += h.count[b] }
                let ext = hi - lo
                let axis = ext.x >= ext.y && ext.x >= ext.z ? 0 : (ext.y >= ext.z ? 1 : 2)
                let score = ext[axis] * sqrt(n)
                if score > bestScore { bestScore = score; bestI = i; bestAxis = axis }
            }
            if bestI < 0 { break }
            let bx = boxes[bestI]
            let sorted = bx.bins.sorted { comps($0)[bestAxis] < comps($1)[bestAxis] }
            let total = sorted.reduce(0.0) { $0 + h.count[$1] }
            var acc = 0.0, cut = 1
            for (j, b) in sorted.enumerated() {
                acc += h.count[b]
                if acc >= total / 2 { cut = max(1, min(sorted.count - 1, j + 1)); break }
            }
            boxes[bestI] = Box(bins: Array(sorted[..<cut]))
            boxes.append(Box(bins: Array(sorted[cut...])))
        }
        return boxes.map { mean($0.bins) }
    }

    // MARK: Lab helpers

    static func lab(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = ColorConvert.lab(RGBA(r: c.x / 255, g: c.y / 255, b: c.z / 255))
        return SIMD3(l.0, l.1, l.2)
    }

    static func rgb(fromLab l: SIMD3<Double>) -> SIMD3<Double> {
        func finv(_ t: Double) -> Double { let t3 = t * t * t; return t3 > 0.008856 ? t3 : (t - 16.0 / 116) / 7.787 }
        let fy = (l.x + 16) / 116, fx = fy + l.y / 500, fz = fy - l.z / 200
        let X = finv(fx) * 0.95047, Y = finv(fy), Z = finv(fz) * 1.08883
        var r = 3.2406 * X - 1.5372 * Y - 0.4986 * Z
        var g = -0.9689 * X + 1.8758 * Y + 0.0415 * Z
        var b = 0.0557 * X - 0.2040 * Y + 1.0570 * Z
        func enc(_ v: Double) -> Double { let c = clamp(v, 0, 1); return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }
        r = enc(r); g = enc(g); b = enc(b)
        return SIMD3(r, g, b) * 255
    }

    /// Weighted k-means in Lab over histogram bins, starting from `initial`. `fixed` colours never move.
    static func kmeans(_ h: Histogram, initial: [SIMD3<Double>], fixed: Int, iterations: Int = 6, emphasizeSaturated: Bool = false) -> [SIMD3<Double>] {
        let bins = (0..<32768).filter { h.count[$0] > 0 }
        if bins.isEmpty || initial.isEmpty { return initial }
        let pts = bins.map { lab(h.sum[$0] / h.count[$0]) }
        var wts = bins.map { h.count[$0] }
        if emphasizeSaturated {
            // Selective: favour saturated / distinctive colours a little (they are perceptually important).
            for i in pts.indices { let ch = sqrt(pts[i].y * pts[i].y + pts[i].z * pts[i].z); wts[i] *= 1 + ch / 60 }
        }
        var centers = initial.map(lab)
        let k = centers.count
        var assign = [Int](repeating: 0, count: pts.count)
        for _ in 0..<iterations {
            pts.withUnsafeBufferPointer { pp in
                centers.withUnsafeBufferPointer { cc in
                    for i in 0..<pp.count {
                        let p = pp[i]
                        var best = 0, bd = Double.greatestFiniteMagnitude
                        for j in 0..<k {
                            let d = p - cc[j]
                            let dd = d.x * d.x + d.y * d.y + d.z * d.z
                            if dd < bd { bd = dd; best = j }
                        }
                        assign[i] = best
                    }
                }
            }
            var sums = [SIMD3<Double>](repeating: .zero, count: k), ws = [Double](repeating: 0, count: k)
            for i in pts.indices { sums[assign[i]] += pts[i] * wts[i]; ws[assign[i]] += wts[i] }
            for j in fixed..<k where ws[j] > 0 { centers[j] = sums[j] / ws[j] }
        }
        return centers.enumerated().map { j, c in j < fixed ? initial[j] : rgb(fromLab: c) }
    }

    /// Builds the colour table for `buf`. Returns nil when Exact is requested but the image has more than the allowed colours.
    static func palette(for buf: PixelBuffer, options o: IndexedOptions) -> (colors: [RGBA], transparentIndex: Int?) {
        let hasTransparency = o.transparency && buf.opaqueBounds(threshold: 0) != nil && hasTransparentPixels(buf)
        let slots = max(2, min(256, o.colors)) - (hasTransparency ? 1 : 0)
        let h = histogram(buf, matte: o.matte, skipTransparent: hasTransparency)
        let forced = o.forced.colors
        var colors: [RGBA]
        switch o.palette {
        case .exact:
            if !h.uniqueOverflow, h.unique.count <= 256 - (hasTransparency ? 1 : 0) {
                colors = h.unique.sorted { $0.value > $1.value }.map { RGBA(r8: UInt8($0.key >> 16 & 255), g8: UInt8($0.key >> 8 & 255), b8: UInt8($0.key & 255)) }
            } else {
                var oo = o; oo.palette = .selective
                return palette(for: buf, options: oo)
            }
        case .systemMac: colors = Palettes.systemMac
        case .systemWindows: colors = Palettes.systemWindows
        case .web: colors = Palettes.web
        case .uniform: colors = Palettes.uniform(slots)
        case .custom: colors = Array((o.custom ?? Palettes.web).prefix(256))
        case .adaptive, .perceptual, .selective:
            let useForced = forced.count < slots ? forced : []
            let free = slots - useForced.count
            var init0 = medianCut(h, k: free)
            if o.palette == .adaptive {
                colors = useForced + init0.map { RGBA(r: $0.x / 255, g: $0.y / 255, b: $0.z / 255) }
            } else {
                init0 = useForced.map { SIMD3($0.r * 255, $0.g * 255, $0.b * 255) } + init0
                var cs = kmeans(h, initial: init0, fixed: useForced.count, emphasizeSaturated: o.palette == .selective)
                if o.palette == .selective {
                    // snap to nearby web-safe colours (Selective favours web colours)
                    for i in useForced.count..<cs.count {
                        let w = (cs[i] / 51.0).rounded(.toNearestOrEven) * 51.0
                        if simd_distance(w, cs[i]) < 10 { cs[i] = w }
                    }
                }
                colors = cs.map { RGBA(r: clamp($0.x / 255, 0, 1), g: clamp($0.y / 255, 0, 1), b: clamp($0.z / 255, 0, 1)) }
            }
            // drop exact duplicates
            var seen = Set<String>()
            colors = colors.filter { seen.insert($0.hex).inserted }
        }
        if !o.palette.usesCount, o.palette != .exact, o.palette != .custom, !forced.isEmpty {
            // fixed palettes: forced colours replace the least important entries only if missing
            for f in forced where !colors.contains(where: { $0.hex == f.hex }) { if colors.count >= slots { colors.removeLast() }; colors.insert(f, at: 0) }
        }
        colors = Array(colors.prefix(slots)).map { RGBA(r8: UInt8($0.r8), g8: UInt8($0.g8), b8: UInt8($0.b8)) }
        if hasTransparency {
            colors.append(RGBA(r: 0, g: 0, b: 0, a: 0))
            return (colors, colors.count - 1)
        }
        return (colors, nil)
    }

    static func hasTransparentPixels(_ buf: PixelBuffer) -> Bool {
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<buf.height {
            let row = p + y * buf.bytesPerRow
            for x in 0..<buf.width where row[x * 4 + 3] < 128 { return true }
        }
        return false
    }

    // MARK: Mapping

    /// Palette index per pixel (row-major, width × height). Uses Metal for none / pattern / noise; CPU Floyd–Steinberg for diffusion.
    static func indices(_ buf: PixelBuffer, palette: [RGBA], transparentIndex: Int?, dither: DitherKind, amount: Double, preserveExact: Bool, matte: RGBA) -> [UInt8] {
        if dither == .diffusion { return diffuse(buf, palette: palette, transparentIndex: transparentIndex, amount: amount, preserveExact: preserveExact, matte: matte) }
        let w = buf.width, h = buf.height
        var out = [UInt8](repeating: 0, count: w * h)
        let dev = RenderEngine.device
        var pal = palette.map { SIMD4<Float>(Float($0.r8), Float($0.g8), Float($0.b8), 0) }
        if pal.isEmpty { pal = [SIMD4<Float>(0, 0, 0, 0)] }
        struct Params { var width: UInt32; var height: UInt32; var rowPixels: UInt32; var count: UInt32; var mode: Int32; var spread: Float
            var transparentIndex: Int32; var preserveExact: Int32; var matte: SIMD4<Float>; var seed: UInt32; var p0: UInt32 = 0; var p1: UInt32 = 0; var p2: UInt32 = 0 }
        var prm = Params(width: UInt32(w), height: UInt32(h), rowPixels: UInt32(buf.bytesPerRow / 4), count: UInt32(pal.count),
                         mode: dither == .none ? 0 : (dither == .pattern ? 1 : 2), spread: Float(spread(palette) * max(0.05, amount) * 1.3),
                         transparentIndex: Int32(transparentIndex ?? -1), preserveExact: preserveExact ? 1 : 0,
                         matte: SIMD4<Float>(Float(matte.r), Float(matte.g), Float(matte.b), 1), seed: 17)
        if dither == .pattern || dither == .noise { prm.spread = Float(spread(palette) * max(0.1, amount) * 1.0) }
        guard let src = dev.makeBuffer(bytes: buf.data, length: buf.bytesPerRow * h, options: .storageModeShared),
              let dst = dev.makeBuffer(length: w * h, options: .storageModeShared),
              let pb = dev.makeBuffer(bytes: &pal, length: MemoryLayout<SIMD4<Float>>.stride * pal.count, options: .storageModeShared) else { return out }
        let ok = ImagingMetal.dispatch("lumenMapPalette", width: w, height: h) { enc in
            enc.setBuffer(src, offset: 0, index: 0); enc.setBuffer(dst, offset: 0, index: 1); enc.setBuffer(pb, offset: 0, index: 2)
            enc.setBytes(&prm, length: MemoryLayout<Params>.stride, index: 3)
        }
        if ok { out.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, dst.contents(), w * h) } }
        else { return diffuse(buf, palette: palette, transparentIndex: transparentIndex, amount: 0, preserveExact: true, matte: matte) }
        return out
    }

    /// Mean nearest-neighbour distance between palette colours (0…255 units): the dither amplitude.
    static func spread(_ palette: [RGBA]) -> Double {
        let c = palette.filter { $0.a > 0.5 }.map { SIMD3(Double($0.r8), Double($0.g8), Double($0.b8)) }
        if c.count < 2 { return 128 }
        var tot = 0.0
        for i in c.indices {
            var best = Double.greatestFiniteMagnitude
            for j in c.indices where j != i { best = min(best, simd_distance(c[i], c[j])) }
            tot += best
        }
        return max(8, tot / Double(c.count))
    }

    /// Floyd–Steinberg error diffusion with a lazily-filled 6-bit inverse colour map.
    static func diffuse(_ buf: PixelBuffer, palette: [RGBA], transparentIndex: Int?, amount: Double, preserveExact: Bool, matte: RGBA) -> [UInt8] {
        let w = buf.width, h = buf.height
        var out = [UInt8](repeating: 0, count: w * h)
        let pal = palette.map { SIMD3<Float>(Float($0.r8), Float($0.g8), Float($0.b8)) }
        let ti = transparentIndex ?? -1
        var inverse = [Int16](repeating: -1, count: 64 * 64 * 64)
        var exactIndex: [UInt32: UInt8] = [:]
        for (i, c) in palette.enumerated() where i != ti { let k = UInt32(c.r8) << 16 | UInt32(c.g8) << 8 | UInt32(c.b8); if exactIndex[k] == nil { exactIndex[k] = UInt8(i) } }
        func nearest(_ c: SIMD3<Float>) -> Int {
            var best = 0, bd = Float.greatestFiniteMagnitude
            for (i, p) in pal.enumerated() where i != ti {
                let d = c - p
                let dd = (d * d).sum()
                if dd < bd { bd = dd; best = i }
            }
            return best
        }
        let amt = Float(clamp(amount, 0, 1))
        var errCur = [SIMD3<Float>](repeating: .zero, count: w + 2)
        var errNext = [SIMD3<Float>](repeating: .zero, count: w + 2)
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        let m = SIMD3<Float>(Float(matte.r * 255), Float(matte.g * 255), Float(matte.b * 255))
        for y in 0..<h {
            let row = p + y * buf.bytesPerRow
            let serp = y % 2 == 1
            for i in 0..<(w + 2) { errNext[i] = .zero }
            for k in 0..<w {
                let x = serp ? w - 1 - k : k
                let a = row[x * 4 + 3]
                if ti >= 0 && a < 128 { out[y * w + x] = UInt8(ti); continue }
                var c = SIMD3<Float>(Float(row[x * 4]), Float(row[x * 4 + 1]), Float(row[x * 4 + 2]))
                if a < 255 {
                    let fa = Float(a) / 255
                    if a > 0 { c /= fa }
                    c = c * fa + m * (1 - fa)
                }
                let key = UInt32(min(255, c.x + 0.5)) << 16 | UInt32(min(255, c.y + 0.5)) << 8 | UInt32(min(255, c.z + 0.5))
                if preserveExact, let e = exactIndex[key] { out[y * w + x] = e; continue }
                let v = simd_clamp(c + errCur[x + 1], SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 255))
                let qr = Int(v.x) >> 2, qg = Int(v.y) >> 2, qb = Int(v.z) >> 2
                let ci = (qr << 12) | (qg << 6) | qb
                var idx = Int(inverse[ci])
                if idx < 0 {
                    idx = nearest(SIMD3<Float>(Float(qr * 4 + 2), Float(qg * 4 + 2), Float(qb * 4 + 2)))
                    inverse[ci] = Int16(idx)
                }
                out[y * w + x] = UInt8(idx)
                let e = (v - pal[idx]) * amt
                if serp {
                    errCur[x] += e * (7.0 / 16); errNext[x + 2] += e * (3.0 / 16); errNext[x + 1] += e * (5.0 / 16); errNext[x] += e * (1.0 / 16)
                } else {
                    errCur[x + 2] += e * (7.0 / 16); errNext[x] += e * (3.0 / 16); errNext[x + 1] += e * (5.0 / 16); errNext[x + 2] += e * (1.0 / 16)
                }
            }
            swap(&errCur, &errNext)
        }
        return out
    }

    /// RGBA buffer of the palette colours (transparent entry → clear).
    static func render(indices: [UInt8], width: Int, height: Int, palette: [RGBA], transparentIndex: Int?) -> PixelBuffer {
        let b = PixelBuffer(width: width, height: height)
        let p = b.data.assumingMemoryBound(to: UInt8.self)
        let lut = palette.map { (UInt8($0.r8), UInt8($0.g8), UInt8($0.b8)) }
        for y in 0..<height {
            let row = p + y * b.bytesPerRow
            for x in 0..<width {
                let i = Int(indices[y * width + x])
                if i == transparentIndex || i >= lut.count { row[x * 4 + 3] = 0; continue }
                let c = lut[i]
                row[x * 4] = c.0; row[x * 4 + 1] = c.1; row[x * 4 + 2] = c.2; row[x * 4 + 3] = 255
            }
        }
        b.markDirty()
        return b
    }
}
