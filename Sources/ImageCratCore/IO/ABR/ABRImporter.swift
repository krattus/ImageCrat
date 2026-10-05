import Foundation

// MARK: - Photoshop brushes (.abr) and tool presets (.tpl)
//
// * Versions 1 & 2: a flat list of brushes. Sampled brushes (type 2) are decoded; computed brushes (type 1) become
//   round tips with their diameter, hardness, roundness and angle.
// * Versions 6–10: `8BIM` tagged sections. `samp` holds the tip bitmaps (8 or 16 bit, raw or PackBits), `patt` the
//   patterns used by brush textures, `desc` an action descriptor with every preset's settings (tip shape and all the
//   Brush Settings panel sections, see `ABRPresetMapping`), and `phry` (newer files) the preset hierarchy. Groups —
//   nested objects with their own list of presets in the descriptor, or the `phry` hierarchy — become folder paths.
// * Tool presets (.tpl) share the section layout; every brush preset found anywhere in their descriptor is imported
//   with the tool's opacity / flow / mode / colour.
//
// Every read is bounds checked; malformed input throws or skips the damaged brush, never crashes.

/// A brush tip imported from a Photoshop .abr file (kept for callers of the original importer).
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

package typealias ABRImportError = BrushImportError

/// Original API: every brush of an .abr as a gray tip (computed brushes rendered).
package enum ABRImporter {
    /// Upper bound on tip size (per side) to reject garbage headers before allocating.
    package static let maxTipSide = 10_000

    package static func load(url: URL) throws -> [ImportedBrushTip] {
        try load(data: Data(contentsOf: url))
    }

    package static func load(data: Data) throws -> [ImportedBrushTip] {
        let set = try ABRBrushReader.read(data: data, name: "")
        return set.brushes.map { b in
            let tip: PixelBuffer
            if let k = b.tipKey, let t = set.tips[k], case .gray(let g)? = t.frames.first {
                tip = g
            } else {
                tip = renderRound(diameter: Int(min(Double(maxTipSide / 2), max(1, b.params.size.rounded()))), hardness: b.params.hardness,
                                  roundness: b.params.roundness, angle: b.params.angle)
            }
            return ImportedBrushTip(name: b.name, tip: tip, spacing: b.params.spacing, diameter: b.params.size)
        }
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
}

package enum ABRBrushReader {
    package static let maxTipSide = ABRImporter.maxTipSide

    package static func read(url: URL) throws -> ImportedBrushSet {
        try read(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    package static func read(data: Data, name: String) throws -> ImportedBrushSet {
        var r = ABRByteReader(Array(data))
        let version = Int(try r.u16())
        var set: ImportedBrushSet
        switch version {
        case 1, 2:
            set = ImportedBrushSet(name: name, format: "Photoshop ABR v\(version)")
            try readV12(&r, version: version, into: &set)
        case 6, 7, 8, 9, 10:
            let sub = Int(try r.u16())
            set = ImportedBrushSet(name: name, format: "Photoshop ABR v\(version).\(sub)")
            let sections = scanSections(&r)
            if sections.isEmpty { throw BrushImportError.malformed("no brush sections") }
            try ABRSections.build(sections, subversion: sub, into: &set, toolPresets: false)
        default:
            throw BrushImportError.unsupportedVersion(version)
        }
        if set.brushes.isEmpty { throw BrushImportError.noBrushes }
        return set
    }

    // MARK: Version 1 / 2

    private static func readV12(_ r: inout ABRByteReader, version: Int, into set: inout ImportedBrushSet) throws {
        let count = Int(try r.u16())
        for n in 0..<count {
            guard r.remaining >= 6 else { set.skipped.append("Brush \(n + 1): file ends early"); break }
            let type = try r.u16()
            let size = Int(try r.u32())
            guard size >= 0, size <= r.remaining else {
                if set.brushes.isEmpty { throw BrushImportError.malformed("brush \(n + 1) length") }
                set.skipped.append("Brush \(n + 1): damaged length"); break
            }
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
                    var p = BrushParams(size: Double(max(1, min(maxTipSide / 2, diameter))), hardness: Double(min(100, hardness)) / 100,
                                        spacing: spacingFraction(spacing), angle: Double(angle),
                                        roundness: Double(max(1, min(100, roundness == 0 ? 100 : roundness))) / 100)
                    p.pressureSize = false
                    p.sanitize()
                    set.brushes.append(ImportedBrush(name: "Brush \(set.brushes.count + 1)", tipKey: nil, params: p))
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
                    let bmp = try ABRBitmap.decode(&b, width: w, height: h, depth: depth, compressed: compression != 0)
                    let key = "v\(version)-\(n)"
                    set.tips[key] = ImportedTipImage(.gray(ABRBitmap.squarePadded(bmp, width: w, height: h)))
                    var p = BrushParams(size: Double(max(w, h)), hardness: 1, spacing: spacingFraction(spacing))
                    p.pressureSize = false
                    p.sanitize()
                    set.brushes.append(ImportedBrush(name: name.isEmpty ? "Brush \(set.brushes.count + 1)" : name, tipKey: key, params: p))
                default:
                    set.skipped.append("Brush \(n + 1): unknown brush type \(type)")
                }
            } catch {
                set.skipped.append("Brush \(n + 1): \((error as? LocalizedError)?.errorDescription ?? "damaged")")
            }
        }
    }

    static func spacingFraction(_ percent: Int) -> Double {
        percent <= 0 || percent > 1000 ? 0.25 : Double(percent) / 100
    }

    // MARK: 8BIM sections

    /// `8BIM` + 4-char tag + u32 length + payload, in file order (tolerates a little padding between sections).
    static func scanSections(_ r: inout ABRByteReader) -> [(tag: String, data: ABRByteReader)] {
        var out: [(String, ABRByteReader)] = []
        while r.remaining >= 12 {
            if !r.peekASCII("8BIM") {
                var found = false
                for _ in 0..<3 where r.remaining > 12 {
                    try? r.skip(1)
                    if r.peekASCII("8BIM") { found = true; break }
                }
                if !found { break }
            }
            guard (try? r.skip(4)) != nil, let tag = try? r.ascii(4), let len32 = try? r.u32() else { break }
            let len = Int(len32)
            guard len <= r.remaining, let s = try? r.sub(len) else {
                // A damaged length: hand over what is left (the section parsers are bounds checked).
                if let s = try? r.sub(r.remaining) { out.append((tag, s)) }
                break
            }
            out.append((tag, s))
        }
        return out
    }
}

/// Photoshop tool presets (.tpl): the brush part of every painting tool preset.
package enum TPLReader {
    package static func read(url: URL) throws -> ImportedBrushSet {
        try read(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
    }

    package static func read(data: Data, name: String) throws -> ImportedBrushSet {
        let bytes = Array(data)
        guard bytes.count >= 12 else { throw BrushImportError.malformed("file too short") }
        // The sections follow a short header whose layout varies between versions: find the first `8BIM` tag.
        let magic: [UInt8] = Array("8BIM".utf8)
        var start: Int?
        var i = 0
        while i + 4 <= min(bytes.count, 4096) {
            if bytes[i] == magic[0] && bytes[i + 1] == magic[1] && bytes[i + 2] == magic[2] && bytes[i + 3] == magic[3] { start = i; break }
            i += 1
        }
        guard let s = start else { throw BrushImportError.unsupportedFormat("This tool preset file") }
        var r = ABRByteReader(bytes)
        try r.skip(s)
        let sections = ABRBrushReader.scanSections(&r)
        var set = ImportedBrushSet(name: name, format: "Photoshop tool presets")
        try ABRSections.build(sections, subversion: 2, into: &set, toolPresets: true)
        if set.brushes.isEmpty { throw BrushImportError.noBrushes }
        return set
    }
}

// MARK: - Section contents

enum ABRSections {
    struct Sample {
        var key: String
        var tip: PixelBuffer
        var side: Int
    }

    static func build(_ sections: [(tag: String, data: ABRByteReader)], subversion: Int, into set: inout ImportedBrushSet, toolPresets: Bool) throws {
        var samples: [Sample] = []
        var root: PSDDescriptor?
        var hierarchy: PSDDescriptor?
        var sawSamp = false
        for (tag, data) in sections {
            var s = data
            switch tag {
            case "samp":
                sawSamp = true
                samples += try readSamples(&s, subversion: subversion, skipped: &set.skipped)
            case "patt":
                set.patterns += ABRPatterns.read(&s, skipped: &set.skipped)
            case "desc":
                do { root = try PSDDescriptor.readVersioned(Data(s.remainingBytes())) } catch {
                    set.skipped.append("Brush settings could not be read (\(error)); tips imported with default settings")
                }
            case "phry":
                hierarchy = try? PSDDescriptor.readVersioned(Data(s.remainingBytes()))
            default:
                break
            }
        }
        if !sawSamp && root == nil { throw BrushImportError.malformed("no brush sections") }

        var byKey: [String: Sample] = [:]
        for s in samples where byKey[s.key] == nil { byKey[s.key] = s }
        var usedSamples = Set<String>()
        var found: [ABRPresetMapping.Found] = []
        if let root {
            found = toolPresets ? ABRPresetMapping.findToolPresets(root) : ABRPresetMapping.findPresets(root)
        }
        // `phry`: the folder of each preset, in preset order, when the hierarchy lists exactly the presets found.
        if let h = hierarchy, !found.isEmpty {
            let paths = ABRPresetMapping.hierarchyPaths(h)
            if paths.count == found.count {
                for i in found.indices where found[i].folder.isEmpty { found[i].folder = paths[i] }
            }
        }
        for f in found {
            var params = f.params
            var tipKey: String?
            if let key = f.sampleKey {
                guard let s = byKey[key] else {
                    set.skipped.append("\(f.name): its tip is missing from the file")
                    continue
                }
                usedSamples.insert(key)
                tipKey = key
                if set.tips[key] == nil { set.tips[key] = ImportedTipImage(.gray(s.tip)) }
                if !(params.size > 0) { params.size = Double(s.side) }
            }
            if params.dualEnabled, let dk = f.dualSampleKey {
                if let s = byKey[dk] {
                    usedSamples.insert(dk)
                    if set.tips[dk] == nil { set.tips[dk] = ImportedTipImage(.gray(s.tip)) }
                    params.dualTipID = dk
                } else {
                    params.dualTipID = "round"
                }
            }
            if params.textureEnabled, !set.patterns.contains(where: { $0.id == params.texturePatternID }) {
                // The pattern isn't in this file: the app falls back to a pattern of the same name or a built-in one.
                params.texturePatternID = ""
            }
            params.sanitize()
            set.brushes.append(ImportedBrush(name: f.name.isEmpty ? "Brush \(set.brushes.count + 1)" : f.name, folderPath: f.folder,
                                             tipKey: tipKey, params: params, color: f.color,
                                             includesSize: true, includesToolSettings: f.hasToolSettings))
        }
        // Samples no preset refers to (or no descriptor at all).
        for s in samples where !usedSamples.contains(s.key) {
            if set.tips[s.key] == nil { set.tips[s.key] = ImportedTipImage(.gray(s.tip)) }
            var p = BrushParams(size: Double(s.side), hardness: 1, spacing: 0.25)
            p.pressureSize = false
            set.brushes.append(ImportedBrush(name: "Sampled Brush \(set.brushes.count + 1)", tipKey: s.key, params: p))
            usedSamples.insert(s.key)
        }
    }

    static func readSamples(_ s: inout ABRByteReader, subversion: Int, skipped: inout [String]) throws -> [Sample] {
        var out: [Sample] = []
        var index = 0
        var guardCount = 0
        while s.remaining >= 4 && guardCount < 100_000 {
            guardCount += 1
            let size = Int(try s.u32())
            if size == 0 { continue }
            guard size <= s.remaining else {
                if out.isEmpty { throw BrushImportError.malformed("sample length") }
                skipped.append("Tip \(index + 1): damaged length")
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
                let bmp = try ABRBitmap.decode(&b, width: w, height: h, depth: depth, compressed: compression != 0)
                out.append(Sample(key: key.isEmpty ? "#\(index)" : key, tip: ABRBitmap.squarePadded(bmp, width: w, height: h), side: max(w, h)))
            } catch {
                skipped.append("Tip \(index): \((error as? LocalizedError)?.errorDescription ?? "damaged")")
                continue   // skip this sample, keep going
            }
        }
        return out
    }

    /// Sample UUIDs are compared without NULs, a leading "$" or surrounding whitespace.
    static func normalizedKey(_ k: String) -> String {
        var t = k.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
        if t.hasPrefix("$") { t.removeFirst() }
        return t.lowercased()
    }
}

// MARK: - Bitmaps

enum ABRBitmap {
    /// Decodes a w×h tip to 8-bit (one byte per pixel, tightly packed).
    static func decode(_ r: inout ABRByteReader, width w: Int, height h: Int, depth: Int, compressed: Bool) throws -> [UInt8] {
        guard w > 0, h > 0, w <= ABRImporter.maxTipSide, h <= ABRImporter.maxTipSide else { throw BrushImportError.malformed("tip size \(w)×\(h)") }
        guard depth == 8 || depth == 16 else { throw BrushImportError.malformed("bit depth \(depth)") }
        let bpc = depth / 8
        let rowBytes = w * bpc
        // Raw data must be present in full; RLE data needs at least the row counts.
        guard compressed ? h * 2 <= r.remaining : rowBytes * h <= r.remaining else { throw BrushImportError.malformed("tip data") }
        var raw = [UInt8](repeating: 0, count: rowBytes * h)
        if !compressed {
            raw = try r.bytes(rowBytes * h)
        } else {
            var counts = [Int](repeating: 0, count: h)
            for y in 0..<h { counts[y] = Int(try r.u16()) }
            for y in 0..<h {
                var row = try r.sub(min(counts[y], r.remaining))
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

    static func unpackBits(_ r: inout ABRByteReader, into out: inout [UInt8], offset: Int, count: Int) throws {
        var o = 0
        while o < count && r.remaining > 0 {
            let n = Int(Int8(bitPattern: try r.u8()))
            if n >= 0 {
                let lit = try r.bytes(min(n + 1, r.remaining))
                for b in lit where o < count { out[offset + o] = b; o += 1 }
            } else if n != -128 {
                guard r.remaining > 0 else { break }
                let b = try r.u8()
                let run = 1 - n
                for _ in 0..<run where o < count { out[offset + o] = b; o += 1 }
            }
        }
    }

    /// PackBits (Photoshop RLE) of one row.
    static func packBits(_ row: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        let b = Array(row)
        var i = 0
        while i < b.count {
            var run = 1
            while i + run < b.count && run < 128 && b[i + run] == b[i] { run += 1 }
            if run >= 2 {
                out.append(UInt8(bitPattern: Int8(1 - run)))
                out.append(b[i])
                i += run
            } else {
                var j = i
                while j < b.count && j - i < 128 && !(j + 1 < b.count && b[j + 1] == b[j]) { j += 1 }
                if j == i { j = i + 1 }
                out.append(UInt8(j - i - 1))
                out.append(contentsOf: b[i..<j])
                i = j
            }
        }
        return out
    }

    /// Centres a w×h tip in a black square and normalises polarity to white = paint.
    static func squarePadded(_ px: [UInt8], width w: Int, height h: Int) -> PixelBuffer {
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
    static func looksInverted(_ px: [UInt8], width w: Int, height h: Int) -> Bool {
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
}

// MARK: - Patterns (8BIMpatt)

enum ABRPatterns {
    static let maxSide = 8192

    /// Patterns as stored in .pat files and ABR `patt` sections: u32 length, u32 version (1), u32 image mode, u16 height,
    /// u16 width, Unicode name, Pascal id, [indexed: 768-byte colour table], virtual memory array list.
    static func read(_ r: inout ABRByteReader, skipped: inout [String]) -> [ImportedPattern] {
        var out: [ImportedPattern] = []
        var n = 0
        while r.remaining >= 4 && n < 10_000 {
            n += 1
            guard let len32 = try? r.u32() else { break }
            let len = Int(len32)
            if len == 0 { continue }
            guard len <= r.remaining, var p = try? r.sub(len) else { skipped.append("Pattern \(n): damaged length"); break }
            let pad = (4 - len % 4) % 4
            try? r.skip(min(pad, r.remaining))
            if let pat = try? one(&p) { out.append(pat) } else { skipped.append("Pattern \(n): not readable") }
        }
        return out
    }

    static func one(_ p: inout ABRByteReader) throws -> ImportedPattern {
        _ = try p.u32()                               // version
        let mode = Int(try p.u32())
        let h = Int(try p.u16()), w = Int(try p.u16())
        guard w > 0, h > 0, w <= maxSide, h <= maxSide else { throw BrushImportError.malformed("pattern size") }
        let name = try p.unicodeString()
        let idLen = Int(try p.u8())
        let id = String(decoding: try p.bytes(idLen), as: UTF8.self)
        var table: [UInt8] = []
        if mode == 2 { table = try p.bytes(768) }
        // Virtual memory array list
        _ = try p.u32()                               // version (3)
        let vlen = Int(try p.u32())
        var v = try p.sub(min(vlen, p.remaining))
        let top = Int(try v.i32()), left = Int(try v.i32()), bottom = Int(try v.i32()), right = Int(try v.i32())
        let channels = Int(try v.u32())
        let rw = right - left, rh = bottom - top
        guard rw > 0, rh > 0, rw <= maxSide, rh <= maxSide, channels >= 0, channels < 64 else { throw BrushImportError.malformed("pattern bounds") }
        var planes: [[UInt8]] = []
        let wanted = mode == 3 ? 3 : (mode == 4 ? 4 : 1)
        for _ in 0..<(channels + 2) where planes.count < wanted && v.remaining >= 8 {
            let written = try v.u32()
            if written == 0 { continue }
            let clen = Int(try v.u32())
            if clen == 0 { continue }
            var c = try v.sub(min(clen, v.remaining))
            let depth = Int(try c.u32())
            let ct = Int(try c.i32()), cl = Int(try c.i32()), cb = Int(try c.i32()), cr = Int(try c.i32())
            _ = try c.u16()                           // depth again
            let comp = try c.u8()
            let cw = cr - cl, ch = cb - ct
            guard cw == rw, ch == rh else { throw BrushImportError.malformed("pattern channel bounds") }
            planes.append(try ABRBitmap.decode(&c, width: cw, height: ch, depth: depth == 16 ? 16 : 8, compressed: comp != 0))
        }
        guard !planes.isEmpty else { throw BrushImportError.malformed("pattern has no pixels") }
        let buf = PixelBuffer(width: rw, height: rh, format: .gray)
        let d = buf.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<rh {
            for x in 0..<rw {
                let i = y * rw + x
                var g: Int
                switch mode {
                case 3 where planes.count >= 3:
                    g = (Int(planes[0][i]) * 77 + Int(planes[1][i]) * 150 + Int(planes[2][i]) * 29) >> 8
                case 4 where planes.count >= 4:   // CMYK (inverted storage)
                    let k = 255 - Int(planes[3][i])
                    g = ((255 - Int(planes[0][i])) * 77 + (255 - Int(planes[1][i])) * 150 + (255 - Int(planes[2][i])) * 29) >> 8
                    g = g * (255 - k) / 255
                case 2 where table.count == 768:
                    let k = Int(planes[0][i])
                    g = (Int(table[k]) * 77 + Int(table[256 + k]) * 150 + Int(table[512 + k]) * 29) >> 8
                default:
                    g = Int(planes[0][i])
                }
                d[y * buf.bytesPerRow + x] = UInt8(max(0, min(255, g)))
            }
        }
        buf.markDirty()
        return ImportedPattern(id: id.trimmingCharacters(in: CharacterSet(charactersIn: "\0")), name: name.isEmpty ? "Pattern" : name, image: .gray(buf))
    }
}

// MARK: - Reader

/// Bounds-checked big-endian reader over a byte array slice.
struct ABRByteReader {
    let buf: [UInt8]
    var pos: Int
    let end: Int

    init(_ b: [UInt8]) { buf = b; pos = 0; end = b.count }
    private init(buf: [UInt8], pos: Int, end: Int) { self.buf = buf; self.pos = pos; self.end = end }

    var remaining: Int { end - pos }

    func need(_ n: Int) throws {
        guard n >= 0, n <= end - pos else { throw BrushImportError.malformed("unexpected end of data") }
    }
    mutating func u8() throws -> UInt8 { try need(1); defer { pos += 1 }; return buf[pos] }
    mutating func u16() throws -> UInt16 {
        try need(2); defer { pos += 2 }
        return UInt16(buf[pos]) << 8 | UInt16(buf[pos + 1])
    }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 {
        try need(4); defer { pos += 4 }
        return UInt32(buf[pos]) << 24 | UInt32(buf[pos + 1]) << 16 | UInt32(buf[pos + 2]) << 8 | UInt32(buf[pos + 3])
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func skip(_ n: Int) throws { try need(n); pos += n }
    mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n); defer { pos += n }
        return Array(buf[pos..<(pos + n)])
    }
    func remainingBytes() -> ArraySlice<UInt8> { buf[pos..<end] }
    mutating func ascii(_ n: Int) throws -> String {
        String(decoding: try bytes(n), as: UTF8.self)
    }
    /// UTF-16BE string with a u32 character count (trailing NULs stripped).
    mutating func unicodeString() throws -> String {
        let n = Int(try u32())
        guard n <= remaining / 2 else { throw BrushImportError.malformed("string length") }
        var units: [UInt16] = []
        units.reserveCapacity(n)
        for _ in 0..<n { units.append(try u16()) }
        while units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
    func peekASCII(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count <= remaining else { return false }
        for i in 0..<b.count where buf[pos + i] != b[i] { return false }
        return true
    }
    /// A sub-reader over the next n bytes; advances self past them.
    mutating func sub(_ n: Int) throws -> ABRByteReader {
        try need(n)
        let r = ABRByteReader(buf: buf, pos: pos, end: pos + n)
        pos += n
        return r
    }
}
