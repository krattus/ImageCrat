import Foundation

/// A small DEFLATE compressor (RFC 1951): greedy LZ77 with hash chains and the fixed Huffman code, falling back to
/// stored blocks when that would be smaller. Good enough for brush tips and patterns (large flat areas); not tuned for
/// ratio. Output is decodable by any inflater (verified against zlib).
package enum Deflate {
    /// Raw deflate stream.
    package static func compress(_ input: [UInt8]) -> [UInt8] {
        let fixed = input.withUnsafeBufferPointer { compressFixed($0) }
        let storedSize = input.count + 5 * max(1, (input.count + 65534) / 65535)
        return fixed.count <= storedSize ? fixed : stored(input)
    }

    /// zlib stream (RFC 1950): header, deflate data, Adler-32.
    package static func zlibCompress(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]   // 32K window, fastest-compression flag; (0x78 * 256 + 0x01) % 31 == 0
        out.append(contentsOf: compress(input))
        let a = Adler32.checksum(input)
        out.append(contentsOf: [UInt8(a >> 24), UInt8((a >> 16) & 0xFF), UInt8((a >> 8) & 0xFF), UInt8(a & 0xFF)])
        return out
    }

    package static func zlibCompress(_ data: Data) -> Data { Data(zlibCompress([UInt8](data))) }

    /// Raw deflate made of stored (uncompressed) blocks only.
    package static func stored(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(input.count + 5 * (input.count / 65535 + 1))
        var p = 0
        repeat {
            let n = min(65535, input.count - p)
            let final: UInt8 = p + n >= input.count ? 1 : 0
            out.append(final)
            out.append(contentsOf: [UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8((~n >> 8) & 0xFF)])
            out.append(contentsOf: input[p..<(p + n)])
            p += n
        } while p < input.count
        return out
    }

    // MARK: Fixed-Huffman LZ77

    private struct BitWriter {
        var out: [UInt8] = []
        var buf: UInt64 = 0
        var cnt = 0
        @inline(__always) mutating func put(_ value: UInt32, _ n: Int) {
            buf |= UInt64(value) << UInt64(cnt)
            cnt += n
            while cnt >= 8 { out.append(UInt8(truncatingIfNeeded: buf)); buf >>= 8; cnt -= 8 }
        }
        mutating func flush() { if cnt > 0 { out.append(UInt8(truncatingIfNeeded: buf)); buf = 0; cnt = 0 } }
    }

    private static func reversed(_ code: Int, _ len: Int) -> UInt32 {
        var r = 0, v = code
        for _ in 0..<len { r = (r << 1) | (v & 1); v >>= 1 }
        return UInt32(r)
    }

    /// Bit-reversed fixed literal/length codes and their lengths.
    private static let fixedLit: [(UInt32, Int)] = (0..<288).map { s in
        switch s {
        case 0..<144: return (reversed(0x30 + s, 8), 8)
        case 144..<256: return (reversed(0x190 + s - 144, 9), 9)
        case 256..<280: return (reversed(s - 256, 7), 7)
        default: return (reversed(0xC0 + s - 280, 8), 8)
        }
    }
    private static let fixedDist: [UInt32] = (0..<30).map { reversed($0, 5) }
    private static let lengthBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59,
                                            67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
                                          1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
                                           12, 12, 13, 13]
    /// Length (3...258) → length code index.
    private static let lengthCode: [Int] = {
        var t = [Int](repeating: 0, count: 259)
        for len in 3...258 {
            var i = 28
            while lengthBase[i] > len { i -= 1 }
            t[len] = i
        }
        return t
    }()

    private static func distCode(_ d: Int) -> Int {
        var i = 29
        while distBase[i] > d { i -= 1 }
        return i
    }

    private static func compressFixed(_ src: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        let n = src.count
        var w = BitWriter()
        w.out.reserveCapacity(n / 2 + 64)
        w.put(1, 1)   // BFINAL
        w.put(1, 2)   // BTYPE = fixed Huffman
        let hashBits = 15
        let hashSize = 1 << hashBits
        let window = 32768
        let maxChain = 32
        var head = [Int32](repeating: -1, count: hashSize)
        var prev = [Int32](repeating: -1, count: window)
        let lit = fixedLit
        @inline(__always) func hash(_ i: Int) -> Int {
            let v = Int(src[i]) << 16 | Int(src[i + 1]) << 8 | Int(src[i + 2])
            return ((v &* 2_654_435_761) >> 17) & (hashSize - 1)
        }
        @inline(__always) func insert(_ i: Int) {
            guard i + 2 < n else { return }
            let h = hash(i)
            prev[i & (window - 1)] = head[h]
            head[h] = Int32(i)
        }
        var i = 0
        while i < n {
            var bestLen = 0, bestDist = 0
            if i + 2 < n {
                let h = hash(i)
                var cand = Int(head[h])
                var chain = 0
                let maxLen = min(258, n - i)
                while cand >= 0, i - cand <= window, chain < maxChain {
                    if src[cand + bestLen] == src[i + bestLen] || bestLen == 0 {
                        var l = 0
                        while l < maxLen && src[cand + l] == src[i + l] { l += 1 }
                        if l > bestLen { bestLen = l; bestDist = i - cand; if l == maxLen { break } }
                    }
                    let p = Int(prev[cand & (window - 1)])
                    if p >= cand { break }
                    cand = p
                    chain += 1
                }
            }
            if bestLen >= 3 {
                let lc = lengthCode[bestLen]
                let (code, cl) = lit[257 + lc]
                w.put(code, cl)
                if lengthExtra[lc] > 0 { w.put(UInt32(bestLen - lengthBase[lc]), lengthExtra[lc]) }
                let dc = distCode(bestDist)
                w.put(fixedDist[dc], 5)
                if distExtra[dc] > 0 { w.put(UInt32(bestDist - distBase[dc]), distExtra[dc]) }
                for k in 0..<bestLen { insert(i + k) }
                i += bestLen
            } else {
                let (code, cl) = lit[Int(src[i])]
                w.put(code, cl)
                insert(i)
                i += 1
            }
        }
        let (eob, el) = lit[256]
        w.put(eob, el)
        w.flush()
        return w.out
    }
}
