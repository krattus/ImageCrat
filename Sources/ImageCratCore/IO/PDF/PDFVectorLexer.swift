import Foundation

/// An operand of a content-stream operator.
package enum PDFVectorOperand {
    case number(Double)
    case name(String)
    case string([UInt8])
    case array([PDFVectorOperand])
    case dict([String: PDFVectorOperand])
    case bool(Bool)
    case null

    package var number: Double? { if case .number(let n) = self { return n }; return nil }
    package var name: String? { if case .name(let n) = self { return n }; return nil }
    package var bytes: [UInt8]? { if case .string(let b) = self { return b }; return nil }
    package var array: [PDFVectorOperand]? { if case .array(let a) = self { return a }; return nil }
    package var dict: [String: PDFVectorOperand]? { if case .dict(let d) = self { return d }; return nil }
}

/// Content-stream operators packed into an integer (up to three ASCII bytes, first byte lowest).
package enum PDFVectorOp {
    package static func code(_ s: StaticString) -> UInt32 {
        var v: UInt32 = 0
        s.withUTF8Buffer { b in for (i, c) in b.enumerated() where i < 4 { v |= UInt32(c) << UInt32(8 * i) } }
        return v
    }
    package static let q = code("q"), Q = code("Q"), cm = code("cm"), w = code("w"), J = code("J"), j = code("j"), M = code("M"), d = code("d")
    package static let ri = code("ri"), i = code("i"), gs = code("gs")
    package static let m = code("m"), l = code("l"), c = code("c"), v = code("v"), y = code("y"), h = code("h"), re = code("re")
    package static let S = code("S"), s = code("s"), f = code("f"), F = code("F"), fStar = code("f*"), B = code("B"), BStar = code("B*")
    package static let b = code("b"), bStar = code("b*"), n = code("n"), W = code("W"), WStar = code("W*")
    package static let BT = code("BT"), ET = code("ET"), Tc = code("Tc"), Tw = code("Tw"), Tz = code("Tz"), TL = code("TL"), Tf = code("Tf")
    package static let Tr = code("Tr"), Ts = code("Ts"), Td = code("Td"), TD = code("TD"), Tm = code("Tm"), TStar = code("T*")
    package static let Tj = code("Tj"), TJ = code("TJ"), quote = code("'"), dquote = code("\"")
    package static let d0 = code("d0"), d1 = code("d1")
    package static let CS = code("CS"), cs = code("cs"), SC = code("SC"), SCN = code("SCN"), sc = code("sc"), scn = code("scn")
    package static let G = code("G"), g = code("g"), RG = code("RG"), rg = code("rg"), K = code("K"), k = code("k")
    package static let sh = code("sh"), BI = code("BI"), ID = code("ID"), EI = code("EI"), Do = code("Do")
    package static let MP = code("MP"), DP = code("DP"), BMC = code("BMC"), BDC = code("BDC"), EMC = code("EMC"), BX = code("BX"), EX = code("EX")
}

/// Streaming tokenizer for page content. `next()` reads up to and including the next operator and leaves its
/// operands in `operands` and its byte range (operands included) in `start`…`end`, so parts of the stream can be
/// replayed verbatim when something has to be rasterized from the PDF itself.
package struct PDFVectorLexer {
    package let bytes: [UInt8]
    package private(set) var pos = 0
    package private(set) var operands: [PDFVectorOperand] = []
    package private(set) var op: UInt32 = 0
    package private(set) var start = 0
    package private(set) var end = 0
    /// Whether the last operand was written as an integer (a few operators accept nothing else).
    package private(set) var tailIsInteger = false
    /// Set for `BI`: the image dictionary; the whole inline image (through `EI`) is one operator.
    package private(set) var inlineImage: [String: PDFVectorOperand]? = nil

    package init(_ bytes: [UInt8]) { self.bytes = bytes }

    @inline(__always) private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 || c == 0 }
    @inline(__always) private static func isDelimiter(_ c: UInt8) -> Bool {
        c == 40 || c == 41 || c == 60 || c == 62 || c == 91 || c == 93 || c == 123 || c == 125 || c == 47 || c == 37
    }
    @inline(__always) private static func isRegular(_ c: UInt8) -> Bool { !isSpace(c) && !isDelimiter(c) }

    private mutating func skipSpace() {
        let n = bytes.count
        while pos < n {
            let c = bytes[pos]
            if PDFVectorLexer.isSpace(c) { pos += 1 }
            else if c == 37 { while pos < n && bytes[pos] != 10 && bytes[pos] != 13 { pos += 1 } }   // % comment
            else { break }
        }
    }

    /// Reads the next operator. Returns false at the end of the data.
    package mutating func next() -> Bool {
        operands.removeAll(keepingCapacity: true)
        inlineImage = nil
        skipSpace()
        start = pos
        let n = bytes.count
        while pos < n {
            skipSpace()
            guard pos < n else { break }
            let c = bytes[pos]
            if c == 47 || c == 40 || c == 60 || c == 91 {
                if let o = object(depth: 0) { push(o) }
                continue
            }
            if c == 93 || c == 62 || c == 41 || c == 123 || c == 125 { pos += 1; continue }   // stray closer: ignore
            // number or keyword
            let t0 = pos
            while pos < n && PDFVectorLexer.isRegular(bytes[pos]) { pos += 1 }
            if pos == t0 { pos += 1; continue }
            let first = bytes[t0]
            if (first >= 48 && first <= 57) || first == 45 || first == 43 || first == 46 {
                push(.number(PDFVectorLexer.parseNumber(bytes, t0, pos)))
                tailIsInteger = !bytes[t0..<pos].contains(46)
                continue
            }
            let len = pos - t0
            if len == 4, bytes[t0] == 116, bytes[t0 + 1] == 114, bytes[t0 + 2] == 117, bytes[t0 + 3] == 101 { push(.bool(true)); continue }
            if len == 5, bytes[t0] == 102, bytes[t0 + 1] == 97, bytes[t0 + 2] == 108, bytes[t0 + 3] == 115, bytes[t0 + 4] == 101 { push(.bool(false)); continue }
            if len == 4, bytes[t0] == 110, bytes[t0 + 1] == 117, bytes[t0 + 2] == 108, bytes[t0 + 3] == 108 { push(.null); continue }
            if len > 3 {   // not an operator: garbage — drop what was collected with it
                operands.removeAll(keepingCapacity: true)
                start = pos
                continue
            }
            var code: UInt32 = 0
            for k in 0..<len { code |= UInt32(bytes[t0 + k]) << UInt32(8 * k) }
            if code == PDFVectorOp.BI {
                readInlineImage()
                op = code
                end = pos
                return true
            }
            op = code
            end = pos
            return true
        }
        return false
    }

    private mutating func push(_ o: PDFVectorOperand) {
        // operators take a handful of operands; a runaway list means a damaged stream
        if operands.count >= 4096 { operands.removeAll(keepingCapacity: true) }
        operands.append(o)
        tailIsInteger = false
    }

    package static func parseNumber(_ b: [UInt8], _ from: Int, _ to: Int) -> Double {
        var i = from
        var neg = false
        while i < to, b[i] == 45 || b[i] == 43 { if b[i] == 45 { neg = !neg }; i += 1 }
        var v = 0.0
        var digits = 0
        while i < to, b[i] >= 48, b[i] <= 57 { if digits < 18 { v = v * 10 + Double(b[i] - 48) }; digits += 1; i += 1 }
        if i < to, b[i] == 46 {
            i += 1
            var scale = 0.1
            var fd = 0
            while i < to, b[i] >= 48, b[i] <= 57 { if fd < 12 { v += Double(b[i] - 48) * scale; scale *= 0.1 }; fd += 1; i += 1 }
        }
        if digits >= 18 { v = 1e18 }
        return neg ? -v : v
    }

    private mutating func object(depth: Int) -> PDFVectorOperand? {
        let n = bytes.count
        guard pos < n else { return nil }
        if depth > 32 { pos = n; return nil }
        let c = bytes[pos]
        switch c {
        case 47:   // name
            pos += 1
            var s: [UInt8] = []
            while pos < n && PDFVectorLexer.isRegular(bytes[pos]) {
                if bytes[pos] == 35, pos + 2 < n, let h = PDFVectorLexer.hex(bytes[pos + 1]), let lo = PDFVectorLexer.hex(bytes[pos + 2]) {
                    s.append(h << 4 | lo); pos += 3
                } else { s.append(bytes[pos]); pos += 1 }
            }
            return .name(String(decoding: s, as: UTF8.self))
        case 40: return .string(literalString())
        case 60:
            if pos + 1 < n && bytes[pos + 1] == 60 {
                pos += 2
                var d: [String: PDFVectorOperand] = [:]
                var count = 0
                while pos < n {
                    skipSpace()
                    guard pos < n else { break }
                    if bytes[pos] == 62 { pos += pos + 1 < n && bytes[pos + 1] == 62 ? 2 : 1; break }
                    guard bytes[pos] == 47, case .name(let key)? = object(depth: depth + 1) else { pos += 1; continue }
                    skipSpace()
                    guard let v = value(depth: depth + 1) else { break }
                    count += 1
                    if count < 4096 { d[key] = v }
                }
                return .dict(d)
            }
            return .string(hexString())
        case 91:
            pos += 1
            var a: [PDFVectorOperand] = []
            while pos < n {
                skipSpace()
                guard pos < n else { break }
                if bytes[pos] == 93 { pos += 1; break }
                guard let v = value(depth: depth + 1) else { continue }
                if a.count < 1 << 20 { a.append(v) }
            }
            return .array(a)
        default:
            pos += 1
            return nil
        }
    }

    /// Any value inside an array or dictionary (objects, numbers, keywords).
    private mutating func value(depth: Int) -> PDFVectorOperand? {
        let n = bytes.count
        guard pos < n else { return nil }
        let c = bytes[pos]
        if c == 47 || c == 40 || c == 60 || c == 91 { return object(depth: depth) }
        if PDFVectorLexer.isDelimiter(c) { pos += 1; return nil }
        let t0 = pos
        while pos < n && PDFVectorLexer.isRegular(bytes[pos]) { pos += 1 }
        if pos == t0 { pos += 1; return nil }
        let first = bytes[t0]
        if (first >= 48 && first <= 57) || first == 45 || first == 43 || first == 46 { return .number(PDFVectorLexer.parseNumber(bytes, t0, pos)) }
        let word = String(decoding: bytes[t0..<pos], as: UTF8.self)
        switch word {
        case "true": return .bool(true)
        case "false": return .bool(false)
        default: return .null
        }
    }

    private static func hex(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 65...70: return c - 55
        case 97...102: return c - 87
        default: return nil
        }
    }

    private mutating func hexString() -> [UInt8] {
        let n = bytes.count
        pos += 1
        var out: [UInt8] = []
        var hi: UInt8? = nil
        while pos < n {
            let c = bytes[pos]
            pos += 1
            if c == 62 { break }
            guard let v = PDFVectorLexer.hex(c) else { continue }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        if let h = hi { out.append(h << 4) }
        return out
    }

    private mutating func literalString() -> [UInt8] {
        let n = bytes.count
        pos += 1
        var out: [UInt8] = []
        var level = 1
        while pos < n {
            let c = bytes[pos]
            pos += 1
            if c == 92 {   // backslash
                guard pos < n else { break }
                let e = bytes[pos]
                pos += 1
                switch e {
                case 110: out.append(10)
                case 114: out.append(13)
                case 116: out.append(9)
                case 98: out.append(8)
                case 102: out.append(12)
                case 48...55:
                    var v = Int(e - 48)
                    var k = 0
                    while k < 2, pos < n, bytes[pos] >= 48, bytes[pos] <= 55 { v = v * 8 + Int(bytes[pos] - 48); pos += 1; k += 1 }
                    out.append(UInt8(truncatingIfNeeded: v))
                case 13: if pos < n && bytes[pos] == 10 { pos += 1 }   // line continuation
                case 10: break
                default: out.append(e)
                }
            } else if c == 40 { level += 1; out.append(c) }
            else if c == 41 { level -= 1; if level == 0 { break }; out.append(c) }
            else { out.append(c) }
        }
        return out
    }

    /// `BI` has been read: parses the key/value pairs up to `ID` and skips the image data through `EI`.
    private mutating func readInlineImage() {
        let n = bytes.count
        var d: [String: PDFVectorOperand] = [:]
        // Core Graphics reads key / value pairs up to ID, skipping anything that is not a key. It gives up on the
        // whole stream when a key is followed by an operator instead of a value (a stray BI in front of other
        // operators); the same happens here, so what is drawn stays what PDFKit draws.
        while pos < n {
            skipSpace()
            guard pos < n else { break }
            if bytes[pos] == 47 {
                guard case .name(let key)? = object(depth: 1) else { continue }
                skipSpace()
                guard pos < n else { break }
                let c = bytes[pos]
                if PDFVectorLexer.isRegular(c), !((c >= 48 && c <= 57) || c == 45 || c == 43 || c == 46) {
                    var e = pos
                    while e < n && PDFVectorLexer.isRegular(bytes[e]) { e += 1 }
                    let word = String(decoding: bytes[pos..<e], as: UTF8.self)
                    if word != "true" && word != "false" && word != "null" {
                        pos = n
                        return
                    }
                }
                if let v = value(depth: 1), d.count < 64 { d[key] = v }
                continue
            }
            let t0 = pos
            while pos < n && PDFVectorLexer.isRegular(bytes[pos]) { pos += 1 }
            if pos == t0 { pos += 1; continue }
            if pos - t0 == 2 && bytes[t0] == 73 && bytes[t0 + 1] == 68 { break }   // ID
        }
        guard pos < n else { return }
        if pos < n && PDFVectorLexer.isSpace(bytes[pos]) { pos += 1 }
        // Unfiltered data has a known length; otherwise look for a free-standing EI followed by plain text.
        func num(_ a: String, _ b: String) -> Double? { d[a]?.number ?? d[b]?.number }
        let filtered = d["F"] != nil || d["Filter"] != nil
        if !filtered, let w = num("W", "Width"), let h = num("H", "Height"), w > 0, h > 0, w < 1e6, h < 1e6 {
            var comps = 1.0
            var bpc = Swift.max(1, Swift.min(32, num("BPC", "BitsPerComponent") ?? 8))
            var mask = false
            if case .bool(true)? = d["IM"] ?? d["ImageMask"] { mask = true; bpc = 1 }
            if !mask, let cs = (d["CS"] ?? d["ColorSpace"])?.name {
                switch cs {
                case "RGB", "DeviceRGB": comps = 3
                case "CMYK", "DeviceCMYK": comps = 4
                default: comps = 1
                }
            }
            let len = Int((w * comps * bpc / 8).rounded(.up) * h)
            var p = pos + len
            if p <= n {
                while p < n && PDFVectorLexer.isSpace(bytes[p]) { p += 1 }
                if p + 1 < n && bytes[p] == 69 && bytes[p + 1] == 73 && (p + 2 >= n || !PDFVectorLexer.isRegular(bytes[p + 2])) {
                    pos = p + 2
                    inlineImage = d
                    return
                }
            }
        }
        var p = pos
        while p + 1 < n {
            if bytes[p] == 69 && bytes[p + 1] == 73 && (p == 0 || PDFVectorLexer.isSpace(bytes[p - 1])) && (p + 2 >= n || PDFVectorLexer.isSpace(bytes[p + 2])) {
                var ok = true
                var k = p + 2
                while k < min(n, p + 24) { if bytes[k] > 127 || (bytes[k] < 9) { ok = false; break }; k += 1 }
                if ok { pos = p + 2; inlineImage = d; return }
            }
            p += 1
        }
        pos = n
        inlineImage = d
    }
}
