import Foundation
import zlib

// Lumen Ultra PNG — lossless pipeline:
//   reductions → filter search → zlib parameter search → Ultra Deflate (optimal parse) → self-verification.
// Each stage records the file size it reached so the gain of every step is measurable on its own.

enum UPEffort: Int, CaseIterable, Identifiable {
    case fast, thorough, maximum
    var id: Int { rawValue }
    var title: String { ["Fast", "Thorough", "Maximum"][rawValue] }
}

struct UPLosslessOptions {
    var effort: UPEffort = .thorough
    var reduce = UPReduceOptions()
    var ancillary = UPAncillary()
    /// Overrides the Ultra Deflate iteration count of the effort level.
    var iterations: Int? = nil
    /// Skip the decode-and-compare self check (only for internal estimates).
    var verify = true
    /// Row filters an 8-bit RGB / RGBA image was shaped for (near-lossless path); tried in addition to the searched ones.
    var seedFilters: [UInt8]? = nil
}

struct UPStage {
    var name: String
    var bytes: Int
    var seconds: Double
}

struct UPEncodeResult {
    var data: Data
    var representation: String
    var filter: String
    var deflater: String
    var stages: [UPStage]
    var seconds: Double
    /// The written file decoded (own decoder) to exactly the intended pixels.
    var verified: Bool
}

enum UPLossless {
    /// Bytes of a finished file around its IDAT payload.
    static func overhead(_ rep: UPRep, _ anc: UPAncillary) -> Int {
        var n = 8 + 25 + 12 + 12 + rep.headerOverhead
        if anc.icc != nil { n += 12 + 5 + (anc.icc?.count ?? 0) / 2 } else if anc.srgbIntent != nil { n += 13 } else if anc.gamma != nil { n += 16 }
        if anc.dpi != nil { n += 21 }
        return n
    }

    private struct Trial {
        var rep: Int
        var strategy: UPFilterStrategy
        var clean: Bool
        var filters: [UInt8] = []
        var size = Int.max        // best proxy: zlib stream + representation overhead
        var lz = Int.max          // zlib, default strategy
        var huff = Int.max        // zlib, Huffman only (pure entropy coding)
    }

    static func strategies(for rep: UPRep, effort: UPEffort) -> [UPFilterStrategy] {
        let indexed = rep.colorType == 3 || rep.bitDepth < 8
        let rawBytes = rep.raw.count
        let cheap: [UPFilterStrategy] = [.fixed(0), .fixed(1), .fixed(2), .fixed(3), .fixed(4), .minSum, .entropy, .bigrams]
        switch effort {
        case .fast:
            return indexed ? [.fixed(0), .bigrams] : cheap
        case .thorough:
            var s = cheap + [.globalEntropy]
            if rawBytes <= 24 << 20 && !(indexed && rawBytes > 4 << 20) { s.append(.brute) }
            return s
        case .maximum:
            var s = cheap + [.globalEntropy]
            if rawBytes <= 64 << 20 { s.append(.brute) }
            return s
        }
    }

    static func encode(_ source: UPImage, options o: UPLosslessOptions = UPLosslessOptions(), progress: UPProgress? = nil) -> UPEncodeResult? {
        let t0 = Date()
        var ro = o.reduce
        if o.effort == .fast && source.width * source.height > 65536 {
            ro.paletteOrders = ro.paletteOrders.filter { [.popularity, .alphaLuminance, .alphaPopularity, .neighbour].contains($0) }
            if ro.paletteOrders.isEmpty { ro.paletteOrders = [.alphaPopularity] }
            ro.tryWidePalette = false
        }
        let reps = UPReduce.candidates(source, options: ro)
        guard !reps.isEmpty else { return nil }
        progress?.report(0.02, "Reductions")
        var stages: [UPStage] = []

        // ---- trials: every representation × filter strategy (× alpha cleanup), sized with cheap zlib proxies
        var trials: [Trial] = []
        for (ri, rep) in reps.enumerated() {
            let cleanable = rep.hasAlphaChannel && !ro.keepHiddenRGB
            for s in strategies(for: rep, effort: o.effort) {
                trials.append(Trial(rep: ri, strategy: s, clean: false))
                if cleanable { trials.append(Trial(rep: ri, strategy: s, clean: true)) }
            }
            if let seed = o.seedFilters, seed.count == rep.height, rep.bitDepth == 8, rep.colorType == 2 || rep.colorType == 6 {
                trials.append(Trial(rep: ri, strategy: .preset, clean: cleanable, filters: seed))
            }
        }
        let nT = trials.count
        let tp = UnsafeMutablePointer<Trial>.allocate(capacity: nT)
        tp.initialize(from: trials, count: nT)
        defer { tp.deinitialize(count: nT); tp.deallocate() }
        let lock = NSLock()
        var doneTrials = 0
        DispatchQueue.concurrentPerform(iterations: nT) { i in
            if progress?.cancelled == true { return }
            let t = tp[i]
            let rep = reps[t.rep]
            let f: UPFiltered
            if t.strategy == .preset {
                f = UPFiltered(filters: t.filters, stream: UPFilter.apply(rep, filters: t.filters, cleanAlpha: t.clean), strategy: "perceptual", cleanAlpha: t.clean)
            } else {
                f = UPFilter.choose(rep, strategy: t.strategy, cleanAlpha: t.clean, progress: progress)
            }
            // level 9 walks very long hash chains on noisy data; big streams are ranked at level 6
            let level: Int32 = o.effort == .fast ? (f.stream.count > 1 << 20 ? 4 : 6) : (f.stream.count > 1 << 20 ? 6 : 9)
            let (lz, huff) = f.stream.withUnsafeBufferPointer {
                (UPZlib.deflatedSize($0, level: level, strategy: Z_DEFAULT_STRATEGY), UPZlib.deflatedSize($0, level: 9, strategy: Z_HUFFMAN_ONLY))
            }
            tp[i].filters = f.filters
            tp[i].lz = lz; tp[i].huff = huff
            tp[i].size = min(lz, huff) + rep.headerOverhead
            lock.lock(); doneTrials += 1; let d = doneTrials; lock.unlock()
            progress?.report(0.02 + 0.38 * Double(d) / Double(nT), "Filters")
        }
        if progress?.cancelled == true { return nil }
        trials = Array(UnsafeBufferPointer(start: tp, count: nT))
        let fixedOverhead = 8 + 25 + 12 + 12
        // "reductions" stage = best representation with the default filter for its kind, plain zlib, no alpha cleanup
        var reduced = Int.max
        for t in trials where !t.clean {
            let rep = reps[t.rep]
            let indexed = rep.colorType == 3 || rep.bitDepth < 8
            let isDefault = indexed ? t.strategy == .fixed(0) : t.strategy == .minSum
            if isDefault { reduced = min(reduced, t.lz + rep.headerOverhead) }
        }
        if reduced == Int.max { reduced = trials.map(\.size).min() ?? 0 }
        stages.append(UPStage(name: "reductions", bytes: reduced + fixedOverhead, seconds: Date().timeIntervalSince(t0)))

        // ---- best filter strategy (+ genetic search at maximum effort)
        var ranked = trials.sorted { $0.size < $1.size }
        if o.effort == .maximum, let bestT = ranked.first {
            let rep = reps[bestT.rep]
            let evals = min(480, Int(1.5e9 / Double(max(1, rep.raw.count))))
            if evals >= 24 && rep.height >= 4 {
                let seeds = ranked.filter { $0.rep == bestT.rep && $0.clean == bestT.clean }.prefix(8).map(\.filters)
                // entropy-bound data is judged by Huffman-only size (fast and what matters); the rest by real LZ77
                let entropyBound = Double(bestT.huff) <= 1.05 * Double(bestT.lz)
                if let g = UPFilter.genetic(rep, seeds: Array(seeds), cleanAlpha: bestT.clean, evaluations: evals,
                                            level: entropyBound ? 9 : 5, strategy: entropyBound ? Z_HUFFMAN_ONLY : Z_DEFAULT_STRATEGY,
                                            progress: progress?.child(from: 0.40, to: 0.55)) {
                    let (lz, huff) = g.stream.withUnsafeBufferPointer {
                        (UPZlib.deflatedSize($0, level: g.stream.count > 1 << 20 ? 6 : 9, strategy: Z_DEFAULT_STRATEGY), UPZlib.deflatedSize($0, level: 9, strategy: Z_HUFFMAN_ONLY))
                    }
                    ranked.append(Trial(rep: bestT.rep, strategy: .genetic, clean: bestT.clean, filters: g.filters, size: min(lz, huff) + rep.headerOverhead, lz: lz, huff: huff))
                    ranked.sort { $0.size < $1.size }
                }
            }
        }
        if progress?.cancelled == true { return nil }
        stages.append(UPStage(name: "filters", bytes: (ranked.first?.size ?? 0) + fixedOverhead, seconds: Date().timeIntervalSince(t0)))

        // ---- finalists: distinct (representation, filter vector) pairs close to the best proxy size
        // small images cost nothing to treat thoroughly, whatever the effort level
        let small = (reps.map { $0.raw.count }.max() ?? 0) <= 256 << 10
        let keep = o.effort == .fast ? (small ? 3 : 1) : (o.effort == .thorough ? 3 : 5)
        var finalists: [Trial] = []
        let cutoff = (ranked.first?.size ?? 0) + (ranked.first?.size ?? 0) / 25 + 32
        for t in ranked where t.size <= cutoff {
            if finalists.contains(where: { $0.rep == t.rep && $0.filters == t.filters && $0.clean == t.clean }) { continue }
            finalists.append(t)
            if finalists.count >= keep { break }
        }
        let streams: [[UInt8]] = finalists.map { UPFilter.apply(reps[$0.rep], filters: $0.filters, cleanAlpha: $0.clean) }

        // ---- zlib parameter search
        struct ZParam { var level: Int32; var strategy: Int32; var mem: Int32 }
        var jobs: [(Int, ZParam)] = []
        for (fi, t) in finalists.enumerated() {
            // entropy-bound big streams: level 9 costs seconds and cannot win, stay at 6
            let slow = streams[fi].count > 3 << 19 && Double(t.huff) <= 1.08 * Double(t.lz)
            let top: Int32 = slow ? 6 : 9
            jobs.append((fi, ZParam(level: top, strategy: Z_DEFAULT_STRATEGY, mem: 8)))
            jobs.append((fi, ZParam(level: top, strategy: Z_FILTERED, mem: 8)))
            jobs.append((fi, ZParam(level: 9, strategy: Z_HUFFMAN_ONLY, mem: 8)))
            jobs.append((fi, ZParam(level: 9, strategy: Z_RLE, mem: 8)))
            if o.effort != .fast || small {
                jobs.append((fi, ZParam(level: top, strategy: Z_DEFAULT_STRATEGY, mem: 9)))
                jobs.append((fi, ZParam(level: top, strategy: Z_FILTERED, mem: 9)))
                jobs.append((fi, ZParam(level: 9, strategy: Z_HUFFMAN_ONLY, mem: 9)))
                jobs.append((fi, ZParam(level: 9, strategy: Z_RLE, mem: 9)))
            }
            if o.effort == .maximum && !slow {
                jobs.append((fi, ZParam(level: 8, strategy: Z_DEFAULT_STRATEGY, mem: 9)))
                jobs.append((fi, ZParam(level: 7, strategy: Z_DEFAULT_STRATEGY, mem: 9)))
                jobs.append((fi, ZParam(level: 8, strategy: Z_FILTERED, mem: 9)))
            }
        }
        var best: (stream: [UInt8], finalist: Int, label: String)? = nil
        let nZ = jobs.count
        let zOut = UnsafeMutablePointer<[UInt8]>.allocate(capacity: nZ)
        zOut.initialize(repeating: [], count: nZ)
        defer { zOut.deinitialize(count: nZ); zOut.deallocate() }
        DispatchQueue.concurrentPerform(iterations: nZ) { i in
            if progress?.cancelled == true { return }
            let (fi, p) = jobs[i]
            zOut[i] = UPZlib.deflate(streams[fi], level: p.level, strategy: p.strategy, memLevel: p.mem)
        }
        if progress?.cancelled == true { return nil }
        func total(_ w: (stream: [UInt8], finalist: Int, label: String)) -> Int { w.stream.count + reps[finalists[w.finalist].rep].headerOverhead }
        for i in 0..<nZ where !zOut[i].isEmpty {
            let (fi, p) = jobs[i]
            let sName = [Z_DEFAULT_STRATEGY: "default", Z_FILTERED: "filtered", Z_RLE: "rle", Z_HUFFMAN_ONLY: "huffman"][p.strategy] ?? "?"
            let cand = (stream: zOut[i], finalist: fi, label: "zlib-\(p.level) \(sName) mem\(p.mem)")
            if best == nil || total(cand) < total(best!) { best = cand }
        }
        guard var win = best else { return nil }
        stages.append(UPStage(name: "zlib search", bytes: total(win) + fixedOverhead, seconds: Date().timeIntervalSince(t0)))
        progress?.report(0.6, "Deflate")

        // ---- Ultra Deflate on the finalists (in parallel)
        var uo = UPUltraDeflateOptions()
        uo.iterations = o.iterations ?? (o.effort == .fast ? 3 : (o.effort == .thorough ? 10 : 40))
        uo.maxChain = o.effort == .fast ? 128 : (o.effort == .thorough ? 1024 : 8192)
        let ultraLimit = o.effort == .fast ? 4 << 20 : 96 << 20
        if streams.contains(where: { $0.count <= ultraLimit }) {
            let uOut = UnsafeMutablePointer<[UInt8]>.allocate(capacity: streams.count)
            uOut.initialize(repeating: [], count: streams.count)
            defer { uOut.deinitialize(count: streams.count); uOut.deallocate() }
            let uLock = NSLock()
            var fractions = [Double](repeating: 0, count: streams.count)
            DispatchQueue.concurrentPerform(iterations: streams.count) { fi in
                let s = streams[fi]
                guard s.count <= ultraLimit, progress?.cancelled != true else { return }
                let sub = progress?.child { f, _ in
                    uLock.lock(); fractions[fi] = f; let avg = fractions.reduce(0, +) / Double(fractions.count); uLock.unlock()
                    progress?.report(0.6 + 0.38 * avg, "Optimal deflate")
                }
                let raw = s.withUnsafeBufferPointer { UPUltraDeflate.compress($0, options: uo, progress: sub) }
                guard !raw.isEmpty else { return }
                uOut[fi] = s.withUnsafeBufferPointer { UPZlib.wrap(rawDeflate: raw, of: $0) }
            }
            if progress?.cancelled == true { return nil }
            for fi in 0..<streams.count where !uOut[fi].isEmpty {
                let cand = (stream: uOut[fi], finalist: fi, label: "ultra-deflate ×\(uo.iterations)")
                if total(cand) < total(win) { win = cand }
            }
            stages.append(UPStage(name: "ultra deflate", bytes: total(win) + fixedOverhead, seconds: Date().timeIntervalSince(t0)))
        }
        let f = finalists[win.finalist]
        let rep = reps[f.rep]
        let data = UPPNG.assemble(rep, zlibStream: win.stream, ancillary: o.ancillary)
        var verified = true
        if o.verify {
            let v = UPValidator.validate(data)
            let want = UPReduce.canonical(source, keepHiddenRGB: ro.keepHiddenRGB)
            if let im = v.image, v.ok { verified = ro.keepHiddenRGB ? im.exactlyEqual(to: want) : im.visuallyIdentical(to: want) } else { verified = false }
            if !verified, let safe = safeEncode(source) {
                // never hand out a file that failed its own check
                return UPEncodeResult(data: safe, representation: "rgba8 (fallback)", filter: "min-sum", deflater: "zlib-9", stages: stages,
                                      seconds: Date().timeIntervalSince(t0), verified: false)
            }
        }
        progress?.report(1, "Done")
        return UPEncodeResult(data: data, representation: rep.label, filter: f.strategy.description + (f.clean ? " +alpha-clean" : ""), deflater: win.label,
                              stages: stages, seconds: Date().timeIntervalSince(t0), verified: verified)
    }

    /// Plain RGBA / zlib-9 writer used as a fallback.
    static func safeEncode(_ img: UPImage) -> Data? {
        let c = UPReduce.canonical(img, keepHiddenRGB: true)
        let rep: UPRep
        if let p16 = c.px16 {
            var raw = [UInt8](repeating: 0, count: p16.count * 2)
            for i in 0..<p16.count { raw[i * 2] = UInt8(p16[i] >> 8); raw[i * 2 + 1] = UInt8(p16[i] & 255) }
            rep = UPRep(width: c.width, height: c.height, colorType: 6, bitDepth: 16, raw: raw)
        } else { rep = UPRep(width: c.width, height: c.height, colorType: 6, bitDepth: 8, raw: c.px) }
        let f = UPFilter.choose(rep, strategy: .minSum, cleanAlpha: false)
        return UPPNG.assemble(rep, zlibStream: UPZlib.deflate(f.stream, level: 9, strategy: Z_DEFAULT_STRATEGY))
    }

    // MARK: baseline (b): "zlib -9, best filter" — what OptiPNG-class tools do

    /// Standard reductions, the five fixed filters plus libpng's adaptive heuristic, zlib level 9 with the four
    /// strategies and memLevel 8 / 9; smallest wins. No alpha cleanup beyond zeroing, no palette order search, no optimal parse.
    static func optiLikeBaseline(_ source: UPImage) -> Data? {
        var ro = UPReduceOptions()
        ro.paletteOrders = [.alphaPopularity]
        ro.tryWidePalette = false
        let reps = UPReduce.candidates(source, options: ro)
        guard !reps.isEmpty else { return nil }
        let strategies: [UPFilterStrategy] = [.fixed(0), .fixed(1), .fixed(2), .fixed(3), .fixed(4), .minSum]
        let zs: [(Int32, Int32)] = [(Z_DEFAULT_STRATEGY, 8), (Z_DEFAULT_STRATEGY, 9), (Z_FILTERED, 8), (Z_FILTERED, 9), (Z_RLE, 8), (Z_HUFFMAN_ONLY, 8)]
        let jobs = reps.count * strategies.count * zs.count
        let out = UnsafeMutablePointer<[UInt8]>.allocate(capacity: jobs)
        out.initialize(repeating: [], count: jobs)
        defer { out.deinitialize(count: jobs); out.deallocate() }
        DispatchQueue.concurrentPerform(iterations: reps.count * strategies.count) { i in
            let rep = reps[i / strategies.count]
            let f = UPFilter.choose(rep, strategy: strategies[i % strategies.count], cleanAlpha: false)
            for (k, z) in zs.enumerated() { out[i * zs.count + k] = UPZlib.deflate(f.stream, level: 9, strategy: z.0, memLevel: z.1) }
        }
        var best: Data? = nil
        var bestTotal = Int.max
        for i in 0..<jobs where !out[i].isEmpty {
            let rep = reps[i / (strategies.count * zs.count)]
            let t = out[i].count + rep.headerOverhead
            if t < bestTotal { bestTotal = t; best = UPPNG.assemble(rep, zlibStream: out[i]) }
        }
        return best
    }
}

// MARK: - optimising an existing PNG file

enum UPRecompress {
    /// Splits the ancillary chunks of a PNG into the three positions the specification allows.
    /// Palette-dependent chunks (bKGD, hIST, sBIT) are dropped because the representation may change.
    static func ancillary(of data: Data) -> UPAncillary {
        var a = UPAncillary()
        let d = [UInt8](data)
        var pos = 8
        var seenIDAT = false
        while pos + 12 <= d.count {
            let len = Int(d[pos]) << 24 | Int(d[pos + 1]) << 16 | Int(d[pos + 2]) << 8 | Int(d[pos + 3])
            guard len >= 0, pos + 12 + len <= d.count else { break }
            let type = String(decoding: d[(pos + 4)..<(pos + 8)], as: UTF8.self)
            let body = Array(d[(pos + 8)..<(pos + 8 + len)])
            switch type {
            case "IHDR", "PLTE", "tRNS", "IEND", "bKGD", "hIST", "sBIT": break
            case "IDAT": seenIDAT = true
            case "iCCP", "sRGB", "gAMA", "cHRM", "cICP": a.rawBeforePLTE.append((type, body))
            case "pHYs", "sPLT", "eXIf": if !seenIDAT { a.rawBeforeIDAT.append((type, body)) } else { a.rawAfterIDAT.append((type, body)) }
            default:
                // other ancillary chunks (text, time, C2PA "caBX", …) are order-free: keep them after the image data
                if let f = type.utf8.first, f & 0x20 != 0 { a.rawAfterIDAT.append((type, body)) }
            }
            pos += 12 + len
        }
        return a
    }

    /// Losslessly re-encodes a PNG file, keeping its metadata chunks. Returns nil when the file cannot be read exactly
    /// (interlaced, damaged, …) or when the result would not be smaller.
    static func optimise(_ data: Data, effort: UPEffort, keepMetadata: Bool = true, progress: UPProgress? = nil) -> Data? {
        let v = UPValidator.validate(data)
        guard v.ok, let img = v.image else { return nil }
        var o = UPLosslessOptions()
        o.effort = effort
        if keepMetadata {
            o.ancillary = ancillary(of: data)
            // an RGB ICC profile is not valid in a grayscale PNG
            if o.ancillary.hasRGBProfile { o.reduce.allowGray = false }
        }
        guard let r = UPLossless.encode(img, options: o, progress: progress), r.verified, r.data.count < data.count else { return nil }
        return r.data
    }
}
