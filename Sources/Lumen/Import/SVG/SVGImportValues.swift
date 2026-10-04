import Foundation
import CoreGraphics
import ImageCratCore

// SVG import, part 2: attribute values — numbers, lengths, colours, transforms and path data.
// Everything here is total: bad input yields nil / a shorter result, never a trap, NaN or infinity.

/// Byte scanner for number lists and path data.
struct SVGImportScanner {
    let b: [UInt8]
    var i = 0
    init(_ s: String) { b = Array(s.utf8) }
    init(_ s: Substring) { b = Array(s.utf8) }

    var atEnd: Bool { i >= b.count }
    var peek: UInt8? { i < b.count ? b[i] : nil }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C }

    mutating func skipSpace() { while i < b.count, Self.isSpace(b[i]) { i += 1 } }
    /// Whitespace with at most one comma.
    mutating func skipSeparator() {
        skipSpace()
        if i < b.count, b[i] == 0x2C { i += 1; skipSpace() }
    }

    /// SVG number (sign, digits, fraction, exponent). Always finite; a value too large for a float is not a number.
    mutating func number() -> Double? {
        let start = i
        var neg = false
        if i < b.count, b[i] == 0x2B || b[i] == 0x2D { neg = b[i] == 0x2D; i += 1 }
        var mant = 0.0
        var digits = 0
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { mant = mant * 10 + Double(b[i] - 0x30); i += 1; digits += 1 }
        if i < b.count, b[i] == 0x2E {
            i += 1
            var scale = 0.1
            while i < b.count, b[i] >= 0x30, b[i] <= 0x39 {
                if scale > 1e-18 { mant += Double(b[i] - 0x30) * scale; scale *= 0.1 }
                i += 1; digits += 1
            }
        }
        guard digits > 0 else { i = start; return nil }
        // exponent only when followed by a digit ("1em" and "1ex" are units)
        if i < b.count, b[i] == 0x65 || b[i] == 0x45 {
            var j = i + 1
            var eneg = false
            if j < b.count, b[j] == 0x2B || b[j] == 0x2D { eneg = b[j] == 0x2D; j += 1 }
            if j < b.count, b[j] >= 0x30, b[j] <= 0x39 {
                var e = 0
                while j < b.count, b[j] >= 0x30, b[j] <= 0x39 { if e < 1000 { e = e * 10 + Int(b[j] - 0x30) }; j += 1 }
                i = j
                mant *= pow(10, Double(eneg ? -min(e, 400) : min(e, 400)))
            }
        }
        // beyond single precision a browser reads infinity, which makes the value (and its attribute) invalid
        guard mant.isFinite, mant <= 3.4e38 else { i = start; return nil }
        return neg ? -mant : mant
    }

    /// Arc flag: a single '0' or '1', which may be followed directly by the next number.
    mutating func flag() -> Bool? {
        skipSeparator()
        guard i < b.count, b[i] == 0x30 || b[i] == 0x31 else { return nil }
        defer { i += 1 }
        return b[i] == 0x31
    }

    mutating func separatedNumber() -> Double? { skipSeparator(); return number() }

    /// Remaining text (for unit suffixes).
    mutating func identifier() -> String {
        let start = i
        while i < b.count, (b[i] >= 0x41 && b[i] <= 0x5A) || (b[i] >= 0x61 && b[i] <= 0x7A) || b[i] == 0x25 { i += 1 }
        return String(decoding: b[start..<i], as: UTF8.self)
    }
}

struct SVGImportLength: Equatable {
    enum Unit { case user, percent, em, ex, rem }
    var value: Double
    var unit: Unit = .user

    /// Resolves against a reference length for percentages and the font size for em / ex.
    func resolve(percentOf ref: Double, fontSize: Double) -> Double {
        switch unit {
        case .user: return value
        case .percent: return value / 100 * ref
        case .em: return value * fontSize
        case .ex: return value * fontSize * 0.5
        case .rem: return value * 16
        }
    }
}

enum SVGImportValue {
    static func number(_ s: String?) -> Double? {
        guard let s else { return nil }
        var sc = SVGImportScanner(s)
        sc.skipSpace()
        guard let v = sc.number() else { return nil }
        // "50%" as a plain number (opacity, offset) is a fraction
        if sc.peek == 0x25 { return v / 100 }
        return v
    }

    static func numbers(_ s: String?) -> [Double] {
        guard let s else { return [] }
        var sc = SVGImportScanner(s)
        var out: [Double] = []
        while out.count < 4_000_000, let v = sc.separatedNumber() { out.append(v) }
        return out
    }

    /// Length in CSS px (absolute units converted) or a relative unit.
    static func length(_ s: String?) -> SVGImportLength? {
        guard let s else { return nil }
        var sc = SVGImportScanner(s)
        sc.skipSpace()
        guard let v = sc.number() else { return nil }
        switch sc.identifier().lowercased() {
        case "", "px": return SVGImportLength(value: v)
        case "%": return SVGImportLength(value: v, unit: .percent)
        case "em": return SVGImportLength(value: v, unit: .em)
        case "ex", "ch": return SVGImportLength(value: v, unit: .ex)
        case "rem": return SVGImportLength(value: v, unit: .rem)
        case "pt": return SVGImportLength(value: v * 96 / 72)
        case "pc": return SVGImportLength(value: v * 16)
        case "mm": return SVGImportLength(value: v * 96 / 25.4)
        case "cm": return SVGImportLength(value: v * 96 / 2.54)
        case "in": return SVGImportLength(value: v * 96)
        case "q": return SVGImportLength(value: v * 96 / 101.6)
        default: return nil
        }
    }

    static func lengths(_ s: String?) -> [SVGImportLength] {
        guard let s else { return [] }
        return s.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).prefix(100_000).compactMap { length(String($0)) }
    }

    static func points(_ s: String?) -> [CGPoint] {
        let v = numbers(s)
        var out: [CGPoint] = []
        out.reserveCapacity(v.count / 2)
        var i = 0
        while i + 1 < v.count { out.append(CGPoint(x: v[i], y: v[i + 1])); i += 2 }
        return out
    }

    /// Angle in degrees from a CSS / SVG angle ("45", "45deg", "0.5turn", "1rad", "50grad").
    static func angle(_ s: String) -> Double? {
        var sc = SVGImportScanner(s)
        sc.skipSpace()
        guard let v = sc.number() else { return nil }
        switch sc.identifier().lowercased() {
        case "", "deg": return v
        case "rad": return v * 180 / .pi
        case "turn": return v * 360
        case "grad": return v * 0.9
        default: return nil
        }
    }

    // MARK: Colour

    /// nil for anything that is not a colour this importer understands (`none`, `currentColor` and `url()` are paints).
    static func color(_ raw: String) -> RGBA? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("#") {
            let h = String(s.dropFirst())
            guard h.allSatisfy({ $0.isHexDigit }) else { return nil }
            switch h.count {
            case 3, 6, 8: return RGBA(hex: h)
            case 4: return RGBA(hex: h.map { "\($0)\($0)" }.joined())
            default: return nil
            }
        }
        if s == "transparent" { return .clear }
        if let v = named[s] { return RGBA(r8: UInt8((v >> 16) & 0xff), g8: UInt8((v >> 8) & 0xff), b8: UInt8(v & 0xff)) }
        guard let open = s.firstIndex(of: "("), s.hasSuffix(")") else { return nil }
        let fn = s[..<open]
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        let parts = inner.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == "\t" }).map(String.init)
        func comp(_ t: String, scale: Double) -> Double? {
            var sc = SVGImportScanner(t)
            guard let v = sc.number() else { return nil }
            return sc.peek == 0x25 ? v / 100 : v / scale
        }
        func alpha(_ i: Int) -> Double { parts.count > i ? clamp(comp(parts[i], scale: 1) ?? 1, 0, 1) : 1 }
        switch fn {
        case "rgb", "rgba":
            guard parts.count >= 3, let r = comp(parts[0], scale: 255), let g = comp(parts[1], scale: 255), let b = comp(parts[2], scale: 255) else { return nil }
            return RGBA(r: clamp(r, 0, 1), g: clamp(g, 0, 1), b: clamp(b, 0, 1), a: alpha(3))
        case "hsl", "hsla":
            guard parts.count >= 3, let h = angle(parts[0]), let sat = comp(parts[1], scale: 100), let l = comp(parts[2], scale: 100) else { return nil }
            let hue = (h / 360).truncatingRemainder(dividingBy: 1)
            return RGBA(h: hue < 0 ? hue + 1 : hue, s: clamp(sat, 0, 1), l: clamp(l, 0, 1), a: alpha(3))
        default: return nil
        }
    }

    static let named: [String: UInt32] = [
        "aliceblue": 0xf0f8ff, "antiquewhite": 0xfaebd7, "aqua": 0x00ffff, "aquamarine": 0x7fffd4, "azure": 0xf0ffff, "beige": 0xf5f5dc, "bisque": 0xffe4c4,
        "black": 0x000000, "blanchedalmond": 0xffebcd, "blue": 0x0000ff, "blueviolet": 0x8a2be2, "brown": 0xa52a2a, "burlywood": 0xdeb887, "cadetblue": 0x5f9ea0,
        "chartreuse": 0x7fff00, "chocolate": 0xd2691e, "coral": 0xff7f50, "cornflowerblue": 0x6495ed, "cornsilk": 0xfff8dc, "crimson": 0xdc143c, "cyan": 0x00ffff,
        "darkblue": 0x00008b, "darkcyan": 0x008b8b, "darkgoldenrod": 0xb8860b, "darkgray": 0xa9a9a9, "darkgreen": 0x006400, "darkgrey": 0xa9a9a9,
        "darkkhaki": 0xbdb76b, "darkmagenta": 0x8b008b, "darkolivegreen": 0x556b2f, "darkorange": 0xff8c00, "darkorchid": 0x9932cc, "darkred": 0x8b0000,
        "darksalmon": 0xe9967a, "darkseagreen": 0x8fbc8f, "darkslateblue": 0x483d8b, "darkslategray": 0x2f4f4f, "darkslategrey": 0x2f4f4f,
        "darkturquoise": 0x00ced1, "darkviolet": 0x9400d3, "deeppink": 0xff1493, "deepskyblue": 0x00bfff, "dimgray": 0x696969, "dimgrey": 0x696969,
        "dodgerblue": 0x1e90ff, "firebrick": 0xb22222, "floralwhite": 0xfffaf0, "forestgreen": 0x228b22, "fuchsia": 0xff00ff, "gainsboro": 0xdcdcdc,
        "ghostwhite": 0xf8f8ff, "gold": 0xffd700, "goldenrod": 0xdaa520, "gray": 0x808080, "green": 0x008000, "greenyellow": 0xadff2f, "grey": 0x808080,
        "honeydew": 0xf0fff0, "hotpink": 0xff69b4, "indianred": 0xcd5c5c, "indigo": 0x4b0082, "ivory": 0xfffff0, "khaki": 0xf0e68c, "lavender": 0xe6e6fa,
        "lavenderblush": 0xfff0f5, "lawngreen": 0x7cfc00, "lemonchiffon": 0xfffacd, "lightblue": 0xadd8e6, "lightcoral": 0xf08080, "lightcyan": 0xe0ffff,
        "lightgoldenrodyellow": 0xfafad2, "lightgray": 0xd3d3d3, "lightgreen": 0x90ee90, "lightgrey": 0xd3d3d3, "lightpink": 0xffb6c1, "lightsalmon": 0xffa07a,
        "lightseagreen": 0x20b2aa, "lightskyblue": 0x87cefa, "lightslategray": 0x778899, "lightslategrey": 0x778899, "lightsteelblue": 0xb0c4de,
        "lightyellow": 0xffffe0, "lime": 0x00ff00, "limegreen": 0x32cd32, "linen": 0xfaf0e6, "magenta": 0xff00ff, "maroon": 0x800000,
        "mediumaquamarine": 0x66cdaa, "mediumblue": 0x0000cd, "mediumorchid": 0xba55d3, "mediumpurple": 0x9370db, "mediumseagreen": 0x3cb371,
        "mediumslateblue": 0x7b68ee, "mediumspringgreen": 0x00fa9a, "mediumturquoise": 0x48d1cc, "mediumvioletred": 0xc71585, "midnightblue": 0x191970,
        "mintcream": 0xf5fffa, "mistyrose": 0xffe4e1, "moccasin": 0xffe4b5, "navajowhite": 0xffdead, "navy": 0x000080, "oldlace": 0xfdf5e6, "olive": 0x808000,
        "olivedrab": 0x6b8e23, "orange": 0xffa500, "orangered": 0xff4500, "orchid": 0xda70d6, "palegoldenrod": 0xeee8aa, "palegreen": 0x98fb98,
        "paleturquoise": 0xafeeee, "palevioletred": 0xdb7093, "papayawhip": 0xffefd5, "peachpuff": 0xffdab9, "peru": 0xcd853f, "pink": 0xffc0cb, "plum": 0xdda0dd,
        "powderblue": 0xb0e0e6, "purple": 0x800080, "rebeccapurple": 0x663399, "red": 0xff0000, "rosybrown": 0xbc8f8f, "royalblue": 0x4169e1,
        "saddlebrown": 0x8b4513, "salmon": 0xfa8072, "sandybrown": 0xf4a460, "seagreen": 0x2e8b57, "seashell": 0xfff5ee, "sienna": 0xa0522d, "silver": 0xc0c0c0,
        "skyblue": 0x87ceeb, "slateblue": 0x6a5acd, "slategray": 0x708090, "slategrey": 0x708090, "snow": 0xfffafa, "springgreen": 0x00ff7f, "steelblue": 0x4682b4,
        "tan": 0xd2b48c, "teal": 0x008080, "thistle": 0xd8bfd8, "tomato": 0xff6347, "turquoise": 0x40e0d0, "violet": 0xee82ee, "wheat": 0xf5deb3,
        "white": 0xffffff, "whitesmoke": 0xf5f5f5, "yellow": 0xffff00, "yellowgreen": 0x9acd32,
    ]

    // MARK: Transform

    /// SVG transform list (also accepts the CSS spellings with units). nil when nothing valid was found.
    static func transform(_ raw: String?) -> CGAffineTransform? {
        guard let raw, !raw.isEmpty else { return nil }
        let s = Array(raw.utf8)
        var i = 0
        var result = CGAffineTransform.identity
        var any = false
        var count = 0
        while i < s.count, count < 4096 {
            while i < s.count, SVGImportScanner.isSpace(s[i]) || s[i] == 0x2C { i += 1 }
            let nameStart = i
            while i < s.count, (s[i] >= 0x41 && s[i] <= 0x5A) || (s[i] >= 0x61 && s[i] <= 0x7A) || (s[i] >= 0x30 && s[i] <= 0x39 && i > nameStart) { i += 1 }
            let name = String(decoding: s[nameStart..<i], as: UTF8.self)
            while i < s.count, SVGImportScanner.isSpace(s[i]) { i += 1 }
            guard !name.isEmpty, i < s.count, s[i] == 0x28 else { break }
            i += 1
            let argStart = i
            while i < s.count, s[i] != 0x29 { i += 1 }
            guard i < s.count else { break }
            let args = String(decoding: s[argStart..<i], as: UTF8.self)
            i += 1
            count += 1
            // arguments with optional units
            var v: [Double] = []
            var bad = false
            let isAngle = name.hasPrefix("rotate") || name.hasPrefix("skew")
            for (k, tok) in args.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).enumerated() {
                if isAngle && k == 0 { if let a = angle(String(tok)) { v.append(a) } else { bad = true } }
                else if let l = length(String(tok)), l.unit == .user { v.append(l.value) }
                else { bad = true }
            }
            if bad { break }
            var t: CGAffineTransform
            switch name {
            case "matrix":
                guard v.count == 6 else { return any ? result : nil }
                t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case "translate":
                guard v.count == 1 || v.count == 2 else { return any ? result : nil }
                t = CGAffineTransform(translationX: v[0], y: v.count > 1 ? v[1] : 0)
            case "translateX": guard v.count == 1 else { return any ? result : nil }; t = CGAffineTransform(translationX: v[0], y: 0)
            case "translateY": guard v.count == 1 else { return any ? result : nil }; t = CGAffineTransform(translationX: 0, y: v[0])
            case "scale":
                guard v.count == 1 || v.count == 2 else { return any ? result : nil }
                t = CGAffineTransform(scaleX: v[0], y: v.count > 1 ? v[1] : v[0])
            case "scaleX": guard v.count == 1 else { return any ? result : nil }; t = CGAffineTransform(scaleX: v[0], y: 1)
            case "scaleY": guard v.count == 1 else { return any ? result : nil }; t = CGAffineTransform(scaleX: 1, y: v[0])
            case "rotate":
                guard v.count == 1 || v.count == 3 else { return any ? result : nil }
                let r = CGAffineTransform(rotationAngle: CGFloat(v[0] * .pi / 180))
                t = v.count == 3 ? CGAffineTransform(translationX: -v[1], y: -v[2]).concatenating(r).concatenating(CGAffineTransform(translationX: v[1], y: v[2])) : r
            case "skewX":
                guard v.count == 1 else { return any ? result : nil }
                t = CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(clamp(v[0], -89.9, 89.9) * .pi / 180)), d: 1, tx: 0, ty: 0)
            case "skewY":
                guard v.count == 1 else { return any ? result : nil }
                t = CGAffineTransform(a: 1, b: CGFloat(tan(clamp(v[0], -89.9, 89.9) * .pi / 180)), c: 0, d: 1, tx: 0, ty: 0)
            default:
                return any ? result : nil
            }
            result = t.concatenating(result)
            any = true
        }
        guard any, result.isFinite else { return nil }
        return result
    }

    // MARK: Path data

    /// Parses path data; on a syntax error everything up to the last complete command is kept (as the SVG spec asks).
    static func path(_ d: String?) -> CGPath {
        let p = CGMutablePath()
        guard let d, !d.isEmpty else { return p }
        var sc = SVGImportScanner(d)
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCubic: CGPoint? = nil, lastQuad: CGPoint? = nil
        var cmd: UInt8 = 0
        var open = false
        var segments = 0
        func pt(_ x: Double, _ y: Double, _ rel: Bool) -> CGPoint { rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y) }
        sc.skipSpace()
        guard let first = sc.peek, first == 0x4D || first == 0x6D else { return p }
        while !sc.atEnd, segments < 2_000_000 {
            sc.skipSeparator()
            guard let c = sc.peek else { break }
            let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
            if isLetter {
                // 'e' can only start a number's exponent, never a command
                cmd = c
                sc.i += 1
                if cmd == 0x5A || cmd == 0x7A {
                    if open { p.closeSubpath() }
                    cur = start; open = false; lastCubic = nil; lastQuad = nil
                    continue
                }
            } else if cmd == 0 || cmd == 0x5A || cmd == 0x7A {
                break
            }
            let rel = cmd >= 0x61
            func ensureOpen() { if !open { p.move(to: cur); start = cur; open = true } }
            switch cmd {
            case 0x4D, 0x6D:    // M m
                guard let x = sc.separatedNumber(), let y = sc.separatedNumber() else { return p }
                cur = pt(x, y, rel); start = cur
                p.move(to: cur); open = true
                cmd = rel ? 0x6C : 0x4C     // further pairs are line-tos
                lastCubic = nil; lastQuad = nil
            case 0x4C, 0x6C:    // L l
                guard let x = sc.separatedNumber(), let y = sc.separatedNumber() else { return p }
                ensureOpen(); cur = pt(x, y, rel); p.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case 0x48, 0x68:    // H h
                guard let x = sc.separatedNumber() else { return p }
                ensureOpen(); cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); p.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case 0x56, 0x76:    // V v
                guard let y = sc.separatedNumber() else { return p }
                ensureOpen(); cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); p.addLine(to: cur); lastCubic = nil; lastQuad = nil
            case 0x43, 0x63:    // C c
                guard let x1 = sc.separatedNumber(), let y1 = sc.separatedNumber(), let x2 = sc.separatedNumber(), let y2 = sc.separatedNumber(),
                      let x = sc.separatedNumber(), let y = sc.separatedNumber() else { return p }
                ensureOpen()
                let c1 = pt(x1, y1, rel), c2 = pt(x2, y2, rel), e = pt(x, y, rel)
                p.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCubic = c2; lastQuad = nil
            case 0x53, 0x73:    // S s
                guard let x2 = sc.separatedNumber(), let y2 = sc.separatedNumber(), let x = sc.separatedNumber(), let y = sc.separatedNumber() else { return p }
                ensureOpen()
                let c1 = lastCubic.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let c2 = pt(x2, y2, rel), e = pt(x, y, rel)
                p.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCubic = c2; lastQuad = nil
            case 0x51, 0x71:    // Q q
                guard let x1 = sc.separatedNumber(), let y1 = sc.separatedNumber(), let x = sc.separatedNumber(), let y = sc.separatedNumber() else { return p }
                ensureOpen()
                let c1 = pt(x1, y1, rel), e = pt(x, y, rel)
                p.addQuadCurve(to: e, control: c1); cur = e; lastQuad = c1; lastCubic = nil
            case 0x54, 0x74:    // T t
                guard let x = sc.separatedNumber(), let y = sc.separatedNumber() else { return p }
                ensureOpen()
                let c1 = lastQuad.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                let e = pt(x, y, rel)
                p.addQuadCurve(to: e, control: c1); cur = e; lastQuad = c1; lastCubic = nil
            case 0x41, 0x61:    // A a
                guard let rx = sc.separatedNumber(), let ry = sc.separatedNumber(), let rot = sc.separatedNumber(),
                      let large = sc.flag(), let sweep = sc.flag(), let x = sc.separatedNumber(), let y = sc.separatedNumber() else { return p }
                ensureOpen()
                let e = pt(x, y, rel)
                addArc(p, from: cur, to: e, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep)
                cur = e; lastCubic = nil; lastQuad = nil
            default:
                return p
            }
            segments += 1
        }
        return p
    }

    /// A subpath without any extent ("M5 5z", "M5 5h0") still gets its line caps — the usual way to draw dots. Core
    /// Graphics only draws them for an open segment with a direction, so such subpaths become a hair's length along x.
    /// (A lone move-to draws nothing, here as in SVG.)
    static func withDrawableDots(_ path: CGPath) -> CGPath {
        struct Sub { var start = CGPoint.zero; var segments = 0; var closed = false; var flat = true }
        var subs: [Sub] = []
        path.applyWithBlock { ep in
            let e = ep.pointee
            func note(_ n: Int) {
                guard !subs.isEmpty else { return }
                subs[subs.count - 1].segments += 1
                for k in 0..<n where e.points[k] != subs[subs.count - 1].start { subs[subs.count - 1].flat = false }
            }
            switch e.type {
            case .moveToPoint: subs.append(Sub(start: e.points[0]))
            case .addLineToPoint: note(1)
            case .addQuadCurveToPoint: note(2)
            case .addCurveToPoint: note(3)
            case .closeSubpath: if !subs.isEmpty { subs[subs.count - 1].closed = true }
            @unknown default: break
            }
        }
        guard subs.contains(where: { $0.flat && ($0.segments > 0 || $0.closed) }) else { return path }
        let out = CGMutablePath()
        var index = -1
        var skipping = false
        path.applyWithBlock { ep in
            let e = ep.pointee
            if e.type == .moveToPoint {
                index += 1
                let s = subs[index]
                skipping = s.flat && (s.segments > 0 || s.closed)
                out.move(to: s.start)
                if skipping { out.addLine(to: CGPoint(x: s.start.x + 1e-4, y: s.start.y)) }
                return
            }
            if skipping { return }
            switch e.type {
            case .addLineToPoint: out.addLine(to: e.points[0])
            case .addQuadCurveToPoint: out.addQuadCurve(to: e.points[1], control: e.points[0])
            case .addCurveToPoint: out.addCurve(to: e.points[2], control1: e.points[0], control2: e.points[1])
            case .closeSubpath: out.closeSubpath()
            default: break
            }
        }
        return out
    }

    /// Elliptical arc (endpoint parameterization, SVG 1.1 appendix F.6) as cubic Béziers.
    static func addArc(_ p: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rx0: Double, ry ry0: Double, rotation: Double, large: Bool, sweep: Bool) {
        if p0 == p1 { return }
        var rx = abs(rx0), ry = abs(ry0)
        if rx < 1e-12 || ry < 1e-12 { p.addLine(to: p1); return }
        let phi = rotation.truncatingRemainder(dividingBy: 360) * .pi / 180
        let cosP = cos(phi), sinP = sin(phi)
        let dx = Double(p0.x - p1.x) / 2, dy = Double(p0.y - p1.y) / 2
        let x1 = cosP * dx + sinP * dy, y1 = -sinP * dx + cosP * dy
        let lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lam > 1 { let s = sqrt(lam); rx *= s; ry *= s }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den > 0 ? sqrt(max(0, num / den)) : 0
        if large == sweep { coef = -coef }
        let cxp = coef * rx * y1 / ry, cyp = -coef * ry * x1 / rx
        let cx = cosP * cxp - sinP * cyp + Double(p0.x + p1.x) / 2
        let cy = sinP * cxp + cosP * cyp + Double(p0.y + p1.y) / 2
        func ang(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let d = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            guard d > 0 else { return 0 }
            let a = acos(max(-1, min(1, (ux * vx + uy * vy) / d)))
            return ux * vy - uy * vx < 0 ? -a : a
        }
        let ux = (x1 - cxp) / rx, uy = (y1 - cyp) / ry
        let vx = (-x1 - cxp) / rx, vy = (-y1 - cyp) / ry
        let theta = ang(1, 0, ux, uy)
        var delta = ang(ux, uy, vx, vy)
        if !sweep && delta > 0 { delta -= 2 * .pi } else if sweep && delta < 0 { delta += 2 * .pi }
        guard theta.isFinite, delta.isFinite, cx.isFinite, cy.isFinite else { p.addLine(to: p1); return }
        let n = max(1, Int(ceil(abs(delta) / (.pi / 2) - 1e-9)))
        let step = delta / Double(n)
        let k = 4.0 / 3.0 * tan(step / 4)
        var a = theta
        func point(_ t: Double) -> (Double, Double, Double, Double) {
            let ct = cos(t), st = sin(t)
            // position and derivative on the rotated ellipse
            return (cx + rx * ct * cosP - ry * st * sinP, cy + rx * ct * sinP + ry * st * cosP,
                    -rx * st * cosP - ry * ct * sinP, -rx * st * sinP + ry * ct * cosP)
        }
        var (px, py, dx0, dy0) = point(a)
        for i in 0..<n {
            let b = a + step
            let (qx, qy, dx1, dy1) = point(b)
            // the last segment lands exactly on the given end point (no drift between commands)
            let end = i == n - 1 ? p1 : CGPoint(x: qx, y: qy)
            p.addCurve(to: end, control1: CGPoint(x: px + k * dx0, y: py + k * dy0), control2: CGPoint(x: qx - k * dx1, y: qy - k * dy1))
            a = b; px = qx; py = qy; dx0 = dx1; dy0 = dy1
        }
    }

    /// Flattened length of a path (dash arrays with `pathLength`, text on a path).
    static func length(of path: CGPath) -> Double {
        var total = 0.0
        var cur = CGPoint.zero, start = CGPoint.zero
        func cubic(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) {
            var prev = a
            let n = 24
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n), u = 1 - t
                let x = u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c.x + t * t * t * d.x
                let y = u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c.y + t * t * t * d.y
                total += Double(hypot(x - prev.x, y - prev.y)); prev = CGPoint(x: x, y: y)
            }
        }
        path.applyWithBlock { ep in
            let e = ep.pointee
            switch e.type {
            case .moveToPoint: cur = e.points[0]; start = cur
            case .addLineToPoint: total += Double(cur.distance(to: e.points[0])); cur = e.points[0]
            case .addQuadCurveToPoint:
                let c = e.points[0], q = e.points[1]
                cubic(cur, cur + (c - cur) * (2.0 / 3.0), q + (c - q) * (2.0 / 3.0), q); cur = q
            case .addCurveToPoint: cubic(cur, e.points[0], e.points[1], e.points[2]); cur = e.points[2]
            case .closeSubpath: total += Double(cur.distance(to: start)); cur = start
            @unknown default: break
            }
        }
        return total
    }
}

extension CGRect {
    func equalTo(_ o: CGRect, tolerance t: CGFloat) -> Bool {
        abs(minX - o.minX) <= t && abs(minY - o.minY) <= t && abs(maxX - o.maxX) <= t && abs(maxY - o.maxY) <= t
    }
}

extension CGAffineTransform {
    var isFinite: Bool { a.isFinite && b.isFinite && c.isFinite && d.isFinite && tx.isFinite && ty.isFinite }
    var determinant: CGFloat { a * d - b * c }
    /// Uniform scale + rotation / reflection (angles are preserved), within a relative tolerance.
    var isSimilarity: Bool {
        let lu = hypot(a, b), lv = hypot(c, d)
        guard lu > 1e-12, lv > 1e-12 else { return false }
        return abs(lu - lv) <= 1e-4 * max(lu, lv) && abs(a * c + b * d) <= 1e-4 * lu * lv
    }
    /// Mean linear scale factor (√|det|).
    var meanScale: CGFloat { abs(determinant).squareRoot() }
    /// No rotation or skew.
    var isAxisAligned: Bool { abs(b) <= 1e-9 * max(1, abs(a)) && abs(c) <= 1e-9 * max(1, abs(d)) }
}
