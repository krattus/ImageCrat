import Foundation
import CoreGraphics
import CoreText
import ImageCratCore

/// A font resource of a PDF: metrics for positioning, character code → Unicode for editable text, and the embedded
/// font program as a CGFont (character code → glyph) for outlining text whose font is not installed.
final class PDFVectorFont {
    let dict: CGPDFDictionaryRef
    /// PostScript name without the subset prefix ("ABCDEF+").
    let baseName: String
    let subtype: String
    let isComposite: Bool
    let isType3: Bool
    /// Bytes per character code; 0 when the encoding (a non-identity CMap) is not understood.
    let bytesPerCode: Int
    let isVertical: Bool
    /// Glyph widths are available from the PDF (or from the installed standard font).
    private(set) var widthsKnown = true
    let isEmbedded: Bool

    private var simpleWidths = [Double](repeating: .nan, count: 256)
    private var missingWidth = 0.0
    private var cidWidths: [Int: Double] = [:]
    private var cidDefaultWidth = 1000.0
    private var toUni: [Int: String] = [:]
    private var hasToUnicode = false
    /// Glyph names per code for simple fonts (named base encoding + /Differences). nil entries = font's own encoding.
    private var names = [String?](repeating: nil, count: 256)
    private var hasNamedEncoding = false
    private var symbolic = false
    private var descriptor: CGPDFDictionaryRef?
    private var cidToGID: [UInt16]? = nil
    private var cidSubtype = ""

    init(_ d: CGPDFDictionaryRef) {
        dict = d
        subtype = PDFVectorObj.name(d, "Subtype") ?? "Type1"
        isType3 = subtype == "Type3"
        isComposite = subtype == "Type0"
        var base = PDFVectorObj.name(d, "BaseFont") ?? PDFVectorObj.name(d, "Name") ?? "Font"
        if base.count > 7, base[base.index(base.startIndex, offsetBy: 6)] == "+" { base = String(base.dropFirst(7)) }
        baseName = base
        var desc = PDFVectorObj.dict(d, "FontDescriptor")
        var bytes = 1
        var vertical = false
        var descendant: CGPDFDictionaryRef? = nil
        if isComposite {
            let enc = PDFVectorObj.name(d, "Encoding")
            if enc == "Identity-H" { bytes = 2 } else if enc == "Identity-V" { bytes = 2; vertical = true } else { bytes = 0 }
            descendant = PDFVectorObj.asDict(PDFVectorObj.objects(PDFVectorObj.array(d, "DescendantFonts")).first)
            if let df = descendant { desc = PDFVectorObj.dict(df, "FontDescriptor") } else { bytes = 0 }
        }
        bytesPerCode = bytes
        isVertical = vertical
        var embedded = false
        if let desc { embedded = ["FontFile", "FontFile2", "FontFile3"].contains { PDFVectorObj.stream(desc, $0) != nil } }
        isEmbedded = embedded || isType3
        descriptor = desc
        if let desc {
            let flags = PDFVectorObj.int(desc, "Flags") ?? 0
            symbolic = flags & 4 != 0 && flags & 32 == 0
            missingWidth = PDFVectorObj.number(desc, "MissingWidth") ?? 0
        }
        if let df = descendant {
            cidSubtype = PDFVectorObj.name(df, "Subtype") ?? ""
            cidDefaultWidth = PDFVectorObj.number(df, "DW") ?? 1000
            parseCIDWidths(PDFVectorObj.array(df, "W"))
            if let s = PDFVectorObj.stream(df, "CIDToGIDMap"), let (data, _) = PDFVectorObj.data(s) {
                var map = [UInt16](repeating: 0, count: data.count / 2)
                data.withUnsafeBytes { p in for i in 0..<map.count { map[i] = UInt16(p[2 * i]) << 8 | UInt16(p[2 * i + 1]) } }
                cidToGID = map
            }
        }
        if !isComposite { parseSimple() }
        if let s = PDFVectorObj.stream(d, "ToUnicode"), let (data, _) = PDFVectorObj.data(s), data.count < 8_000_000 {
            toUni = PDFVectorEncoding.toUnicode(data)
            hasToUnicode = !toUni.isEmpty
        }
    }

    // MARK: Metrics

    private func parseCIDWidths(_ a: CGPDFArrayRef?) {
        let items = PDFVectorObj.objects(a)
        var i = 0
        while i < items.count {
            guard let first = PDFVectorObj.asNumber(items[i]), abs(first) < 1e7 else { i += 1; continue }
            if i + 1 < items.count, let list = PDFVectorObj.asArray(items[i + 1]) {
                for (k, w) in PDFVectorObj.numbers(list).enumerated() where cidWidths.count < 200_000 { cidWidths[Int(first) + k] = w }
                i += 2
            } else if i + 2 < items.count, let last = PDFVectorObj.asNumber(items[i + 1]), abs(last) < 1e7, let w = PDFVectorObj.asNumber(items[i + 2]) {
                let lo = Int(first), hi = Int(last)
                if hi >= lo, hi - lo < 70_000 { for c in lo...hi where cidWidths.count < 200_000 { cidWidths[c] = w } }
                i += 3
            } else { i += 1 }
        }
    }

    private func parseSimple() {
        // encoding: named, or a dictionary with an optional base and /Differences
        var base: [String?]? = nil
        var differences: CGPDFArrayRef? = nil
        if let n = PDFVectorObj.name(dict, "Encoding") {
            base = PDFVectorEncoding.named(n)
        } else if let e = PDFVectorObj.dict(dict, "Encoding") {
            base = PDFVectorEncoding.named(PDFVectorObj.name(e, "BaseEncoding"))
            differences = PDFVectorObj.array(e, "Differences")
        }
        if let base { names = base; hasNamedEncoding = true }
        else if !symbolic && !isType3 && descriptor.map({ d in !["FontFile", "FontFile2", "FontFile3"].contains { PDFVectorObj.stream(d, $0) != nil } }) ?? true {
            // a non-embedded, non-symbolic font without an encoding uses the standard one
            names = PDFVectorEncoding.standard; hasNamedEncoding = true
        }
        var code = 0
        for o in PDFVectorObj.objects(differences) {
            if let n = PDFVectorObj.asNumber(o) { code = abs(n) < 1e6 ? Int(n) : 256 }
            else if let nm = PDFVectorObj.asName(o) { if code >= 0 && code < 256 { names[code] = nm }; code += 1 }
        }
        // widths
        let first = PDFVectorObj.int(dict, "FirstChar") ?? 0
        let w = PDFVectorObj.numbers(dict, "Widths")
        if !w.isEmpty {
            for (i, v) in w.enumerated() where first + i >= 0 && first + i < 256 { simpleWidths[first + i] = v }
        } else if !isType3 {
            // one of the standard 14 fonts: metrics come from the installed font
            if let ps = installedName {
                let f = CTFontCreateWithName(ps as CFString, 1000, nil)
                for c in 0..<256 {
                    guard let u = unicode(for: c), let ch = u.utf16.first, u.utf16.count == 1 else { continue }
                    var g: CGGlyph = 0
                    var chars = [ch]
                    if CTFontGetGlyphsForCharacters(f, &chars, &g, 1) {
                        var adv = CGSize.zero
                        CTFontGetAdvancesForGlyphs(f, .horizontal, &g, &adv, 1)
                        simpleWidths[c] = Double(adv.width)
                    }
                }
            } else { widthsKnown = false }
        }
    }

    /// Horizontal advance of a character code in thousandths of text space (Type 3: glyph space × font matrix).
    func width(_ code: Int) -> Double {
        if isComposite { return cidWidths[code] ?? cidDefaultWidth }
        guard code >= 0, code < 256 else { return missingWidth }
        let w = simpleWidths[code]
        if w.isNaN { return missingWidth }
        if isType3 {
            let m = PDFVectorObj.numbers(dict, "FontMatrix")
            return w * (m.count >= 1 ? m[0] : 0.001) * 1000
        }
        return w
    }

    // MARK: Unicode

    func unicode(for code: Int) -> String? {
        if let s = toUni[code] { return s }
        if hasToUnicode { return nil }
        if isComposite { return nil }
        guard code >= 0, code < 256, let n = names[code] else { return nil }
        return PDFVectorEncoding.unicode(forGlyph: n)
    }

    /// Whether `unicode(for:)` came from a one-code-to-several-characters mapping somewhere (ligature glyphs).
    var mapsLigatures: Bool { toUni.values.contains { $0.unicodeScalars.count > 1 } }

    // MARK: Installed font

    /// PostScript name of an installed font that matches this font's name, if any.
    private(set) lazy var installedName: String? = {
        var candidates = [baseName]
        let dashed = baseName.replacingOccurrences(of: ",", with: "-")
        if dashed != baseName { candidates.append(dashed) }
        let aliases: [String: String] = [
            "Arial": "ArialMT", "Arial-Bold": "Arial-BoldMT", "Arial-Italic": "Arial-ItalicMT", "Arial-BoldItalic": "Arial-BoldItalicMT",
            "TimesNewRoman": "TimesNewRomanPSMT", "TimesNewRoman-Bold": "TimesNewRomanPS-BoldMT", "TimesNewRoman-Italic": "TimesNewRomanPS-ItalicMT",
            "TimesNewRoman-BoldItalic": "TimesNewRomanPS-BoldItalicMT", "CourierNew": "CourierNewPSMT", "CourierNew-Bold": "CourierNewPS-BoldMT",
            "CourierNew-Italic": "CourierNewPS-ItalicMT", "CourierNew-BoldItalic": "CourierNewPS-BoldItalicMT",
            "ZapfDingbats": "ZapfDingbatsITC", "Helvetica-Italic": "Helvetica-Oblique", "Helvetica-BoldItalic": "Helvetica-BoldOblique",
            "Courier-Italic": "Courier-Oblique", "Courier-BoldItalic": "Courier-BoldOblique", "Times": "Times-Roman",
        ]
        if let a = aliases[dashed] { candidates.append(a) }
        for c in candidates where !c.hasPrefix(".") {
            let f = CTFontCreateWithName(c as CFString, 12, nil)
            if (CTFontCopyPostScriptName(f) as String) == c { return c }
        }
        return nil
    }()

    // MARK: Embedded program

    private(set) lazy var program: PDFVectorFontProgram? = {
        guard let descriptor, !isType3 else { return nil }
        for key in ["FontFile2", "FontFile3", "FontFile"] {
            guard let s = PDFVectorObj.stream(descriptor, key), let (data, _) = PDFVectorObj.data(s), data.count > 16, data.count < 64_000_000 else { continue }
            let sub = CGPDFStreamGetDictionary(s).flatMap { PDFVectorObj.name($0, "Subtype") } ?? ""
            if let p = PDFVectorFontProgram(data: data, key: key, streamSubtype: sub) { return p }
        }
        return nil
    }()

    /// Glyph of the embedded font for a character code.
    func glyph(for code: Int) -> CGGlyph? {
        guard let p = program else { return nil }
        if isComposite {
            guard bytesPerCode == 2 else { return nil }
            if cidSubtype == "CIDFontType2" || p.isTrueType {
                if let map = cidToGID { return code < map.count ? map[code] : nil }
                return code < p.glyphCount ? CGGlyph(code) : nil
            }
            return p.glyph(forCID: code)
        }
        guard code >= 0, code < 256 else { return nil }
        if p.isTrueType {
            if hasNamedEncoding && !symbolic, let n = names[code] {
                if let u = PDFVectorEncoding.unicode(forGlyph: n)?.unicodeScalars.first?.value, let g = p.cmapGlyph(unicode: Int(u)) { return g }
                if let mac = PDFVectorEncoding.macRoman.firstIndex(where: { $0 == n }), let g = p.cmapGlyph(mac: mac) { return g }
                let g = p.cgFont.getGlyphWithGlyphName(name: n as CFString)
                if g != 0 { return g }
            }
            return p.cmapGlyph(symbol: code) ?? p.cmapGlyph(mac: code) ?? p.cmapGlyph(unicode: code)
        }
        // Type 1 / CFF: by glyph name, falling back to the program's own encoding
        if let n = names[code] {
            let g = p.cgFont.getGlyphWithGlyphName(name: n as CFString)
            if g != 0 || n == ".notdef" { return g }
        }
        if hasNamedEncoding && names[code] != nil { return nil }
        return p.builtInGlyph(code: code)
    }

    /// Outline of a character's glyph in thousandths of an em (y up). `found` is false when the code cannot be
    /// mapped to a glyph of the embedded program; an empty glyph (a space) is found with a nil path.
    func outline(for code: Int) -> (found: Bool, path: CGPath?) {
        guard let p = program, let g = glyph(for: code) else { return (false, nil) }
        return (true, p.path(g))
    }
}

/// An embedded font program loaded through Core Graphics, with the few tables parsed that CGFont does not expose
/// (TrueType `cmap`, CFF charset / encoding, Type 1 encoding vector).
final class PDFVectorFontProgram {
    let cgFont: CGFont
    let isTrueType: Bool
    let glyphCount: Int
    private let ctFont: CTFont
    private let unitsPerEm: CGFloat
    private var paths: [CGGlyph: CGPath?] = [:]
    private var cmapUnicode: ((Int) -> Int?)?
    private var cmapSymbol: ((Int) -> Int?)?
    private var cmapMac: ((Int) -> Int?)?
    private var cidGlyphs: [Int: CGGlyph]? = nil
    private var builtIn: [Int: CGGlyph] = [:]
    private var builtInNames: [Int: String] = [:]

    init?(data: Data, key: String, streamSubtype: String) {
        guard let prov = CGDataProvider(data: data as CFData), let f = CGFont(prov), f.numberOfGlyphs > 0 else { return nil }
        cgFont = f
        glyphCount = f.numberOfGlyphs
        unitsPerEm = CGFloat(max(1, f.unitsPerEm))
        ctFont = CTFontCreateWithGraphicsFont(f, 1000, nil, nil)
        let b = [UInt8](data.prefix(32_000_000))
        let tag = b.count >= 4 ? (UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : 0
        let sfnt = tag == 0x00010000 || tag == 0x74727565 || tag == 0x4F54544F || tag == 0x74746366
        isTrueType = key == "FontFile2" || (sfnt && tag != 0x4F54544F)
        if sfnt {
            parseSFNT(b)
        } else if key == "FontFile3" {
            parseCFF(b, 0)
        } else if key == "FontFile" {
            parseType1(b)
        }
    }

    func path(_ g: CGGlyph) -> CGPath? {
        if let p = paths[g] { return p }
        let p = CTFontCreatePathForGlyph(ctFont, g, nil)
        if paths.count < 20_000 { paths[g] = p }
        return p
    }

    func cmapGlyph(unicode u: Int) -> CGGlyph? { cmapUnicode?(u).flatMap { $0 > 0 && $0 < glyphCount ? CGGlyph($0) : nil } }
    func cmapGlyph(mac c: Int) -> CGGlyph? { cmapMac?(c).flatMap { $0 > 0 && $0 < glyphCount ? CGGlyph($0) : nil } }
    func cmapGlyph(symbol c: Int) -> CGGlyph? {
        guard let t = cmapSymbol else { return nil }
        for base in [0xF000, 0, 0xF100, 0xF200] { if let g = t(base | c), g > 0, g < glyphCount { return CGGlyph(g) } }
        return nil
    }
    func glyph(forCID cid: Int) -> CGGlyph? {
        if let m = cidGlyphs { return m[cid] }
        return cid < glyphCount ? CGGlyph(cid) : nil
    }
    func builtInGlyph(code: Int) -> CGGlyph? {
        if let g = builtIn[code] { return g }
        if let n = builtInNames[code] { let g = cgFont.getGlyphWithGlyphName(name: n as CFString); return g != 0 ? g : nil }
        return nil
    }

    // MARK: sfnt

    private static func u16(_ b: [UInt8], _ o: Int) -> Int { o + 1 < b.count && o >= 0 ? Int(b[o]) << 8 | Int(b[o + 1]) : 0 }
    private static func u32(_ b: [UInt8], _ o: Int) -> Int { o + 3 < b.count && o >= 0 ? Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) : 0 }

    private func u16(_ b: [UInt8], _ o: Int) -> Int { PDFVectorFontProgram.u16(b, o) }
    private func u32(_ b: [UInt8], _ o: Int) -> Int { PDFVectorFontProgram.u32(b, o) }

    private func parseSFNT(_ b: [UInt8]) {
        let n = min(u16(b, 4), 256)
        for i in 0..<n {
            let r = 12 + i * 16
            guard r + 16 <= b.count else { break }
            let tag = String(decoding: b[r..<r + 4], as: UTF8.self)
            let off = u32(b, r + 8)
            if tag == "cmap" { parseCmap(b, off) }
            if tag == "CFF " { parseCFF(b, off) }
        }
    }

    private func parseCmap(_ b: [UInt8], _ base: Int) {
        let n = min(u16(b, base + 2), 64)
        for i in 0..<n {
            let r = base + 4 + i * 8
            let platform = u16(b, r), encoding = u16(b, r + 2)
            let off = base + u32(b, r + 4)
            guard off + 6 <= b.count, let table = subtable(b, off) else { continue }
            if platform == 3 && encoding == 0 { cmapSymbol = table }
            else if platform == 3 && (encoding == 1 || encoding == 10) { if cmapUnicode == nil || encoding == 10 { cmapUnicode = table } }
            else if platform == 0 { if cmapUnicode == nil { cmapUnicode = table } }
            else if platform == 1 && encoding == 0 { cmapMac = table }
        }
    }

    private func subtable(_ b: [UInt8], _ o: Int) -> ((Int) -> Int?)? {
        switch u16(b, o) {
        case 0:
            return { c in c >= 0 && c < 256 && o + 6 + c < b.count ? Int(b[o + 6 + c]) : nil }
        case 4:
            let segs = u16(b, o + 6) / 2
            guard segs > 0, o + 16 + segs * 8 <= b.count else { return nil }
            let endO = o + 14, startO = endO + segs * 2 + 2, deltaO = startO + segs * 2, rangeO = deltaO + segs * 2
            return { c in
                guard c >= 0, c <= 0xFFFF else { return nil }
                var lo = 0, hi = segs - 1
                while lo < hi { let mid = (lo + hi) / 2; if PDFVectorFontProgram.u16(b, endO + mid * 2) < c { lo = mid + 1 } else { hi = mid } }
                let start = PDFVectorFontProgram.u16(b, startO + lo * 2)
                guard c >= start, c <= PDFVectorFontProgram.u16(b, endO + lo * 2) else { return nil }
                let delta = PDFVectorFontProgram.u16(b, deltaO + lo * 2), ro = PDFVectorFontProgram.u16(b, rangeO + lo * 2)
                if ro == 0 { return (c + delta) & 0xFFFF }
                let g = PDFVectorFontProgram.u16(b, rangeO + lo * 2 + ro + (c - start) * 2)
                return g == 0 ? nil : (g + delta) & 0xFFFF
            }
        case 6:
            let first = u16(b, o + 6), count = u16(b, o + 8)
            return { c in c >= first && c < first + count ? PDFVectorFontProgram.u16(b, o + 10 + (c - first) * 2) : nil }
        case 12:
            let groups = min(u32(b, o + 12), 200_000)
            guard o + 16 + groups * 12 <= b.count else { return nil }
            return { c in
                var lo = 0, hi = groups - 1
                while lo <= hi {
                    let mid = (lo + hi) / 2, r = o + 16 + mid * 12
                    let s = PDFVectorFontProgram.u32(b, r), e = PDFVectorFontProgram.u32(b, r + 4)
                    if c < s { hi = mid - 1 } else if c > e { lo = mid + 1 } else { return PDFVectorFontProgram.u32(b, r + 8) + (c - s) }
                }
                return nil
            }
        default: return nil
        }
    }

    // MARK: CFF

    /// Offsets of an INDEX's objects (absolute) and the offset just past it.
    private func cffIndex(_ b: [UInt8], _ o: Int) -> (offsets: [Int], end: Int)? {
        guard o + 2 <= b.count else { return nil }
        let count = u16(b, o)
        if count == 0 { return ([], o + 2) }
        guard o + 3 <= b.count else { return nil }
        let size = Int(b[o + 2])
        guard size >= 1, size <= 4, o + 3 + (count + 1) * size <= b.count else { return nil }
        let data = o + 3 + (count + 1) * size - 1
        var offs: [Int] = []
        offs.reserveCapacity(count + 1)
        for i in 0...count {
            var v = 0
            for k in 0..<size { v = v << 8 | Int(b[o + 3 + i * size + k]) }
            offs.append(data + v)
        }
        guard let last = offs.last, last <= b.count else { return nil }
        return (offs, last)
    }

    private func parseCFF(_ b: [UInt8], _ base: Int) {
        guard base + 4 <= b.count else { return }
        let hdr = Int(b[base + 2])
        guard let nameIdx = cffIndex(b, base + hdr), let topIdx = cffIndex(b, nameIdx.end), topIdx.offsets.count >= 2,
              let strIdx = cffIndex(b, topIdx.end) else { return }
        // Top DICT
        var operands: [Double] = []
        var charset = 0, encoding = 0, charStrings = 0
        var isCID = false
        var i = topIdx.offsets[0]
        let end = min(topIdx.offsets[1], b.count)
        while i < end {
            let c = Int(b[i])
            if c <= 21 {
                var op = c
                i += 1
                if c == 12, i < end { op = 1200 + Int(b[i]); i += 1 }
                switch op {
                case 15: charset = Int(operands.last ?? 0)
                case 16: encoding = Int(operands.last ?? 0)
                case 17: charStrings = Int(operands.last ?? 0)
                case 1230: isCID = true
                default: break
                }
                operands.removeAll()
            } else if c == 28 { operands.append(Double(Int16(truncatingIfNeeded: u16(b, i + 1)))); i += 3 }
            else if c == 29 { operands.append(Double(Int32(truncatingIfNeeded: u32(b, i + 1)))); i += 5 }
            else if c == 30 { i += 1; while i < end { let v = b[i]; i += 1; if v & 0x0F == 0x0F || v >> 4 == 0x0F { break } }; operands.append(0) }
            else if c >= 32 && c <= 246 { operands.append(Double(c - 139)); i += 1 }
            else if c >= 247 && c <= 250, i + 1 < end { operands.append(Double((c - 247) * 256 + Int(b[i + 1]) + 108)); i += 2 }
            else if c >= 251 && c <= 254, i + 1 < end { operands.append(Double(-(c - 251) * 256 - Int(b[i + 1]) - 108)); i += 2 }
            else { i += 1 }
        }
        guard charStrings > 0, let cs = cffIndex(b, base + charStrings) else { return }
        let nGlyphs = cs.offsets.count - 1
        // charset: glyph → SID (name-keyed) or CID
        var sids = [Int](repeating: 0, count: max(1, nGlyphs))
        if charset > 2 {
            var p = base + charset
            guard p < b.count else { return }
            let format = Int(b[p]); p += 1
            var g = 1
            if format == 0 {
                while g < nGlyphs, p + 1 < b.count { sids[g] = u16(b, p); p += 2; g += 1 }
            } else if format == 1 || format == 2 {
                while g < nGlyphs, p + 2 < b.count {
                    let first = u16(b, p)
                    let left = format == 1 ? Int(b[p + 2]) : u16(b, p + 2)
                    p += format == 1 ? 3 : 4
                    var k = 0
                    while k <= left && g < nGlyphs { sids[g] = first + k; g += 1; k += 1 }
                }
            }
        } else if !isCID {
            for g in 0..<nGlyphs { sids[g] = g }   // ISOAdobe: SID = glyph index
        }
        if isCID {
            var m: [Int: CGGlyph] = [:]
            for g in 0..<nGlyphs where g < 65535 { m[sids[g]] = CGGlyph(g) }
            cidGlyphs = m
            return
        }
        // Encoding: code → glyph
        if encoding > 1 {
            var p = base + encoding
            guard p + 1 < b.count else { return }
            let format = Int(b[p]) & 0x7F
            let count = Int(b[p + 1]); p += 2
            var g = 1
            if format == 0 {
                for _ in 0..<count where p < b.count { builtIn[Int(b[p])] = CGGlyph(g); p += 1; g += 1 }
            } else if format == 1 {
                for _ in 0..<count where p + 1 < b.count {
                    let first = Int(b[p]), left = Int(b[p + 1]); p += 2
                    for k in 0...left where g < 65535 { builtIn[first + k] = CGGlyph(g); g += 1 }
                }
            }
        } else if encoding == 0 {
            for c in 0..<256 { if let n = PDFVectorEncoding.standard[c] { builtInNames[c] = n } }
        }
        _ = strIdx
    }

    // MARK: Type 1

    /// Reads the clear-text `/Encoding` array ("dup 65 /A put").
    private func parseType1(_ b: [UInt8]) {
        let head = String(decoding: b.prefix(min(b.count, 60_000)), as: UTF8.self)
        guard let r = head.range(of: "/Encoding") else { return }
        let rest = head[r.upperBound...]
        if rest.prefix(40).contains("StandardEncoding") {
            for c in 0..<256 { if let n = PDFVectorEncoding.standard[c] { builtInNames[c] = n } }
            return
        }
        let stop = rest.range(of: "readonly def")?.lowerBound ?? rest.range(of: "currentdict end")?.lowerBound ?? rest.endIndex
        let parts = rest[..<stop].split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" })
        var k = 0
        while k + 3 < parts.count {
            if parts[k] == "dup", let code = Int(parts[k + 1]), parts[k + 2].hasPrefix("/"), code >= 0, code < 256 {
                builtInNames[code] = String(parts[k + 2].dropFirst())
                k += 4
            } else { k += 1 }
        }
    }
}
