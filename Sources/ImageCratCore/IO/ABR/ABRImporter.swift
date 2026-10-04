import Foundation

/// A brush tip imported from a Photoshop .abr file.
package struct ImportedBrushTip {
    package var name: String
    /// .gray, white = paint on black, padded to a square (content centred).
    package var tip: PixelBuffer
    /// Stamp spacing as a fraction of the diameter (0.25 = 25%).
    package var spacing: Double
    /// Nominal diameter in pixels.
    package var diameter: Double
    package init(name: String, tip: PixelBuffer, spacing: Double, diameter: Double) {
        self.name = name; self.tip = tip; self.spacing = spacing; self.diameter = diameter
    }
}

package enum ABRImportError: LocalizedError {
    case malformed(String)
    case unsupportedVersion(Int)
    case noBrushes

    package var errorDescription: String? {
        switch self {
        case .malformed(let s): return "The brush file is damaged (\(s))."
        case .unsupportedVersion(let v): return "Brush file version \(v) is not supported."
        case .noBrushes: return "The file contains no brushes that can be imported."
        }
    }
}

/// Photoshop brush (.abr) importer.
///
/// * Versions 1 & 2: a flat list of brushes. Sampled brushes (type 2) are decoded; computed brushes
///   (type 1) are rendered as round/elliptical tips from their diameter, hardness, roundness and angle.
/// * Versions 6, 7, 10: `8BIM` tagged sections. Tip bitmaps come from `8BIMsamp` (8 or 16 bit, raw or
///   PackBits); names, spacing and diameters come from the `8BIMdesc` action descriptor when it parses,
///   and computed presets described there are rendered as round tips.
///
/// All reads are bounds checked; malformed input throws instead of crashing.
package enum ABRImporter {
    /// Upper bound on tip size (per side) to reject garbage headers before allocating.
    package static let maxTipSide = 10_000

    package static func load(url: URL) throws -> [ImportedBrushTip] {
        try load(data: Data(contentsOf: url))
    }

    package static func load(data: Data) throws -> [ImportedBrushTip] {
        var r = Reader(Array(data))
        let version = Int(try r.u16())
        let tips: [ImportedBrushTip]
        switch version {
        case 1, 2: tips = try loadV12(&r, version: version)
        case 6, 7, 10: tips = try loadV6(&r)
        default: throw ABRImportError.unsupportedVersion(version)
        }
        if tips.isEmpty { throw ABRImportError.noBrushes }
        return tips
    }

    // MARK: - Version 1 / 2

    private static func loadV12(_ r: inout Reader, version: Int) throws -> [ImportedBrushTip] {
        let count = Int(try r.u16())
        var out: [ImportedBrushTip] = []
        for n in 0..<count {
            guard r.remaining >= 6 else { break }   // tolerate truncated trailing entries
            let type = try r.u16()
            let size = Int(try r.u32())
            guard size >= 0, size <= r.remaining else { throw ABRImportError.malformed("brush \(n + 1) length") }
            var b = try r.sub(size)
            do {
                switch type {
                case 1:
                    // misc(4) spacing(2) diameter(2) roundness(2) angle(2) hardness(2)
                    _ = try b.u32()
                    let spacing = Int(try b.u16())
                    let diameter = Int(try b.u16())
                    let roundness = Int(try b.u16())
                    let angle = Int(try b.i16())
                    let hardness = Int(try b.u16())
                    let d = max(1, min(maxTipSide / 2, diameter))
                    out.append(ImportedBrushTip(name: "Brush \(out.count + 1)",
                                                tip: renderRound(diameter: d, hardness: Double(min(100, hardness)) / 100,
                                                                 roundness: Double(max(1, min(100, roundness == 0 ? 100 : roundness))) / 100,
                                                                 angle: Double(angle)),
                                                spacing: spacingFraction(spacing), diameter: Double(d)))
                case 2:
                    _ = try b.u32()                       // misc
                    let spacing = Int(try b.u16())
                    var name = ""
                    if version == 2 { name = try b.unicodeString() }
                    _ = try b.u8()                        // anti-aliasing
                    try b.skip(8)                         // short bounds
                    let top = Int(try b.i32()), left = Int(try b.i32())
                    let bottom = Int(try b.i32()), right = Int(try b.i32())
                    let depth = Int(try b.u16())
                    let compression = try b.u8()
                    let w = right - left, h = bottom - top
                    let bmp = try decodeBitmap(&b, width: w, height: h, depth: depth, compressed: compression != 0)
                    let side = max(w, h)
                    out.append(ImportedBrushTip(name: name.isEmpty ? "Brush \(out.count + 1)" : name,
                                                tip: squarePadded(bmp, width: w, height: h),
                                                spacing: spacingFraction(spacing), diameter: Double(side)))
                default:
                    break   // unknown type: skip
                }
            } catch {
                continue   // a single broken brush shouldn't prevent importing the others
            }
        }
        return out
    }

    /// Sample UUIDs are compared without NULs, a leading "$" or surrounding whitespace.
    private static func normalizedKey(_ k: String) -> String {
        var t = k.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
        if t.hasPrefix("$") { t.removeFirst() }
        return t.lowercased()
    }

    private static func spacingFraction(_ percent: Int) -> Double {
        percent <= 0 || percent > 1000 ? 0.25 : Double(percent) / 100
    }

    // MARK: - Version 6+

    private struct Sample {
        package var key: String
        package var tip: PixelBuffer
        package var side: Int
    }

    private struct Preset {
        package var name: String?
        package var sampleKey: String?
        package var diameter: Double?
        package var spacing: Double?     // fraction
        package var hardness: Double?
        package var roundness: Double?
        package var angle: Double?
        package var computed: Bool
    }

    private static func loadV6(_ r: inout Reader) throws -> [ImportedBrushTip] {
        let subversion = Int(try r.u16())
        var samples: [Sample] = []
        var presets: [Preset]? = nil
        var sawSamp = false

        while r.remaining >= 12 {
            // Tolerate padding between sections.
            if !r.peekASCII("8BIM") {
                var found = false
                for _ in 0..<3 where r.remaining > 12 {
                    try r.skip(1)
                    if r.peekASCII("8BIM") { found = true; break }
                }
                if !found { break }
            }
            try r.skip(4)
            let tag = try r.ascii(4)
            let len = Int(try r.u32())
            guard len <= r.remaining else {
                if tag == "samp" { throw ABRImportError.malformed("sample section length") }
                break
            }
            var s = try r.sub(len)
            switch tag {
            case "samp":
                sawSamp = true
                samples = try readSamples(&s, subversion: subversion)
            case "desc":
                presets = try? readPresets(&s)
            default:
                break
            }
        }
        if !sawSamp && presets == nil { throw ABRImportError.malformed("no brush sections") }

        var out: [ImportedBrushTip] = []
        var used = Set<String>()
        if let presets = presets, !presets.isEmpty {
            var byKey: [String: Sample] = [:]
            for s in samples where byKey[s.key] == nil { byKey[s.key] = s }
            for p in presets {
                let spacing = p.spacing.map { $0 > 0 && $0 <= 10 ? $0 : 0.25 } ?? 0.25
                if let key = p.sampleKey, let s = byKey[key] {
                    used.insert(key)
                    out.append(ImportedBrushTip(name: p.name ?? "Brush \(out.count + 1)", tip: s.tip, spacing: spacing,
                                                diameter: p.diameter.flatMap { $0 > 0 && $0 < 100_000 ? $0 : nil } ?? Double(s.side)))
                } else if p.computed, p.sampleKey == nil {
                    let d = Int(min(Double(maxTipSide / 2), max(1, (p.diameter ?? 30).rounded())))
                    out.append(ImportedBrushTip(name: p.name ?? "Brush \(out.count + 1)",
                                                tip: renderRound(diameter: d, hardness: min(1, max(0, p.hardness ?? 1)),
                                                                 roundness: min(1, max(0.01, p.roundness ?? 1)), angle: p.angle ?? 0),
                                                spacing: spacing, diameter: Double(d)))
                }
            }
        }
        // Samples not referenced by any preset (or no descriptor at all).
        for s in samples where !used.contains(s.key) {
            out.append(ImportedBrushTip(name: "Brush \(out.count + 1)", tip: s.tip, spacing: 0.25, diameter: Double(s.side)))
        }
        return out
    }

    private static func readSamples(_ s: inout Reader, subversion: Int) throws -> [Sample] {
        var out: [Sample] = []
        var index = 0
        while s.remaining >= 4 {
            let size = Int(try s.u32())
            if size == 0 { continue }
            guard size <= s.remaining else {
                if out.isEmpty { throw ABRImportError.malformed("sample length") }
                break
            }
            var b = try s.sub(size)
            // Entries are padded to a multiple of 4.
            let pad = (4 - size % 4) % 4
            try? s.skip(min(pad, s.remaining))
            index += 1
            do {
                let keyLen = Int(try b.u8())
                let keyBytes = try b.bytes(keyLen)
                let key = normalizedKey(String(decoding: keyBytes, as: UTF8.self))
                if subversion == 1 {
                    try b.skip(10)          // short bounds + unknown short
                } else {
                    try b.skip(264)         // unknown
                }
                let top = Int(try b.i32()), left = Int(try b.i32())
                let bottom = Int(try b.i32()), right = Int(try b.i32())
                let depth = Int(try b.u16())
                let compression = try b.u8()
                let w = right - left, h = bottom - top
                let bmp = try decodeBitmap(&b, width: w, height: h, depth: depth, compressed: compression != 0)
                out.append(Sample(key: key.isEmpty ? "#\(index)" : key, tip: squarePadded(bmp, width: w, height: h), side: max(w, h)))
            } catch {
                continue   // skip this sample, keep going
            }
        }
        return out
    }

    // MARK: - Bitmaps

    /// Decodes a w×h tip to 8-bit (one byte per pixel, tightly packed).
    private static func decodeBitmap(_ r: inout Reader, width w: Int, height h: Int, depth: Int, compressed: Bool) throws -> [UInt8] {
        guard w > 0, h > 0, w <= maxTipSide, h <= maxTipSide else { throw ABRImportError.malformed("tip size") }
        guard depth == 8 || depth == 16 else { throw ABRImportError.malformed("bit depth \(depth)") }
        let bpc = depth / 8
        let rowBytes = w * bpc
        var raw = [UInt8](repeating: 0, count: rowBytes * h)
        if !compressed {
            let bytes = try r.bytes(rowBytes * h)
            raw = bytes
        } else {
            var counts = [Int](repeating: 0, count: h)
            for y in 0..<h { counts[y] = Int(try r.u16()) }
            for y in 0..<h {
                var row = try r.sub(counts[y])
                try unpackBits(&row, into: &raw, offset: y * rowBytes, count: rowBytes)
            }
        }
        if bpc == 1 { return raw }
        var out = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let v = UInt32(raw[i * 2]) << 8 | UInt32(raw[i * 2 + 1])
            out[i] = UInt8((v * 255 + 32767) / 65535)
        }
        return out
    }

    private static func unpackBits(_ r: inout Reader, into out: inout [UInt8], offset: Int, count: Int) throws {
        var o = 0
        while o < count && r.remaining > 0 {
            let n = Int(Int8(bitPattern: try r.u8()))
            if n >= 0 {
                let lit = try r.bytes(min(n + 1, r.remaining))
                for b in lit where o < count { out[offset + o] = b; o += 1 }
            } else if n != -128 {
                let b = try r.u8()
                let run = 1 - n
                for _ in 0..<run where o < count { out[offset + o] = b; o += 1 }
            }
        }
    }

    /// Centres a w×h tip in a black square and normalises polarity to white = paint.
    private static func squarePadded(_ px: [UInt8], width w: Int, height h: Int) -> PixelBuffer {
        let invert = looksInverted(px, width: w, height: h)
        let side = max(w, h)
        let buf = PixelBuffer(width: side, height: side, format: .gray)
        let d = buf.data.assumingMemoryBound(to: UInt8.self)
        let ox = (side - w) / 2, oy = (side - h) / 2
        for y in 0..<h {
            let row = d + (y + oy) * buf.bytesPerRow + ox
            for x in 0..<w {
                let v = px[y * w + x]
                row[x] = invert ? 255 - v : v
            }
        }
        buf.markDirty()
        return buf
    }

    /// Photoshop stores samples as coverage (255 = paint). Some third-party writers store black-on-white
    /// instead; detect that by a near-white frame around darker content.
    private static func looksInverted(_ px: [UInt8], width w: Int, height h: Int) -> Bool {
        guard w >= 3, h >= 3 else { return false }
        var border = 0, bn = 0, total = 0
        for y in 0..<h {
            for x in 0..<w {
                let v = Int(px[y * w + x])
                total += v
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 { border += v; bn += 1 }
            }
        }
        let bMean = Double(border) / Double(bn)
        let mean = Double(total) / Double(w * h)
        return bMean >= 240 && mean < bMean - 40
    }

    /// Round/elliptical tip (white on black) for computed brushes.
    package static func renderRound(diameter d: Int, hardness: Double, roundness: Double, angle: Double) -> PixelBuffer {
        let side = max(1, d)
        let buf = PixelBuffer(width: side, height: side, format: .gray)
        let p = buf.data.assumingMemoryBound(to: UInt8.self)
        let c = Double(side) / 2
        let rad = Double(side) / 2
        let th = -angle * .pi / 180
        let ca = cos(th), sa = sin(th)
        let hard = min(0.999, max(0, hardness))
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) + 0.5 - c, dy = Double(y) + 0.5 - c
                let u = dx * ca - dy * sa
                let v = (dx * sa + dy * ca) / max(0.01, roundness)
                let dist = sqrt(u * u + v * v) / rad
                var a: Double
                if dist <= hard { a = 1 }
                else if dist >= 1 { a = 0 }
                else {
                    let t = (dist - hard) / (1 - hard)
                    a = 1 - t * t * (3 - 2 * t)
                }
                // 1px anti-aliased rim for hard tips
                if hard >= 0.99 { a = min(1, max(0, (rad - dist * rad) + 0.5)) }
                p[y * buf.bytesPerRow + x] = UInt8(max(0, min(255, (a * 255).rounded())))
            }
        }
        buf.markDirty()
        return buf
    }

    // MARK: - Action descriptor (8BIMdesc)

    private indirect enum DValue {
        case object(cls: String, items: [(String, DValue)])
        case list([DValue])
        case text(String)
        case double(Double)
        case unitFloat(String, Double)
        case long(Int)
        case bool(Bool)
        case enumerated(String, String)
        case other

        package subscript(_ key: String) -> DValue? {
            if case .object(_, let items) = self { return items.first { $0.0 == key }?.1 }
            return nil
        }
        package var number: Double? {
            switch self {
            case .double(let v): return v
            case .unitFloat(_, let v): return v
            case .long(let v): return Double(v)
            default: return nil
            }
        }
        package var string: String? { if case .text(let s) = self { return s }; return nil }
        package var className: String? { if case .object(let c, _) = self { return c }; return nil }
    }

    private static func readPresets(_ r: inout Reader) throws -> [Preset] {
        let version = try r.u32()
        guard version == 16 else { throw ABRImportError.malformed("descriptor version") }
        var depth = 0
        let root = try readDescriptor(&r, depth: &depth)
        guard case .list(let items)? = root["Brsh"] else { return [] }
        var out: [Preset] = []
        for item in items {
            guard case .object = item else { continue }
            let tip = item["Brsh"]
            var p = Preset(computed: false)
            p.name = item["Nm  "]?.string.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }
            if let t = tip {
                p.sampleKey = t["sampledData"]?.string.map(normalizedKey)
                p.diameter = t["Dmtr"]?.number
                if let sp = t["Spcn"]?.number { p.spacing = sp / 100 }
                if let h = t["Hrdn"]?.number { p.hardness = h / 100 }
                if let rn = t["Rndn"]?.number { p.roundness = rn / 100 }
                p.angle = t["Angl"]?.number
                p.computed = t.className == "computedBrush" || (p.sampleKey == nil && p.diameter != nil)
            }
            out.append(p)
        }
        return out
    }

    private static func readDescriptor(_ r: inout Reader, depth: inout Int) throws -> DValue {
        depth += 1
        defer { depth -= 1 }
        guard depth < 64 else { throw ABRImportError.malformed("descriptor nesting") }
        _ = try r.unicodeString()           // class name
        let cls = try readID(&r)
        let n = Int(try r.u32())
        guard n <= r.remaining else { throw ABRImportError.malformed("descriptor count") }
        var items: [(String, DValue)] = []
        for _ in 0..<n {
            let key = try readID(&r)
            let type = try r.ascii(4)
            items.append((key, try readValue(&r, type: type, depth: &depth)))
        }
        return .object(cls: cls, items: items)
    }

    private static func readID(_ r: inout Reader) throws -> String {
        let len = Int(try r.u32())
        return try r.ascii(len == 0 ? 4 : len)
    }

    private static func readValue(_ r: inout Reader, type: String, depth: inout Int) throws -> DValue {
        switch type {
        case "Objc", "GlbO":
            return try readDescriptor(&r, depth: &depth)
        case "VlLs":
            let n = Int(try r.u32())
            guard n <= r.remaining else { throw ABRImportError.malformed("list count") }
            var vals: [DValue] = []
            for _ in 0..<n {
                let t = try r.ascii(4)
                vals.append(try readValue(&r, type: t, depth: &depth))
            }
            return .list(vals)
        case "doub": return .double(try r.f64())
        case "UntF":
            let unit = try r.ascii(4)
            return .unitFloat(unit, try r.f64())
        case "UnFl":
            _ = try r.ascii(4)
            let n = Int(try r.u32())
            guard n <= r.remaining / 8 else { throw ABRImportError.malformed("unit list") }
            try r.skip(n * 8)
            return .other
        case "TEXT": return .text(try r.unicodeString())
        case "enum":
            let t = try readID(&r)
            return .enumerated(t, try readID(&r))
        case "long": return .long(Int(try r.i32()))
        case "comp": try r.skip(8); return .other
        case "bool": return .bool(try r.u8() != 0)
        case "type", "GlbC":
            _ = try r.unicodeString()
            _ = try readID(&r)
            return .other
        case "alis", "tdta", "Pth ":
            let n = Int(try r.u32())
            try r.skip(n)
            return .other
        case "obj ":
            let n = Int(try r.u32())
            guard n <= r.remaining else { throw ABRImportError.malformed("reference count") }
            for _ in 0..<n {
                let form = try r.ascii(4)
                switch form {
                case "prop": _ = try r.unicodeString(); _ = try readID(&r); _ = try readID(&r)
                case "Clss": _ = try r.unicodeString(); _ = try readID(&r)
                case "Enmr": _ = try r.unicodeString(); _ = try readID(&r); _ = try readID(&r); _ = try readID(&r)
                case "rele": _ = try r.unicodeString(); _ = try readID(&r); try r.skip(4)
                case "Idnt", "indx": try r.skip(4)
                case "name": _ = try r.unicodeString(); _ = try readID(&r); _ = try r.unicodeString()
                default: throw ABRImportError.malformed("reference form")
                }
            }
            return .other
        default:
            throw ABRImportError.malformed("descriptor type \(type)")
        }
    }

    // MARK: - Reader

    /// Bounds-checked big-endian reader over a byte array slice.
    private struct Reader {
        package let buf: [UInt8]
        package var pos: Int
        package let end: Int

        package init(_ b: [UInt8]) { buf = b; pos = 0; end = b.count }
        private init(buf: [UInt8], pos: Int, end: Int) { self.buf = buf; self.pos = pos; self.end = end }

        package var remaining: Int { end - pos }

        package mutating func need(_ n: Int) throws {
            guard n >= 0, n <= end - pos else { throw ABRImportError.malformed("unexpected end of data") }
        }
        package mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return buf[pos] }
        package mutating func u16() throws -> UInt16 {
            try need(2); defer { pos += 2 }
            return UInt16(buf[pos]) << 8 | UInt16(buf[pos + 1])
        }
        package mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
        package mutating func u32() throws -> UInt32 {
            try need(4); defer { pos += 4 }
            return UInt32(buf[pos]) << 24 | UInt32(buf[pos + 1]) << 16 | UInt32(buf[pos + 2]) << 8 | UInt32(buf[pos + 3])
        }
        package mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
        package mutating func f64() throws -> Double {
            let hi = UInt64(try u32()), lo = UInt64(try u32())
            return Double(bitPattern: hi << 32 | lo)
        }
        package mutating func skip(_ n: Int) throws { try need(n); pos += n }
        package mutating func bytes(_ n: Int) throws -> [UInt8] {
            try need(n); defer { pos += n }
            return Array(buf[pos..<(pos + n)])
        }
        package mutating func ascii(_ n: Int) throws -> String {
            String(decoding: try bytes(n), as: UTF8.self)
        }
        /// UTF-16BE string with a u32 character count (trailing NULs stripped).
        package mutating func unicodeString() throws -> String {
            let n = Int(try u32())
            guard n <= remaining / 2 else { throw ABRImportError.malformed("string length") }
            var units: [UInt16] = []
            units.reserveCapacity(n)
            for _ in 0..<n { units.append(try u16()) }
            while units.last == 0 { units.removeLast() }
            return String(decoding: units, as: UTF16.self)
        }
        package func peekASCII(_ s: String) -> Bool {
            let b = Array(s.utf8)
            guard b.count <= remaining else { return false }
            for i in 0..<b.count where buf[pos + i] != b[i] { return false }
            return true
        }
        /// A sub-reader over the next n bytes; advances self past them.
        package mutating func sub(_ n: Int) throws -> Reader {
            try need(n)
            let r = Reader(buf: buf, pos: pos, end: pos + n)
            pos += n
            return r
        }
    }
}
