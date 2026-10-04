import Foundation

// Lumen's own JPEG encoder. macOS ImageIO always writes baseline JPEG with the standard Huffman tables and 4:2:0
// chroma (its "progressive" property is ignored), so the usual web optimisations are implemented here:
//   * Huffman tables optimised for the image (two-pass, length-limited with package-merge);
//   * progressive scans (spectral selection with end-of-band runs, each scan with its own tables; several scan
//     scripts are tried and the smallest kept);
//   * 4:4:4 or 4:2:0 chroma;
//   * a saliency-adaptive dead zone: AC coefficients in areas nobody looks at are rounded towards zero a little more.

enum WXJPEG {
    enum Subsampling { case s444, s420 }

    static let zigzag: [Int] = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
                                35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]
    static let lumaQ: [Int] = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
                               18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
    static let chromaQ: [Int] = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
                                 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99]

    static func table(_ base: [Int], quality: Int) -> [Int] {
        let q = max(1, min(100, quality))
        let scale = q < 50 ? 5000 / q : 200 - 2 * q
        return base.map { max(1, min(255, ($0 * scale + 50) / 100)) }
    }

    private static let cosT: [Float] = {
        var t = [Float](repeating: 0, count: 64)
        for u in 0..<8 { for x in 0..<8 { t[u * 8 + x] = cosf(Float(2 * x + 1) * Float(u) * .pi / 16) * (u == 0 ? 0.35355339 : 0.5) } }
        return t
    }()

    /// One colour component: quantised coefficients in natural (row-major) block order, zig-zag inside each block.
    final class Component {
        let id: UInt8
        let hs: Int, vs: Int           // sampling factors
        let tq: UInt8                  // quantisation table
        var blocksW = 0, blocksH = 0   // MCU-padded block grid
        var scanW = 0, scanH = 0       // block grid of a non-interleaved scan
        var coef: [Int16] = []
        init(id: UInt8, hs: Int, vs: Int, tq: UInt8) { self.id = id; self.hs = hs; self.vs = vs; self.tq = tq }
    }

    // MARK: bit writer (MSB first, byte stuffing)

    struct Bits {
        var bytes: [UInt8] = []
        private var acc: UInt32 = 0
        private var n = 0
        @inline(__always) mutating func put(_ v: Int, _ count: Int) {
            guard count > 0 else { return }
            acc = (acc << UInt32(count)) | (UInt32(truncatingIfNeeded: v) & ((1 << UInt32(count)) - 1))
            n += count
            while n >= 8 {
                let b = UInt8(truncatingIfNeeded: acc >> UInt32(n - 8))
                bytes.append(b)
                if b == 0xFF { bytes.append(0) }
                n -= 8
            }
        }
        mutating func flush() { if n > 0 { put(0x7F, 8 - n) } }
    }

    // MARK: Huffman

    struct Huff {
        var counts = [Int](repeating: 0, count: 257)
        var code = [UInt16](repeating: 0, count: 256)
        var size = [UInt8](repeating: 0, count: 256)
        var bits = [UInt8](repeating: 0, count: 17)     // number of codes of each length (1…16)
        var vals: [UInt8] = []

        /// Optimal code lengths ≤ 16 with the all-ones codeword reserved (JPEG forbids it).
        mutating func build() {
            var freq = [UInt32](repeating: 0, count: 288)
            for i in 0..<256 { freq[i] = UInt32(clamping: counts[i]) }
            freq[256] = 1                                   // dummy symbol takes the all-ones code
            if freq[0..<256].allSatisfy({ $0 == 0 }) { freq[0] = 1 }
            var len = [UInt8](repeating: 0, count: 288)
            let h = UPHuffman()
            freq.withUnsafeBufferPointer { f in len.withUnsafeMutableBufferPointer { l in h.lengths(f.baseAddress!, 288, maxBits: 16, out: l.baseAddress!) } }
            // the dummy must be the last code of the longest length
            let maxLen = len[0...256].max() ?? 1
            if len[256] < maxLen, let j = (0..<256).first(where: { len[$0] == maxLen }) { len.swapAt(256, j) }
            bits = [UInt8](repeating: 0, count: 17)
            vals = []
            for l in 1...16 {
                for s in 0..<256 where len[s] == UInt8(l) { vals.append(UInt8(s)); bits[l] += 1 }
            }
            // canonical codes
            var c = 0
            var k = 0
            for l in 1...16 {
                for _ in 0..<Int(bits[l]) {
                    let s = Int(vals[k])
                    code[s] = UInt16(c); size[s] = UInt8(l)
                    c += 1; k += 1
                }
                if l == Int(len[256]) { c += 1 }      // skip the dummy's slot
                c <<= 1
            }
        }

        func dht(_ tableClass: Int, _ id: Int) -> [UInt8] {
            var seg: [UInt8] = [0xFF, 0xC4]
            let len = 2 + 1 + 16 + vals.count
            seg += [UInt8(len >> 8), UInt8(len & 255), UInt8(tableClass << 4 | id)]
            seg += bits[1...16]
            seg += vals
            return seg
        }
    }

    @inline(__always) static func category(_ v: Int) -> Int { v == 0 ? 0 : 32 - Int(UInt32(abs(v)).leadingZeroBitCount) }

    // MARK: forward transform

    /// Planar YCbCr → quantised coefficients. `deadZone` (per block of the component, 0…1) moves AC rounding from 0.5 down to 0.36.
    static func transform(_ plane: [Float], _ pw: Int, _ ph: Int, _ comp: Component, q: [Int], deadZone: [Float]?) {
        let bw = pw / 8, bh = ph / 8
        comp.coef = [Int16](repeating: 0, count: bw * bh * 64)
        let cosT = WXJPEG.cosT
        let zz = zigzag
        plane.withUnsafeBufferPointer { p in
            comp.coef.withUnsafeMutableBufferPointer { out in
                cosT.withUnsafeBufferPointer { ct in
                    DispatchQueue.concurrentPerform(iterations: bh) { by in
                        var tmp = [Float](repeating: 0, count: 64), blk = [Float](repeating: 0, count: 64)
                        for bx in 0..<bw {
                            // rows
                            for y in 0..<8 {
                                let row = (by * 8 + y) * pw + bx * 8
                                for u in 0..<8 {
                                    var s: Float = 0
                                    for x in 0..<8 { s += (p[row + x] - 128) * ct[u * 8 + x] }
                                    tmp[y * 8 + u] = s
                                }
                            }
                            // columns
                            for u in 0..<8 {
                                for v in 0..<8 {
                                    var s: Float = 0
                                    for y in 0..<8 { s += tmp[y * 8 + u] * ct[v * 8 + y] }
                                    blk[v * 8 + u] = s
                                }
                            }
                            let dz = deadZone?[by * bw + bx] ?? 0
                            let rAC: Float = 0.5 - 0.14 * dz
                            let base = (by * bw + bx) * 64
                            for k in 0..<64 {
                                let n = zz[k]
                                let v = blk[n] / Float(q[n])
                                let r: Float = k == 0 ? 0.5 : rAC
                                let m = Int(abs(v) + r)
                                out[base + k] = Int16(v < 0 ? -m : m)
                            }
                        }
                    }
                }
            }
        }
        comp.blocksW = bw; comp.blocksH = bh
    }

    // MARK: scans

    struct Scan {
        var comps: [Int]        // component indices
        var ss: Int, se: Int
    }

    /// Codes one scan. With `huff == nil` only gathers symbol statistics into `stats`.
    private static func codeScan(_ scan: Scan, _ comps: [Component], mcuW: Int, mcuH: Int, dcStats: inout [Huff], acStats: inout [Huff], emit: Bool, bits: inout Bits, progressive: Bool) {
        var pred = [Int](repeating: 0, count: comps.count)
        var eobrun = 0
        var acTable = 0

        func flushEOB() {
            guard eobrun > 0 else { return }
            let nbits = 31 - Int(UInt32(eobrun).leadingZeroBitCount)
            let sym = nbits << 4
            if emit { bits.put(Int(acStats[acTable].code[sym]), Int(acStats[acTable].size[sym])); if nbits > 0 { bits.put(eobrun & ((1 << nbits) - 1), nbits) } }
            else { acStats[acTable].counts[sym] += 1 }
            eobrun = 0
        }

        func block(_ ci: Int, _ bx: Int, _ by: Int) {
            let c = comps[ci]
            let base = (by * c.blocksW + bx) * 64
            let dcT = ci == 0 ? 0 : 1, acT = ci == 0 ? 0 : 1
            if scan.ss == 0 {
                let v = Int(c.coef[base])
                let diff = v - pred[ci]
                pred[ci] = v
                let s = category(diff)
                if emit {
                    bits.put(Int(dcStats[dcT].code[s]), Int(dcStats[dcT].size[s]))
                    if s > 0 { bits.put(diff < 0 ? diff - 1 : diff, s) }
                } else { dcStats[dcT].counts[s] += 1 }
            }
            if scan.se == 0 { return }
            acTable = acT
            var run = 0
            let from = max(1, scan.ss)
            for k in from...scan.se {
                let v = Int(c.coef[base + k])
                if v == 0 { run += 1; continue }
                if progressive { flushEOB() }
                while run > 15 {
                    if emit { bits.put(Int(acStats[acT].code[0xF0]), Int(acStats[acT].size[0xF0])) } else { acStats[acT].counts[0xF0] += 1 }
                    run -= 16
                }
                let s = category(v)
                let sym = run << 4 | s
                if emit {
                    bits.put(Int(acStats[acT].code[sym]), Int(acStats[acT].size[sym]))
                    bits.put(v < 0 ? v - 1 : v, s)
                } else { acStats[acT].counts[sym] += 1 }
                run = 0
            }
            if run > 0 {
                if progressive {
                    eobrun += 1
                    if eobrun == 0x7FFF { flushEOB() }
                } else {
                    if emit { bits.put(Int(acStats[acT].code[0]), Int(acStats[acT].size[0])) } else { acStats[acT].counts[0] += 1 }
                }
            }
        }

        if scan.comps.count > 1 {
            for my in 0..<mcuH {
                for mx in 0..<mcuW {
                    for ci in scan.comps {
                        let c = comps[ci]
                        for v in 0..<c.vs { for h in 0..<c.hs { block(ci, mx * c.hs + h, my * c.vs + v) } }
                    }
                }
            }
        } else {
            let ci = scan.comps[0]
            let c = comps[ci]
            let single = comps.count == 1
            let bw = single ? c.blocksW : c.scanW, bh = single ? c.blocksH : c.scanH
            for by in 0..<bh { for bx in 0..<bw { block(ci, bx, by) } }
        }
        if progressive { flushEOB() }
    }

    private static func encodeScans(_ scans: [Scan], _ comps: [Component], mcuW: Int, mcuH: Int, progressive: Bool) -> [UInt8] {
        var out: [UInt8] = []
        for scan in scans {
            var dc = [Huff(), Huff()], ac = [Huff(), Huff()]
            var dummy = Bits()
            codeScan(scan, comps, mcuW: mcuW, mcuH: mcuH, dcStats: &dc, acStats: &ac, emit: false, bits: &dummy, progressive: progressive)
            let usesLuma = scan.comps.contains(0), usesChroma = scan.comps.contains { $0 > 0 }
            if scan.ss == 0 {
                if usesLuma { dc[0].build(); out += dc[0].dht(0, 0) }
                if usesChroma { dc[1].build(); out += dc[1].dht(0, 1) }
            }
            if scan.se > 0 {
                if usesLuma { ac[0].build(); out += ac[0].dht(1, 0) }
                if usesChroma { ac[1].build(); out += ac[1].dht(1, 1) }
            }
            out += [0xFF, 0xDA]
            let len = 6 + 2 * scan.comps.count
            out += [UInt8(len >> 8), UInt8(len & 255), UInt8(scan.comps.count)]
            for ci in scan.comps { out += [comps[ci].id, ci == 0 ? 0x00 : 0x11] }
            out += [UInt8(scan.ss), UInt8(progressive ? scan.se : 63), 0]
            var bits = Bits()
            codeScan(scan, comps, mcuW: mcuW, mcuH: mcuH, dcStats: &dc, acStats: &ac, emit: true, bits: &bits, progressive: progressive)
            bits.flush()
            out += bits.bytes
        }
        return out
    }

    /// Encodes an opaque image (alpha is ignored). `importance` (0…1 per pixel) enables the adaptive dead zone.
    static func encode(_ img: UPImage, quality: Int, subsampling: Subsampling, progressive: Bool, importance: [Float]? = nil, deadZone: Float = 0) -> Data? {
        let w = img.width, h = img.height
        guard w > 0, h > 0, w < 65536, h < 65536 else { return nil }
        let gray = UPReduce.analyse(img).gray
        let hmax = (!gray && subsampling == .s420) ? 2 : 1
        let mcu = 8 * hmax
        let mcuW = (w + mcu - 1) / mcu, mcuH = (h + mcu - 1) / mcu
        let pw = mcuW * mcu, ph = mcuH * mcu
        // colour planes, edge-replicated to whole MCUs
        var yP = [Float](repeating: 0, count: pw * ph)
        var cbFull = [Float](repeating: 0, count: gray ? 0 : pw * ph), crFull = cbFull
        img.px.withUnsafeBufferPointer { p in
            for y in 0..<ph {
                let sy = min(h - 1, y)
                for x in 0..<pw {
                    let o = (sy * w + min(w - 1, x)) * 4
                    let r = Float(p[o]), g = Float(p[o + 1]), b = Float(p[o + 2])
                    yP[y * pw + x] = 0.299 * r + 0.587 * g + 0.114 * b
                    if !gray {
                        cbFull[y * pw + x] = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
                        crFull[y * pw + x] = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
                    }
                }
            }
        }
        let ql = table(lumaQ, quality: quality), qc = table(chromaQ, quality: quality)
        var comps: [Component] = [Component(id: 1, hs: hmax, vs: hmax, tq: 0)]
        // dead-zone map per luma block
        func blockImportance(_ bw: Int, _ bh: Int, _ size: Int) -> [Float]? {
            guard let imp = importance, deadZone > 0 else { return nil }
            var out = [Float](repeating: 0, count: bw * bh)
            for by in 0..<bh {
                for bx in 0..<bw {
                    var s: Float = 0
                    var c: Float = 0
                    for yy in stride(from: by * size, to: min(h, by * size + size), by: 2) {
                        for xx in stride(from: bx * size, to: min(w, bx * size + size), by: 2) { s += imp[yy * w + xx]; c += 1 }
                    }
                    out[by * bw + bx] = c > 0 ? max(0, min(1, (1 - s / c) * deadZone)) : deadZone
                }
            }
            return out
        }
        transform(yP, pw, ph, comps[0], q: ql, deadZone: blockImportance(pw / 8, ph / 8, 8))
        comps[0].scanW = (w + 7) / 8; comps[0].scanH = (h + 7) / 8
        if !gray {
            var cw = pw, chh = ph
            var cb = cbFull, cr = crFull
            if hmax == 2 {
                cw = pw / 2; chh = ph / 2
                cb = [Float](repeating: 0, count: cw * chh); cr = cb
                for y in 0..<chh {
                    for x in 0..<cw {
                        let o = (y * 2) * pw + x * 2
                        cb[y * cw + x] = (cbFull[o] + cbFull[o + 1] + cbFull[o + pw] + cbFull[o + pw + 1]) * 0.25
                        cr[y * cw + x] = (crFull[o] + crFull[o + 1] + crFull[o + pw] + crFull[o + pw + 1]) * 0.25
                    }
                }
            }
            let dz = blockImportance(cw / 8, chh / 8, 8 * hmax)
            let c1 = Component(id: 2, hs: 1, vs: 1, tq: 1), c2 = Component(id: 3, hs: 1, vs: 1, tq: 1)
            transform(cb, cw, chh, c1, q: qc, deadZone: dz)
            transform(cr, cw, chh, c2, q: qc, deadZone: dz)
            let cwPix = (w + hmax - 1) / hmax, chPix = (h + hmax - 1) / hmax
            c1.scanW = (cwPix + 7) / 8; c1.scanH = (chPix + 7) / 8
            c2.scanW = c1.scanW; c2.scanH = c1.scanH
            comps += [c1, c2]
        }
        // header
        var out: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]
        func dqt(_ id: Int, _ t: [Int]) { out += [0xFF, 0xDB, 0, 67, UInt8(id)]; for k in 0..<64 { out.append(UInt8(t[zigzag[k]])) } }
        dqt(0, ql)
        if !gray { dqt(1, qc) }
        func sof(_ marker: UInt8) -> [UInt8] {
            var s: [UInt8] = [0xFF, marker]
            let len = 8 + 3 * comps.count
            s += [UInt8(len >> 8), UInt8(len & 255), 8, UInt8(h >> 8), UInt8(h & 255), UInt8(w >> 8), UInt8(w & 255), UInt8(comps.count)]
            for c in comps { s += [c.id, UInt8(c.hs << 4 | c.vs), c.tq] }
            return s
        }
        let all = Array(0..<comps.count)
        var bodies: [[UInt8]] = []
        // baseline with optimised tables
        bodies.append(sof(0xC0) + encodeScans([Scan(comps: all, ss: 0, se: 63)], comps, mcuW: mcuW, mcuH: mcuH, progressive: false))
        if progressive {
            // spectral-selection scripts; each band gets its own Huffman table and end-of-band runs
            let lumaBands: [[(Int, Int)]] = [[(1, 5), (6, 63)], [(1, 2), (3, 9), (10, 63)], [(1, 63)], [(1, 9), (10, 63)]]
            let chromaBands: [[(Int, Int)]] = [[(1, 63)], [(1, 5), (6, 63)]]
            let dcScan = encodeScans([Scan(comps: all, ss: 0, se: 0)], comps, mcuW: mcuW, mcuH: mcuH, progressive: true)
            func bandBytes(_ ci: Int, _ bands: [(Int, Int)]) -> [UInt8] {
                encodeScans(bands.map { Scan(comps: [ci], ss: $0.0, se: $0.1) }, comps, mcuW: mcuW, mcuH: mcuH, progressive: true)
            }
            var prog = sof(0xC2) + dcScan
            prog += lumaBands.map { bandBytes(0, $0) }.min { $0.count < $1.count } ?? []
            if !gray {
                for ci in 1...2 { prog += chromaBands.map { bandBytes(ci, $0) }.min { $0.count < $1.count } ?? [] }
            }
            bodies.append(prog)
        }
        out += bodies.min { $0.count < $1.count } ?? []
        out += [0xFF, 0xD9]
        return Data(out)
    }

    /// Reads SOF / scan facts from a JPEG for the report ("progressive 4:2:0, 7 scans").
    static func describe(_ data: Data) -> String {
        let b = [UInt8](data)
        var i = 2
        var kind = "", sampling = "", scans = 0
        while i + 4 < b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let m = b[i + 1]
            if m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01 || m == 0xFF || m == 0x00 { i += 2; continue }
            let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
            if m == 0xC0 || m == 0xC1 || m == 0xC2 {
                kind = m == 0xC2 ? "progressive" : "baseline"
                let nc = Int(b[i + 9])
                if nc == 1 { sampling = "gray" } else { sampling = (b[i + 11] >> 4) == 2 ? "4:2:0" : "4:4:4" }
            }
            if m == 0xDA {
                scans += 1
                i += 2 + len
                // skip entropy-coded data
                while i + 1 < b.count && !(b[i] == 0xFF && b[i + 1] != 0 && !(b[i + 1] >= 0xD0 && b[i + 1] <= 0xD7)) { i += 1 }
                continue
            }
            if m == 0xD9 { break }
            i += 2 + len
        }
        return "\(kind) \(sampling)" + (scans > 1 ? ", \(scans) scans" : "")
    }
}

enum WXJPEGSearch {
    struct Result {
        var data: Data
        var quality: UPQuality
        var setting: String
        var met: Bool
        var image: UPImage
    }

    /// Smallest JPEG that meets the target: quality searched separately for 4:2:0 and 4:4:4, progressive on,
    /// optimised tables, optional saliency dead zone.
    static func best(_ img: UPImage, target: UPQualityTarget, ref: UPMetricReference, maps: UPPerceptualMaps?, progress: UPProgress? = nil) -> Result? {
        var best: Result? = nil
        let variants: [(WXJPEG.Subsampling, Float)] = maps == nil ? [(.s420, 0), (.s444, 0)] : [(.s420, 0), (.s444, 0), (.s420, 1), (.s444, 1)]
        let results = UnsafeMutablePointer<Result?>.allocate(capacity: variants.count)
        results.initialize(repeating: nil, count: variants.count)
        defer { results.deinitialize(count: variants.count); results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: variants.count) { vi in
            let (sub, dz) = variants[vi]
            guard let r = WXAssistant.searchQuality(target, ref: ref, encode: { q in
                WXJPEG.encode(img, quality: max(1, Int((q * 100).rounded())), subsampling: sub, progressive: true, importance: maps?.importance, deadZone: dz)
            }, progress: progress) else { return }
            results[vi] = Result(data: r.data, quality: r.quality,
                                 setting: String(format: "quality %.0f, %@%@", r.q * 100, WXJPEG.describe(r.data), dz > 0 ? ", saliency dead zone" : ""), met: r.met, image: r.image)
        }
        for vi in 0..<variants.count {
            guard let r = results[vi] else { continue }
            if best == nil || (r.met && !best!.met) || (r.met == best!.met && r.data.count < best!.data.count) { best = r }
        }
        return best
    }
}
