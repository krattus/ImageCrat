import Foundation

/// Portable PNG decoder / encoder (no ImageIO): all colour types (0 gray, 2 RGB, 3 palette, 4 gray+alpha, 6 RGBA), bit
/// depths 1/2/4/8/16, tRNS transparency, non-interlaced and Adam7. 16-bit samples are reduced to their high byte.
/// Decoding is lenient about CRCs, unknown chunks and truncated image data (missing rows stay transparent) but strict
/// about sizes: at most `maxSide` per side and `maxPixels` in total.
package enum PNGCodec {
    package static let maxSide = 16384
    package static let maxPixels = 64 << 20
    package static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    package struct Header: Equatable {
        package var width: Int
        package var height: Int
        package var bitDepth: Int
        package var colorType: Int
        package var interlaced: Bool
        package init(width: Int, height: Int, bitDepth: Int, colorType: Int, interlaced: Bool) {
            self.width = width; self.height = height; self.bitDepth = bitDepth; self.colorType = colorType; self.interlaced = interlaced
        }
    }

    /// A decoded image as straight (non-premultiplied) RGBA8, row-major, tightly packed.
    package struct Image {
        package var width: Int
        package var height: Int
        package var rgba: [UInt8]
        /// Colour type 0 or 4.
        package var isGrayscale: Bool
        /// Colour type 4/6, or a tRNS chunk.
        package var hasAlphaChannel: Bool
        package init(width: Int, height: Int, rgba: [UInt8], isGrayscale: Bool, hasAlphaChannel: Bool) {
            self.width = width; self.height = height; self.rgba = rgba; self.isGrayscale = isGrayscale; self.hasAlphaChannel = hasAlphaChannel
        }
    }

    package static func isPNG(_ data: Data) -> Bool {
        data.count >= 8 && [UInt8](data.prefix(8)) == signature
    }

    // MARK: Chunks

    private struct Chunk { var type: String; var range: Range<Int> }

    /// Chunk list (stops at IEND, a truncated chunk keeps whatever bytes are present).
    private static func chunks(_ b: [UInt8]) -> [Chunk]? {
        guard b.count >= 8, Array(b[0..<8]) == signature else { return nil }
        var out: [Chunk] = []
        var p = 8
        while p + 8 <= b.count {
            let len = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
            let typeBytes = b[(p + 4)..<(p + 8)]
            let type = String(decoding: typeBytes, as: UTF8.self)
            let start = p + 8
            let end = min(b.count, start + min(len, b.count))
            out.append(Chunk(type: type, range: start..<end))
            if type == "IEND" || len > b.count - start { break }
            p = start + len + 4
            if out.count > 1_000_000 { break }
        }
        return out
    }

    package static func header(_ data: Data) -> Header? {
        let b = [UInt8](data.prefix(64))
        guard let cs = chunks(b), let ih = cs.first, ih.type == "IHDR" else { return nil }
        return parseHeader(b, ih.range)
    }

    private static func parseHeader(_ b: [UInt8], _ r: Range<Int>) -> Header? {
        guard r.count >= 13 else { return nil }
        let p = r.lowerBound
        func be32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        let w = be32(p), h = be32(p + 4)
        let depth = Int(b[p + 8]), ct = Int(b[p + 9])
        guard b[p + 10] == 0, b[p + 11] == 0, b[p + 12] <= 1 else { return nil }
        guard w > 0, h > 0, w <= maxSide, h <= maxSide, w * h <= maxPixels else { return nil }
        let ok: Bool
        switch ct {
        case 0: ok = [1, 2, 4, 8, 16].contains(depth)
        case 3: ok = [1, 2, 4, 8].contains(depth)
        case 2, 4, 6: ok = depth == 8 || depth == 16
        default: ok = false
        }
        guard ok else { return nil }
        return Header(width: w, height: h, bitDepth: depth, colorType: ct, interlaced: b[p + 12] == 1)
    }

    // MARK: Decode

    /// Straight RGBA8 decode.
    package static func decodeImage(_ data: Data) -> Image? {
        let b = [UInt8](data)
        guard let cs = chunks(b), let first = cs.first, first.type == "IHDR", let hd = parseHeader(b, first.range) else { return nil }
        var palette: [UInt8] = []
        var trns: [UInt8]? = nil
        var idat: [UInt8] = []
        for c in cs.dropFirst() {
            switch c.type {
            case "PLTE": palette = Array(b[c.range].prefix(768))
            case "tRNS": trns = Array(b[c.range].prefix(256))
            case "IDAT": idat.append(contentsOf: b[c.range])
            default: break
            }
        }
        guard !idat.isEmpty else { return nil }
        if hd.colorType == 3 && palette.isEmpty { return nil }
        let channels: Int
        switch hd.colorType {
        case 0, 3: channels = 1
        case 2: channels = 3
        case 4: channels = 2
        default: channels = 4
        }
        let bitsPerPixel = channels * hd.bitDepth
        let bpp = max(1, bitsPerPixel / 8)
        func rowBytes(_ w: Int) -> Int { (w * bitsPerPixel + 7) / 8 }
        // Adam7 pass geometry (or the single full pass).
        let passes: [(Int, Int, Int, Int)] = hd.interlaced
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]
        var expected = 0
        for (xs, ys, dx, dy) in passes {
            let pw = (hd.width - xs + dx - 1) / dx, ph = (hd.height - ys + dy - 1) / dy
            if pw > 0 && ph > 0 { expected += ph * (1 + rowBytes(pw)) }
        }
        // DEFLATE cannot expand more than ~1032:1, so a header claiming far more pixels than the image data could hold
        // is corrupt; rejecting it here avoids allocating for impossible sizes.
        guard expected <= idat.count * 1040 + 65536 else { return nil }
        let inflated = idat.withUnsafeBytes {
            Inflate.zlibDecompressPartial($0, maxOutput: expected, verifyChecksum: false, stopAtLimit: true)
        }
        var raw = inflated.output
        guard !raw.isEmpty else { return nil }
        if raw.count < expected { raw.append(contentsOf: [UInt8](repeating: 0, count: expected - raw.count)) }
        let available = inflated.output.count

        // Transparency keys.
        var trnsGray = -1, trnsR = -1, trnsG = -1, trnsB = -1
        var palAlpha = [UInt8](repeating: 255, count: 256)
        if let t = trns {
            switch hd.colorType {
            case 0 where t.count >= 2: trnsGray = Int(t[0]) << 8 | Int(t[1])
            case 2 where t.count >= 6:
                trnsR = Int(t[0]) << 8 | Int(t[1]); trnsG = Int(t[2]) << 8 | Int(t[3]); trnsB = Int(t[4]) << 8 | Int(t[5])
            case 3: for (i, a) in t.enumerated() where i < 256 { palAlpha[i] = a }
            default: break
            }
        }
        let w = hd.width, h = hd.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let depth = hd.bitDepth
        let maxv = (1 << depth) - 1
        let palCount = palette.count / 3

        var offset = 0
        for (xs, ys, dx, dy) in passes {
            let pw = (w - xs + dx - 1) / dx, ph = (h - ys + dy - 1) / dy
            guard pw > 0 && ph > 0 else { continue }
            let rb = rowBytes(pw)
            var prev = [UInt8](repeating: 0, count: rb)
            var cur = [UInt8](repeating: 0, count: rb)
            for py in 0..<ph {
                let rowStart = offset + py * (rb + 1)
                if rowStart >= available { break }   // truncated: remaining rows stay transparent
                let filter = raw[rowStart]
                for i in 0..<rb { cur[i] = raw[rowStart + 1 + i] }
                unfilter(&cur, prev, filter: filter, bpp: bpp)
                let y = ys + py * dy
                cur.withUnsafeBufferPointer { row in
                    @inline(__always) func sample(_ i: Int) -> Int {
                        switch depth {
                        case 8: return Int(row[i])
                        case 16: return Int(row[2 * i]) << 8 | Int(row[2 * i + 1])
                        default:
                            let bit = i * depth
                            return Int(row[bit >> 3] >> UInt8(8 - depth - (bit & 7))) & maxv
                        }
                    }
                    @inline(__always) func to8(_ v: Int) -> UInt8 {
                        switch depth {
                        case 16: return UInt8(v >> 8)
                        case 8: return UInt8(v)
                        default: return UInt8(v * 255 / maxv)
                        }
                    }
                    for px in 0..<pw {
                        let x = xs + px * dx
                        let o = (y * w + x) * 4
                        switch hd.colorType {
                        case 0:
                            let v = sample(px)
                            let g = to8(v)
                            rgba[o] = g; rgba[o + 1] = g; rgba[o + 2] = g
                            rgba[o + 3] = v == trnsGray ? 0 : 255
                        case 2:
                            let r = sample(px * 3), g = sample(px * 3 + 1), bl = sample(px * 3 + 2)
                            rgba[o] = to8(r); rgba[o + 1] = to8(g); rgba[o + 2] = to8(bl)
                            rgba[o + 3] = (r == trnsR && g == trnsG && bl == trnsB) ? 0 : 255
                        case 3:
                            let idx = sample(px)
                            if idx < palCount {
                                rgba[o] = palette[idx * 3]; rgba[o + 1] = palette[idx * 3 + 1]; rgba[o + 2] = palette[idx * 3 + 2]
                            }
                            rgba[o + 3] = palAlpha[idx & 255]
                        case 4:
                            let g = to8(sample(px * 2))
                            rgba[o] = g; rgba[o + 1] = g; rgba[o + 2] = g
                            rgba[o + 3] = to8(sample(px * 2 + 1))
                        default:
                            rgba[o] = to8(sample(px * 4)); rgba[o + 1] = to8(sample(px * 4 + 1))
                            rgba[o + 2] = to8(sample(px * 4 + 2)); rgba[o + 3] = to8(sample(px * 4 + 3))
                        }
                    }
                }
                swap(&prev, &cur)
            }
            offset += ph * (rb + 1)
        }
        let gray = hd.colorType == 0 || hd.colorType == 4
        let alpha = hd.colorType == 4 || hd.colorType == 6 || trns != nil
        return Image(width: w, height: h, rgba: rgba, isGrayscale: gray, hasAlphaChannel: alpha)
    }

    private static func unfilter(_ cur: inout [UInt8], _ prev: [UInt8], filter: UInt8, bpp: Int) {
        let n = cur.count
        switch filter {
        case 1:
            if n > bpp { for i in bpp..<n { cur[i] = cur[i] &+ cur[i - bpp] } }
        case 2:
            for i in 0..<n { cur[i] = cur[i] &+ prev[i] }
        case 3:
            for i in 0..<n {
                let left = i >= bpp ? Int(cur[i - bpp]) : 0
                cur[i] = cur[i] &+ UInt8((left + Int(prev[i])) >> 1)
            }
        case 4:
            for i in 0..<n {
                let a = i >= bpp ? Int(cur[i - bpp]) : 0
                let b = Int(prev[i])
                let c = i >= bpp ? Int(prev[i - bpp]) : 0
                let p = a + b - c
                let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                cur[i] = cur[i] &+ UInt8(pred)
            }
        default:
            break   // 0 = none; unknown filter types are treated as none (lenient)
        }
    }

    /// Premultiplied RGBA8 buffer.
    package static func decode(_ data: Data) -> PixelBuffer? {
        guard let img = decodeImage(data) else { return nil }
        return rgbaBuffer(img)
    }

    package static func rgbaBuffer(_ img: Image) -> PixelBuffer {
        let buf = PixelBuffer(width: img.width, height: img.height, format: .rgba)
        let d = buf.data.assumingMemoryBound(to: UInt8.self)
        img.rgba.withUnsafeBufferPointer { s in
            for y in 0..<img.height {
                let row = d + y * buf.bytesPerRow
                for x in 0..<img.width {
                    let i = (y * img.width + x) * 4
                    let a = Int(s[i + 3])
                    if a == 255 {
                        row[x * 4] = s[i]; row[x * 4 + 1] = s[i + 1]; row[x * 4 + 2] = s[i + 2]
                    } else if a > 0 {
                        row[x * 4] = UInt8((Int(s[i]) * a + 127) / 255)
                        row[x * 4 + 1] = UInt8((Int(s[i + 1]) * a + 127) / 255)
                        row[x * 4 + 2] = UInt8((Int(s[i + 2]) * a + 127) / 255)
                    }
                    row[x * 4 + 3] = UInt8(a)
                }
            }
        }
        buf.markDirty()
        return buf
    }

    /// A .gray buffer holding the gray samples of a grayscale PNG without transparency (colour type 0 without tRNS,
    /// or colour type 4 whose alpha is fully opaque); nil for any other PNG.
    package static func decodeGrayscale(_ data: Data) -> PixelBuffer? {
        guard let img = decodeImage(data), img.isGrayscale else { return nil }
        let n = img.width * img.height
        if img.hasAlphaChannel {
            for i in 0..<n where img.rgba[i * 4 + 3] != 255 { return nil }
        }
        let buf = PixelBuffer(width: img.width, height: img.height, format: .gray)
        let d = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<img.height {
            let row = d + y * buf.bytesPerRow
            for x in 0..<img.width { row[x] = img.rgba[(y * img.width + x) * 4] }
        }
        buf.markDirty()
        return buf
    }

    /// Brush coverage of any PNG (see `BrushTipImaging.grayCoverage`), not square-padded.
    package static func decodeCoverage(_ data: Data) -> PixelBuffer? {
        guard let b = decode(data) else { return nil }
        return BrushTipImaging.grayCoverage(fromRGBA: b)
    }

    // MARK: Text chunks

    /// tEXt / zTXt / iTXt keyword → text (compressed text is inflated, capped at 16 MB per chunk). Text is read as
    /// UTF-8 when valid (writers often put UTF-8 into tEXt) and as Latin-1 otherwise. The first chunk of a keyword wins.
    package static func textChunks(_ data: Data) -> [String: String] {
        let b = [UInt8](data)
        guard let cs = chunks(b) else { return [:] }
        var out: [String: String] = [:]
        let cap = 16 << 20
        func text(_ bytes: ArraySlice<UInt8>) -> String {
            String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }
        func inflate(_ bytes: ArraySlice<UInt8>) -> [UInt8]? {
            let r = Array(bytes).withUnsafeBytes { Inflate.zlibDecompressPartial($0, maxOutput: cap, verifyChecksum: false) }
            return r.error == nil ? r.output : nil
        }
        for c in cs where c.type == "tEXt" || c.type == "zTXt" || c.type == "iTXt" {
            let body = b[c.range]
            guard let z = body.firstIndex(of: 0) else { continue }
            let key = String(bytes: body[body.startIndex..<z], encoding: .isoLatin1) ?? ""
            guard !key.isEmpty, out[key] == nil else { continue }
            var p = z + 1
            switch c.type {
            case "tEXt":
                out[key] = text(body[p...])
            case "zTXt":
                guard p < body.endIndex, body[p] == 0, let t = inflate(body[(p + 1)...]) else { continue }
                out[key] = text(t[...])
            default:
                guard p + 2 <= body.endIndex else { continue }
                let compressed = body[p] != 0
                p += 2
                guard let l = body[p...].firstIndex(of: 0) else { continue }      // language tag
                guard let k = body[(l + 1)...].firstIndex(of: 0) else { continue } // translated keyword
                let t = body[(k + 1)...]
                if compressed {
                    guard let d = inflate(t) else { continue }
                    out[key] = String(decoding: d, as: UTF8.self)
                } else {
                    out[key] = String(decoding: t, as: UTF8.self)
                }
            }
        }
        return out
    }

    // MARK: Encode

    /// 8-bit gray PNG for .gray buffers, 8-bit RGBA (un-premultiplied) for .rgba buffers, deflate-compressed with
    /// adaptive per-row filters. `text` adds tEXt chunks (zTXt when `compressText`; iTXt for non-Latin-1 text).
    package static func encode(_ buf: PixelBuffer, text: [(String, String)] = [], compressText: Bool = false) -> Data {
        let w = buf.width, h = buf.height
        let gray = buf.format == .gray
        let bpp = gray ? 1 : 4
        let rb = w * bpp
        var raw = [UInt8]()
        raw.reserveCapacity(h * (rb + 1))
        var prev = [UInt8](repeating: 0, count: rb)
        var cur = [UInt8](repeating: 0, count: rb)
        var cand = [UInt8](repeating: 0, count: rb)
        var best = [UInt8](repeating: 0, count: rb)
        let s = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = s + y * buf.bytesPerRow
            if gray {
                for x in 0..<w { cur[x] = row[x] }
            } else {
                for x in 0..<w {
                    let a = Int(row[x * 4 + 3])
                    if a == 0 {
                        cur[x * 4] = 0; cur[x * 4 + 1] = 0; cur[x * 4 + 2] = 0
                    } else if a == 255 {
                        cur[x * 4] = row[x * 4]; cur[x * 4 + 1] = row[x * 4 + 1]; cur[x * 4 + 2] = row[x * 4 + 2]
                    } else {
                        for c in 0..<3 { cur[x * 4 + c] = UInt8(min(255, (Int(row[x * 4 + c]) * 255 + a / 2) / a)) }
                    }
                    cur[x * 4 + 3] = UInt8(a)
                }
            }
            // Pick the filter with the smallest sum of absolute (signed) residuals.
            var bestFilter: UInt8 = 0
            var bestScore = Int.max
            for f in 0...4 {
                var score = 0
                for i in 0..<rb {
                    let a = i >= bpp ? Int(cur[i - bpp]) : 0
                    let b = Int(prev[i])
                    let c = i >= bpp ? Int(prev[i - bpp]) : 0
                    let pred: Int
                    switch f {
                    case 0: pred = 0
                    case 1: pred = a
                    case 2: pred = b
                    case 3: pred = (a + b) >> 1
                    default:
                        let p = a + b - c
                        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                        pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
                    }
                    let v = cur[i] &- UInt8(pred)
                    cand[i] = v
                    score += v < 128 ? Int(v) : 256 - Int(v)
                }
                if score < bestScore { bestScore = score; bestFilter = UInt8(f); swap(&best, &cand) }
            }
            raw.append(bestFilter)
            raw.append(contentsOf: best)
            swap(&prev, &cur)
        }
        var out = signature
        var ihdr = [UInt8]()
        appendBE32(&ihdr, w); appendBE32(&ihdr, h)
        ihdr.append(contentsOf: [8, gray ? 0 : 6, 0, 0, 0])
        appendChunk(&out, "IHDR", ihdr)
        for (k, v) in text {
            let key = Array(k.utf8.prefix(79))
            if let latin = v.data(using: .isoLatin1), k.data(using: .isoLatin1) != nil {
                if compressText {
                    appendChunk(&out, "zTXt", key + [0, 0] + Deflate.zlibCompress([UInt8](latin)))
                } else {
                    appendChunk(&out, "tEXt", key + [0] + [UInt8](latin))
                }
            } else {
                let t = Array(v.utf8)
                appendChunk(&out, "iTXt", key + [0, compressText ? 1 : 0, 0, 0, 0] + (compressText ? Deflate.zlibCompress(t) : t))
            }
        }
        appendChunk(&out, "IDAT", Deflate.zlibCompress(raw))
        appendChunk(&out, "IEND", [])
        return Data(out)
    }

    private static func appendBE32(_ a: inout [UInt8], _ v: Int) {
        a.append(UInt8((v >> 24) & 0xFF)); a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8((v >> 8) & 0xFF)); a.append(UInt8(v & 0xFF))
    }

    /// Appends a chunk (length, type, data, CRC over type + data).
    package static func appendChunk(_ out: inout [UInt8], _ type: String, _ body: [UInt8]) {
        appendBE32(&out, body.count)
        let t = Array(type.utf8.prefix(4))
        out.append(contentsOf: t)
        out.append(contentsOf: body)
        var crc = t.withUnsafeBytes { CRC32.update(0, $0) }
        crc = body.withUnsafeBytes { CRC32.update(crc, $0) }
        appendBE32(&out, Int(crc))
    }
}
