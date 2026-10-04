import Foundation
import CoreImage
import Compression
import ImageCratCore

/// GIF / PNG-8 writers that keep the exact colour table (and transparent index) of Indexed / Bitmap documents.
enum IndexedExport {
    // MARK: Hook used by DocumentIO.export

    /// Writes Indexed Color / Bitmap documents as palette GIF or PNG-8. Returns false when not applicable.
    static func exportIfNeeded(_ st: DocumentState, to url: URL, format: ExportFormat, scale: Double) throws -> Bool {
        guard format == .gif || format == .png, st.colorMode == .indexed || st.colorMode == .bitmap else { return false }
        let (palette, ti) = paletteFor(st)
        let (idx, w, h) = indices(st, palette: palette, transparentIndex: ti, scale: scale)
        let data: Data
        if format == .gif {
            data = gif(indices: idx, width: w, height: h, palette: palette, transparentIndex: ti)
        } else {
            data = png(indices: idx, width: w, height: h, palette: palette, transparentIndex: ti, dpi: st.resolution)
        }
        try data.write(to: url, options: .atomic)
        return true
    }

    static func paletteFor(_ st: DocumentState) -> ([RGBA], Int?) {
        if st.colorMode == .bitmap { return ([.black, .white], nil) }
        if let t = st.imaging?.colorTable, !t.isEmpty { return (t, st.imaging?.transparentIndex) }
        return (Palettes.web, nil)
    }

    static func indices(_ st: DocumentState, palette: [RGBA], transparentIndex: Int?, scale: Double) -> ([UInt8], Int, Int) {
        let sp = CanvasSpace(width: st.width, height: st.height)
        var ci = Compositor.shared.composite(st)
        var rect = sp.ciCanvas
        if abs(scale - 1) > 0.001 {
            ci = ci.cropped(to: rect).samplingNearest().transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            rect = CGRect(x: 0, y: 0, width: max(1, Int(Double(st.width) * scale)), height: max(1, Int(Double(st.height) * scale)))
        }
        let w = Int(rect.width), h = Int(rect.height)
        let buf = PixelBuffer(width: w, height: h)
        RenderEngine.readbackContext.render(ci.composited(over: CIImage.clearImage.cropped(to: rect)), toBitmap: buf.data, rowBytes: buf.bytesPerRow,
                                            bounds: rect, format: .RGBA8, colorSpace: sRGBSpace)
        buf.markDirty()
        let idx = Quantizer.indices(buf, palette: palette, transparentIndex: transparentIndex, dither: .none, amount: 0, preserveExact: true, matte: .white)
        return (idx, w, h)
    }

    // MARK: GIF (LZW)

    static func gif(indices: [UInt8], width: Int, height: Int, palette: [RGBA], transparentIndex: Int?) -> Data {
        var d = Data("GIF89a".utf8)
        func u16(_ v: Int) { d.append(UInt8(v & 255)); d.append(UInt8((v >> 8) & 255)) }
        var bits = 1
        while (1 << bits) < max(2, palette.count) { bits += 1 }
        u16(width); u16(height)
        d.append(0x80 | UInt8((bits - 1) << 4) | UInt8(bits - 1))
        d.append(0); d.append(0)
        for i in 0..<(1 << bits) {
            if i < palette.count { let c = palette[i]; d.append(UInt8(c.r8)); d.append(UInt8(c.g8)); d.append(UInt8(c.b8)) } else { d.append(contentsOf: [0, 0, 0]) }
        }
        if let t = transparentIndex {
            d.append(contentsOf: [0x21, 0xF9, 0x04, 0x01, 0, 0, UInt8(t), 0])
        }
        d.append(0x2C); u16(0); u16(0); u16(width); u16(height); d.append(0)
        let minCode = max(2, bits)
        d.append(UInt8(minCode))
        let lzw = lzwEncode(indices, minCodeSize: minCode)
        var i = 0
        while i < lzw.count {
            let n = min(255, lzw.count - i)
            d.append(UInt8(n))
            d.append(contentsOf: lzw[i..<(i + n)])
            i += n
        }
        d.append(0)
        d.append(0x3B)
        return d
    }

    static func lzwEncode(_ data: [UInt8], minCodeSize: Int) -> [UInt8] {
        let clear = 1 << minCodeSize, eoi = clear + 1
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 2)
        var bitBuf = 0, bitCount = 0
        var codeSize = minCodeSize + 1
        func emit(_ code: Int) {
            bitBuf |= code << bitCount
            bitCount += codeSize
            while bitCount >= 8 { out.append(UInt8(bitBuf & 255)); bitBuf >>= 8; bitCount -= 8 }
        }
        var table = [Int16](repeating: -1, count: 4096 * 256)
        var next = eoi + 1
        emit(clear)
        guard !data.isEmpty else { emit(eoi); if bitCount > 0 { out.append(UInt8(bitBuf & 255)) }; return out }
        table.withUnsafeMutableBufferPointer { tb in
            data.withUnsafeBufferPointer { src in
                var prefix = Int(src[0])
                for i in 1..<src.count {
                    let k = Int(src[i])
                    let slot = prefix * 256 + k
                    let e = Int(tb[slot])
                    if e >= 0 { prefix = e; continue }
                    emit(prefix)
                    if next < 4096 {
                        tb[slot] = Int16(next)
                        next += 1
                        if next > (1 << codeSize) && codeSize < 12 { codeSize += 1 }
                    } else {
                        emit(clear)
                        for j in 0..<tb.count { tb[j] = -1 }
                        next = eoi + 1
                        codeSize = minCodeSize + 1
                    }
                    prefix = k
                }
                emit(prefix)
            }
        }
        emit(eoi)
        if bitCount > 0 { out.append(UInt8(bitBuf & 255)) }
        return out
    }

    // MARK: PNG-8

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ bytes: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    static func zlib(_ raw: Data) -> Data {
        var out = Data([0x78, 0x9C])
        let cap = raw.count + raw.count / 10 + 1024
        var dst = [UInt8](repeating: 0, count: cap)
        let n = raw.withUnsafeBytes { src in
            compression_encode_buffer(&dst, cap, src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
        }
        out.append(contentsOf: dst[0..<n])
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)])
        return out
    }

    static func png(indices: [UInt8], width: Int, height: Int, palette: [RGBA], transparentIndex: Int?, dpi: Double = 72) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        func be32(_ v: UInt32, _ into: inout Data) { into.append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]) }
        func chunk(_ type: String, _ body: Data) {
            be32(UInt32(body.count), &d)
            var td = Data(type.utf8); td.append(body)
            d.append(td)
            be32(crc32(td), &d)
        }
        let depth = palette.count <= 2 ? 1 : (palette.count <= 4 ? 2 : (palette.count <= 16 ? 4 : 8))
        var ihdr = Data()
        be32(UInt32(width), &ihdr); be32(UInt32(height), &ihdr)
        ihdr.append(contentsOf: [UInt8(depth), 3, 0, 0, 0])
        chunk("IHDR", ihdr)
        var plte = Data()
        for c in palette { plte.append(contentsOf: [UInt8(c.r8), UInt8(c.g8), UInt8(c.b8)]) }
        chunk("PLTE", plte)
        if let t = transparentIndex, t < palette.count {
            var trns = Data(repeating: 255, count: t + 1)
            trns[t] = 0
            chunk("tRNS", trns)
        }
        var phys = Data()
        let ppm = UInt32(max(1, dpi / 0.0254))
        be32(ppm, &phys); be32(ppm, &phys); phys.append(1)
        chunk("pHYs", phys)
        let rowBytes = (width * depth + 7) / 8
        var raw = Data(count: (rowBytes + 1) * height)
        raw.withUnsafeMutableBytes { rb in
            let p = rb.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<height {
                let row = p + y * (rowBytes + 1)
                row[0] = 0
                if depth == 8 {
                    for x in 0..<width { row[1 + x] = indices[y * width + x] }
                } else {
                    let perByte = 8 / depth
                    for x in 0..<width {
                        let v = indices[y * width + x] & UInt8((1 << depth) - 1)
                        let shift = (perByte - 1 - x % perByte) * depth
                        row[1 + x / perByte] |= v << UInt8(shift)
                    }
                }
            }
        }
        chunk("IDAT", zlib(raw))
        chunk("IEND", Data())
        return d
    }

    // MARK: Inspection (tests)

    /// Number of colour-table entries declared by a GIF (global table) or PNG (PLTE chunk).
    static func declaredPaletteSize(_ url: URL) -> Int? {
        guard let d = try? Data(contentsOf: url), d.count > 16 else { return nil }
        if d.starts(with: Data("GIF8".utf8)) {
            let packed = d[10]
            guard packed & 0x80 != 0 else { return 0 }
            return 1 << (Int(packed & 7) + 1)
        }
        var i = 8
        while i + 8 <= d.count {
            let len = Int(d[i]) << 24 | Int(d[i + 1]) << 16 | Int(d[i + 2]) << 8 | Int(d[i + 3])
            let type = String(data: d[(i + 4)..<(i + 8)], encoding: .ascii)
            if type == "PLTE" { return len / 3 }
            i += 12 + len
        }
        return nil
    }
}
