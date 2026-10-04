import Foundation
import zlib

// Lumen Ultra PNG — scanline filter optimisation.
// Every strategy yields one filter type per row; the caller keeps whichever final stream deflates smallest.
// When `cleanAlpha` is on (gray+alpha / RGBA), the colour of fully transparent pixels is rewritten, row by row,
// to whatever the chosen filter predicts, so their residuals become zero ("filter-following alpha cleanup").

enum UPFilterStrategy: Hashable, CustomStringConvertible {
    case fixed(UInt8)        // 0 none, 1 sub, 2 up, 3 average, 4 paeth
    case minSum              // smallest sum of absolute residuals (libpng's heuristic)
    case entropy             // smallest Shannon entropy of the row's residual bytes
    case globalEntropy       // iteratively minimises the entropy of the whole residual stream (not just each row's)
    case bigrams             // fewest distinct byte pairs
    case brute               // real deflate cost of the row given a sliding window of the rows before it
    case genetic             // evolutionary search over whole filter vectors
    case preset              // filter vector supplied by the caller (the near-lossless shaper)

    var description: String {
        switch self {
        case .fixed(let f): return ["none", "sub", "up", "avg", "paeth"][Int(f)]
        case .minSum: return "min-sum"
        case .entropy: return "entropy"
        case .globalEntropy: return "global-entropy"
        case .bigrams: return "bigrams"
        case .brute: return "brute"
        case .genetic: return "genetic"
        case .preset: return "perceptual"
        }
    }
}

struct UPFiltered {
    var filters: [UInt8]
    /// Filter bytes + residuals, `(rowBytes + 1) * height`.
    var stream: [UInt8]
    var strategy: String
    var cleanAlpha: Bool
}

enum UPFilter {
    /// Residuals of one row. `prev` is nil for the first row.
    @inline(__always)
    static func filterRow(_ type: UInt8, _ cur: UnsafePointer<UInt8>, _ prev: UnsafePointer<UInt8>?, _ out: UnsafeMutablePointer<UInt8>, _ n: Int, _ bpp: Int) {
        switch type {
        case 0:
            out.update(from: cur, count: n)
        case 1:
            for i in 0..<min(bpp, n) { out[i] = cur[i] }
            if n > bpp { for i in bpp..<n { out[i] = cur[i] &- cur[i - bpp] } }
        case 2:
            if let p = prev { for i in 0..<n { out[i] = cur[i] &- p[i] } } else { out.update(from: cur, count: n) }
        case 3:
            if let p = prev {
                for i in 0..<min(bpp, n) { out[i] = cur[i] &- (p[i] >> 1) }
                if n > bpp { for i in bpp..<n { out[i] = cur[i] &- UInt8((Int(cur[i - bpp]) + Int(p[i])) >> 1) } }
            } else {
                for i in 0..<min(bpp, n) { out[i] = cur[i] }
                if n > bpp { for i in bpp..<n { out[i] = cur[i] &- (cur[i - bpp] >> 1) } }
            }
        default:
            if let p = prev {
                for i in 0..<min(bpp, n) { out[i] = cur[i] &- p[i] }
                if n > bpp {
                    for i in bpp..<n {
                        let a = Int(cur[i - bpp]), b = Int(p[i]), c = Int(p[i - bpp])
                        let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - c - c)
                        out[i] = cur[i] &- UInt8(pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
                    }
                }
            } else {
                for i in 0..<min(bpp, n) { out[i] = cur[i] }
                if n > bpp { for i in bpp..<n { out[i] = cur[i] &- cur[i - bpp] } }
            }
        }
    }

    /// Like `filterRow`, but rewrites the colour bytes of fully transparent pixels in `cur` to the prediction (residual 0).
    /// `alphaBytes` = 1 (8-bit) or 2 (16-bit); the alpha sample is the last sample of each pixel.
    static func filterRowClean(_ type: UInt8, _ cur: UnsafeMutablePointer<UInt8>, _ prev: UnsafePointer<UInt8>?, _ out: UnsafeMutablePointer<UInt8>,
                               _ n: Int, _ bpp: Int, _ alphaBytes: Int) {
        let colorBytes = bpp - alphaBytes
        var x = 0
        while x < n {
            var transparent = true
            for k in colorBytes..<bpp where cur[x + k] != 0 { transparent = false }
            for k in 0..<bpp {
                let i = x + k
                let a = i >= bpp ? Int(cur[i - bpp]) : 0
                let b = prev != nil ? Int(prev![i]) : 0
                let c = (i >= bpp && prev != nil) ? Int(prev![i - bpp]) : 0
                let pred: Int
                switch type {
                case 0: pred = 0
                case 1: pred = a
                case 2: pred = b
                case 3: pred = (a + b) >> 1
                default:
                    let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - c - c)
                    pred = pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
                }
                if transparent && k < colorBytes { cur[i] = UInt8(pred); out[i] = 0 } else { out[i] = cur[i] &- UInt8(pred) }
            }
            x += bpp
        }
    }

    /// Applies a complete filter vector.
    static func apply(_ rep: UPRep, filters: [UInt8], cleanAlpha: Bool) -> [UInt8] {
        let rb = rep.rowBytes, h = rep.height, bpp = rep.bpp
        var out = [UInt8](repeating: 0, count: (rb + 1) * h)
        let clean = cleanAlpha && rep.hasAlphaChannel
        let alphaBytes = Int(rep.bitDepth) / 8
        if clean {
            var work = rep.raw
            work.withUnsafeMutableBufferPointer { w in
                out.withUnsafeMutableBufferPointer { o in
                    for y in 0..<h {
                        o[y * (rb + 1)] = filters[y]
                        filterRowClean(filters[y], w.baseAddress! + y * rb, y > 0 ? UnsafePointer(w.baseAddress! + (y - 1) * rb) : nil,
                                       o.baseAddress! + y * (rb + 1) + 1, rb, bpp, alphaBytes)
                    }
                }
            }
        } else {
            rep.raw.withUnsafeBufferPointer { w in
                out.withUnsafeMutableBufferPointer { o in
                    for y in 0..<h {
                        o[y * (rb + 1)] = filters[y]
                        filterRow(filters[y], w.baseAddress! + y * rb, y > 0 ? w.baseAddress! + (y - 1) * rb : nil, o.baseAddress! + y * (rb + 1) + 1, rb, bpp)
                    }
                }
            }
        }
        return out
    }

    // MARK: per-row heuristics

    private static let cLog2c: [Float] = (0...4096).map { $0 == 0 ? 0 : Float($0) * log2f(Float($0)) }

    /// Chooses row filters with one of the per-row heuristics (not `.genetic`).
    static func choose(_ rep: UPRep, strategy: UPFilterStrategy, cleanAlpha: Bool, bruteLevel: Int32 = 5, progress: UPProgress? = nil) -> UPFiltered {
        let rb = rep.rowBytes, h = rep.height, bpp = rep.bpp
        let clean = cleanAlpha && rep.hasAlphaChannel
        if case .fixed(let f) = strategy {
            let fs = [UInt8](repeating: f, count: h)
            return UPFiltered(filters: fs, stream: apply(rep, filters: fs, cleanAlpha: clean), strategy: strategy.description, cleanAlpha: clean)
        }
        let alphaBytes = Int(rep.bitDepth) / 8
        var filters = [UInt8](repeating: 0, count: h)
        var out = [UInt8](repeating: 0, count: (rb + 1) * h)
        var work = rep.raw
        // candidate buffers: residuals (with the filter byte in front) and cleaned rows for each filter
        var cand = [UInt8](repeating: 0, count: 5 * (rb + 1))
        var cleaned = [UInt8](repeating: 0, count: clean ? 5 * rb : 0)
        var hist = [Int32](repeating: 0, count: 256)
        var costTable = [Float](repeating: 8, count: 256)       // global-entropy model: bits per residual byte value
        var globalPass = 0
        let passes: Int = { if case .globalEntropy = strategy { return 6 }; return 1 }()
        var seen = [UInt8](repeating: 0, count: 65536)
        var touched = [Int](); touched.reserveCapacity(rb + 2)
        let window = 32768
        for pass in 0..<passes {
        globalPass = pass
        var changed = 0
        if pass > 0 {
            // cost of each byte value under the histogram of the previous pass' stream
            var gh = [Int](repeating: 0, count: 256)
            for b in out { gh[Int(b)] += 1 }
            let total = Float(out.count) + 128
            for i in 0..<256 { costTable[i] = -log2f((Float(gh[i]) + 0.5) / total) }
            if clean { work = rep.raw }
        }
        work.withUnsafeMutableBufferPointer { w in
            out.withUnsafeMutableBufferPointer { o in
                cand.withUnsafeMutableBufferPointer { cb in
                    cleaned.withUnsafeMutableBufferPointer { cl in
                        for y in 0..<h {
                            if y & 63 == 0, progress?.cancelled == true { return }
                            let cur = w.baseAddress! + y * rb
                            let prev: UnsafePointer<UInt8>? = y > 0 ? UnsafePointer(w.baseAddress! + (y - 1) * rb) : nil
                            var best = 0
                            var bestScore = Double.infinity
                            for f in 0..<5 {
                                let res = cb.baseAddress! + f * (rb + 1)
                                res[0] = UInt8(f)
                                if clean {
                                    let tmp = cl.baseAddress! + f * rb
                                    tmp.update(from: cur, count: rb)
                                    filterRowClean(UInt8(f), tmp, prev, res + 1, rb, bpp, alphaBytes)
                                } else {
                                    filterRow(UInt8(f), cur, prev, res + 1, rb, bpp)
                                }
                                var score = 0.0
                                switch strategy {
                                case .minSum:
                                    var s = 0
                                    for i in 1...rb { let v = Int(res[i]); s += v < 128 ? v : 256 - v }
                                    score = Double(s)
                                case .entropy:
                                    for i in 0..<256 { hist[i] = 0 }
                                    for i in 0...rb { hist[Int(res[i])] += 1 }
                                    var e: Float = 0
                                    for i in 0..<256 where hist[i] > 0 {
                                        let c = Int(hist[i])
                                        e -= c <= 4096 ? cLog2c[c] : Float(c) * log2f(Float(c))
                                    }
                                    score = Double(e)       // + n log2 n is the same for every filter
                                case .globalEntropy:
                                    if globalPass == 0 {
                                        for i in 0..<256 { hist[i] = 0 }
                                        for i in 0...rb { hist[Int(res[i])] += 1 }
                                        var e: Float = 0
                                        for i in 0..<256 where hist[i] > 0 {
                                            let c = Int(hist[i])
                                            e -= c <= 4096 ? cLog2c[c] : Float(c) * log2f(Float(c))
                                        }
                                        score = Double(e)
                                    } else {
                                        var e: Float = 0
                                        for i in 0...rb { e += costTable[Int(res[i])] }
                                        score = Double(e)
                                    }
                                case .bigrams:
                                    var distinct = 0
                                    touched.removeAll(keepingCapacity: true)
                                    for i in 0..<rb {
                                        let k = Int(res[i]) << 8 | Int(res[i + 1])
                                        if seen[k] == 0 { seen[k] = 1; distinct += 1; touched.append(k) }
                                    }
                                    for k in touched { seen[k] = 0 }
                                    score = Double(distinct)
                                case .brute:
                                    let used = y * (rb + 1)
                                    let dictLen = min(used, window)
                                    let dict = UnsafeBufferPointer(start: UnsafePointer(o.baseAddress! + used - dictLen), count: dictLen)
                                    score = Double(UPZlib.deflatedSize(UnsafeBufferPointer(start: UnsafePointer(res), count: rb + 1), level: bruteLevel,
                                                                       dictionary: dictLen > 0 ? dict : nil))
                                    // ties: prefer the filter with the smaller residual energy
                                    var s = 0
                                    for i in 1...rb { let v = Int(res[i]); s += v < 128 ? v : 256 - v }
                                    score += Double(s) / Double(rb * 256 + 1)
                                default: break
                                }
                                if score < bestScore { bestScore = score; best = f }
                            }
                            if filters[y] != UInt8(best) { changed += 1 }
                            filters[y] = UInt8(best)
                            (o.baseAddress! + y * (rb + 1)).update(from: cb.baseAddress! + best * (rb + 1), count: rb + 1)
                            if clean { cur.update(from: cl.baseAddress! + best * rb, count: rb) }
                        }
                    }
                }
            }
        }
        if pass > 0 && changed == 0 { break }
        }
        return UPFiltered(filters: filters, stream: out, strategy: strategy.description, cleanAlpha: clean)
    }

    // MARK: genetic search

    /// Evolves whole filter vectors; fitness is the real zlib size of the filtered image.
    static func genetic(_ rep: UPRep, seeds: [[UInt8]], cleanAlpha: Bool, evaluations: Int, level: Int32 = 4, strategy: Int32 = Z_DEFAULT_STRATEGY,
                        progress: UPProgress? = nil) -> UPFiltered? {
        let h = rep.height
        guard h >= 2, evaluations >= 8, !seeds.isEmpty else { return nil }
        let clean = cleanAlpha && rep.hasAlphaChannel
        let popSize = max(8, min(24, evaluations / 6))
        var rng: UInt64 = 0x2545_F491_4F6C_DD1D ^ UInt64(h) &* 0x9E37_79B9
        func rnd(_ n: Int) -> Int {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Int((rng >> 11) % UInt64(max(1, n)))
        }
        func fitness(_ g: [UInt8]) -> Int {
            let s = apply(rep, filters: g, cleanAlpha: clean)
            return s.withUnsafeBufferPointer { UPZlib.deflatedSize($0, level: level, strategy: strategy, memLevel: 8) }
        }
        var pop: [[UInt8]] = []
        var seen = Set<[UInt8]>()
        for s in seeds where s.count == h && !seen.contains(s) { pop.append(s); seen.insert(s) }
        let seedCount = pop.count
        while pop.count < popSize {
            var g = pop[rnd(seedCount)]
            // block mutation: copy a run of rows from another seed or set it to one filter
            let a = rnd(h), len = 1 + rnd(max(1, h / 4))
            let src = pop[rnd(seedCount)]
            let fixed = UInt8(rnd(5)), useFixed = rnd(2) == 0
            for y in a..<min(h, a + len) { g[y] = useFixed ? fixed : src[y] }
            pop.append(g)
        }
        var fit = [Int](repeating: 0, count: pop.count)
        func evalAll(_ range: Range<Int>) {
            let p = pop
            let out = UnsafeMutablePointer<Int>.allocate(capacity: range.count)
            defer { out.deallocate() }
            DispatchQueue.concurrentPerform(iterations: range.count) { i in out[i] = fitness(p[range.lowerBound + i]) }
            for i in 0..<range.count { fit[range.lowerBound + i] = out[i] }
        }
        evalAll(0..<pop.count)
        var used = pop.count
        var stale = 0
        var bestEver = fit.min() ?? Int.max
        while used < evaluations && stale < 12 {
            if progress?.cancelled == true { return nil }
            // rank, keep the better half, refill with children
            let order = (0..<pop.count).sorted { fit[$0] < fit[$1] }
            let keep = pop.count / 2
            var next: [[UInt8]] = [], nextFit: [Int] = []
            for k in 0..<keep { next.append(pop[order[k]]); nextFit.append(fit[order[k]]) }
            while next.count < pop.count {
                let pa = next[min(rnd(keep), rnd(keep))], pb = next[rnd(keep)]
                var child = pa
                // two-point crossover
                var a = rnd(h), b = rnd(h)
                if a > b { swap(&a, &b) }
                for y in a...b { child[y] = pb[y] }
                // mutation: a few rows, or a short run, get a different filter
                let muts = 1 + rnd(max(1, h / 64))
                for _ in 0..<muts {
                    let y = rnd(h), f = UInt8(rnd(5)), run = rnd(3) == 0 ? 1 + rnd(8) : 1
                    for yy in y..<min(h, y + run) { child[yy] = f }
                }
                next.append(child); nextFit.append(Int.max)
            }
            pop = next; fit = nextFit
            evalAll(keep..<pop.count)
            used += pop.count - keep
            let b = fit.min() ?? Int.max
            if b < bestEver { bestEver = b; stale = 0 } else { stale += 1 }
            progress?.report(min(1, Double(used) / Double(evaluations)), "Genetic filter search")
        }
        guard let bi = fit.indices.min(by: { fit[$0] < fit[$1] }) else { return nil }
        let g = pop[bi]
        return UPFiltered(filters: g, stream: apply(rep, filters: g, cleanAlpha: clean), strategy: "genetic", cleanAlpha: clean)
    }
}
