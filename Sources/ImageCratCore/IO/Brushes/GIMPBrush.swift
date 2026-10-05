import Foundation

/// GIMP brushes: `.gbr` (single tip) and `.gih` (image pipe = animated tip).
///
/// GBR (all fields big-endian u32): header_size, version, width, height, bytes per pixel, then (version ≥ 2) magic
/// "GIMP" and spacing (percent), then the UTF-8 name (NUL terminated, header_size − 28 bytes; version 1 has no magic or
/// spacing, so the name is header_size − 20 bytes), then width × height × bytes of pixel data.
/// * bytes = 1: gray mask, 255 = full paint (GIMP's file-gbr saves 255 − image value, so black in the image paints).
/// * bytes = 4: RGBA "pixmap" brush; GIMP uses the alpha channel as the mask. A fully opaque pixmap falls back to the
///   shared coverage rule (`BrushTipImaging.grayCoverage`: dark = paint).
/// * version 3 with bytes = 18: CinePaint 16-bit float gray.
///
/// GIH: line 1 = name, line 2 = "<ncells> ncells:<n> cellwidth:… cellheight:… step:… dim:… cols:… rows:…
/// placement:… rank0:… sel0:…", followed by ncells complete GBR brushes.
package enum GIMPBrush {
    package static let maxSide = 8192
    package static let maxCells = 4096

    /// One decoded GBR.
    package struct Tip {
        package var name: String
        package var width: Int
        package var height: Int
        /// Spacing in percent of the brush size.
        package var spacing: Int
        /// Tightly packed coverage (255 = paint).
        package var coverage: [UInt8]
        package var isPixmap: Bool
        package init(name: String, width: Int, height: Int, spacing: Int, coverage: [UInt8], isPixmap: Bool) {
            self.name = name; self.width = width; self.height = height; self.spacing = spacing
            self.coverage = coverage; self.isPixmap = isPixmap
        }
    }

    /// True when the data starts with a GBR header carrying the "GIMP" magic.
    package static func isGBR(_ data: Data) -> Bool {
        guard data.count >= 28 else { return false }
        let b = [UInt8](data.prefix(28))
        return b[20] == 0x47 && b[21] == 0x49 && b[22] == 0x4D && b[23] == 0x50
    }

    /// Heuristic for an image pipe: a text line, then a parameter line containing "ncells:", then a GBR.
    package static func looksLikeGIH(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(4096))
        guard let nl1 = head.firstIndex(of: 0x0A), let nl2 = head[(nl1 + 1)...].firstIndex(of: 0x0A) else { return false }
        let line = String(decoding: head[(nl1 + 1)..<nl2], as: UTF8.self)
        return line.contains("ncells:") || line.split(separator: " ").first.map { Int($0) != nil } == true && line.contains(":")
    }

    // MARK: Decoding

    /// Decodes the GBR at `offset` and advances it past the brush.
    package static func decodeTip(_ b: [UInt8], offset: inout Int) throws -> Tip {
        let p = offset
        func be32(_ i: Int) throws -> Int {
            guard i >= 0, i + 4 <= b.count else { throw BrushImportError.malformed("GIMP brush header truncated") }
            return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        let headerSize = try be32(p)
        let version = try be32(p + 4)
        let w = try be32(p + 8), h = try be32(p + 12)
        var bytes = try be32(p + 16)
        var spacing = 25
        let fixed: Int
        switch version {
        case 1:
            fixed = 20
        case 2, 3:
            guard try be32(p + 20) == 0x4749_4D50 else { throw BrushImportError.malformed("GIMP brush magic") }
            spacing = try be32(p + 24)
            fixed = 28
            if version == 3 {
                guard bytes == 18 else { throw BrushImportError.unsupportedFormat("GIMP brush version 3 pixel type \(bytes)") }
                bytes = 2
            }
        default:
            throw BrushImportError.unsupportedVersion(version)
        }
        guard headerSize >= fixed, headerSize <= b.count - p else { throw BrushImportError.malformed("GIMP brush header size") }
        guard w > 0, h > 0, w <= maxSide, h <= maxSide else { throw BrushImportError.malformed("GIMP brush size \(w)×\(h)") }
        guard bytes == 1 || bytes == 2 || bytes == 4 else {
            throw BrushImportError.unsupportedFormat("GIMP brush with \(bytes) bytes per pixel")
        }
        let nameBytes = b[(p + fixed)..<(p + headerSize)]
        let nameEnd = nameBytes.firstIndex(of: 0) ?? nameBytes.endIndex
        let name = String(decoding: nameBytes[nameBytes.startIndex..<nameEnd], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let start = p + headerSize
        let size = w * h * bytes
        guard size <= b.count - start else { throw BrushImportError.malformed("GIMP brush pixel data truncated") }
        var cov = [UInt8](repeating: 0, count: w * h)
        var pixmap = false
        switch bytes {
        case 1:
            for i in 0..<(w * h) { cov[i] = b[start + i] }
        case 2:
            for i in 0..<(w * h) {
                let half = UInt16(b[start + 2 * i]) << 8 | UInt16(b[start + 2 * i + 1])
                let f = Double(halfToFloat(half))
                cov[i] = UInt8(max(0, min(255, (f.isFinite ? f : 0) * 255 + 0.5)))
            }
        default:
            pixmap = true
            var translucent = 0
            for i in 0..<(w * h) where b[start + 4 * i + 3] < 250 { translucent += 1 }
            if Double(translucent) >= 0.005 * Double(w * h) {
                for i in 0..<(w * h) { cov[i] = b[start + 4 * i + 3] }
            } else {
                let buf = PixelBuffer(width: w, height: h, format: .rgba)
                let d = buf.data.assumingMemoryBound(to: UInt8.self)
                for y in 0..<h {
                    for x in 0..<w {
                        let s = start + 4 * (y * w + x)
                        let a = Int(b[s + 3])
                        let o = y * buf.bytesPerRow + x * 4
                        for c in 0..<3 { d[o + c] = UInt8((Int(b[s + c]) * a + 127) / 255) }
                        d[o + 3] = UInt8(a)
                    }
                }
                cov = BrushTipImaging.tightGray(BrushTipImaging.grayCoverage(fromRGBA: buf))
            }
        }
        offset = start + size
        return Tip(name: name, width: w, height: h, spacing: spacing, coverage: cov, isPixmap: pixmap)
    }

    private static func halfToFloat(_ h: UInt16) -> Float {
        let sign: UInt32 = UInt32(h >> 15) << 31
        let exp = Int((h >> 10) & 0x1F)
        let mant = UInt32(h & 0x3FF)
        if exp == 0 {
            return (sign != 0 ? -1 : 1) * Float(mant) / 1024 / 16384   // subnormal: mant × 2^-24
        }
        if exp == 31 { return Float(bitPattern: sign | 0x7F80_0000 | (mant << 13)) }
        return Float(bitPattern: sign | UInt32(exp - 15 + 127) << 23 | (mant << 13))
    }

    private static func params(for tip: Tip) -> BrushParams {
        var p = BrushParams(size: Double(max(tip.width, tip.height)), hardness: 1,
                            spacing: tip.spacing > 0 ? Double(tip.spacing) / 100 : 0.25)
        p.sanitize()
        return p
    }

    // MARK: GBR

    package static func readGBR(data: Data, name: String) throws -> ImportedBrushSet {
        let b = [UInt8](data)
        var off = 0
        let tip = try decodeTip(b, offset: &off)
        var set = ImportedBrushSet(name: name, format: "GIMP brush")
        let key = "gbr0"
        set.tips[key] = ImportedTipImage(.gray(BrushTipImaging.squareGray(tip.coverage, width: tip.width, height: tip.height)))
        set.brushes = [ImportedBrush(name: tip.name.isEmpty ? name : tip.name, tipKey: key, params: params(for: tip))]
        return set
    }

    // MARK: GIH

    /// Parsed GIH parameter line.
    package struct PipeParams {
        package var ncells = 1
        package var values: [String: String] = [:]
        package init(ncells: Int = 1, values: [String: String] = [:]) { self.ncells = ncells; self.values = values }
        package var selection: BrushFrameSelection {
            // The selection mode of the first dimension that actually has more than one entry.
            let dim = max(1, min(4, Int(values["dim"] ?? "1") ?? 1))
            var chosen = values["sel0"]
            for i in 0..<dim {
                if let r = Int(values["rank\(i)"] ?? ""), r > 1 { chosen = values["sel\(i)"]; break }
            }
            switch (chosen ?? "incremental").lowercased() {
            case "random": return .random
            case "angular", "xtilt", "ytilt": return .angular
            case "pressure": return .pressure
            case "velocity": return .velocity
            default: return .incremental
            }
        }
    }

    package static func parsePipeParams(_ line: String) -> PipeParams {
        var p = PipeParams()
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
        if let first = parts.first, let n = Int(first) { p.ncells = n }
        for part in parts {
            guard let c = part.firstIndex(of: ":") else { continue }
            p.values[String(part[..<c]).lowercased()] = String(part[part.index(after: c)...])
        }
        if let n = Int(p.values["ncells"] ?? "") { p.ncells = n }
        return p
    }

    package static func readGIH(data: Data, name: String) throws -> ImportedBrushSet {
        let b = [UInt8](data)
        let head = b.prefix(65536)
        guard let nl1 = head.firstIndex(of: 0x0A), let nl2 = head[(nl1 + 1)...].firstIndex(of: 0x0A) else {
            throw BrushImportError.malformed("GIMP image pipe header")
        }
        let pipeName = String(decoding: b[0..<nl1], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let params = parsePipeParams(String(decoding: b[(nl1 + 1)..<nl2], as: UTF8.self))
        guard params.ncells >= 1 else { throw BrushImportError.noBrushes }
        let ncells = min(params.ncells, maxCells)
        var set = ImportedBrushSet(name: name, format: "GIMP image pipe")
        var tips: [Tip] = []
        var off = nl2 + 1
        var totalPixels = 0
        for i in 0..<ncells {
            do {
                let t = try decodeTip(b, offset: &off)
                totalPixels += t.width * t.height
                if totalPixels > 256 << 20 { set.skipped.append("Cells \(i + 1)–\(ncells): too much image data"); break }
                tips.append(t)
            } catch {
                set.skipped.append("Cell \(i + 1) of \(params.ncells): \((error as? LocalizedError)?.errorDescription ?? "unreadable")")
                break
            }
        }
        guard let first = tips.first else { throw BrushImportError.noBrushes }
        if params.ncells > maxCells { set.skipped.append("Cells beyond \(maxCells) were ignored") }
        let side = tips.map { max($0.width, $0.height) }.max() ?? 1
        let frames = tips.map { BrushImageData.gray(BrushTipImaging.squareGray($0.coverage, width: $0.width, height: $0.height, side: side)) }
        let key = "gih0"
        set.tips[key] = ImportedTipImage(frames: frames, selection: params.selection)
        var p = self.params(for: first)
        p.size = Double(side)
        p.sanitize()
        let display = !pipeName.isEmpty ? pipeName : (!first.name.isEmpty ? first.name : name)
        set.brushes = [ImportedBrush(name: display, tipKey: key, params: p)]
        set.format = "GIMP image pipe (\(frames.count) frame\(frames.count == 1 ? "" : "s"), \(params.selection.rawValue))"
        return set
    }
}

// MARK: - Writer

/// Writes GIMP brushes (used by tests and for exporting).
package enum GIMPBrushWriter {
    private static func be32(_ a: inout [UInt8], _ v: Int) {
        a.append(UInt8((v >> 24) & 0xFF)); a.append(UInt8((v >> 16) & 0xFF)); a.append(UInt8((v >> 8) & 0xFF)); a.append(UInt8(v & 0xFF))
    }

    /// Version 2 GBR. `pixels` is w×h gray coverage (bytes = 1, 255 = paint) or w×h×4 straight RGBA (bytes = 4).
    package static func gbr(name: String, width: Int, height: Int, pixels: [UInt8], bytesPerPixel: Int = 1, spacing: Int = 25) -> Data {
        var out: [UInt8] = []
        let nameBytes = Array(name.utf8) + [0]
        be32(&out, 28 + nameBytes.count)
        be32(&out, 2)
        be32(&out, width)
        be32(&out, height)
        be32(&out, bytesPerPixel)
        out.append(contentsOf: Array("GIMP".utf8))
        be32(&out, spacing)
        out.append(contentsOf: nameBytes)
        let n = width * height * bytesPerPixel
        out.append(contentsOf: pixels.prefix(n))
        if pixels.count < n { out.append(contentsOf: [UInt8](repeating: 0, count: n - pixels.count)) }
        return Data(out)
    }

    /// Image pipe with one dimension (rank0 = cells.count).
    package static func gih(name: String, cells: [(width: Int, height: Int, gray: [UInt8])], spacing: Int = 25,
                            selection: String = "incremental") -> Data {
        let cw = cells.map(\.width).max() ?? 1, ch = cells.map(\.height).max() ?? 1
        var text = "\(name)\n"
        text += "\(cells.count) ncells:\(cells.count) cellwidth:\(cw) cellheight:\(ch) step:\(spacing) dim:1 cols:1 rows:1 "
        text += "placement:constant rank0:\(cells.count) sel0:\(selection)\n"
        var out = Data(text.utf8)
        for (i, c) in cells.enumerated() {
            out.append(gbr(name: "\(name) \(i)", width: c.width, height: c.height, pixels: c.gray, spacing: spacing))
        }
        return out
    }
}
