import Foundation

// MARK: - Checksums

/// CRC-32 (ISO 3309 / ITU-T V.42, polynomial 0xEDB88320) as used by ZIP and PNG.
package enum CRC32 {
    package static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Continues a CRC: `update(update(0, a), b) == checksum(a + b)`.
    package static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        table.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    package static func checksum(_ data: Data) -> UInt32 { data.withUnsafeBytes { update(0, $0) } }
    package static func checksum(_ bytes: [UInt8]) -> UInt32 { bytes.withUnsafeBytes { update(0, $0) } }
}

/// Adler-32 (RFC 1950) as used by zlib streams.
package enum Adler32 {
    package static func update(_ adler: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var a = adler & 0xFFFF, b = adler >> 16
        var i = 0
        let n = bytes.count
        while i < n {
            let end = min(n, i + 5552)   // largest run that cannot overflow 32 bits before the modulo
            while i < end { a &+= UInt32(bytes[i]); b &+= a; i += 1 }
            a %= 65521; b %= 65521
        }
        return (b << 16) | a
    }

    package static func checksum(_ data: Data) -> UInt32 { data.withUnsafeBytes { update(1, $0) } }
    package static func checksum(_ bytes: [UInt8]) -> UInt32 { bytes.withUnsafeBytes { update(1, $0) } }
}

// MARK: - Inflate (RFC 1951 / RFC 1950)

/// DEFLATE decoder: stored, fixed-Huffman and dynamic-Huffman blocks, plus the zlib wrapper.
///
/// Pure Swift (no zlib / Compression framework) so the core builds everywhere. Huffman codes up to 9 bits decode with
/// one table lookup; longer codes fall back to the canonical (puff-style) decoder. Every read is bounds checked and the
/// output is capped (`maxOutput`), so hostile streams fail with `BrushImportError.malformed` instead of exhausting memory.
package enum Inflate {
    /// Default output cap (zip-bomb guard).
    package static let defaultMaxOutput = 256 << 20

    /// Result of a lenient decode: whatever was produced before an error, and where the stream ended.
    package struct Result {
        package var output: [UInt8]
        /// Input bytes consumed (meaningful when `error == nil`).
        package var consumed: Int
        package var error: BrushImportError?
        package init(output: [UInt8], consumed: Int, error: BrushImportError?) {
            self.output = output; self.consumed = consumed; self.error = error
        }
    }

    // MARK: Raw deflate

    package static func inflateRaw(_ data: Data, maxOutput: Int = defaultMaxOutput) throws -> Data {
        let r = data.withUnsafeBytes { inflateRawPartial($0, maxOutput: maxOutput) }
        if let e = r.error { throw e }
        return Data(r.output)
    }

    package static func inflateRaw(bytes: [UInt8], maxOutput: Int = defaultMaxOutput) throws -> [UInt8] {
        let r = bytes.withUnsafeBytes { inflateRawPartial($0, maxOutput: maxOutput) }
        if let e = r.error { throw e }
        return r.output
    }

    /// Never throws: returns the output decoded so far plus the error that stopped it (nil = complete stream).
    /// When the cap is reached with `stopAtLimit` the result is the first `maxOutput` bytes and no error.
    package static func inflateRawPartial(_ input: UnsafeRawBufferPointer, maxOutput: Int = defaultMaxOutput,
                                          stopAtLimit: Bool = false) -> Result {
        let src = input.bindMemory(to: UInt8.self)
        var d = Decoder(src: src, maxOut: max(0, maxOutput), stopAtLimit: stopAtLimit)
        do {
            try d.run()
            return Result(output: d.out, consumed: d.consumedBytes, error: nil)
        } catch let e as BrushImportError {
            if case .malformed(let s) = e, s == Decoder.limitReachedMarker {
                return Result(output: d.out, consumed: d.consumedBytes, error: nil)
            }
            return Result(output: d.out, consumed: d.consumedBytes, error: e)
        } catch {
            return Result(output: d.out, consumed: d.consumedBytes, error: .malformed("deflate"))
        }
    }

    // MARK: zlib

    package static func zlibDecompress(_ data: Data, maxOutput: Int = defaultMaxOutput, verifyChecksum: Bool = true) throws -> Data {
        let r = data.withUnsafeBytes { zlibDecompressPartial($0, maxOutput: maxOutput, verifyChecksum: verifyChecksum) }
        if let e = r.error { throw e }
        return Data(r.output)
    }

    package static func zlibDecompress(bytes: [UInt8], maxOutput: Int = defaultMaxOutput, verifyChecksum: Bool = true) throws -> [UInt8] {
        let r = bytes.withUnsafeBytes { zlibDecompressPartial($0, maxOutput: maxOutput, verifyChecksum: verifyChecksum) }
        if let e = r.error { throw e }
        return r.output
    }

    /// Lenient zlib decode. A missing Adler-32 trailer is tolerated; a present but wrong one is an error when
    /// `verifyChecksum` is set.
    package static func zlibDecompressPartial(_ input: UnsafeRawBufferPointer, maxOutput: Int = defaultMaxOutput,
                                              verifyChecksum: Bool = true, stopAtLimit: Bool = false) -> Result {
        guard input.count >= 2 else { return Result(output: [], consumed: 0, error: .malformed("zlib header")) }
        let cmf = Int(input[0]), flg = Int(input[1])
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, (cmf * 256 + flg) % 31 == 0 else {
            return Result(output: [], consumed: 0, error: .malformed("zlib header"))
        }
        guard flg & 0x20 == 0 else { return Result(output: [], consumed: 0, error: .malformed("zlib preset dictionary")) }
        let body = UnsafeRawBufferPointer(rebasing: input[2...])
        var r = inflateRawPartial(body, maxOutput: maxOutput, stopAtLimit: stopAtLimit)
        r.consumed += 2
        guard r.error == nil else { return r }
        if verifyChecksum, r.output.count < maxOutput || !stopAtLimit, r.consumed + 4 <= input.count {
            let p = r.consumed
            let stored = UInt32(input[p]) << 24 | UInt32(input[p + 1]) << 16 | UInt32(input[p + 2]) << 8 | UInt32(input[p + 3])
            if stored != Adler32.checksum(r.output) { r.error = .malformed("zlib checksum") }
            else { r.consumed += 4 }
        }
        return r
    }

    // MARK: - Decoder

    fileprivate static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
                                                67, 83, 99, 115, 131, 163, 195, 227, 258]
    fileprivate static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    fileprivate static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                              1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    fileprivate static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
                                               12, 12, 13, 13]

    fileprivate static let fixedLiteral: Huffman = {
        var l = [UInt8](repeating: 8, count: 288)
        for i in 144..<256 { l[i] = 9 }
        for i in 256..<280 { l[i] = 7 }
        return (try? Huffman(lengths: l)) ?? Huffman.empty
    }()
    fileprivate static let fixedDistance: Huffman = {
        (try? Huffman(lengths: [UInt8](repeating: 5, count: 30))) ?? Huffman.empty
    }()
}

/// Canonical Huffman decoding table.
private struct Huffman {
    static let fastBits = 9
    /// Number of codes of each length (index 0 unused).
    var count: [Int]
    /// Symbols ordered by code.
    var symbol: [Int]
    /// `(symbol << 8) | length` for codes up to `fastBits` long, indexed by the next (bit-reversed) input bits; 0 = slow path.
    var fast: [UInt32]

    static let empty = Huffman(count: [Int](repeating: 0, count: 16), symbol: [], fast: [UInt32](repeating: 0, count: 1 << fastBits))

    private init(count: [Int], symbol: [Int], fast: [UInt32]) { self.count = count; self.symbol = symbol; self.fast = fast }

    init(lengths: [UInt8]) throws {
        var count = [Int](repeating: 0, count: 16)
        for l in lengths {
            guard l <= 15 else { throw BrushImportError.malformed("deflate code length") }
            count[Int(l)] += 1
        }
        count[0] = 0
        var left = 1
        for len in 1...15 {
            left <<= 1
            left -= count[len]
            if left < 0 { throw BrushImportError.malformed("deflate over-subscribed code") }
        }
        var offs = [Int](repeating: 0, count: 16)
        for len in 1..<15 { offs[len + 1] = offs[len] + count[len] }
        var symbol = [Int](repeating: 0, count: lengths.count)
        for (s, l) in lengths.enumerated() where l != 0 {
            symbol[offs[Int(l)]] = s
            offs[Int(l)] += 1
        }
        var fast = [UInt32](repeating: 0, count: 1 << Huffman.fastBits)
        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for len in 1...15 {
            code = (code + count[len - 1]) << 1
            nextCode[len] = code
        }
        for (s, l8) in lengths.enumerated() where l8 != 0 {
            let l = Int(l8)
            let c = nextCode[l]
            nextCode[l] += 1
            guard l <= Huffman.fastBits else { continue }
            var r = 0, v = c
            for _ in 0..<l { r = (r << 1) | (v & 1); v >>= 1 }
            let entry = UInt32(s) << 8 | UInt32(l)
            while r < (1 << Huffman.fastBits) { fast[r] = entry; r += 1 << l }
        }
        self.count = count; self.symbol = symbol; self.fast = fast
    }
}

private struct Decoder {
    static let limitReachedMarker = "\u{0}limit"
    let src: UnsafeBufferPointer<UInt8>
    var pos = 0
    var bitBuf: UInt64 = 0
    var bitCnt = 0
    var out: [UInt8] = []
    let maxOut: Int
    let stopAtLimit: Bool

    init(src: UnsafeBufferPointer<UInt8>, maxOut: Int, stopAtLimit: Bool) {
        self.src = src; self.maxOut = maxOut; self.stopAtLimit = stopAtLimit
        out.reserveCapacity(min(maxOut, max(1024, src.count * 4)))
    }

    var consumedBytes: Int { pos - bitCnt / 8 }

    @inline(__always) mutating func refill() {
        while bitCnt <= 56 && pos < src.count {
            bitBuf |= UInt64(src[pos]) << UInt64(bitCnt)
            pos += 1
            bitCnt += 8
        }
    }

    @inline(__always) mutating func bits(_ n: Int) throws -> Int {
        if n == 0 { return 0 }
        if bitCnt < n {
            refill()
            if bitCnt < n { throw BrushImportError.malformed("deflate stream truncated") }
        }
        let v = Int(bitBuf & ((1 << UInt64(n)) - 1))
        bitBuf >>= UInt64(n)
        bitCnt -= n
        return v
    }

    func limitError() -> BrushImportError {
        stopAtLimit ? .malformed(Decoder.limitReachedMarker) : .malformed("decompressed data exceeds the size limit")
    }

    mutating func decode(_ h: Huffman) throws -> Int {
        if bitCnt < 15 { refill() }
        let e = h.fast[Int(bitBuf & UInt64((1 << Huffman.fastBits) - 1))]
        if e != 0 {
            let l = Int(e & 0xFF)
            guard l <= bitCnt else { throw BrushImportError.malformed("deflate stream truncated") }
            bitBuf >>= UInt64(l)
            bitCnt -= l
            return Int(e >> 8)
        }
        var code = 0, first = 0, index = 0
        for len in 1...15 {
            if bitCnt == 0 {
                refill()
                if bitCnt == 0 { throw BrushImportError.malformed("deflate stream truncated") }
            }
            code |= Int(bitBuf & 1)
            bitBuf >>= 1
            bitCnt -= 1
            let cnt = h.count[len]
            if code - cnt < first { return h.symbol[index + (code - first)] }
            index += cnt
            first += cnt
            first <<= 1
            code <<= 1
        }
        throw BrushImportError.malformed("deflate invalid code")
    }

    mutating func run() throws {
        var final = false
        var blocks = 0
        while !final {
            blocks += 1
            if blocks > 10_000_000 { throw BrushImportError.malformed("deflate block count") }
            final = try bits(1) == 1
            switch try bits(2) {
            case 0: try stored()
            case 1: try codes(Inflate.fixedLiteral, Inflate.fixedDistance)
            case 2:
                let (lit, dist) = try dynamicTables()
                try codes(lit, dist)
            default: throw BrushImportError.malformed("deflate block type")
            }
        }
    }

    mutating func stored() throws {
        // Drop to a byte boundary and hand any whole buffered bytes back to the input.
        let drop = bitCnt & 7
        bitBuf >>= UInt64(drop)
        bitCnt -= drop
        pos -= bitCnt / 8
        bitBuf = 0
        bitCnt = 0
        guard pos + 4 <= src.count else { throw BrushImportError.malformed("deflate stream truncated") }
        let len = Int(src[pos]) | Int(src[pos + 1]) << 8
        let nlen = Int(src[pos + 2]) | Int(src[pos + 3]) << 8
        pos += 4
        guard len == (~nlen & 0xFFFF) else { throw BrushImportError.malformed("deflate stored length") }
        let avail = min(len, src.count - pos)
        let room = maxOut - out.count
        if avail > room {
            out.append(contentsOf: src[pos..<(pos + room)])
            pos += room
            throw limitError()
        }
        out.append(contentsOf: src[pos..<(pos + avail)])
        pos += avail
        if avail < len { throw BrushImportError.malformed("deflate stream truncated") }
    }

    mutating func dynamicTables() throws -> (Huffman, Huffman) {
        let nlen = try bits(5) + 257
        let ndist = try bits(5) + 1
        let ncode = try bits(4) + 4
        guard nlen <= 286, ndist <= 30 else { throw BrushImportError.malformed("deflate table size") }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var cl = [UInt8](repeating: 0, count: 19)
        for i in 0..<ncode { cl[order[i]] = UInt8(try bits(3)) }
        let clCode = try Huffman(lengths: cl)
        var lengths = [UInt8](repeating: 0, count: nlen + ndist)
        var i = 0
        while i < nlen + ndist {
            let sym = try decode(clCode)
            if sym < 16 {
                lengths[i] = UInt8(sym)
                i += 1
                continue
            }
            var rep = 0
            var val: UInt8 = 0
            switch sym {
            case 16:
                guard i > 0 else { throw BrushImportError.malformed("deflate repeat without length") }
                val = lengths[i - 1]
                rep = 3 + (try bits(2))
            case 17: rep = 3 + (try bits(3))
            case 18: rep = 11 + (try bits(7))
            default: throw BrushImportError.malformed("deflate code length symbol")
            }
            guard i + rep <= nlen + ndist else { throw BrushImportError.malformed("deflate too many lengths") }
            for _ in 0..<rep { lengths[i] = val; i += 1 }
        }
        guard lengths[256] != 0 else { throw BrushImportError.malformed("deflate missing end-of-block code") }
        let lit = try Huffman(lengths: Array(lengths[0..<nlen]))
        let dist = try Huffman(lengths: Array(lengths[nlen...]))
        return (lit, dist)
    }

    mutating func codes(_ lit: Huffman, _ dist: Huffman) throws {
        while true {
            let sym = try decode(lit)
            if sym < 256 {
                guard out.count < maxOut else { throw limitError() }
                out.append(UInt8(truncatingIfNeeded: sym))
            } else if sym == 256 {
                return
            } else {
                let s = sym - 257
                guard s < 29 else { throw BrushImportError.malformed("deflate length symbol") }
                var len = Inflate.lengthBase[s] + (try bits(Inflate.lengthExtra[s]))
                let ds = try decode(dist)
                guard ds < 30 else { throw BrushImportError.malformed("deflate distance symbol") }
                let d = Inflate.distBase[ds] + (try bits(Inflate.distExtra[ds]))
                guard d <= out.count else { throw BrushImportError.malformed("deflate distance too far back") }
                var limited = false
                if out.count + len > maxOut { len = maxOut - out.count; limited = true }
                var from = out.count - d
                for _ in 0..<len {
                    out.append(out[from])
                    from += 1
                }
                if limited { throw limitError() }
            }
        }
    }
}
