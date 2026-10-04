import AppKit
import ImageCratCore

// SVG import, part 3: computed style (the inherited properties) and font matching.

indirect enum SVGImportPaint: Equatable {
    case none
    case color(RGBA)
    case currentColor
    /// `url(#id)` with an optional fallback paint.
    case server(String, SVGImportPaint?)

    /// nil = not a valid paint (the declaration is ignored, as in CSS).
    static func parse(_ raw: String) -> SVGImportPaint? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = s.lowercased()
        if l == "none" || l == "context-fill" || l == "context-stroke" { return SVGImportPaint.none }
        if l == "currentcolor" { return .currentColor }
        if l.hasPrefix("url(") {
            guard let close = s.firstIndex(of: ")") else { return nil }
            var ref = String(s[s.index(s.startIndex, offsetBy: 4)..<close]).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            guard ref.hasPrefix("#") else { return SVGImportPaint.none }      // external documents are never loaded
            ref.removeFirst()
            let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return .server(ref.removingPercentEncoding ?? ref, rest.isEmpty ? nil : parse(rest))
        }
        if let c = SVGImportValue.color(s) { return .color(c) }
        return nil
    }
}

/// Inherited properties, resolved top-down while the element tree is walked (referenced content of `<use>` inherits
/// from the `<use>`, which is why this is not stored on the nodes).
struct SVGImportStyle {
    var fill: SVGImportPaint = .color(.black)
    var fillOpacity = 1.0
    var evenOdd = false
    var stroke: SVGImportPaint = .none
    var strokeOpacity = 1.0
    var strokeWidth = 1.0
    var cap: LineCapStyle = .butt
    var join: LineJoinStyle = .miter
    var miterLimit = 4.0
    var dash: [Double] = []
    var dashOffset = 0.0
    var color = RGBA.black
    var visible = true
    var clipEvenOdd = false
    var strokeFirst = false
    var markerStart: String? = nil, markerMid: String? = nil, markerEnd: String? = nil
    // text
    var fontFamilies: [String] = []
    var fontSize = 16.0
    var fontWeight = 400
    var italic = false
    var anchor = 0                  // 0 start, 1 middle, 2 end
    var letterSpacing = 0.0
    var wordSpacing = 0.0
    var underline = false
    var strike = false
    var preserveSpace = false
    var vertical = false
    var rtl = false
    var upper = false
    var smallCaps = false
    var baseline = "auto"
    /// Custom properties (`--name`), for `var()`.
    var vars: [String: String] = [:]

    /// `var(--x, fallback)` substitution (one level of nesting is enough in practice).
    func substitute(_ value: String) -> String {
        guard value.contains("var(") else { return value }
        var out = value
        var guardCount = 0
        while let r = out.range(of: "var("), guardCount < 8 {
            guardCount += 1
            var depth = 1
            var i = r.upperBound
            while i < out.endIndex, depth > 0 {
                if out[i] == "(" { depth += 1 } else if out[i] == ")" { depth -= 1 }
                if depth > 0 { i = out.index(after: i) }
            }
            guard i < out.endIndex else { return out }
            let inner = String(out[r.upperBound..<i])
            let parts = SVGImportCSS.splitTopLevel(inner, ",")
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let fallback = parts.count > 1 ? parts[1...].joined(separator: ",").trimmingCharacters(in: .whitespaces) : ""
            out.replaceSubrange(r.lowerBound...i, with: vars[name] ?? fallback)
        }
        return out
    }

    /// Non-inherited property of `n` (with `var()` resolved); nil when unset.
    func own(_ n: SVGImportNode, _ name: String) -> String? {
        guard let v = n.decls[name] else { return nil }
        let s = substitute(v).trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s == "inherit" || s == "initial" || s == "unset" ? nil : s
    }

    /// Applies the element's declarations. `viewport` is the nearest viewport size in user units (percentages).
    mutating func apply(_ n: SVGImportNode, viewport: CGSize) {
        let d = n.decls
        if n.attrs["xml:space"] == "preserve" { preserveSpace = true } else if n.attrs["xml:space"] == "default" { preserveSpace = false }
        guard !d.isEmpty else { return }
        for (k, v) in d where k.hasPrefix("--") { vars[k] = v }
        func val(_ k: String) -> String? {
            guard let raw = d[k] else { return nil }
            let s = substitute(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            // `inherit` keeps the parent's value, which is what an inherited property already has
            return s.isEmpty || s == "inherit" || s == "unset" ? nil : s
        }
        let diag = (Double(viewport.width * viewport.width + viewport.height * viewport.height) / 2).squareRoot()
        // font size first: em units of the other properties refer to it
        if let v = val("font-size") {
            switch v.lowercased() {
            case "xx-small": fontSize = 9
            case "x-small": fontSize = 10
            case "small": fontSize = 13
            case "medium", "initial": fontSize = 16
            case "large": fontSize = 18
            case "x-large": fontSize = 24
            case "xx-large": fontSize = 32
            case "xxx-large": fontSize = 48
            case "smaller": fontSize /= 1.2
            case "larger": fontSize *= 1.2
            default:
                if let l = SVGImportValue.length(v) {
                    let px = l.resolve(percentOf: fontSize, fontSize: fontSize)
                    if px >= 0, px.isFinite { fontSize = min(px, 100_000) }
                }
            }
        }
        func len(_ k: String, _ ref: Double) -> Double? {
            guard let v = val(k), let l = SVGImportValue.length(v) else { return nil }
            let r = l.resolve(percentOf: ref, fontSize: fontSize)
            return r.isFinite ? r : nil
        }
        func opacity(_ k: String) -> Double? { val(k).flatMap { SVGImportValue.number($0) }.map { clamp($0, 0, 1) } }
        if let v = val("color"), v.lowercased() != "currentcolor", let c = SVGImportValue.color(v) { color = c }
        if let v = val("fill"), let p = SVGImportPaint.parse(v) { fill = p }
        if let v = val("stroke"), let p = SVGImportPaint.parse(v) { stroke = p }
        if let v = opacity("fill-opacity") { fillOpacity = v }
        if let v = opacity("stroke-opacity") { strokeOpacity = v }
        if let v = val("fill-rule") { evenOdd = v.lowercased() == "evenodd" }
        if let v = val("clip-rule") { clipEvenOdd = v.lowercased() == "evenodd" }
        if let v = len("stroke-width", diag), v >= 0 { strokeWidth = v }
        if let v = val("stroke-linecap") { cap = LineCapStyle(rawValue: v.lowercased()) ?? cap }
        if let v = val("stroke-linejoin") {
            switch v.lowercased() {
            case "miter", "miter-clip", "arcs": join = .miter
            case "round": join = .round
            case "bevel": join = .bevel
            default: break
            }
        }
        if let v = val("stroke-miterlimit").flatMap({ SVGImportValue.number($0) }), v >= 1 { miterLimit = v }
        if let v = val("stroke-dasharray") {
            if v.lowercased() == "none" { dash = [] }
            else {
                let ls = SVGImportValue.lengths(v).map { $0.resolve(percentOf: diag, fontSize: fontSize) }
                // a negative value makes the whole list invalid; all zeros means a solid line
                dash = ls.contains { $0 < 0 || !$0.isFinite } || !ls.contains { $0 > 0 } ? [] : Array(ls.prefix(64))
            }
        }
        if let v = len("stroke-dashoffset", diag) { dashOffset = v }
        if let v = val("visibility") { visible = v.lowercased() == "visible" }
        if let v = val("paint-order") {
            let order = v.lowercased().split(separator: " ").map(String.init)
            let fi = order.firstIndex(of: "fill"), si = order.firstIndex(of: "stroke")
            strokeFirst = si != nil && (fi == nil || si! < fi!)
        }
        func marker(_ k: String, _ cur: String?) -> String? {
            guard let v = val(k) else { return cur }
            if v.lowercased() == "none" { return nil }
            if case .server(let id, _)? = SVGImportPaint.parse(v) { return id }
            return cur
        }
        markerStart = marker("marker-start", markerStart); markerMid = marker("marker-mid", markerMid); markerEnd = marker("marker-end", markerEnd)
        // text
        if let v = val("font-family") {
            let list = SVGImportCSS.splitTopLevel(v, ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\t\n")) }.filter { !$0.isEmpty }
            if !list.isEmpty { fontFamilies = list }
        }
        if let v = val("font-weight") {
            switch v.lowercased() {
            case "normal": fontWeight = 400
            case "bold": fontWeight = 700
            case "bolder": fontWeight = fontWeight < 350 ? 400 : (fontWeight < 550 ? 700 : 900)
            case "lighter": fontWeight = fontWeight < 550 ? 100 : (fontWeight < 750 ? 400 : 700)
            default: if let w = SVGImportValue.number(v), w >= 1, w <= 1000 { fontWeight = Int(w) }
            }
        }
        if let v = val("font-style") { italic = v.lowercased().hasPrefix("italic") || v.lowercased().hasPrefix("oblique") }
        if let v = val("font-variant") { smallCaps = v.lowercased().contains("small-caps") }
        if let v = val("text-anchor") { anchor = v.lowercased() == "middle" ? 1 : (v.lowercased() == "end" ? 2 : 0) }
        if let v = val("letter-spacing") { letterSpacing = v.lowercased() == "normal" ? 0 : (len("letter-spacing", fontSize) ?? letterSpacing) }
        if let v = val("word-spacing") { wordSpacing = v.lowercased() == "normal" ? 0 : (len("word-spacing", fontSize) ?? wordSpacing) }
        if let v = val("text-decoration") {
            // decorations are not inherited but propagate to descendants, which comes to the same thing here
            let l = v.lowercased()
            if l.contains("none") { underline = false; strike = false }
            if l.contains("underline") { underline = true }
            if l.contains("line-through") { strike = true }
        }
        if let v = val("white-space") { preserveSpace = v.lowercased().hasPrefix("pre") || v.lowercased() == "break-spaces" }
        if let v = val("writing-mode") { let l = v.lowercased(); vertical = l.hasPrefix("tb") || l.hasPrefix("vertical") }
        if let v = val("direction") { rtl = v.lowercased() == "rtl" }
        if let v = val("text-transform") { upper = v.lowercased() == "uppercase" }
        if let v = val("dominant-baseline") ?? val("alignment-baseline") { baseline = v.lowercased() }
    }
}

// MARK: - Fonts

struct SVGImportFontMatch {
    var postScriptName: String
    /// The family that was asked for first (for the report when it is missing).
    var requested: String
    /// False when none of the listed families is installed and a default face was substituted.
    var found: Bool
    var fauxBold = false
    var fauxItalic = false
}

enum SVGImportFonts {
    private static let lock = NSLock()
    private static var cache: [String: SVGImportFontMatch] = [:]

    /// Generic CSS families as WebKit resolves them on macOS.
    private static let generic: [String: String] = [
        "sans-serif": "Helvetica", "serif": "Times", "monospace": "Courier", "cursive": "Apple Chancery", "fantasy": "Papyrus",
        "system-ui": ".AppleSystemUIFont", "-apple-system": ".AppleSystemUIFont", "blinkmacsystemfont": ".AppleSystemUIFont", "ui-sans-serif": ".AppleSystemUIFont",
        "ui-monospace": "Menlo", "ui-serif": "New York", "ui-rounded": ".AppleSystemUIFont",
    ]

    /// AppKit font-manager weight (5 = regular, 9 = bold) for a CSS weight.
    private static func appKitWeight(_ css: Int) -> Int {
        switch css {
        case ..<150: return 2
        case ..<250: return 3
        case ..<350: return 4
        case ..<450: return 5
        case ..<550: return 6
        case ..<650: return 8
        case ..<750: return 9
        case ..<850: return 10
        default: return 12
        }
    }

    static func resolve(_ list: [String], weight: Int, italic: Bool) -> SVGImportFontMatch {
        let key = list.joined(separator: "\u{1}") + "|\(weight)|\(italic)"
        lock.lock(); defer { lock.unlock() }
        if let c = cache[key] { return c }
        var m = match(list, weight: weight, italic: italic)
        if m == nil {
            // no listed family is installed: the browser's standard font
            m = member(of: "Times", weight: weight, italic: italic, requested: list.first ?? "Times")
            m?.found = list.isEmpty
        }
        let out = m ?? SVGImportFontMatch(postScriptName: "Times-Roman", requested: list.first ?? "Times", found: list.isEmpty)
        if cache.count > 512 { cache.removeAll() }
        cache[key] = out
        return out
    }

    private static func match(_ list: [String], weight: Int, italic: Bool) -> SVGImportFontMatch? {
        for name in list {
            let l = name.lowercased()
            if let g = generic[l] {
                if g.hasPrefix(".") {
                    // the system font has no family entry: build it from the system descriptor
                    let w: NSFont.Weight = weight >= 650 ? .bold : (weight >= 550 ? .semibold : (weight >= 450 ? .medium : (weight <= 250 ? .thin : (weight <= 350 ? .light : .regular))))
                    var f = NSFont.systemFont(ofSize: 12, weight: w)
                    if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
                    return SVGImportFontMatch(postScriptName: f.fontName, requested: name, found: true)
                }
                if let m = member(of: g, weight: weight, italic: italic, requested: name) { return m }
                continue
            }
            // (the font manager's family list leaves out Courier, Times and other legacy families; asking for the members
            // finds them, whatever the case)
            if let m = member(of: name, weight: weight, italic: italic, requested: name) { return m }
            // a PostScript or full name used as the family ("Helvetica-Bold", "Arial Bold")
            if let f = NSFont(name: name, size: 12) {
                if let fam = f.familyName, weight != 400 || italic,
                   let m = member(of: fam, weight: max(weight, NSFontManager.shared.traits(of: f).contains(.boldFontMask) ? 700 : 0),
                                  italic: italic || NSFontManager.shared.traits(of: f).contains(.italicFontMask), requested: name) { return m }
                return SVGImportFontMatch(postScriptName: f.fontName, requested: name, found: true)
            }
        }
        return nil
    }

    private static func member(of family: String, weight: Int, italic: Bool, requested: String) -> SVGImportFontMatch? {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family), !members.isEmpty else { return nil }
        let want = appKitWeight(weight)
        var best: (name: String, score: Int, weight: Int, italic: Bool)? = nil
        for m in members {
            guard m.count >= 4, let ps = m[0] as? String, let w = m[2] as? Int, let traits = m[3] as? UInt else { continue }
            let t = NSFontTraitMask(rawValue: traits)
            let isItalic = t.contains(.italicFontMask)
            // condensed / expanded faces only when nothing else fits
            var score = abs(w - want) * 10 + (isItalic == italic ? 0 : 35)
            if t.contains(.condensedFontMask) || t.contains(.expandedFontMask) || t.contains(.narrowFontMask) { score += 60 }
            // heavier request prefers the next heavier face, lighter the next lighter (CSS font matching)
            if want >= 6 && w < want { score += 4 } else if want <= 5 && w > want { score += 4 }
            if best == nil || score < best!.score { best = (ps, score, w, isItalic) }
        }
        guard let b = best else { return nil }
        var m = SVGImportFontMatch(postScriptName: b.name, requested: requested, found: true)
        // synthesized styles, as the browser does when the family has no such face
        if weight >= 600 && b.weight <= 6 { m.fauxBold = true }
        if italic && !b.italic { m.fauxItalic = true }
        return m
    }
}
