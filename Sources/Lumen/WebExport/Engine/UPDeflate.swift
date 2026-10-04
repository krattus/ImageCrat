import Foundation

// Lumen "Ultra Deflate": an optimal-parse DEFLATE encoder written from scratch in the spirit of Zopfli.
//
//  * every position's match set (shortest distance for each achievable length) is found once, in parallel,
//    and cached, so the iterations below never search again;
//  * the input is cut into blocks where the symbol statistics change (recursive cost-minimising splitter);
//  * each block is parsed by a shortest-path search whose edge costs are the entropy of the previous
//    iteration's parse; the parse → statistics → parse loop runs `iterations` times (blocks in parallel),
//    with a small statistics perturbation when it stalls, and the cheapest real encoding is kept;
//  * Huffman code lengths are length-limited with package-merge, the code-length header is RLE-searched
//    (8 variants, with and without RLE-friendly count smoothing) and every block picks stored / fixed / dynamic.

// MARK: - Tables

enum UPDeflateTables {
    static let lenBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lenExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    static let clOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

    /// length (0...258) → litlen symbol (257...285)
    static let lenSym: UnsafeMutablePointer<UInt16> = {
        let p = UnsafeMutablePointer<UInt16>.allocate(capacity: 259)
        p.initialize(repeating: 0, count: 259)
        for s in 0..<29 {
            let hi = s == 28 ? 258 : lenBase[s] + (1 << lenExtra[s]) - 1
            for l in lenBase[s]...hi { p[l] = UInt16(257 + s) }
        }
        p[258] = 285
        return p
    }()
    static let lenExtraBits: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 259)
        p.initialize(repeating: 0, count: 259)
        for l in 3...258 { p[l] = UInt8(lenExtra[Int(lenSym[l]) - 257]) }
        return p
    }()
    /// distance (1...32768) → distance symbol (0...29)
    static let distSym: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 32769)
        p.initialize(repeating: 0, count: 32769)
        for s in 0..<30 {
            let hi = distBase[s] + (1 << distExtra[s]) - 1
            for d in distBase[s]...min(32768, hi) { p[d] = UInt8(s) }
        }
        return p
    }()
    static let distExtraBits: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
        p.initialize(repeating: 0, count: 32)
        for s in 0..<30 { p[s] = UInt8(distExtra[s]) }
        return p
    }()
}

// MARK: - Length-limited Huffman (package-merge)

/// Reusable scratch space for optimal length-limited code construction.
final class UPHuffman {
    private var keys = [UInt64](repeating: 0, count: 288)
    private var listA = [UInt64](repeating: 0, count: 600)
    private var listB = [UInt64](repeating: 0, count: 600)
    private var flags = [Bool](repeating: false, count: 17 * 600)
    private var listLen = [Int](repeating: 0, count: 18)

    /// Optimal code lengths (≤ maxBits) for `n` symbol counts; zero counts get length 0.
    func lengths(_ counts: UnsafePointer<UInt32>, _ n: Int, maxBits: Int, out: UnsafeMutablePointer<UInt8>) {
        var m = 0
        for i in 0..<n {
            out[i] = 0
            if counts[i] > 0 { keys[m] = UInt64(counts[i]) << 16 | UInt64(i); m += 1 }
        }
        if m == 0 { return }
        if m == 1 { out[Int(keys[0] & 0xFFFF)] = 1; return }
        if m == 2 { out[Int(keys[0] & 0xFFFF)] = 1; out[Int(keys[1] & 0xFFFF)] = 1; return }
        keys.withUnsafeMutableBufferPointer { k in
            var slice = UnsafeMutableBufferPointer(rebasing: k[0..<m])
            slice.sort()
            _ = slice
        }
        let want = 2 * m - 2
        keys.withUnsafeBufferPointer { k in
            listA.withUnsafeMutableBufferPointer { a in
                listB.withUnsafeMutableBufferPointer { b in
                    flags.withUnsafeMutableBufferPointer { fl in
                        var prev = a.baseAddress!, cur = b.baseAddress!
                        // level 1: the leaves
                        for i in 0..<m { prev[i] = k[i] >> 16; fl[i] = true }
                        var prevLen = m
                        listLen[1] = m
                        if maxBits >= 2 {
                            for level in 2...maxBits {
                                let packs = prevLen / 2
                                var li = 0, pi = 0, o = 0
                                let f = fl.baseAddress! + level * 600 - 600
                                while o < want && (li < m || pi < packs) {
                                    let lw = li < m ? k[li] >> 16 : UInt64.max
                                    let pw = pi < packs ? prev[2 * pi] &+ prev[2 * pi + 1] : UInt64.max
                                    if lw <= pw { cur[o] = lw; f[o] = true; li += 1 } else { cur[o] = pw; f[o] = false; pi += 1 }
                                    o += 1
                                }
                                prevLen = o
                                listLen[level] = o
                                swap(&prev, &cur)
                            }
                        }
                        var take = min(want, listLen[maxBits])
                        var level = maxBits
                        while level >= 1 && take > 0 {
                            let f = fl.baseAddress! + level * 600 - 600
                            var leaves = 0
                            for i in 0..<take where f[i] { leaves += 1 }
                            for i in 0..<leaves { out[Int(k[i] & 0xFFFF)] &+= 1 }
                            take = 2 * (take - leaves)
                            level -= 1
                        }
                    }
                }
            }
        }
    }

    /// Canonical codes, already bit-reversed for an LSB-first bit writer.
    static func codes(_ lengths: UnsafePointer<UInt8>, _ n: Int, out: UnsafeMutablePointer<UInt16>) {
        var blCount = [Int](repeating: 0, count: 17)
        for i in 0..<n { blCount[Int(lengths[i])] += 1 }
        blCount[0] = 0
        var next = [Int](repeating: 0, count: 17)
        var code = 0
        for b in 1...16 { code = (code + blCount[b - 1]) << 1; next[b] = code }
        for i in 0..<n {
            let l = Int(lengths[i])
            if l == 0 { out[i] = 0; continue }
            var c = next[l]; next[l] += 1
            var r = 0
            for _ in 0..<l { r = r << 1 | (c & 1); c >>= 1 }
            out[i] = UInt16(r)
        }
    }
}

// MARK: - Bit writer

struct UPBitWriter {
    var bytes: [UInt8] = []
    private var acc: UInt64 = 0
    private var nbits = 0

    @inline(__always) mutating func put(_ value: Int, _ count: Int) {
        acc |= UInt64(truncatingIfNeeded: value) << UInt64(nbits)
        nbits += count
        while nbits >= 8 { bytes.append(UInt8(truncatingIfNeeded: acc)); acc >>= 8; nbits -= 8 }
    }
    mutating func alignToByte() { if nbits > 0 { bytes.append(UInt8(truncatingIfNeeded: acc)); acc = 0; nbits = 0 } }
    var bitCount: Int { bytes.count * 8 + nbits }
}

// MARK: - LZ77 symbol stream

struct UPLZStore {
    /// literal byte, or match length (when `dist` > 0)
    var litlen: [UInt16] = []
    var dist: [UInt16] = []
    var count: Int { litlen.count }

    mutating func append(_ o: UPLZStore) { litlen.append(contentsOf: o.litlen); dist.append(contentsOf: o.dist) }
    mutating func reserve(_ n: Int) { litlen.reserveCapacity(n); dist.reserveCapacity(n) }
}

// MARK: - Match cache

/// For every input position: the (length, distance) breakpoints of its matches, ascending in both,
/// so that for any length L the smallest usable distance is that of the first breakpoint with length ≥ L.
final class UPMatchCache {
    let n: Int
    let data: UnsafePointer<UInt8>
    let start: UnsafeMutablePointer<UInt32>
    private(set) var lens: UnsafeMutablePointer<UInt16>
    private(set) var dists: UnsafeMutablePointer<UInt16>
    private(set) var total = 0
    static let maxPerPosition = 24

    init(data: UnsafePointer<UInt8>, count n: Int, maxChain: Int) {
        self.n = n
        self.data = data
        start = UnsafeMutablePointer<UInt32>.allocate(capacity: n + 1)
        lens = UnsafeMutablePointer<UInt16>.allocate(capacity: 1)
        dists = UnsafeMutablePointer<UInt16>.allocate(capacity: 1)
        guard n >= 3 else { for i in 0...n { start[i] = 0 }; return }
        // hash chains (sequential, O(n))
        let prev = UnsafeMutablePointer<Int32>.allocate(capacity: n)
        let head = UnsafeMutablePointer<Int32>.allocate(capacity: 65536)
        head.initialize(repeating: -1, count: 65536)
        defer { prev.deallocate(); head.deallocate() }
        for i in 0..<(n - 2) {
            let h = Int(((UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16) &* 0x9E37_79B1) >> 16)
            prev[i] = head[h]
            head[h] = Int32(i)
        }
        prev[n - 2] = -1; prev[n - 1] = -1
        // parallel match search
        let chunk = max(4096, min(1 << 16, n / (ProcessInfo.processInfo.activeProcessorCount * 4) + 1))
        let chunks = (n + chunk - 1) / chunk
        let counts = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
        defer { counts.deallocate() }
        let results = UnsafeMutablePointer<([UInt16], [UInt16])>.allocate(capacity: chunks)
        results.initialize(repeating: ([], []), count: chunks)
        defer { results.deinitialize(count: chunks); results.deallocate() }
        let cap = UPMatchCache.maxPerPosition
        let dsym = UPDeflateTables.distSym
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let lo = c * chunk, hi = min(n, lo + chunk)
            var ls = [UInt16](), ds = [UInt16]()
            ls.reserveCapacity((hi - lo) * 2); ds.reserveCapacity((hi - lo) * 2)
            for i in lo..<hi {
                let limit = min(258, n - i)
                if limit < 3 { counts[i] = 0; continue }
                let base = ls.count
                var best = 2
                var cand = prev[i]
                var chain = maxChain
                let cur = data + i
                while cand >= 0 {
                    let d = i - Int(cand)
                    if d > 32768 { break }
                    let cp = data + Int(cand)
                    if cp[best] == cur[best] && cp[0] == cur[0] {
                        var l = 0
                        var done = false
                        while l + 8 <= limit {
                            let a = UnsafeRawPointer(cur + l).loadUnaligned(as: UInt64.self)
                            let b = UnsafeRawPointer(cp + l).loadUnaligned(as: UInt64.self)
                            if a != b { l += (a ^ b).trailingZeroBitCount >> 3; done = true; break }
                            l += 8
                        }
                        if !done { while l < limit && cur[l] == cp[l] { l += 1 } }
                        if l > best {
                            best = l
                            if ls.count - base == cap {
                                // keep the table bounded: drop a breakpoint whose distance code equals its successor's
                                var drop = base
                                for k in base..<(ls.count - 1) where dsym[Int(ds[k])] == dsym[Int(ds[k + 1])] { drop = k; break }
                                ls.remove(at: drop); ds.remove(at: drop)
                            }
                            ls.append(UInt16(l)); ds.append(UInt16(d))
                            if l >= limit { break }
                        }
                    }
                    chain -= 1
                    if chain == 0 { break }
                    cand = prev[Int(cand)]
                }
                counts[i] = UInt8(ls.count - base)
            }
            results[c] = (ls, ds)
        }
        var sum = 0
        for i in 0..<n { start[i] = UInt32(sum); sum += Int(counts[i]) }
        start[n] = UInt32(sum)
        total = sum
        lens.deallocate(); dists.deallocate()
        lens = UnsafeMutablePointer<UInt16>.allocate(capacity: max(1, sum))
        dists = UnsafeMutablePointer<UInt16>.allocate(capacity: max(1, sum))
        let lp = lens, dp = dists
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let off = Int(start[c * chunk])
            let r = results[c]
            r.0.withUnsafeBufferPointer { b in if b.count > 0 { (lp + off).update(from: b.baseAddress!, count: b.count) } }
            r.1.withUnsafeBufferPointer { b in if b.count > 0 { (dp + off).update(from: b.baseAddress!, count: b.count) } }
        }
    }

    deinit { start.deallocate(); lens.deallocate(); dists.deallocate() }
}

// MARK: - Block statistics and sizes

struct UPSymbolStats {
    var ll = [UInt32](repeating: 0, count: 288)
    var d = [UInt32](repeating: 0, count: 32)

    mutating func clear() {
        for i in 0..<288 { ll[i] = 0 }
        for i in 0..<32 { d[i] = 0 }
    }
}

/// Bit costs used by the shortest-path parse.
final class UPCostModel {
    let lit = UnsafeMutablePointer<Float>.allocate(capacity: 256)
    let len = UnsafeMutablePointer<Float>.allocate(capacity: 259)
    let dist = UnsafeMutablePointer<Float>.allocate(capacity: 32)
    deinit { lit.deallocate(); len.deallocate(); dist.deallocate() }

    /// Entropy of the given statistics (fractional bits); unseen symbols cost log2(total).
    func set(from s: UPSymbolStats) {
        var sumLL = 0.0, sumD = 0.0
        for i in 0..<288 { sumLL += Double(s.ll[i]) }
        for i in 0..<30 { sumD += Double(s.d[i]) }
        let lsum = sumLL > 0 ? log2(sumLL) : 0, dsum = sumD > 0 ? log2(sumD) : 0
        func bits(_ c: UInt32, _ l: Double) -> Float { c == 0 ? Float(max(l, 1)) : Float(max(0, l - log2(Double(c)))) }
        for i in 0..<256 { lit[i] = bits(s.ll[i], lsum) }
        let ls = UPDeflateTables.lenSym, le = UPDeflateTables.lenExtraBits
        len[0] = 0; len[1] = 0; len[2] = 0
        for l in 3...258 { len[l] = bits(s.ll[Int(ls[l])], lsum) + Float(le[l]) }
        for i in 0..<30 { dist[i] = bits(s.d[i], dsum) + Float(UPDeflateTables.distExtra[i]) }
        dist[30] = 100; dist[31] = 100
    }

    /// The fixed Huffman code of DEFLATE.
    func setFixed() {
        for i in 0..<256 { lit[i] = i < 144 ? 8 : 9 }
        let ls = UPDeflateTables.lenSym, le = UPDeflateTables.lenExtraBits
        len[0] = 0; len[1] = 0; len[2] = 0
        for l in 3...258 { len[l] = (ls[l] < 280 ? 7 : 8) + Float(le[l]) }
        for i in 0..<30 { dist[i] = 5 + Float(UPDeflateTables.distExtra[i]) }
        dist[30] = 100; dist[31] = 100
    }
}

/// Exact block size computation and emission (one instance per thread).
final class UPBlockCoder {
    let huff = UPHuffman()
    private var llLen = [UInt8](repeating: 0, count: 288)
    private var dLen = [UInt8](repeating: 0, count: 32)
    private var llLen2 = [UInt8](repeating: 0, count: 288)
    private var dLen2 = [UInt8](repeating: 0, count: 32)
    private var tmpLL = [UInt32](repeating: 0, count: 288)
    private var tmpD = [UInt32](repeating: 0, count: 32)
    private var rle = [UInt16](repeating: 0, count: 330)
    private var rleExtra = [UInt16](repeating: 0, count: 330)
    private var clCounts = [UInt32](repeating: 0, count: 19)
    private var clLen = [UInt8](repeating: 0, count: 19)
    private var clCodes = [UInt16](repeating: 0, count: 19)

    static func stats(_ s: UPLZStore, _ a: Int, _ b: Int, into st: inout UPSymbolStats) {
        st.clear()
        let ls = UPDeflateTables.lenSym, ds = UPDeflateTables.distSym
        s.litlen.withUnsafeBufferPointer { ll in
            s.dist.withUnsafeBufferPointer { dd in
                st.ll.withUnsafeMutableBufferPointer { cl in
                    st.d.withUnsafeMutableBufferPointer { cd in
                        for i in a..<b {
                            let d = Int(dd[i])
                            if d == 0 { cl[Int(ll[i])] &+= 1 } else { cl[Int(ls[Int(ll[i])])] &+= 1; cd[Int(ds[d])] &+= 1 }
                        }
                    }
                }
            }
        }
        st.ll[256] = 1
    }

    /// Smooths symbol counts so the code-length sequence run-length-encodes better (the classic RLE-friendly heuristic).
    static func optimizeForRLE(_ counts: UnsafeMutablePointer<UInt32>, _ fullLength: Int) {
        var length = fullLength
        while length > 0 && counts[length - 1] == 0 { length -= 1 }
        if length == 0 { return }
        var good = [Bool](repeating: false, count: length)
        var symbol = counts[0]
        var stride = 0
        for i in 0...length {
            if i == length || counts[i] != symbol {
                if (symbol == 0 && stride >= 5) || (symbol != 0 && stride >= 7) { for k in 0..<stride { good[i - k - 1] = true } }
                stride = 1
                if i != length { symbol = counts[i] }
            } else { stride += 1 }
        }
        stride = 0
        var limit = Int(counts[0])
        var sum = 0
        for i in 0...length {
            if i == length || good[i] || abs(Int(counts[i]) - limit) >= 4 {
                if stride >= 4 || (stride >= 3 && sum == 0) {
                    var count = (sum + stride / 2) / stride
                    if count < 1 { count = 1 }
                    if sum == 0 { count = 0 }
                    for k in 0..<stride { counts[i - k - 1] = UInt32(count) }
                }
                stride = 0; sum = 0
                if i < length - 3 { limit = (Int(counts[i]) + Int(counts[i + 1]) + Int(counts[i + 2]) + Int(counts[i + 3]) + 2) / 4 }
                else if i < length { limit = Int(counts[i]) } else { limit = 0 }
            }
            stride += 1
            if i != length { sum += Int(counts[i]) }
        }
    }

    /// Header cost / emission for one RLE variant. Returns the size in bits.
    private func encodeTree(_ ll: UnsafePointer<UInt8>, _ d: UnsafePointer<UInt8>, use16: Bool, use17: Bool, use18: Bool, writer: UnsafeMutablePointer<UPBitWriter>?) -> Int {
        var hlit = 29, hdist = 29
        while hlit > 0 && ll[257 + hlit - 1] == 0 { hlit -= 1 }
        while hdist > 0 && d[1 + hdist - 1] == 0 { hdist -= 1 }
        let hlit2 = hlit + 257
        let total = hlit2 + hdist + 1
        for i in 0..<19 { clCounts[i] = 0 }
        var n = 0
        var i = 0
        @inline(__always) func at(_ k: Int) -> UInt8 { k < hlit2 ? ll[k] : d[k - hlit2] }
        while i < total {
            let sym = at(i)
            var count = 1
            if use16 || (sym == 0 && (use17 || use18)) {
                var j = i + 1
                while j < total && at(j) == sym { count += 1; j += 1 }
            }
            i += count - 1
            if sym == 0 && count >= 3 {
                if use18 {
                    while count >= 11 {
                        let c = min(count, 138)
                        rle[n] = 18; rleExtra[n] = UInt16(c - 11); n += 1; clCounts[18] += 1
                        count -= c
                    }
                }
                if use17 {
                    while count >= 3 {
                        let c = min(count, 10)
                        rle[n] = 17; rleExtra[n] = UInt16(c - 3); n += 1; clCounts[17] += 1
                        count -= c
                    }
                }
            }
            if use16 && count >= 4 {
                count -= 1
                clCounts[Int(sym)] += 1
                rle[n] = UInt16(sym); rleExtra[n] = 0; n += 1
                while count >= 3 {
                    let c = min(count, 6)
                    rle[n] = 16; rleExtra[n] = UInt16(c - 3); n += 1; clCounts[16] += 1
                    count -= c
                }
            }
            clCounts[Int(sym)] += UInt32(count)
            while count > 0 { rle[n] = UInt16(sym); rleExtra[n] = 0; n += 1; count -= 1 }
            i += 1
        }
        clCounts.withUnsafeBufferPointer { c in clLen.withUnsafeMutableBufferPointer { l in huff.lengths(c.baseAddress!, 19, maxBits: 7, out: l.baseAddress!) } }
        var hclen = 15
        while hclen > 0 && clCounts[UPDeflateTables.clOrder[hclen + 4 - 1]] == 0 { hclen -= 1 }
        var size = 14 + (hclen + 4) * 3
        for k in 0..<19 { size += Int(clLen[k]) * Int(clCounts[k]) }
        size += Int(clCounts[16]) * 2 + Int(clCounts[17]) * 3 + Int(clCounts[18]) * 7
        if let w = writer {
            clLen.withUnsafeBufferPointer { l in clCodes.withUnsafeMutableBufferPointer { c in UPHuffman.codes(l.baseAddress!, 19, out: c.baseAddress!) } }
            w.pointee.put(hlit, 5); w.pointee.put(hdist, 5); w.pointee.put(hclen, 4)
            for k in 0..<(hclen + 4) { w.pointee.put(Int(clLen[UPDeflateTables.clOrder[k]]), 3) }
            for k in 0..<n {
                let s = Int(rle[k])
                w.pointee.put(Int(clCodes[s]), Int(clLen[s]))
                if s == 16 { w.pointee.put(Int(rleExtra[k]), 2) } else if s == 17 { w.pointee.put(Int(rleExtra[k]), 3) } else if s == 18 { w.pointee.put(Int(rleExtra[k]), 7) }
            }
        }
        return size
    }

    private func bestTree(_ ll: UnsafePointer<UInt8>, _ d: UnsafePointer<UInt8>) -> (bits: Int, variant: Int) {
        var best = Int.max, bv = 0
        for v in 0..<8 {
            let s = encodeTree(ll, d, use16: v & 1 != 0, use17: v & 2 != 0, use18: v & 4 != 0, writer: nil)
            if s < best { best = s; bv = v }
        }
        return (best, bv)
    }

    private static func dataBits(_ st: UPSymbolStats, _ ll: UnsafePointer<UInt8>, _ d: UnsafePointer<UInt8>) -> Int {
        var bits = 0
        for i in 0..<286 where st.ll[i] > 0 { bits += Int(st.ll[i]) * Int(ll[i]) }
        for i in 265..<285 where st.ll[i] > 0 { bits += Int(st.ll[i]) * UPDeflateTables.lenExtra[i - 257] }
        for i in 0..<30 where st.d[i] > 0 { bits += Int(st.d[i]) * (Int(d[i]) + UPDeflateTables.distExtra[i]) }
        return bits
    }

    /// DEFLATE needs at least one distance code; two keep old decoders happy.
    private static func patchDistanceCodes(_ d: UnsafeMutablePointer<UInt8>) {
        var used = 0
        for i in 0..<30 where d[i] > 0 { used += 1; if used >= 2 { return } }
        if used == 0 { d[0] = 1; d[1] = 1 } else if used == 1 { d[d[0] > 0 ? 1 : 0] = 1 }
    }

    /// Chooses code lengths for the statistics (plain vs. RLE-smoothed counts) and returns the dynamic block size in bits
    /// (3 header bits included). The chosen lengths stay in `llLen` / `dLen`.
    func dynamicBits(_ st: UPSymbolStats) -> Int {
        var bestBits = 0
        st.ll.withUnsafeBufferPointer { cl in
            st.d.withUnsafeBufferPointer { cd in
                llLen.withUnsafeMutableBufferPointer { l1 in
                    dLen.withUnsafeMutableBufferPointer { d1 in
                        huff.lengths(cl.baseAddress!, 288, maxBits: 15, out: l1.baseAddress!)
                        huff.lengths(cd.baseAddress!, 30, maxBits: 15, out: d1.baseAddress!)
                        d1[30] = 0; d1[31] = 0
                        UPBlockCoder.patchDistanceCodes(d1.baseAddress!)
                    }
                }
            }
        }
        let plain: Int = llLen.withUnsafeBufferPointer { l in dLen.withUnsafeBufferPointer { d in
            bestTree(l.baseAddress!, d.baseAddress!).bits + UPBlockCoder.dataBits(st, l.baseAddress!, d.baseAddress!) } }
        // RLE-friendly variant
        for i in 0..<288 { tmpLL[i] = st.ll[i] }
        for i in 0..<32 { tmpD[i] = st.d[i] }
        tmpLL.withUnsafeMutableBufferPointer { UPBlockCoder.optimizeForRLE($0.baseAddress!, 288) }
        tmpD.withUnsafeMutableBufferPointer { UPBlockCoder.optimizeForRLE($0.baseAddress!, 30) }
        tmpLL.withUnsafeBufferPointer { cl in
            tmpD.withUnsafeBufferPointer { cd in
                llLen2.withUnsafeMutableBufferPointer { l2 in
                    dLen2.withUnsafeMutableBufferPointer { d2 in
                        huff.lengths(cl.baseAddress!, 288, maxBits: 15, out: l2.baseAddress!)
                        huff.lengths(cd.baseAddress!, 30, maxBits: 15, out: d2.baseAddress!)
                        d2[30] = 0; d2[31] = 0
                        UPBlockCoder.patchDistanceCodes(d2.baseAddress!)
                    }
                }
            }
        }
        // the smoothed code must still cover every used symbol
        var covers = true
        for i in 0..<286 where st.ll[i] > 0 && llLen2[i] == 0 { covers = false }
        for i in 0..<30 where st.d[i] > 0 && dLen2[i] == 0 { covers = false }
        let smooth: Int = covers ? llLen2.withUnsafeBufferPointer { l in dLen2.withUnsafeBufferPointer { d in
            bestTree(l.baseAddress!, d.baseAddress!).bits + UPBlockCoder.dataBits(st, l.baseAddress!, d.baseAddress!) } } : Int.max
        if smooth < plain {
            swap(&llLen, &llLen2); swap(&dLen, &dLen2)
            bestBits = smooth
        } else { bestBits = plain }
        return bestBits + 3
    }

    static func fixedBits(_ st: UPSymbolStats) -> Int {
        var bits = 3
        for i in 0..<144 { bits += Int(st.ll[i]) * 8 }
        for i in 144..<256 { bits += Int(st.ll[i]) * 9 }
        for i in 256..<280 { bits += Int(st.ll[i]) * 7 }
        for i in 280..<288 { bits += Int(st.ll[i]) * 8 }
        for i in 265..<285 { bits += Int(st.ll[i]) * UPDeflateTables.lenExtra[i - 257] }
        for i in 0..<30 { bits += Int(st.d[i]) * (5 + UPDeflateTables.distExtra[i]) }
        return bits
    }

    static func storedBits(_ byteCount: Int) -> Int {
        let pieces = max(1, (byteCount + 65534) / 65535)
        return pieces * 40 + byteCount * 8      // 3 header bits + up to 5 pad + 32 (upper bound with padding)
    }

    /// Smallest of dynamic / fixed for these statistics (used by the splitter).
    func autoBits(_ st: UPSymbolStats, symbolCount: Int) -> Int {
        let dyn = dynamicBits(st)
        if symbolCount > 1000 { return dyn }
        return min(dyn, UPBlockCoder.fixedBits(st))
    }

    /// Writes symbols [a, b) as a dynamic (type 2) or fixed (type 1) block.
    func emit(_ s: UPLZStore, _ a: Int, _ b: Int, fixed: Bool, final: Bool, into w: inout UPBitWriter) {
        var st = UPSymbolStats()
        UPBlockCoder.stats(s, a, b, into: &st)
        var llCodes = [UInt16](repeating: 0, count: 288), dCodes = [UInt16](repeating: 0, count: 32)
        w.put(final ? 1 : 0, 1)
        if fixed {
            w.put(1, 2)
            for i in 0..<288 { llLen[i] = i < 144 ? 8 : (i < 256 ? 9 : (i < 280 ? 7 : 8)) }
            for i in 0..<32 { dLen[i] = 5 }
        } else {
            w.put(2, 2)
            _ = dynamicBits(st)
            llLen.withUnsafeBufferPointer { l in dLen.withUnsafeBufferPointer { d in
                let v = bestTree(l.baseAddress!, d.baseAddress!).variant
                withUnsafeMutablePointer(to: &w) { wp in
                    _ = encodeTree(l.baseAddress!, d.baseAddress!, use16: v & 1 != 0, use17: v & 2 != 0, use18: v & 4 != 0, writer: wp)
                }
            } }
        }
        llLen.withUnsafeBufferPointer { l in llCodes.withUnsafeMutableBufferPointer { c in UPHuffman.codes(l.baseAddress!, 288, out: c.baseAddress!) } }
        dLen.withUnsafeBufferPointer { l in dCodes.withUnsafeMutableBufferPointer { c in UPHuffman.codes(l.baseAddress!, 32, out: c.baseAddress!) } }
        let ls = UPDeflateTables.lenSym, le = UPDeflateTables.lenExtraBits, ds = UPDeflateTables.distSym
        for i in a..<b {
            let d = Int(s.dist[i]), v = Int(s.litlen[i])
            if d == 0 {
                w.put(Int(llCodes[v]), Int(llLen[v]))
            } else {
                let sym = Int(ls[v])
                w.put(Int(llCodes[sym]), Int(llLen[sym]))
                let eb = Int(le[v])
                if eb > 0 { w.put(v - UPDeflateTables.lenBase[sym - 257], eb) }
                let dsy = Int(ds[d])
                w.put(Int(dCodes[dsy]), Int(dLen[dsy]))
                let deb = UPDeflateTables.distExtra[dsy]
                if deb > 0 { w.put(d - UPDeflateTables.distBase[dsy], deb) }
            }
        }
        w.put(Int(llCodes[256]), Int(llLen[256]))
    }
}

// MARK: - Encoder

struct UPUltraDeflateOptions {
    /// Parse → statistics → parse rounds per block (the quality knob; 1 = a single optimal parse).
    var iterations = 15
    /// Hash-chain depth of the match search.
    var maxChain = 2048
    /// Upper bound for the number of blocks.
    var maxBlocks = 0      // 0 = automatic (grows with the input size)
}

enum UPUltraDeflate {
    /// Raw DEFLATE stream (no zlib header) of `src`.
    static func compress(_ src: UnsafeBufferPointer<UInt8>, options o: UPUltraDeflateOptions = UPUltraDeflateOptions(), progress: UPProgress? = nil) -> [UInt8] {
        let n = src.count
        var w = UPBitWriter()
        guard n > 0, let data = src.baseAddress else {
            w.put(1, 1); w.put(1, 2); w.put(0, 7)       // empty fixed block
            w.alignToByte()
            return w.bytes
        }
        let cache = UPMatchCache(data: data, count: n, maxChain: o.maxChain)
        if progress?.cancelled == true { return [] }
        // 1. greedy parse of everything → first block split
        let greedy = greedyParse(cache, 0, n)
        let maxBlocks = o.maxBlocks > 0 ? o.maxBlocks : max(15, min(400, n / 12000))
        let coder = UPBlockCoder()
        let split1 = splitStore(greedy.store, maxBlocks: maxBlocks, coder: coder)
        var bounds: [Int] = [0]
        for s in split1 { bounds.append(greedy.positions[s]) }
        bounds.append(n)
        // 2. optimal parse per block, in parallel
        let nb = bounds.count - 1
        let results = UnsafeMutablePointer<UPLZStore>.allocate(capacity: nb)
        results.initialize(repeating: UPLZStore(), count: nb)
        defer { results.deinitialize(count: nb); results.deallocate() }
        let doneLock = NSLock()
        var doneBytes = 0
        DispatchQueue.concurrentPerform(iterations: nb) { b in
            if progress?.cancelled == true { return }
            results[b] = optimalParse(cache, bounds[b], bounds[b + 1], iterations: o.iterations, progress: progress)
            if let p = progress {
                doneLock.lock(); doneBytes += bounds[b + 1] - bounds[b]; let f = Double(doneBytes) / Double(n); doneLock.unlock()
                p.report(f, "Optimal deflate")
            }
        }
        if progress?.cancelled == true { return [] }
        var store = UPLZStore()
        var blockEnds: [Int] = []          // symbol index where each block ends
        for b in 0..<nb {
            store.append(results[b])
            blockEnds.append(store.count)
        }
        // 3. re-split on the optimised symbols and keep whichever boundary set is smaller
        func totalBits(_ ends: [Int]) -> Int {
            var bits = 0, a = 0
            var st = UPSymbolStats()
            for e in ends {
                UPBlockCoder.stats(store, a, e, into: &st)
                let dyn = coder.dynamicBits(st), fix = UPBlockCoder.fixedBits(st)
                bits += min(dyn, fix)
                a = e
            }
            return bits
        }
        var ends = blockEnds
        if store.count > 0 {
            let split2 = splitStore(store, maxBlocks: maxBlocks, coder: coder)
            let ends2 = split2 + [store.count]
            if totalBits(ends2) < totalBits(ends) { ends = ends2 }
        }
        // 4. emit; each block picks dynamic / fixed / stored
        var byteStart = 0
        var a = 0
        var st = UPSymbolStats()
        for (k, e) in ends.enumerated() {
            let final = k == ends.count - 1
            UPBlockCoder.stats(store, a, e, into: &st)
            var blockBytes = 0
            for i in a..<e { blockBytes += store.dist[i] == 0 ? 1 : Int(store.litlen[i]) }
            let dyn = coder.dynamicBits(st)
            var fix = UPBlockCoder.fixedBits(st)
            // small blocks: a parse made for the fixed code can beat both
            var fixedStore: UPLZStore? = nil
            if e - a < 1000 || Double(fix) <= Double(dyn) * 1.1 {
                let fs = optimalParseFixed(cache, byteStart, byteStart + blockBytes)
                var fst = UPSymbolStats()
                UPBlockCoder.stats(fs, 0, fs.count, into: &fst)
                let fb = UPBlockCoder.fixedBits(fst)
                if fb < fix { fix = fb; fixedStore = fs }
            }
            let stored = UPBlockCoder.storedBits(blockBytes)
            if stored < dyn && stored < fix {
                var off = byteStart, left = blockBytes
                repeat {
                    let c = min(left, 65535)
                    w.put(final && left == c ? 1 : 0, 1); w.put(0, 2)
                    w.alignToByte()
                    w.put(c, 16); w.put(~c & 0xFFFF, 16)
                    for i in 0..<c { w.bytes.append(data[off + i]) }
                    off += c; left -= c
                } while left > 0
            } else if fix <= dyn {
                if let fs = fixedStore { coder.emit(fs, 0, fs.count, fixed: true, final: final, into: &w) }
                else { coder.emit(store, a, e, fixed: true, final: final, into: &w) }
            } else {
                coder.emit(store, a, e, fixed: false, final: final, into: &w)
            }
            byteStart += blockBytes
            a = e
        }
        w.alignToByte()
        return w.bytes
    }

    // MARK: greedy (lazy) parse

    static func greedyParse(_ c: UPMatchCache, _ start: Int, _ end: Int) -> (store: UPLZStore, positions: [Int]) {
        var s = UPLZStore()
        var pos: [Int] = []
        s.reserve((end - start) / 3 + 16); pos.reserveCapacity((end - start) / 3 + 16)
        let data = c.data, st = c.start, lens = c.lens, dists = c.dists
        @inline(__always) func longest(_ i: Int) -> (Int, Int) {
            let a = Int(st[i]), b = Int(st[i + 1])
            if b == a { return (0, 0) }
            var l = Int(lens[b - 1])
            let d = Int(dists[b - 1])
            if l > end - i { l = end - i }
            return (l, d)
        }
        @inline(__always) func score(_ l: Int, _ d: Int) -> Int { d > 1024 ? l - 1 : l }
        var i = start
        while i < end {
            let (l, d) = longest(i)
            if l >= 3 && !(l == 3 && d > 1024) {
                if i + 1 < end && l < 258 {
                    let (l2, d2) = longest(i + 1)
                    if l2 >= 3 && score(l2, d2) > score(l, d) + 1 {
                        s.litlen.append(UInt16(data[i])); s.dist.append(0); pos.append(i)
                        i += 1
                        continue
                    }
                }
                s.litlen.append(UInt16(l)); s.dist.append(UInt16(d)); pos.append(i)
                i += l
            } else {
                s.litlen.append(UInt16(data[i])); s.dist.append(0); pos.append(i)
                i += 1
            }
        }
        return (s, pos)
    }

    // MARK: shortest-path parse

    private final class ParseScratch {
        var costs: UnsafeMutablePointer<Float>
        var lenArr: UnsafeMutablePointer<UInt16>
        var distArr: UnsafeMutablePointer<UInt16>
        init(_ n: Int) {
            costs = .allocate(capacity: n + 1); lenArr = .allocate(capacity: n + 1); distArr = .allocate(capacity: n + 1)
        }
        deinit { costs.deallocate(); lenArr.deallocate(); distArr.deallocate() }
    }

    /// One shortest-path parse of [start, end) under the given costs.
    private static func shortestPath(_ c: UPMatchCache, _ start: Int, _ end: Int, _ model: UPCostModel, _ sc: ParseScratch, into out: inout UPLZStore) {
        let n = end - start
        let costs = sc.costs, lenArr = sc.lenArr, distArr = sc.distArr
        let data = c.data, st = c.start, lens = c.lens, dists = c.dists
        let lit = model.lit, lenC = model.len, distC = model.dist
        let dsym = UPDeflateTables.distSym
        costs[0] = 0
        for j in 1...n { costs[j] = .greatestFiniteMagnitude }
        var j = 0
        let run258 = lenC[258] + distC[0]
        while j < n {
            let i = start + j
            let base = costs[j]
            // long run of one byte: jump in maximal matches at distance 1 (avoids 258 relaxations per byte)
            let a = Int(st[i]), b = Int(st[i + 1])
            if b - a == 1, lens[a] == 258, dists[a] == 1, j + 258 * 2 + 1 < n, j > 258 {
                let a2 = Int(st[i + 258]), b2 = Int(st[i + 259])
                let a0 = Int(st[i - 258])
                if b2 - a2 == 1, lens[a2] == 258, dists[a2] == 1, Int(st[i - 257]) - a0 == 1, lens[a0] == 258, dists[a0] == 1 {
                    for _ in 0..<258 {
                        let c2 = costs[j] + run258
                        if c2 < costs[j + 258] { costs[j + 258] = c2; lenArr[j + 258] = 258; distArr[j + 258] = 1 }
                        // literals still need a path for the positions in between
                        let cl = costs[j] + lit[Int(data[start + j])]
                        if cl < costs[j + 1] { costs[j + 1] = cl; lenArr[j + 1] = 1; distArr[j + 1] = 0 }
                        j += 1
                    }
                    continue
                }
            }
            let cl = base + lit[Int(data[i])]
            if cl < costs[j + 1] { costs[j + 1] = cl; lenArr[j + 1] = 1; distArr[j + 1] = 0 }
            if b > a {
                var l = 3
                let room = n - j
                var k = a
                while k < b {
                    let d = dists[k]
                    let top = min(Int(lens[k]), room)
                    let dc = base + distC[Int(dsym[Int(d)])]
                    while l <= top {
                        let cc = dc + lenC[l]
                        if cc < costs[j + l] { costs[j + l] = cc; lenArr[j + l] = UInt16(l); distArr[j + l] = d }
                        l += 1
                    }
                    k += 1
                }
            }
            j += 1
        }
        // trace back
        var count = 0
        j = n
        while j > 0 { j -= Int(lenArr[j]); count += 1 }
        out.litlen = [UInt16](repeating: 0, count: count)
        out.dist = [UInt16](repeating: 0, count: count)
        j = n
        var k = count - 1
        out.litlen.withUnsafeMutableBufferPointer { ll in
            out.dist.withUnsafeMutableBufferPointer { dd in
                while j > 0 {
                    let l = Int(lenArr[j])
                    j -= l
                    if l == 1 { ll[k] = UInt16(data[start + j]); dd[k] = 0 } else { ll[k] = UInt16(l); dd[k] = distArr[j + l] }
                    k -= 1
                }
            }
        }
    }

    static func optimalParseFixed(_ c: UPMatchCache, _ start: Int, _ end: Int) -> UPLZStore {
        var out = UPLZStore()
        guard end > start else { return out }
        let model = UPCostModel()
        model.setFixed()
        shortestPath(c, start, end, model, ParseScratch(end - start), into: &out)
        return out
    }

    /// Iterated optimal parse of one block. Two starting points are explored: the statistics of a greedy parse
    /// (match-friendly) and the pure literal histogram (entropy-friendly — what noisy photographic data wants);
    /// the cheapest real encoding seen anywhere wins.
    static func optimalParse(_ c: UPMatchCache, _ start: Int, _ end: Int, iterations: Int, progress: UPProgress? = nil) -> UPLZStore {
        guard end > start else { return UPLZStore() }
        let sc = ParseScratch(end - start)
        let model = UPCostModel()
        let coder = UPBlockCoder()
        let greedy = greedyParse(c, start, end).store
        var greedyStats = UPSymbolStats()
        UPBlockCoder.stats(greedy, 0, greedy.count, into: &greedyStats)
        var best = greedy
        var bestBits = coder.dynamicBits(greedyStats)
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        @inline(__always) func rnd() -> UInt32 {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return UInt32(truncatingIfNeeded: rng >> 16)
        }
        var cur = UPLZStore()
        var st2 = UPSymbolStats()
        /// Runs the parse → statistics loop from `initial`; returns the best size this run reached.
        func run(_ initial: UPSymbolStats, _ iters: Int, giveUpAbove: Int) -> Int {
            var stats = initial, lastStats = initial, runBestStats = initial
            var runBest = Int.max
            var lastBits = -1
            var lastRandom = -1
            for it in 0..<max(1, iters) {
                if progress?.cancelled == true { break }
                model.set(from: stats)
                shortestPath(c, start, end, model, sc, into: &cur)
                UPBlockCoder.stats(cur, 0, cur.count, into: &st2)
                let bits = coder.dynamicBits(st2)
                if bits < runBest { runBest = bits; runBestStats = stats }
                if bits < bestBits { bestBits = bits; best = cur }
                if it == 1 && runBest > giveUpAbove { break }
                lastStats = stats
                stats = st2
                if lastRandom != -1 {
                    // damp oscillation after a perturbation: blend with the previous statistics
                    for i in 0..<288 { stats.ll[i] = stats.ll[i] &+ lastStats.ll[i] / 2 }
                    for i in 0..<32 { stats.d[i] = stats.d[i] &+ lastStats.d[i] / 2 }
                    stats.ll[256] = max(1, stats.ll[256])
                }
                if it > 5 && bits == lastBits {
                    stats = runBestStats
                    for i in 0..<288 where (rnd() >> 4) % 3 == 0 { stats.ll[i] = stats.ll[Int(rnd() % 288)] }
                    for i in 0..<30 where (rnd() >> 4) % 3 == 0 { stats.d[i] = stats.d[Int(rnd() % 30)] }
                    stats.ll[256] = 1
                    lastRandom = it
                }
                lastBits = bits
            }
            return runBest
        }
        let a = run(greedyStats, iterations, giveUpAbove: Int.max)
        // literal-only start
        var lit = UPSymbolStats()
        let data = c.data
        lit.ll.withUnsafeMutableBufferPointer { p in for i in start..<end { p[Int(data[i])] &+= 1 } }
        lit.ll[256] = 1
        let litBits = coder.dynamicBits(lit)
        if litBits < bestBits {
            // all-literal block beats everything so far
            bestBits = litBits
            var s = UPLZStore()
            s.litlen = (start..<end).map { UInt16(data[$0]) }
            s.dist = [UInt16](repeating: 0, count: end - start)
            best = s
        }
        if iterations > 1 { _ = run(lit, max(2, iterations / 2), giveUpAbove: a + a / 50) }
        return best
    }

    // MARK: block splitting

    /// Symbol indices at which to start a new block.
    static func splitStore(_ s: UPLZStore, maxBlocks: Int, coder: UPBlockCoder) -> [Int] {
        let n = s.count
        guard n >= 10, maxBlocks > 1 else { return [] }
        // cumulative histograms every `step` symbols
        let step = 512
        let nCheck = n / step + 1
        let width = 320
        let cum = UnsafeMutablePointer<UInt32>.allocate(capacity: nCheck * width)
        defer { cum.deallocate() }
        let ls = UPDeflateTables.lenSym, ds = UPDeflateTables.distSym
        var running = [UInt32](repeating: 0, count: width)
        for i in 0..<n {
            if i % step == 0 { for k in 0..<width { cum[(i / step) * width + k] = running[k] } }
            let d = Int(s.dist[i])
            if d == 0 { running[Int(s.litlen[i])] += 1 } else { running[Int(ls[Int(s.litlen[i])])] += 1; running[288 + Int(ds[d])] += 1 }
        }
        var h1 = [UInt32](repeating: 0, count: width), h2 = [UInt32](repeating: 0, count: width)
        func hist(_ x: Int, _ out: inout [UInt32]) {
            let ci = min(x / step, (n - 1) / step)
            for k in 0..<width { out[k] = cum[ci * width + k] }
            var i = ci * step
            while i < x {
                let d = Int(s.dist[i])
                if d == 0 { out[Int(s.litlen[i])] += 1 } else { out[Int(ls[Int(s.litlen[i])])] += 1; out[288 + Int(ds[d])] += 1 }
                i += 1
            }
        }
        var st = UPSymbolStats()
        func cost(_ a: Int, _ b: Int) -> Int {
            hist(a, &h1); hist(b, &h2)
            for k in 0..<288 { st.ll[k] = h2[k] &- h1[k] }
            for k in 0..<32 { st.d[k] = h2[288 + k] &- h1[288 + k] }
            st.ll[256] = 1
            return coder.autoBits(st, symbolCount: b - a)
        }
        func findMinimum(_ lo0: Int, _ hi0: Int, _ f: (Int) -> Int) -> (Int, Int) {
            var lo = lo0, hi = hi0
            if hi - lo < 64 {
                var best = Int.max, bi = lo
                for i in lo..<hi { let v = f(i); if v < best { best = v; bi = i } }
                return (bi, best)
            }
            let num = 9
            var p = [Int](repeating: 0, count: num), vp = [Int](repeating: 0, count: num)
            var lastBest = Int.max, pos = lo
            while hi - lo > num {
                for i in 0..<num { p[i] = lo + (i + 1) * ((hi - lo) / (num + 1)); vp[i] = f(p[i]) }
                var bi = 0, best = vp[0]
                for i in 1..<num where vp[i] < best { best = vp[i]; bi = i }
                if best > lastBest { break }
                lo = bi == 0 ? lo : p[bi - 1]
                hi = bi == num - 1 ? hi : p[bi + 1]
                pos = p[bi]; lastBest = best
            }
            return (pos, lastBest)
        }
        var splits: [Int] = []
        var done = Set<Int>()
        var lstart = 0, lend = n
        var blocks = 1
        while blocks < maxBlocks {
            let (pos, splitCost) = findMinimum(lstart + 1, lend) { cost(lstart, $0) + cost($0, lend) }
            let orig = cost(lstart, lend)
            if splitCost > orig || pos == lstart + 1 || pos == lend {
                done.insert(lstart)
            } else {
                splits.append(pos); splits.sort()
                blocks += 1
            }
            // largest block that is not finished
            var best = 0, found = false
            let edges = [0] + splits + [n]
            for k in 0..<(edges.count - 1) where !done.contains(edges[k]) && edges[k + 1] - edges[k] > best {
                best = edges[k + 1] - edges[k]; lstart = edges[k]; lend = edges[k + 1]; found = true
            }
            if !found || lend - lstart < 10 { break }
        }
        return splits
    }
}
