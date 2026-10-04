import Foundation

/// Glyph names and the three standard simple-font encodings (what is needed to turn character codes of Type 1 /
/// TrueType fonts into Unicode and into glyph names of the embedded font program).
package enum PDFVectorEncoding {
    /// Adobe glyph names of the standard Latin character set (name → Unicode scalar).
    package static let glyphUnicode: [String: UInt32] = {
        var m: [String: UInt32] = [:]
        let ascii = ["space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand", "quotesingle", "parenleft", "parenright",
                     "asterisk", "plus", "comma", "hyphen", "period", "slash", "zero", "one", "two", "three", "four", "five", "six", "seven",
                     "eight", "nine", "colon", "semicolon", "less", "equal", "greater", "question", "at"]
        for (i, n) in ascii.enumerated() { m[n] = UInt32(32 + i) }
        for c in 65...90 { m[String(UnicodeScalar(UInt8(c)))] = UInt32(c) }
        for (i, n) in ["bracketleft", "backslash", "bracketright", "asciicircum", "underscore", "grave"].enumerated() { m[n] = UInt32(91 + i) }
        for c in 97...122 { m[String(UnicodeScalar(UInt8(c)))] = UInt32(c) }
        for (i, n) in ["braceleft", "bar", "braceright", "asciitilde"].enumerated() { m[n] = UInt32(123 + i) }
        let latin1 = ["nbspace", "exclamdown", "cent", "sterling", "currency", "yen", "brokenbar", "section", "dieresis", "copyright", "ordfeminine",
                      "guillemotleft", "logicalnot", "sfthyphen", "registered", "macron", "degree", "plusminus", "twosuperior", "threesuperior",
                      "acute", "mu", "paragraph", "periodcentered", "cedilla", "onesuperior", "ordmasculine", "guillemotright", "onequarter",
                      "onehalf", "threequarters", "questiondown", "Agrave", "Aacute", "Acircumflex", "Atilde", "Adieresis", "Aring", "AE",
                      "Ccedilla", "Egrave", "Eacute", "Ecircumflex", "Edieresis", "Igrave", "Iacute", "Icircumflex", "Idieresis", "Eth", "Ntilde",
                      "Ograve", "Oacute", "Ocircumflex", "Otilde", "Odieresis", "multiply", "Oslash", "Ugrave", "Uacute", "Ucircumflex",
                      "Udieresis", "Yacute", "Thorn", "germandbls", "agrave", "aacute", "acircumflex", "atilde", "adieresis", "aring", "ae",
                      "ccedilla", "egrave", "eacute", "ecircumflex", "edieresis", "igrave", "iacute", "icircumflex", "idieresis", "eth", "ntilde",
                      "ograve", "oacute", "ocircumflex", "otilde", "odieresis", "divide", "oslash", "ugrave", "uacute", "ucircumflex",
                      "udieresis", "yacute", "thorn", "ydieresis"]
        for (i, n) in latin1.enumerated() { m[n] = UInt32(0xA0 + i) }
        let other: [(String, UInt32)] = [
            ("quoteleft", 0x2018), ("quoteright", 0x2019), ("quotesinglbase", 0x201A), ("quotedblleft", 0x201C), ("quotedblright", 0x201D),
            ("quotedblbase", 0x201E), ("dagger", 0x2020), ("daggerdbl", 0x2021), ("bullet", 0x2022), ("ellipsis", 0x2026), ("perthousand", 0x2030),
            ("guilsinglleft", 0x2039), ("guilsinglright", 0x203A), ("fraction", 0x2044), ("Euro", 0x20AC), ("trademark", 0x2122), ("minus", 0x2212),
            ("endash", 0x2013), ("emdash", 0x2014), ("florin", 0x0192), ("circumflex", 0x02C6), ("tilde", 0x02DC), ("caron", 0x02C7),
            ("breve", 0x02D8), ("dotaccent", 0x02D9), ("ring", 0x02DA), ("ogonek", 0x02DB), ("hungarumlaut", 0x02DD), ("dotlessi", 0x0131),
            ("Lslash", 0x0141), ("lslash", 0x0142), ("OE", 0x0152), ("oe", 0x0153), ("Scaron", 0x0160), ("scaron", 0x0161), ("Ydieresis", 0x0178),
            ("Zcaron", 0x017D), ("zcaron", 0x017E), ("fi", 0xFB01), ("fl", 0xFB02), ("ff", 0xFB00), ("ffi", 0xFB03), ("ffl", 0xFB04),
            ("Delta", 0x2206), ("Omega", 0x2126), ("pi", 0x03C0), ("partialdiff", 0x2202), ("product", 0x220F), ("summation", 0x2211),
            ("radical", 0x221A), ("infinity", 0x221E), ("integral", 0x222B), ("approxequal", 0x2248), ("notequal", 0x2260), ("lessequal", 0x2264),
            ("greaterequal", 0x2265), ("lozenge", 0x25CA), ("apple", 0xF8FF), ("Gbreve", 0x011E), ("gbreve", 0x011F), ("Idotaccent", 0x0130),
            ("Scedilla", 0x015E), ("scedilla", 0x015F), ("Cacute", 0x0106), ("cacute", 0x0107), ("Ccaron", 0x010C), ("ccaron", 0x010D),
            ("dcroat", 0x0111), ("Dcroat", 0x0110), ("arrowleft", 0x2190), ("arrowup", 0x2191), ("arrowright", 0x2192), ("arrowdown", 0x2193),
            ("periodinferior", 0x2024), ("onedotenleader", 0x2024), ("figuredash", 0x2012), ("underscoredbl", 0x2017),
        ]
        for (n, u) in other { m[n] = u }
        return m
    }()

    /// Unicode scalar → glyph name (first name wins for the few scalars with two names).
    package static let unicodeGlyph: [UInt32: String] = {
        var m: [UInt32: String] = [:]
        for (n, u) in glyphUnicode.sorted(by: { $0.key < $1.key }) where m[u] == nil { m[u] = n }
        m[0xA0] = "space"; m[0xAD] = "hyphen"; m[0x20] = "space"; m[0x2D] = "hyphen"; m[0xB5] = "mu"
        return m
    }()

    /// Unicode of a glyph name (Adobe glyph list conventions: known names, uniXXXX, uXXXX, a suffix after a period is ignored).
    package static func unicode(forGlyph name: String) -> String? {
        var n = name
        if let dot = n.firstIndex(of: "."), dot != n.startIndex { n = String(n[..<dot]) }
        if n.contains("_") {   // ligature components
            var out = ""
            for part in n.split(separator: "_") { guard let u = unicode(forGlyph: String(part)) else { return nil }; out += u }
            return out
        }
        if let u = glyphUnicode[n], let s = UnicodeScalar(u) { return String(s) }
        if n.hasPrefix("uni"), n.count >= 7, (n.count - 3) % 4 == 0 {
            var out = ""
            var i = n.index(n.startIndex, offsetBy: 3)
            while i < n.endIndex {
                let j = n.index(i, offsetBy: 4)
                guard let v = UInt32(n[i..<j], radix: 16), let s = UnicodeScalar(v) else { return nil }
                out.unicodeScalars.append(s)
                i = j
            }
            return out
        }
        if n.hasPrefix("u"), n.count >= 5, n.count <= 7, let v = UInt32(n.dropFirst(), radix: 16), let s = UnicodeScalar(v) { return String(s) }
        return nil
    }

    package static let winAnsi: [String?] = table { code in
        if code == 0x27 { return 0x27 }
        if code == 0x60 { return 0x60 }
        if code < 32 { return nil }
        if code == 127 { return 0x2022 }
        let s = String(bytes: [UInt8(code)], encoding: .windowsCP1252)
        // codes Windows leaves undefined show a bullet
        return s?.unicodeScalars.first.map { $0.value < 0xA0 && code >= 0x80 ? 0x2022 : $0.value } ?? 0x2022
    }

    package static let macRoman: [String?] = table { code in
        if code < 32 || code == 127 { return nil }
        if code == 0xDB { return 0xA4 }   // currency (Apple later put the euro sign here)
        return String(bytes: [UInt8(code)], encoding: .macOSRoman)?.unicodeScalars.first?.value
    }

    package static let standard: [String?] = {
        var t = [String?](repeating: nil, count: 256)
        for c in 32...126 { if let n = unicodeGlyph[UInt32(c)] { t[c] = n } }
        t[0x27] = "quoteright"; t[0x60] = "quoteleft"
        let hi: [(Int, String)] = [
            (0xA1, "exclamdown"), (0xA2, "cent"), (0xA3, "sterling"), (0xA4, "fraction"), (0xA5, "yen"), (0xA6, "florin"), (0xA7, "section"),
            (0xA8, "currency"), (0xA9, "quotesingle"), (0xAA, "quotedblleft"), (0xAB, "guillemotleft"), (0xAC, "guilsinglleft"),
            (0xAD, "guilsinglright"), (0xAE, "fi"), (0xAF, "fl"), (0xB1, "endash"), (0xB2, "dagger"), (0xB3, "daggerdbl"),
            (0xB4, "periodcentered"), (0xB6, "paragraph"), (0xB7, "bullet"), (0xB8, "quotesinglbase"), (0xB9, "quotedblbase"),
            (0xBA, "quotedblright"), (0xBB, "guillemotright"), (0xBC, "ellipsis"), (0xBD, "perthousand"), (0xBF, "questiondown"),
            (0xC1, "grave"), (0xC2, "acute"), (0xC3, "circumflex"), (0xC4, "tilde"), (0xC5, "macron"), (0xC6, "breve"), (0xC7, "dotaccent"),
            (0xC8, "dieresis"), (0xCA, "ring"), (0xCB, "cedilla"), (0xCD, "hungarumlaut"), (0xCE, "ogonek"), (0xCF, "caron"), (0xD0, "emdash"),
            (0xE1, "AE"), (0xE3, "ordfeminine"), (0xE8, "Lslash"), (0xE9, "Oslash"), (0xEA, "OE"), (0xEB, "ordmasculine"), (0xF1, "ae"),
            (0xF5, "dotlessi"), (0xF8, "lslash"), (0xF9, "oslash"), (0xFA, "oe"), (0xFB, "germandbls"),
        ]
        for (c, n) in hi { t[c] = n }
        return t
    }()

    private static func table(_ scalar: (Int) -> UInt32?) -> [String?] {
        var t = [String?](repeating: nil, count: 256)
        for c in 0..<256 { if let u = scalar(c) { t[c] = unicodeGlyph[u] } }
        return t
    }

    package static func named(_ name: String?) -> [String?]? {
        switch name {
        case "WinAnsiEncoding": return winAnsi
        case "MacRomanEncoding": return macRoman
        case "StandardEncoding": return standard
        default: return nil
        }
    }

    // MARK: ToUnicode CMaps

    /// Parses the bfchar / bfrange sections of a ToUnicode CMap: character code → text.
    package static func toUnicode(_ data: Data) -> [Int: String] {
        var map: [Int: String] = [:]
        let b = [UInt8](data)
        let n = b.count
        var i = 0
        func text(_ bytes: [UInt8]) -> String? {
            guard !bytes.isEmpty else { return nil }
            if bytes.count == 1 { return UnicodeScalar(UInt32(bytes[0])).map { String($0) } }
            var units: [UInt16] = []
            var k = 0
            while k + 1 < bytes.count { units.append(UInt16(bytes[k]) << 8 | UInt16(bytes[k + 1])); k += 2 }
            let s = String(decoding: units, as: UTF16.self)
            return s.isEmpty ? nil : s
        }
        func value(_ bytes: [UInt8]) -> Int { bytes.prefix(4).reduce(0) { $0 << 8 | Int($1) } }
        /// Next token: a hex string, "[" / "]", or a keyword.
        enum Tok { case hex([UInt8]), open, close, word(String) }
        func next() -> Tok? {
            while i < n {
                let c = b[i]
                if c == 60 {   // <
                    if i + 1 < n && b[i + 1] == 60 { i += 2; continue }
                    i += 1
                    var out: [UInt8] = []
                    var hi: UInt8? = nil
                    while i < n && b[i] != 62 {
                        let h: UInt8?
                        switch b[i] {
                        case 48...57: h = b[i] - 48
                        case 65...70: h = b[i] - 55
                        case 97...102: h = b[i] - 87
                        default: h = nil
                        }
                        if let h { if let x = hi { out.append(x << 4 | h); hi = nil } else { hi = h } }
                        i += 1
                    }
                    if let x = hi { out.append(x << 4) }
                    i += 1
                    return .hex(out)
                }
                if c == 91 { i += 1; return .open }
                if c == 93 { i += 1; return .close }
                if c == 37 { while i < n && b[i] != 10 && b[i] != 13 { i += 1 }; continue }
                if c <= 32 || c == 62 || c == 40 || c == 41 || c == 47 {
                    if c == 40 { while i < n && b[i] != 41 { i += 1 } }
                    i += 1
                    if c == 47 { while i < n && b[i] > 32 && b[i] != 47 && b[i] != 60 && b[i] != 91 { i += 1 } }
                    continue
                }
                let s = i
                while i < n && b[i] > 32 && b[i] != 60 && b[i] != 91 && b[i] != 93 && b[i] != 47 { i += 1 }
                return .word(String(decoding: b[s..<i], as: UTF8.self))
            }
            return nil
        }
        var mode = 0   // 1 = bfchar, 2 = bfrange
        var pending: [[UInt8]] = []
        while let t = next() {
            switch t {
            case .word(let w):
                if w == "beginbfchar" { mode = 1; pending = [] }
                else if w == "beginbfrange" { mode = 2; pending = [] }
                else if w.hasPrefix("end") { mode = 0; pending = [] }
            case .hex(let h):
                guard mode != 0 else { continue }
                pending.append(h)
                if mode == 1, pending.count == 2 {
                    if let s = text(pending[1]) { map[value(pending[0])] = s }
                    pending = []
                } else if mode == 2, pending.count == 3 {
                    let lo = value(pending[0]), hi = value(pending[1])
                    if hi >= lo, hi - lo < 65536 {
                        var dst = pending[2]
                        for code in lo...hi {
                            if let s = text(dst) { map[code] = s }
                            // the last byte counts up through the range
                            var k = dst.count - 1
                            while k >= 0 { if dst[k] == 255 { dst[k] = 0; k -= 1 } else { dst[k] += 1; break } }
                        }
                    }
                    pending = []
                }
            case .open:
                guard mode == 2, pending.count == 2 else { continue }
                let lo = value(pending[0])
                var code = lo
                while let e = next() {
                    if case .hex(let h) = e { if let s = text(h), code - lo < 65536 { map[code] = s }; code += 1 } else { break }
                }
                pending = []
            case .close: break
            }
            if map.count > 200_000 { break }
        }
        return map
    }
}
