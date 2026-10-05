import Foundation

/// Writes brushes as a Photoshop .abr (version 6.2): `8BIMsamp` with the sampled tips (8-bit, PackBits), `8BIMpatt` with
/// the patterns brush textures use, and `8BIMdesc` with one `brushPreset` per brush (all settings, see
/// `ABRPresetMapping`). Computed round brushes are written as `computedBrush` tips. Folders are not written (Photoshop
/// shows the file's brushes in one group named after the file); re-importing gives one folder named after the file.
package enum ABRWriter {
    /// `set.tips` must hold `.gray` images (frame 0 is written for animated tips; `.encoded` tips are skipped and their
    /// brushes written as round tips). Returns the file and the names of brushes that could not be written faithfully.
    package static func write(_ set: ImportedBrushSet) -> (data: Data, notes: [String]) {
        var notes: [String] = []
        var keyFor: [String: String] = [:]      // set tip key → sample UUID
        var samp = Data()
        func uuid() -> String { UUID().uuidString.lowercased() }
        func sample(_ key: String) -> String? {
            if let k = keyFor[key] { return k }
            guard let t = set.tips[key], case .gray(let g)? = t.frames.first, g.width > 0, g.height > 0,
                  g.width <= ABRImporter.maxTipSide, g.height <= ABRImporter.maxTipSide else { return nil }
            let k = uuid()
            keyFor[key] = k
            samp.append(sampleEntry(key: k, tip: g.format == .gray ? g : g.toGray()))
            return k
        }
        var presets: [PSDDescriptorValue] = []
        var usedPatterns: [String: ImportedPattern] = [:]
        for b in set.brushes {
            var sk: String?
            if let key = b.tipKey {
                sk = sample(key)
                if sk == nil { notes.append("\(b.name): tip image could not be written; saved as a round brush") }
            }
            var dk: String?
            if b.params.dualEnabled && b.params.dualTipID != "round" {
                dk = sample(b.params.dualTipID)
            }
            var pid: String?
            if b.params.textureEnabled, let pat = set.patterns.first(where: { $0.id == b.params.texturePatternID }) {
                pid = pat.id
                usedPatterns[pat.id] = pat
            }
            var p = b.params
            p.sanitize()
            if b.params.dualEnabled && b.params.dualTipID != "round" && dk == nil { p.dualTipID = "round" }
            presets.append(.object(ABRPresetMapping.descriptor(name: b.name, params: p, sampleKey: sk, dualSampleKey: dk, patternID: pid,
                                                              color: b.color, includeToolSettings: b.includesToolSettings)))
        }
        var patt = Data()
        for pat in set.patterns where usedPatterns[pat.id] != nil {
            if let e = patternEntry(pat) { patt.append(e) } else { notes.append("Pattern \(pat.name) could not be written") }
        }
        let root = PSDDescriptor(classID: "null", [("Brsh", .list(presets))])
        let desc = root.serializedVersioned()

        var out = Data()
        u16(6, &out); u16(2, &out)
        section("samp", samp, &out)
        section("patt", patt, &out)
        section("desc", desc, &out)
        return (out, notes)
    }

    // MARK: Pieces

    private static func u8(_ v: Int, _ d: inout Data) { d.append(UInt8(truncatingIfNeeded: v)) }
    private static func u16(_ v: Int, _ d: inout Data) { u8(v >> 8, &d); u8(v, &d) }
    private static func u32(_ v: Int, _ d: inout Data) { u16(v >> 16, &d); u16(v, &d) }

    private static func section(_ tag: String, _ body: Data, _ out: inout Data) {
        out.append(contentsOf: Array("8BIM".utf8))
        out.append(contentsOf: Array(tag.utf8))
        u32(body.count, &out)
        out.append(body)
        if body.count % 2 == 1 { /* sections are not padded in Photoshop's files; the reader tolerates either */ }
    }

    /// Rows of a gray buffer, tightly packed.
    private static func rows(_ g: PixelBuffer) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: g.width * g.height)
        let s = g.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<g.height { for x in 0..<g.width { px[y * g.width + x] = s[y * g.bytesPerRow + x] } }
        return px
    }

    /// 8-bit RLE bitmap: u16 row byte counts, then PackBits rows.
    private static func rleBitmap(_ px: [UInt8], width w: Int, height h: Int, into d: inout Data) {
        var packed: [[UInt8]] = []
        packed.reserveCapacity(h)
        for y in 0..<h { packed.append(ABRBitmap.packBits(px[(y * w)..<((y + 1) * w)])) }
        for r in packed { u16(r.count, &d) }
        for r in packed { d.append(contentsOf: r) }
    }

    /// One `samp` entry (subversion 2): key, 264 unused bytes, bounds, depth 8, PackBits rows; padded to 4 bytes.
    private static func sampleEntry(key: String, tip g: PixelBuffer) -> Data {
        var body = Data()
        let k = Array(key.utf8.prefix(255))
        u8(k.count, &body); body.append(contentsOf: k)
        body.append(Data(count: 264))
        u32(0, &body); u32(0, &body); u32(g.height, &body); u32(g.width, &body)   // top left bottom right
        u16(8, &body)
        u8(1, &body)
        rleBitmap(rows(g), width: g.width, height: g.height, into: &body)
        var e = Data()
        u32(body.count, &e)
        e.append(body)
        while e.count % 4 != 0 { e.append(0) }
        return e
    }

    /// One `patt` entry: a gray (mode 1) pattern with a one-channel virtual memory array list.
    private static func patternEntry(_ pat: ImportedPattern) -> Data? {
        guard case .gray(let img0) = pat.image else { return nil }
        let img = img0.format == .gray ? img0 : img0.toGray()
        let w = img.width, h = img.height
        guard w > 0, h > 0, w <= ABRPatterns.maxSide, h <= ABRPatterns.maxSide else { return nil }
        var body = Data()
        u32(1, &body)                   // version
        u32(1, &body)                   // grayscale
        u16(h, &body); u16(w, &body)
        let name = Array(pat.name.utf16) + [0]
        u32(name.count, &body); for c in name { u16(Int(c), &body) }
        let id = Array(pat.id.utf8.prefix(255))
        u8(id.count, &body); body.append(contentsOf: id)
        // channel
        var ch = Data()
        u32(8, &ch)                     // depth
        u32(0, &ch); u32(0, &ch); u32(h, &ch); u32(w, &ch)
        u16(8, &ch)
        u8(1, &ch)
        rleBitmap(rows(img), width: w, height: h, into: &ch)
        var vma = Data()
        u32(0, &vma); u32(0, &vma); u32(h, &vma); u32(w, &vma)
        u32(24, &vma)                   // max channels
        u32(1, &vma)                    // written
        u32(ch.count, &vma)
        vma.append(ch)
        u32(3, &body)                   // VMA version
        u32(vma.count, &body)
        body.append(vma)
        var e = Data()
        u32(body.count, &e)
        e.append(body)
        while e.count % 4 != 0 { e.append(0) }
        return e
    }
}
