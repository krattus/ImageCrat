import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import zlib

// Lumen Ultra PNG — core types: straight-alpha image model, PNG chunk writer, a strict PNG validator / decoder
// (used to prove that every file we write decodes to the pixels we intended) and ImageIO raw-decode helpers.

/// Straight (non-premultiplied) RGBA image. `px16` is present when the source is deeper than 8 bits per sample.
struct UPImage {
    var width: Int
    var height: Int
    /// RGBA8, straight alpha, `width * height * 4` bytes.
    var px: [UInt8]
    /// RGBA16 (host order), straight alpha, when the source has more than 8 bits per sample.
    var px16: [UInt16]? = nil
    /// ICC profile of the pixel values (nil = sRGB).
    var iccProfile: Data? = nil
    var dpi: Double? = nil

    var pixelCount: Int { width * height }

    init(width: Int, height: Int, px: [UInt8]) {
        self.width = width; self.height = height; self.px = px
    }

    init(width: Int, height: Int, px16: [UInt16]) {
        self.width = width; self.height = height; self.px16 = px16
        var p = [UInt8](repeating: 0, count: px16.count)
        for i in 0..<px16.count { p[i] = UInt8((UInt32(px16[i]) * 255 + 32767) / 65535) }
        self.px = p
    }

    var hasAlpha: Bool {
        var i = 3
        let n = px.count
        return px.withUnsafeBufferPointer { p in
            while i < n { if p[i] != 255 { return true }; i += 4 }
            return false
        }
    }

    /// Equality that ignores the colour of fully transparent pixels (they are invisible in every compositor).
    func visuallyIdentical(to o: UPImage) -> Bool {
        guard width == o.width, height == o.height else { return false }
        if let a = px16, let b = o.px16 {
            for i in stride(from: 0, to: a.count, by: 4) {
                if a[i + 3] != b[i + 3] { return false }
                if a[i + 3] == 0 { continue }
                if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] { return false }
            }
            return true
        }
        if (px16 != nil) != (o.px16 != nil) {
            // one side is 16-bit: compare as 16-bit (8-bit values replicate to v * 257)
            let a = px16 ?? px.map { UInt16($0) * 257 }, b = o.px16 ?? o.px.map { UInt16($0) * 257 }
            for i in stride(from: 0, to: a.count, by: 4) {
                if a[i + 3] != b[i + 3] { return false }
                if a[i + 3] == 0 { continue }
                if a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] { return false }
            }
            return true
        }
        let n = px.count
        return px.withUnsafeBufferPointer { a in
            o.px.withUnsafeBufferPointer { b in
                var i = 0
                while i < n {
                    if a[i + 3] != b[i + 3] { return false }
                    if a[i + 3] != 0 && (a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2]) { return false }
                    i += 4
                }
                return true
            }
        }
    }

    /// Exact equality including hidden RGB under alpha 0.
    func exactlyEqual(to o: UPImage) -> Bool {
        guard width == o.width, height == o.height else { return false }
        if let a = px16, let b = o.px16 { return a == b }
        if px16 != nil || o.px16 != nil { return false }
        return px == o.px
    }
}

// MARK: - CGImage <-> UPImage

enum UPBridge {
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Straight RGBA CGImage (no premultiplication, exact bytes).
    static func cgImage(_ img: UPImage, space: CGColorSpace? = nil) -> CGImage? {
        let cs = space ?? img.iccProfile.flatMap { CGColorSpace(iccData: $0 as CFData) } ?? srgb
        let opaque = !img.hasAlpha
        if let p16 = img.px16 {
            let data = p16.withUnsafeBufferPointer { Data(buffer: $0) }
            guard let prov = CGDataProvider(data: data as CFData) else { return nil }
            let info = CGBitmapInfo(rawValue: (opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.last.rawValue) | CGBitmapInfo.byteOrder16Little.rawValue)
            return CGImage(width: img.width, height: img.height, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: img.width * 8, space: cs,
                           bitmapInfo: info, provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
        guard let prov = CGDataProvider(data: Data(img.px) as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.last.rawValue)
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4, space: cs,
                       bitmapInfo: info, provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Reads the samples of a CGImage without colour management when its layout allows (RGB / gray / indexed, 1–16 bit),
    /// otherwise renders it into sRGB. Premultiplied sources are un-premultiplied (rounded).
    static func image(_ cg: CGImage, forceSRGB: Bool = false) -> UPImage {
        if !forceSRGB, let raw = rawDecode(cg) {
            var r = raw
            if let cs = cg.colorSpace, cs.model == .rgb, let name = cs.name as String?, name != (CGColorSpace.sRGB as String) {
                r.iccProfile = cs.copyICCData() as Data?
            } else if let cs = cg.colorSpace, cs.model == .rgb, cs.name == nil {
                r.iccProfile = cs.copyICCData() as Data?
            }
            return r
        }
        return render(cg)
    }

    /// Renders into an sRGB premultiplied context (16-bit when the source is deep) and un-premultiplies.
    static func render(_ cg: CGImage) -> UPImage {
        let w = cg.width, h = cg.height
        if cg.bitsPerComponent > 8 {
            var buf = [UInt16](repeating: 0, count: w * h * 4)
            buf.withUnsafeMutableBytes { p in
                if let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 16, bytesPerRow: w * 8, space: srgb,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue) {
                    ctx.interpolationQuality = .none
                    ctx.setBlendMode(.copy)
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            for i in stride(from: 0, to: buf.count, by: 4) {
                let a = UInt32(buf[i + 3])
                if a == 0 { buf[i] = 0; buf[i + 1] = 0; buf[i + 2] = 0 } else if a < 65535 {
                    for k in 0..<3 { buf[i + k] = UInt16(min(65535, (UInt32(buf[i + k]) * 65535 + a / 2) / a)) }
                }
            }
            return UPImage(width: w, height: h, px16: buf)
        }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { p in
            if let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: srgb,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.interpolationQuality = .none
                ctx.setBlendMode(.copy)
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        unpremultiply(&buf)
        return UPImage(width: w, height: h, px: buf)
    }

    static func unpremultiply(_ buf: inout [UInt8]) {
        let n = buf.count
        buf.withUnsafeMutableBufferPointer { p in
            var i = 0
            while i < n {
                let a = Int(p[i + 3])
                if a == 0 { p[i] = 0; p[i + 1] = 0; p[i + 2] = 0 } else if a < 255 {
                    p[i] = UInt8(min(255, (Int(p[i]) * 255 + a / 2) / a))
                    p[i + 1] = UInt8(min(255, (Int(p[i + 1]) * 255 + a / 2) / a))
                    p[i + 2] = UInt8(min(255, (Int(p[i + 2]) * 255 + a / 2) / a))
                }
                i += 4
            }
        }
    }

    /// Exact sample read-out for the layouts ImageIO produces for PNG / GIF (returns nil for anything unusual).
    static func rawDecode(_ cg: CGImage) -> UPImage? {
        guard let cs = cg.colorSpace, let data = cg.dataProvider?.data as Data? else { return nil }
        let w = cg.width, h = cg.height, bpc = cg.bitsPerComponent, bpp = cg.bitsPerPixel, rb = cg.bytesPerRow
        let alpha = cg.alphaInfo
        let order = cg.bitmapInfo.intersection(.byteOrderMask)
        if cg.bitmapInfo.contains(.floatComponents) { return nil }
        let model = cs.model
        var palette: [UInt8]? = nil
        var base = model
        if model == .indexed {
            guard let tbl = cs.colorTable, let b = cs.baseColorSpace else { return nil }
            palette = tbl
            base = b.model
            guard base == .rgb, alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst else { return nil }
        }
        guard base == .rgb || base == .monochrome else { return nil }
        guard data.count >= rb * (h - 1) + (w * bpp + 7) / 8 else { return nil }
        let premult = alpha == .premultipliedLast || alpha == .premultipliedFirst
        let alphaFirst = alpha == .premultipliedFirst || alpha == .first || alpha == .noneSkipFirst
        let hasA = alpha == .premultipliedLast || alpha == .premultipliedFirst || alpha == .last || alpha == .first
        let skip = alpha == .noneSkipLast || alpha == .noneSkipFirst
        let nColor = model == .indexed ? 1 : (base == .rgb ? 3 : 1)
        let nComp = nColor + ((hasA || skip) ? 1 : 0)
        guard bpp == nComp * bpc else { return nil }
        return data.withUnsafeBytes { (rawp: UnsafeRawBufferPointer) -> UPImage? in
            let p = rawp.bindMemory(to: UInt8.self)
            if bpc == 16 {
                guard model != .indexed else { return nil }
                let little = order == .byteOrder16Little
                guard little || order == .byteOrder16Big || order == [] else { return nil }
                var out = [UInt16](repeating: 0, count: w * h * 4)
                for y in 0..<h {
                    for x in 0..<w {
                        var c = [UInt16](repeating: 65535, count: 4)
                        var comp = [UInt16](repeating: 0, count: nComp)
                        for k in 0..<nComp {
                            let o = y * rb + (x * nComp + k) * 2
                            comp[k] = little ? UInt16(p[o]) | UInt16(p[o + 1]) << 8 : UInt16(p[o]) << 8 | UInt16(p[o + 1])
                        }
                        let ci = alphaFirst ? 1 : 0
                        if nColor == 3 { c[0] = comp[ci]; c[1] = comp[ci + 1]; c[2] = comp[ci + 2] } else { c[0] = comp[ci]; c[1] = comp[ci]; c[2] = comp[ci] }
                        if hasA { c[3] = alphaFirst ? comp[0] : comp[nComp - 1] }
                        if premult {
                            let a = UInt32(c[3])
                            if a == 0 { c[0] = 0; c[1] = 0; c[2] = 0 } else if a < 65535 { for k in 0..<3 { c[k] = UInt16(min(65535, (UInt32(c[k]) * 65535 + a / 2) / a)) } }
                        }
                        let o = (y * w + x) * 4
                        out[o] = c[0]; out[o + 1] = c[1]; out[o + 2] = c[2]; out[o + 3] = c[3]
                    }
                }
                return UPImage(width: w, height: h, px16: out)
            }
            guard bpc == 8 || ((bpc == 1 || bpc == 2 || bpc == 4) && nComp == 1) else { return nil }
            if bpc == 8, nComp == 4 {
                // 32-bit orders: default / big = memory order as declared; 32Little = reversed
                guard order == [] || order == .byteOrder32Big || order == .byteOrder32Little else { return nil }
            }
            var out = [UInt8](repeating: 255, count: w * h * 4)
            let maxv = (1 << bpc) - 1
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    if nComp == 1 {
                        var v: Int
                        if bpc == 8 { v = Int(p[y * rb + x]) } else {
                            let bit = x * bpc
                            v = (Int(p[y * rb + bit / 8]) >> (8 - bpc - bit % 8)) & maxv
                        }
                        if let pal = palette {
                            guard v * 3 + 2 < pal.count else { return nil }
                            out[o] = pal[v * 3]; out[o + 1] = pal[v * 3 + 1]; out[o + 2] = pal[v * 3 + 2]
                        } else {
                            if bpc < 8 { v = v * 255 / maxv }
                            out[o] = UInt8(v); out[o + 1] = UInt8(v); out[o + 2] = UInt8(v)
                        }
                        continue
                    }
                    var comp = [UInt8](repeating: 0, count: nComp)
                    for k in 0..<nComp { comp[k] = p[y * rb + x * nComp + k] }
                    if nComp == 4, order == .byteOrder32Little { comp.reverse() }
                    let ci = alphaFirst ? 1 : 0
                    if nColor == 3 { out[o] = comp[ci]; out[o + 1] = comp[ci + 1]; out[o + 2] = comp[ci + 2] } else { out[o] = comp[ci]; out[o + 1] = comp[ci]; out[o + 2] = comp[ci] }
                    if hasA { out[o + 3] = alphaFirst ? comp[0] : comp[nComp - 1] }
                }
            }
            if premult { unpremultiply(&out) }
            return UPImage(width: w, height: h, px: out)
        }
    }

    /// Decodes encoded image data with ImageIO. `exact` is true when the samples were read without any conversion.
    static func decode(_ data: Data) -> (image: UPImage, exact: Bool, cg: CGImage)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if let raw = rawDecode(cg) {
            let premult = cg.alphaInfo == .premultipliedLast || cg.alphaInfo == .premultipliedFirst
            return (raw, !premult, cg)
        }
        return (render(cg), false, cg)
    }

    /// The reference "normal PNG" written by macOS ImageIO from the same straight pixels.
    static func imageIOPNG(_ img: UPImage) -> Data? {
        guard let cg = cgImage(img) else { return nil }
        return encode(cg, type: UTType.png.identifier, props: [:])
    }

    static func encode(_ cg: CGImage, type: String, props: [CFString: Any]) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}

// MARK: - PNG container

/// One concrete PNG pixel representation (colour type + bit depth + packed scanlines, not yet filtered).
struct UPRep {
    var width: Int
    var height: Int
    var colorType: UInt8        // 0 gray, 2 RGB, 3 palette, 4 gray+alpha, 6 RGBA
    var bitDepth: UInt8         // 1, 2, 4, 8, 16
    var palette: [UInt32] = []  // r | g << 8 | b << 16 | a << 24
    var trnsKey: [UInt16]? = nil // colour-key transparency for types 0 / 2
    /// Packed scanlines without filter bytes: `rowBytes * height`.
    var raw: [UInt8]
    var label: String = ""

    var channels: Int { switch colorType { case 0, 3: return 1; case 2: return 3; case 4: return 2; default: return 4 } }
    var rowBytes: Int { (width * channels * Int(bitDepth) + 7) / 8 }
    /// Bytes per complete pixel as the PNG filters define it (at least 1).
    var bpp: Int { max(1, channels * Int(bitDepth) / 8) }
    var hasAlphaChannel: Bool { colorType == 4 || colorType == 6 }

    /// PLTE + tRNS chunk bytes this representation needs (0 for none).
    var headerOverhead: Int {
        var n = 0
        if colorType == 3 {
            n += 12 + palette.count * 3
            if let last = palette.lastIndex(where: { $0 >> 24 != 255 }) { n += 12 + last + 1 }
        } else if let k = trnsKey { n += 12 + k.count * 2 }
        return n
    }
}

struct UPAncillary {
    var icc: Data? = nil
    var srgbIntent: UInt8? = nil
    var gamma: UInt32? = nil
    var dpi: Double? = nil
    var text: [(String, String)] = []
    /// Chunks copied verbatim from an existing file (type, body), by where the PNG specification wants them.
    var rawBeforePLTE: [(String, [UInt8])] = []
    var rawBeforeIDAT: [(String, [UInt8])] = []
    var rawAfterIDAT: [(String, [UInt8])] = []
    /// True when a colour profile chunk is carried over that is only valid for RGB colour types.
    var hasRGBProfile: Bool { icc != nil || rawBeforePLTE.contains { $0.0 == "iCCP" } }
}

enum UPPNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    static func crc(_ bytes: UnsafeBufferPointer<UInt8>, seed: UInt = 0) -> UInt32 {
        UInt32(truncatingIfNeeded: crc32(seed, bytes.baseAddress, uInt(bytes.count)))
    }

    static func adler(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBufferPointer { UInt32(truncatingIfNeeded: adler32(1, $0.baseAddress, uInt($0.count))) }
    }

    static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }

    static func appendChunk(_ out: inout [UInt8], _ type: String, _ body: [UInt8]) {
        out.append(contentsOf: be32(UInt32(body.count)))
        let start = out.count
        out.append(contentsOf: Array(type.utf8))
        out.append(contentsOf: body)
        let c = out.withUnsafeBufferPointer { crc(UnsafeBufferPointer(rebasing: $0[start...])) }
        out.append(contentsOf: be32(c))
    }

    /// Assembles a PNG file from a representation and its zlib stream.
    static func assemble(_ rep: UPRep, zlibStream: [UInt8], ancillary: UPAncillary = UPAncillary()) -> Data {
        var out = signature
        out.reserveCapacity(zlibStream.count + 1024)
        var ihdr = be32(UInt32(rep.width)) + be32(UInt32(rep.height))
        ihdr.append(contentsOf: [rep.bitDepth, rep.colorType, 0, 0, 0])
        appendChunk(&out, "IHDR", ihdr)
        if let s = ancillary.srgbIntent, ancillary.icc == nil { appendChunk(&out, "sRGB", [s]) }
        if let g = ancillary.gamma, ancillary.icc == nil, ancillary.srgbIntent == nil { appendChunk(&out, "gAMA", be32(g)) }
        if let icc = ancillary.icc {
            var body = Array("icc".utf8) + [0, 0]
            let z = icc.withUnsafeBytes { UPZlib.deflate($0.bindMemory(to: UInt8.self), level: 9, strategy: Z_DEFAULT_STRATEGY) }
            body.append(contentsOf: z)
            appendChunk(&out, "iCCP", body)
        }
        for (t, b) in ancillary.rawBeforePLTE { appendChunk(&out, t, b) }
        if rep.colorType == 3 {
            var plte = [UInt8](); plte.reserveCapacity(rep.palette.count * 3)
            for c in rep.palette { plte.append(UInt8(c & 255)); plte.append(UInt8(c >> 8 & 255)); plte.append(UInt8(c >> 16 & 255)) }
            appendChunk(&out, "PLTE", plte)
            if let last = rep.palette.lastIndex(where: { $0 >> 24 != 255 }) {
                appendChunk(&out, "tRNS", rep.palette[0...last].map { UInt8($0 >> 24) })
            }
        } else if let k = rep.trnsKey {
            appendChunk(&out, "tRNS", k.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] })
        }
        if let dpi = ancillary.dpi, dpi > 0 {
            let ppm = UInt32((dpi / 0.0254).rounded())
            appendChunk(&out, "pHYs", be32(ppm) + be32(ppm) + [1])
        }
        for (t, b) in ancillary.rawBeforeIDAT { appendChunk(&out, t, b) }
        appendChunk(&out, "IDAT", zlibStream)
        for (t, b) in ancillary.rawAfterIDAT { appendChunk(&out, t, b) }
        for (k, v) in ancillary.text {
            appendChunk(&out, "tEXt", Array(k.utf8.prefix(79)) + [0] + Array(v.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }))
        }
        appendChunk(&out, "IEND", [])
        return Data(out)
    }
}

// MARK: - Validator / reference decoder

struct UPValidation {
    var ok: Bool { errors.isEmpty }
    var errors: [String] = []
    var chunks: [String] = []
    var width = 0, height = 0
    var colorType: UInt8 = 0, bitDepth: UInt8 = 0
    var paletteCount = 0
    var idatBytes = 0
    var image: UPImage? = nil

    var formatLabel: String {
        let t: String
        switch colorType { case 0: t = "gray"; case 2: t = "RGB"; case 3: t = "pal"; case 4: t = "gray+a"; default: t = "RGBA" }
        return colorType == 3 ? "pal\(paletteCount)/\(bitDepth)b" : "\(t)/\(bitDepth)b"
    }
}

enum UPValidator {
    /// Strict structural check (signature, CRCs, chunk order, IHDR legality, zlib stream, scanline size, filter types,
    /// palette index range) plus a full decode to straight RGBA.
    static func validate(_ data: Data) -> UPValidation {
        var v = UPValidation()
        let d = [UInt8](data)
        guard d.count >= 8, Array(d[0..<8]) == UPPNG.signature else { v.errors.append("bad signature"); return v }
        var pos = 8
        var plte: [UInt8] = [], trns: [UInt8]? = nil, idat: [UInt8] = []
        var seenIHDR = false, seenPLTE = false, seenIDAT = false, idatEnded = false, seenIEND = false, seenTRNS = false
        var interlace: UInt8 = 0
        var singles = Set<String>()
        while pos + 12 <= d.count {
            let len = Int(d[pos]) << 24 | Int(d[pos + 1]) << 16 | Int(d[pos + 2]) << 8 | Int(d[pos + 3])
            guard len >= 0, pos + 12 + len <= d.count else { v.errors.append("chunk overruns file"); return v }
            let type = String(decoding: d[(pos + 4)..<(pos + 8)], as: UTF8.self)
            let body = Array(d[(pos + 8)..<(pos + 8 + len)])
            let stored = UInt32(d[pos + 8 + len]) << 24 | UInt32(d[pos + 9 + len]) << 16 | UInt32(d[pos + 10 + len]) << 8 | UInt32(d[pos + 11 + len])
            let calc = d.withUnsafeBufferPointer { UPPNG.crc(UnsafeBufferPointer(rebasing: $0[(pos + 4)..<(pos + 8 + len)])) }
            if stored != calc { v.errors.append("CRC mismatch in \(type)") }
            for b in type.utf8 where !((b >= 65 && b <= 90) || (b >= 97 && b <= 122)) { v.errors.append("illegal chunk name"); break }
            v.chunks.append(type)
            if seenIEND { v.errors.append("chunk after IEND") }
            if !seenIHDR && type != "IHDR" { v.errors.append("first chunk is not IHDR") }
            if ["IHDR", "PLTE", "IEND", "tRNS", "gAMA", "sRGB", "iCCP", "pHYs", "cHRM", "sBIT", "bKGD", "hIST"].contains(type) {
                if singles.contains(type) { v.errors.append("duplicate \(type)") }
                singles.insert(type)
            }
            switch type {
            case "IHDR":
                if seenIHDR { break }
                guard len == 13 else { v.errors.append("IHDR length"); return v }
                seenIHDR = true
                v.width = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
                v.height = Int(body[4]) << 24 | Int(body[5]) << 16 | Int(body[6]) << 8 | Int(body[7])
                v.bitDepth = body[8]; v.colorType = body[9]; interlace = body[12]
                if v.width <= 0 || v.height <= 0 { v.errors.append("zero dimension") }
                let legal: [UInt8: [UInt8]] = [0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16]]
                if legal[v.colorType]?.contains(v.bitDepth) != true { v.errors.append("illegal colour type / bit depth \(v.colorType)/\(v.bitDepth)") }
                if body[10] != 0 || body[11] != 0 { v.errors.append("bad compression / filter method") }
                if interlace > 1 { v.errors.append("bad interlace method") }
            case "PLTE":
                if seenIDAT { v.errors.append("PLTE after IDAT") }
                if seenTRNS { v.errors.append("PLTE after tRNS") }
                if len % 3 != 0 || len == 0 || len > 768 { v.errors.append("bad PLTE length") }
                if v.colorType == 0 || v.colorType == 4 { v.errors.append("PLTE in grayscale image") }
                if v.colorType == 3, len / 3 > (1 << Int(v.bitDepth)) { v.errors.append("PLTE larger than bit depth allows") }
                seenPLTE = true; plte = body; v.paletteCount = len / 3
            case "tRNS":
                if seenIDAT { v.errors.append("tRNS after IDAT") }
                if v.colorType == 3 && !seenPLTE { v.errors.append("tRNS before PLTE") }
                if v.colorType == 4 || v.colorType == 6 { v.errors.append("tRNS with alpha channel") }
                if v.colorType == 3 && len > plte.count / 3 { v.errors.append("tRNS longer than palette") }
                if v.colorType == 0 && len != 2 { v.errors.append("tRNS length (gray)") }
                if v.colorType == 2 && len != 6 { v.errors.append("tRNS length (RGB)") }
                seenTRNS = true; trns = body
            case "IDAT":
                if idatEnded { v.errors.append("IDAT chunks not consecutive") }
                if v.colorType == 3 && !seenPLTE { v.errors.append("IDAT before PLTE") }
                seenIDAT = true; idat.append(contentsOf: body)
            case "IEND":
                if len != 0 { v.errors.append("IEND not empty") }
                seenIEND = true
            case "iCCP", "sRGB", "gAMA", "cHRM", "sBIT":
                if seenPLTE || seenIDAT { v.errors.append("\(type) after PLTE / IDAT") }
            case "pHYs":
                if seenIDAT { v.errors.append("pHYs after IDAT") }
            default:
                if let f = type.utf8.first, f & 0x20 == 0 { v.errors.append("unknown critical chunk \(type)") }
            }
            if seenIDAT && type != "IDAT" { idatEnded = true }
            pos += 12 + len
        }
        if pos != d.count { v.errors.append("trailing bytes") }
        if !seenIEND { v.errors.append("missing IEND") }
        if !seenIDAT { v.errors.append("missing IDAT"); return v }
        if v.colorType == 3 && !seenPLTE { v.errors.append("missing PLTE"); return v }
        guard v.errors.isEmpty else { return v }
        v.idatBytes = idat.count
        if interlace != 0 { v.errors.append("interlaced (not produced by Ultra PNG)"); return v }
        let channels: Int = [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][v.colorType] ?? 1
        let rowBytes = (v.width * channels * Int(v.bitDepth) + 7) / 8
        let bpp = max(1, channels * Int(v.bitDepth) / 8)
        guard let raw = UPZlib.inflate(idat, expected: (rowBytes + 1) * v.height) else { v.errors.append("zlib stream corrupt or wrong size"); return v }
        // un-filter
        var img = [UInt8](repeating: 0, count: rowBytes * v.height)
        var bad = false
        raw.withUnsafeBufferPointer { src in
            img.withUnsafeMutableBufferPointer { dst in
                for y in 0..<v.height {
                    let f = src[y * (rowBytes + 1)]
                    let s = y * (rowBytes + 1) + 1, o = y * rowBytes, up = o - rowBytes
                    switch f {
                    case 0: for i in 0..<rowBytes { dst[o + i] = src[s + i] }
                    case 1: for i in 0..<rowBytes { dst[o + i] = src[s + i] &+ (i >= bpp ? dst[o + i - bpp] : 0) }
                    case 2: for i in 0..<rowBytes { dst[o + i] = src[s + i] &+ (y > 0 ? dst[up + i] : 0) }
                    case 3:
                        for i in 0..<rowBytes {
                            let a = i >= bpp ? Int(dst[o + i - bpp]) : 0, b = y > 0 ? Int(dst[up + i]) : 0
                            dst[o + i] = src[s + i] &+ UInt8((a + b) >> 1)
                        }
                    case 4:
                        for i in 0..<rowBytes {
                            let a = i >= bpp ? Int(dst[o + i - bpp]) : 0, b = y > 0 ? Int(dst[up + i]) : 0, c = (i >= bpp && y > 0) ? Int(dst[up + i - bpp]) : 0
                            let p = a + b - c
                            let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                            dst[o + i] = src[s + i] &+ UInt8(pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
                        }
                    default: bad = true
                    }
                }
            }
        }
        if bad { v.errors.append("illegal filter type"); return v }
        // expand to RGBA
        let w = v.width, h = v.height
        if v.bitDepth == 16 {
            var out = [UInt16](repeating: 65535, count: w * h * 4)
            var key: [UInt16]? = nil
            if let t = trns { key = stride(from: 0, to: t.count, by: 2).map { UInt16(t[$0]) << 8 | UInt16(t[$0 + 1]) } }
            for y in 0..<h {
                for x in 0..<w {
                    func s(_ k: Int) -> UInt16 { let o = y * rowBytes + (x * channels + k) * 2; return UInt16(img[o]) << 8 | UInt16(img[o + 1]) }
                    let o = (y * w + x) * 4
                    switch v.colorType {
                    case 0: let g = s(0); out[o] = g; out[o + 1] = g; out[o + 2] = g; if let k = key, k[0] == g { out[o + 3] = 0 }
                    case 2: out[o] = s(0); out[o + 1] = s(1); out[o + 2] = s(2); if let k = key, k[0] == s(0), k[1] == s(1), k[2] == s(2) { out[o + 3] = 0 }
                    case 4: let g = s(0); out[o] = g; out[o + 1] = g; out[o + 2] = g; out[o + 3] = s(1)
                    default: out[o] = s(0); out[o + 1] = s(1); out[o + 2] = s(2); out[o + 3] = s(3)
                    }
                }
            }
            v.image = UPImage(width: w, height: h, px16: out)
            return v
        }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let bd = Int(v.bitDepth), maxv = (1 << bd) - 1
        var indexOverflow = false
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                switch v.colorType {
                case 0, 3:
                    var s: Int
                    if bd == 8 { s = Int(img[y * rowBytes + x]) } else { let bit = x * bd; s = (Int(img[y * rowBytes + bit / 8]) >> (8 - bd - bit % 8)) & maxv }
                    if v.colorType == 3 {
                        if s * 3 + 2 >= plte.count { indexOverflow = true; continue }
                        out[o] = plte[s * 3]; out[o + 1] = plte[s * 3 + 1]; out[o + 2] = plte[s * 3 + 2]
                        if let t = trns, s < t.count { out[o + 3] = t[s] }
                    } else {
                        if let t = trns, t.count == 2, Int(t[0]) << 8 | Int(t[1]) == s { out[o + 3] = 0 }
                        s = s * 255 / maxv
                        out[o] = UInt8(s); out[o + 1] = UInt8(s); out[o + 2] = UInt8(s)
                    }
                case 2:
                    let i = y * rowBytes + x * 3
                    out[o] = img[i]; out[o + 1] = img[i + 1]; out[o + 2] = img[i + 2]
                    if let t = trns, t.count == 6, t[1] == img[i], t[3] == img[i + 1], t[5] == img[i + 2], t[0] == 0, t[2] == 0, t[4] == 0 { out[o + 3] = 0 }
                case 4:
                    let i = y * rowBytes + x * 2
                    out[o] = img[i]; out[o + 1] = img[i]; out[o + 2] = img[i]; out[o + 3] = img[i + 1]
                default:
                    let i = y * rowBytes + x * 4
                    out[o] = img[i]; out[o + 1] = img[i + 1]; out[o + 2] = img[i + 2]; out[o + 3] = img[i + 3]
                }
            }
        }
        if indexOverflow { v.errors.append("palette index out of range"); return v }
        v.image = UPImage(width: w, height: h, px: out)
        return v
    }
}

// MARK: - zlib

enum UPZlib {
    /// zlib-wrapped deflate with full control over level / strategy / memLevel / window.
    static func deflate(_ src: UnsafeBufferPointer<UInt8>, level: Int32, strategy: Int32, memLevel: Int32 = 8, windowBits: Int32 = 15,
                        dictionary: UnsafeBufferPointer<UInt8>? = nil) -> [UInt8] {
        var s = z_stream()
        guard deflateInit2_(&s, level, Z_DEFLATED, windowBits, memLevel, strategy, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return [] }
        defer { deflateEnd(&s) }
        if let d = dictionary, d.count > 0 { deflateSetDictionary(&s, d.baseAddress, uInt(d.count)) }
        let bound = Int(deflateBound(&s, uLong(src.count))) + 64
        var out = [UInt8](repeating: 0, count: bound)
        var produced = 0
        out.withUnsafeMutableBufferPointer { o in
            s.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
            s.avail_in = uInt(src.count)
            s.next_out = o.baseAddress
            s.avail_out = uInt(bound)
            _ = zlib.deflate(&s, Z_FINISH)
            produced = bound - Int(s.avail_out)
        }
        out.removeLast(bound - produced)
        return out
    }

    static func deflate(_ src: [UInt8], level: Int32, strategy: Int32, memLevel: Int32 = 8, windowBits: Int32 = 15) -> [UInt8] {
        src.withUnsafeBufferPointer { deflate($0, level: level, strategy: strategy, memLevel: memLevel, windowBits: windowBits) }
    }

    /// Compressed size only (bytes), optionally primed with a dictionary (used by the brute-force row filter search).
    static func deflatedSize(_ src: UnsafeBufferPointer<UInt8>, level: Int32, strategy: Int32 = Z_DEFAULT_STRATEGY, memLevel: Int32 = 8,
                             dictionary: UnsafeBufferPointer<UInt8>? = nil) -> Int {
        deflate(src, level: level, strategy: strategy, memLevel: memLevel, dictionary: dictionary).count
    }

    static func inflate(_ data: [UInt8], expected: Int) -> [UInt8]? {
        var s = z_stream()
        guard inflateInit_(&s, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&s) }
        var out = [UInt8](repeating: 0, count: expected + 1)
        var ok = false
        data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { o in
                s.next_in = UnsafeMutablePointer(mutating: src.baseAddress)
                s.avail_in = uInt(src.count)
                s.next_out = o.baseAddress
                s.avail_out = uInt(expected + 1)
                let r = zlib.inflate(&s, Z_FINISH)
                ok = r == Z_STREAM_END && Int(s.total_out) == expected && s.avail_in == 0
            }
        }
        guard ok else { return nil }
        out.removeLast()
        return out
    }

    /// Wraps a raw deflate stream in a zlib container (header + Adler-32 of the uncompressed data).
    static func wrap(rawDeflate: [UInt8], of source: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(rawDeflate.count + 6)
        out.append(0x78); out.append(0xDA)
        out.append(contentsOf: rawDeflate)
        let a = UInt32(truncatingIfNeeded: adler32(1, source.baseAddress, uInt(source.count)))
        out.append(contentsOf: UPPNG.be32(a))
        return out
    }

    /// gzip size of arbitrary data (what a web server would transfer with `Content-Encoding: gzip`).
    static func gzipSize(_ data: Data, level: Int32 = 9) -> Int {
        data.withUnsafeBytes { p -> Int in
            deflate(p.bindMemory(to: UInt8.self), level: level, strategy: Z_DEFAULT_STRATEGY, memLevel: 9, windowBits: 15 + 16).count
        }
    }
}

/// Cooperative cancellation + progress shared by the long-running encoders.
final class UPProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false
    private var _fraction = 0.0
    private var _stage = ""
    private var parent: UPProgress? = nil
    private var forward: ((Double, String) -> Void)? = nil
    var onUpdate: ((Double, String) -> Void)?

    init() {}

    /// A child that maps its 0…1 range onto [from, to] of this progress and shares its cancellation.
    func child(from: Double, to: Double) -> UPProgress {
        child { [weak self] f, s in self?.report(from + (to - from) * min(1, max(0, f)), s) }
    }

    /// A child that shares this progress' cancellation and hands its reports to `forward`.
    func child(_ forward: @escaping (Double, String) -> Void) -> UPProgress {
        let c = UPProgress()
        c.parent = self; c.forward = forward
        return c
    }

    var cancelled: Bool {
        lock.lock(); let c = _cancelled; lock.unlock()
        return c || (parent?.cancelled ?? false)
    }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    var fraction: Double { lock.lock(); defer { lock.unlock() }; return _fraction }
    var stage: String { lock.lock(); defer { lock.unlock() }; return _stage }
    func report(_ f: Double, _ s: String) {
        lock.lock(); _fraction = f; _stage = s; let cb = onUpdate; let fw = forward; lock.unlock()
        cb?(f, s)
        fw?(f, s)
    }
}
