import Foundation

// Lumen Ultra PNG — lossless reductions: every PNG representation that can hold the image exactly
// (16 → 8 bit, RGBA → RGB / gray / gray+alpha, colour-key transparency, palette at 1/2/4/8 bits in several
// index orders). The encoder then measures them and keeps the smallest.

struct UPReduceOptions {
    /// Keep the (invisible) colour stored under fully transparent pixels.
    var keepHiddenRGB = false
    var allowGray = true
    var allowPalette = true
    var allowColorKey = true
    /// Palette index orders to try (all of them at thorough / maximum effort).
    var paletteOrders: [UPPaletteOrder] = UPPaletteOrder.allCases
    /// Also emit 8-bit-per-index variants of palettes that fit in fewer bits.
    var tryWidePalette = true
}

enum UPPaletteOrder: String, CaseIterable {
    case appearance, popularity, luminance, alphaLuminance, alphaPopularity, neighbour, colourChain
}

struct UPAnalysis {
    var deep = false           // needs 16 bits per sample
    var hasAlpha = false
    var binaryAlpha = true
    var gray = true
    var uniqueColors: Int? = nil   // nil when more than 256
}

enum UPReduce {
    /// Canonical working pixels: 16-bit folded to 8 when lossless, hidden RGB zeroed unless it must be kept.
    static func canonical(_ img: UPImage, keepHiddenRGB: Bool) -> UPImage {
        var out = img
        if let p16 = img.px16 {
            var reducible = true
            p16.withUnsafeBufferPointer { p in
                var i = 0
                let n = p.count
                while i < n {
                    let a = p[i + 3]
                    if a >> 8 != a & 255 { reducible = false; break }
                    if a != 0 || keepHiddenRGB {
                        if p[i] >> 8 != p[i] & 255 || p[i + 1] >> 8 != p[i + 1] & 255 || p[i + 2] >> 8 != p[i + 2] & 255 { reducible = false; break }
                    }
                    i += 4
                }
            }
            if reducible {
                out.px16 = nil
                out.px = p16.map { UInt8($0 >> 8) }
            } else if !keepHiddenRGB {
                var q = p16
                for i in stride(from: 0, to: q.count, by: 4) where q[i + 3] == 0 { q[i] = 0; q[i + 1] = 0; q[i + 2] = 0 }
                out.px16 = q
                return out
            } else { return out }
        }
        if !keepHiddenRGB {
            let n = out.px.count
            out.px.withUnsafeMutableBufferPointer { p in
                var i = 0
                while i < n { if p[i + 3] == 0 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0 }; i += 4 }
            }
        }
        return out
    }

    static func analyse(_ img: UPImage) -> UPAnalysis {
        var a = UPAnalysis()
        if let p = img.px16 {
            a.deep = true
            for i in stride(from: 0, to: p.count, by: 4) {
                let al = p[i + 3]
                if al != 65535 { a.hasAlpha = true; if al != 0 { a.binaryAlpha = false } }
                if p[i] != p[i + 1] || p[i] != p[i + 2] { a.gray = false }
            }
            return a
        }
        var colors = Set<UInt32>()
        var over = false
        let n = img.px.count
        img.px.withUnsafeBufferPointer { p in
            var i = 0
            var last: UInt32 = 0xFFFF_FFFE
            while i < n {
                let al = p[i + 3]
                if al != 255 { a.hasAlpha = true; if al != 0 { a.binaryAlpha = false } }
                if p[i] != p[i + 1] || p[i] != p[i + 2] { a.gray = false }
                if !over {
                    let c = UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(al) << 24
                    if c != last { last = c; if colors.insert(c).inserted, colors.count > 256 { over = true } }
                }
                i += 4
            }
        }
        a.uniqueColors = over ? nil : colors.count
        return a
    }

    /// All exact representations worth measuring.
    static func candidates(_ source: UPImage, options o: UPReduceOptions) -> [UPRep] {
        let img = canonical(source, keepHiddenRGB: o.keepHiddenRGB)
        let a = analyse(img)
        let w = img.width, h = img.height, n = w * h
        var reps: [UPRep] = []
        if let p16 = img.px16 {
            // 16-bit: gray / gray+alpha / RGB / RGBA
            let gray = a.gray && o.allowGray
            let ch = (gray ? 1 : 3) + (a.hasAlpha ? 1 : 0)
            var raw = [UInt8](repeating: 0, count: n * ch * 2)
            for i in 0..<n {
                var k = i * ch * 2
                for c in 0..<(gray ? 1 : 3) { raw[k] = UInt8(p16[i * 4 + c] >> 8); raw[k + 1] = UInt8(p16[i * 4 + c] & 255); k += 2 }
                if a.hasAlpha { raw[k] = UInt8(p16[i * 4 + 3] >> 8); raw[k + 1] = UInt8(p16[i * 4 + 3] & 255) }
            }
            let type: UInt8 = gray ? (a.hasAlpha ? 4 : 0) : (a.hasAlpha ? 6 : 2)
            reps.append(UPRep(width: w, height: h, colorType: type, bitDepth: 16, raw: raw, label: ["gray16", "", "rgb16", "", "gray+a16", "", "rgba16"][Int(type)]))
            return reps
        }
        let px = img.px
        let gray = a.gray && o.allowGray
        // --- true colour / gray with alpha channel or opaque
        if a.hasAlpha {
            if gray {
                var raw = [UInt8](repeating: 0, count: n * 2)
                for i in 0..<n { raw[i * 2] = px[i * 4]; raw[i * 2 + 1] = px[i * 4 + 3] }
                reps.append(UPRep(width: w, height: h, colorType: 4, bitDepth: 8, raw: raw, label: "gray+a8"))
            } else {
                reps.append(UPRep(width: w, height: h, colorType: 6, bitDepth: 8, raw: px, label: "rgba8"))
            }
        } else {
            if gray {
                var raw = [UInt8](repeating: 0, count: n)
                for i in 0..<n { raw[i] = px[i * 4] }
                reps.append(UPRep(width: w, height: h, colorType: 0, bitDepth: 8, raw: raw, label: "gray8"))
                reps.append(contentsOf: lowDepthGray(raw, w, h, key: nil))
            } else {
                var raw = [UInt8](repeating: 0, count: n * 3)
                for i in 0..<n { raw[i * 3] = px[i * 4]; raw[i * 3 + 1] = px[i * 4 + 1]; raw[i * 3 + 2] = px[i * 4 + 2] }
                reps.append(UPRep(width: w, height: h, colorType: 2, bitDepth: 8, raw: raw, label: "rgb8"))
            }
        }
        // --- colour-key transparency (binary alpha, some colour unused by the visible pixels)
        if a.hasAlpha && a.binaryAlpha && o.allowColorKey && !o.keepHiddenRGB {
            if gray {
                var used = [Bool](repeating: false, count: 256)
                for i in 0..<n where px[i * 4 + 3] != 0 { used[Int(px[i * 4])] = true }
                // prefer a key next to a used level (small residuals); any unused level is valid
                if let key = (0..<256).first(where: { !used[$0] }) {
                    var raw = [UInt8](repeating: 0, count: n)
                    for i in 0..<n { raw[i] = px[i * 4 + 3] == 0 ? UInt8(key) : px[i * 4] }
                    reps.append(UPRep(width: w, height: h, colorType: 0, bitDepth: 8, trnsKey: [UInt16(key)], raw: raw, label: "gray8+key"))
                }
                // low bit depths need the key among that depth's levels
                for (bits, mul) in [(1, 255), (2, 85), (4, 17)] {
                    var ok = true
                    for v in 0..<256 where used[v] && v % mul != 0 { ok = false; break }
                    guard ok, let kl = (0..<(1 << bits)).first(where: { !used[$0 * mul] }) else { continue }
                    var lv = [UInt8](repeating: 0, count: n)
                    for i in 0..<n { lv[i] = px[i * 4 + 3] == 0 ? UInt8(kl) : UInt8(Int(px[i * 4]) / mul) }
                    reps.append(UPRep(width: w, height: h, colorType: 0, bitDepth: UInt8(bits), trnsKey: [UInt16(kl)], raw: pack(lv, w, h, bits), label: "gray\(bits)+key"))
                }
            } else {
                var used = Set<UInt32>()
                for i in 0..<n where px[i * 4 + 3] != 0 { used.insert(UInt32(px[i * 4]) | UInt32(px[i * 4 + 1]) << 8 | UInt32(px[i * 4 + 2]) << 16) }
                var key: UInt32? = nil
                for c in [0x000000, 0xFFFFFF, 0xFF00FF, 0x00FF00, 0x808080] as [UInt32] where !used.contains(c) { key = c; break }
                if key == nil { var c: UInt32 = 1; while c < 1 << 24 { if !used.contains(c) { key = c; break }; c += 1 } }
                if let k = key {
                    var raw = [UInt8](repeating: 0, count: n * 3)
                    for i in 0..<n {
                        if px[i * 4 + 3] == 0 { raw[i * 3] = UInt8(k & 255); raw[i * 3 + 1] = UInt8(k >> 8 & 255); raw[i * 3 + 2] = UInt8(k >> 16 & 255) }
                        else { raw[i * 3] = px[i * 4]; raw[i * 3 + 1] = px[i * 4 + 1]; raw[i * 3 + 2] = px[i * 4 + 2] }
                    }
                    reps.append(UPRep(width: w, height: h, colorType: 2, bitDepth: 8,
                                      trnsKey: [UInt16(k & 255), UInt16(k >> 8 & 255), UInt16(k >> 16 & 255)], raw: raw, label: "rgb8+key"))
                }
            }
        }
        // --- palette
        if let u = a.uniqueColors, u <= 256, o.allowPalette {
            reps.append(contentsOf: paletteReps(px, w, h, options: o))
        }
        return reps
    }

    private static func lowDepthGray(_ g: [UInt8], _ w: Int, _ h: Int, key: UInt16?) -> [UPRep] {
        var out: [UPRep] = []
        for (bits, mul) in [(1, 255), (2, 85), (4, 17)] {
            var ok = true
            for v in g where Int(v) % mul != 0 { ok = false; break }
            guard ok else { continue }
            let lv = g.map { UInt8(Int($0) / mul) }
            out.append(UPRep(width: w, height: h, colorType: 0, bitDepth: UInt8(bits), raw: pack(lv, w, h, bits), label: "gray\(bits)"))
        }
        return out
    }

    /// Packs one value per pixel into `bits`-wide samples, MSB first, rows padded to a byte.
    static func pack(_ v: [UInt8], _ w: Int, _ h: Int, _ bits: Int) -> [UInt8] {
        if bits == 8 { return v }
        let rb = (w * bits + 7) / 8
        var out = [UInt8](repeating: 0, count: rb * h)
        for y in 0..<h {
            for x in 0..<w {
                let bit = x * bits
                out[y * rb + bit / 8] |= v[y * w + x] << UInt8(8 - bits - bit % 8)
            }
        }
        return out
    }

    // MARK: palette

    static func paletteReps(_ px: [UInt8], _ w: Int, _ h: Int, options o: UPReduceOptions) -> [UPRep] {
        let n = w * h
        // colours in order of first appearance
        var index = [UInt32: Int]()
        var colors: [UInt32] = []
        var counts: [Int] = []
        var idx = [UInt8](repeating: 0, count: n)
        px.withUnsafeBufferPointer { p in
            var last: UInt32 = 0, lastI = -1
            for i in 0..<n {
                let c = UInt32(p[i * 4]) | UInt32(p[i * 4 + 1]) << 8 | UInt32(p[i * 4 + 2]) << 16 | UInt32(p[i * 4 + 3]) << 24
                var k: Int
                if lastI >= 0 && c == last { k = lastI } else if let e = index[c] { k = e } else { k = colors.count; index[c] = k; colors.append(c); counts.append(0) }
                last = c; lastI = k
                counts[k] += 1
                idx[i] = UInt8(truncatingIfNeeded: k)
            }
        }
        let m = colors.count
        guard m >= 1 && m <= 256 else { return [] }
        func luma(_ c: UInt32) -> Double {
            let a = Double(c >> 24) / 255
            return (0.2126 * Double(c & 255) + 0.7152 * Double(c >> 8 & 255) + 0.0722 * Double(c >> 16 & 255)) * a + 255 * (1 - a) * 0.0001
        }
        // co-occurrence of adjacent pixels (for the neighbour ordering)
        var co = [Int32](repeating: 0, count: m * m)
        if o.paletteOrders.contains(.neighbour) && m > 2 {
            for y in 0..<h {
                for x in 0..<w {
                    let a = Int(idx[y * w + x])
                    if x + 1 < w { let b = Int(idx[y * w + x + 1]); if a != b { co[a * m + b] += 1; co[b * m + a] += 1 } }
                    if y + 1 < h { let b = Int(idx[(y + 1) * w + x]); if a != b { co[a * m + b] += 1; co[b * m + a] += 1 } }
                }
            }
        }
        func dist2(_ a: UInt32, _ b: UInt32) -> Int {
            var d = 0
            for s in stride(from: 0, to: 32, by: 8) { let x = Int(a >> UInt32(s) & 255) - Int(b >> UInt32(s) & 255); d += x * x }
            return d
        }
        func order(_ kind: UPPaletteOrder) -> [Int] {   // new position → old index
            let all = Array(0..<m)
            switch kind {
            case .appearance: return all
            case .popularity: return all.sorted { counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1 }
            case .luminance: return all.sorted { luma(colors[$0]) != luma(colors[$1]) ? luma(colors[$0]) < luma(colors[$1]) : $0 < $1 }
            case .alphaLuminance:
                return all.sorted {
                    let a0 = colors[$0] >> 24, a1 = colors[$1] >> 24
                    if (a0 == 255) != (a1 == 255) { return a0 != 255 }
                    if a0 != a1 { return a0 < a1 }
                    return luma(colors[$0]) != luma(colors[$1]) ? luma(colors[$0]) < luma(colors[$1]) : $0 < $1
                }
            case .alphaPopularity:
                return all.sorted {
                    let t0 = colors[$0] >> 24 != 255, t1 = colors[$1] >> 24 != 255
                    if t0 != t1 { return t0 }
                    return counts[$0] != counts[$1] ? counts[$0] > counts[$1] : $0 < $1
                }
            case .neighbour:
                // greedy chain: always continue with the colour that most often touches the recently placed ones
                var placed = [Bool](repeating: false, count: m)
                var out: [Int] = []
                var cur = all.max { counts[$0] < counts[$1] } ?? 0
                placed[cur] = true; out.append(cur)
                while out.count < m {
                    var best = -1, bestScore = -1.0
                    let prev = out.count >= 2 ? out[out.count - 2] : -1
                    for c in 0..<m where !placed[c] {
                        var s = Double(co[cur * m + c])
                        if prev >= 0 { s += 0.5 * Double(co[prev * m + c]) }
                        if s > bestScore { bestScore = s; best = c }
                    }
                    if bestScore <= 0 {
                        // nothing adjacent: jump to the nearest colour instead
                        var bd = Int.max
                        for c in 0..<m where !placed[c] { let d = dist2(colors[cur], colors[c]); if d < bd { bd = d; best = c } }
                    }
                    placed[best] = true; out.append(best); cur = best
                }
                return out
            case .colourChain:
                // nearest-neighbour tour through colour space, starting at the darkest colour
                var placed = [Bool](repeating: false, count: m)
                var out: [Int] = []
                var cur = all.min { luma(colors[$0]) < luma(colors[$1]) } ?? 0
                placed[cur] = true; out.append(cur)
                while out.count < m {
                    var best = -1, bd = Int.max
                    for c in 0..<m where !placed[c] { let d = dist2(colors[cur], colors[c]); if d < bd { bd = d; best = c } }
                    placed[best] = true; out.append(best); cur = best
                }
                return out
            }
        }
        let bits = m <= 2 ? 1 : (m <= 4 ? 2 : (m <= 16 ? 4 : 8))
        var reps: [UPRep] = []
        var seenOrders = Set<[Int]>()
        for kind in o.paletteOrders {
            let ord = order(kind)
            guard seenOrders.insert(ord).inserted else { continue }
            var remap = [UInt8](repeating: 0, count: m)
            for (newI, oldI) in ord.enumerated() { remap[oldI] = UInt8(newI) }
            let pal = ord.map { colors[$0] }
            var v = [UInt8](repeating: 0, count: n)
            for i in 0..<n { v[i] = remap[Int(idx[i])] }
            reps.append(UPRep(width: w, height: h, colorType: 3, bitDepth: UInt8(bits), palette: pal, raw: pack(v, w, h, bits), label: "pal\(m)/\(bits)b·\(kind.rawValue)"))
            if bits < 8 && o.tryWidePalette {
                reps.append(UPRep(width: w, height: h, colorType: 3, bitDepth: 8, palette: pal, raw: v, label: "pal\(m)/8b·\(kind.rawValue)"))
            }
        }
        return reps
    }
}
