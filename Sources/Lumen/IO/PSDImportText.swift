import AppKit
import CoreText
import ImageCratCore

// MARK: - EngineData
//
// Type layers ('TySh') carry their styling in "EngineData": a PostScript-like property list
//   << /Key value … >>  dictionaries,  [ … ] arrays,  ( … ) strings (UTF-16BE with a BOM, `\` escapes),
//   /Name tokens, numbers (".8" is valid) and true / false.

indirect enum PSDEngineValue {
    case dict([String: PSDEngineValue])
    case array([PSDEngineValue])
    case number(Double)
    case bool(Bool)
    case string(String)
    case name(String)

    subscript(key: String) -> PSDEngineValue? { if case .dict(let d) = self { return d[key] }; return nil }
    subscript(i: Int) -> PSDEngineValue? { if case .array(let a) = self, i >= 0, i < a.count { return a[i] }; return nil }
    var array: [PSDEngineValue] { if case .array(let a) = self { return a }; return [] }
    var double: Double? { if case .number(let n) = self, n.isFinite { return n }; return nil }
    var int: Int? { double.flatMap { abs($0) < 1e9 ? Int($0) : nil } }
    var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        default: return nil
        }
    }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var doubles: [Double] { array.compactMap(\.double) }
}

struct PSDEngineParser {
    let b: [UInt8]
    var p = 0
    var depth = 0
    static let maxDepth = 64

    init(_ bytes: [UInt8]) { b = bytes }

    static func parse(_ bytes: [UInt8]) throws -> PSDEngineValue {
        var s = PSDEngineParser(bytes)
        return try s.value()
    }

    private mutating func skipSpace() { while p < b.count, b[p] == 0x20 || b[p] == 0x09 || b[p] == 0x0A || b[p] == 0x0D || b[p] == 0 { p += 1 } }
    private func isDelimiter(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0 || c == 0x2F || c == 0x3C || c == 0x3E || c == 0x5B || c == 0x5D || c == 0x28 || c == 0x29 }

    mutating func value() throws -> PSDEngineValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= PSDEngineParser.maxDepth else { throw PSDImportError.invalid("engine data nested too deeply") }
        skipSpace()
        guard p < b.count else { throw PSDImportError.truncated }
        let c = b[p]
        if c == 0x3C, p + 1 < b.count, b[p + 1] == 0x3C {   // <<
            p += 2
            var d: [String: PSDEngineValue] = [:]
            while true {
                skipSpace()
                guard p < b.count else { throw PSDImportError.truncated }
                if b[p] == 0x3E, p + 1 < b.count, b[p + 1] == 0x3E { p += 2; break }
                guard b[p] == 0x2F else { throw PSDImportError.invalid("engine data: key expected") }
                let k = token()
                d[k] = try value()
            }
            return .dict(d)
        }
        if c == 0x5B {   // [
            p += 1
            var a: [PSDEngineValue] = []
            while true {
                skipSpace()
                guard p < b.count else { throw PSDImportError.truncated }
                if b[p] == 0x5D { p += 1; break }
                a.append(try value())
            }
            return .array(a)
        }
        if c == 0x28 { return .string(try string()) }
        if c == 0x2F { return .name(token()) }
        let start = p
        while p < b.count, !isDelimiter(b[p]) { p += 1 }
        guard p > start else { throw PSDImportError.invalid("engine data: unexpected byte \(c)") }
        let t = String(decoding: b[start..<p], as: UTF8.self)
        if t == "true" { return .bool(true) }
        if t == "false" { return .bool(false) }
        if let n = Double(t.hasPrefix(".") ? "0" + t : (t.hasPrefix("-.") ? "-0" + t.dropFirst() : t)) { return .number(n) }
        return .name(t)
    }

    /// `/Name` → "Name".
    private mutating func token() -> String {
        p += 1
        let start = p
        while p < b.count, !isDelimiter(b[p]) { p += 1 }
        return String(decoding: b[start..<p], as: UTF8.self)
    }

    private mutating func string() throws -> String {
        p += 1
        var raw: [UInt8] = []
        while true {
            guard p < b.count else { throw PSDImportError.truncated }
            let c = b[p]; p += 1
            if c == 0x29 { break }
            if c == 0x5C {
                guard p < b.count else { throw PSDImportError.truncated }
                raw.append(b[p]); p += 1
            } else {
                raw.append(c)
            }
        }
        if raw.count >= 2, raw[0] == 0xFE, raw[1] == 0xFF {
            var u: [UInt16] = []
            var i = 2
            while i + 1 < raw.count { u.append(UInt16(raw[i]) << 8 | UInt16(raw[i + 1])); i += 2 }
            return String(decoding: u, as: UTF16.self)
        }
        return String(String.UnicodeScalarView(raw.map { Unicode.Scalar($0) }))
    }
}

// MARK: - Fonts

/// Maps the PostScript names stored in a PSD to fonts installed on this Mac.
enum PSDFontMatcher {
    private static var cache: [String: (String, Bool)] = [:]
    private static let lock = NSLock()
    /// Font manager queries are serialized: embedded documents are read on several threads.
    static let managerLock = NSLock()

    /// Installed font name for a PostScript name, and whether it is a substitute.
    static func resolve(_ ps: String) -> (name: String, substituted: Bool) {
        lock.lock()
        if let c = cache[ps] { lock.unlock(); return c }
        lock.unlock()
        managerLock.lock()
        let r = lookup(ps)
        managerLock.unlock()
        lock.lock(); cache[ps] = r; lock.unlock()
        return r
    }

    private static func installed(_ name: String) -> Bool { FontLookup.installed(name) }

    /// NSFontManager weight (0…15) a style name asks for.
    static func weight(_ style: String) -> Int {
        let s = style.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let table: [(String, Int)] = [("hairline", 1), ("extralight", 3), ("ultralight", 3), ("thin", 2), ("semilight", 4), ("light", 4),
                                      ("semibold", 8), ("demibold", 8), ("demi", 8), ("extrabold", 10), ("ultrabold", 10), ("heavy", 11),
                                      ("black", 12), ("ultra", 12), ("bold", 9), ("medium", 6), ("book", 5), ("regular", 5)]
        return table.first { s.contains($0.0) }?.1 ?? 5
    }

    private static func lookup(_ ps: String) -> (String, Bool) {
        if installed(ps) { return (ps, false) }
        let parts = ps.split(separator: "-", maxSplits: 1).map(String.init)
        let rawFamily = parts.first ?? ps
        let rawStyle = parts.count > 1 ? parts[1] : ""
        let style = rawStyle.lowercased()
        let whole = ps.lowercased()
        let italic = style.contains("italic") || style.contains("oblique") || style.hasSuffix("it") || style == "i" || whole.hasSuffix("italic")
        let wantWeight = style.isEmpty && whole.hasSuffix("bold") ? 9 : weight(style)
        let fm = NSFontManager.shared
        func norm(_ x: String) -> String { x.lowercased().filter { $0.isLetter || $0.isNumber } }

        /// The family member with the same style name ("Medium", "SemiBold Italic"…), else the nearest weight with the
        /// right slant (families such as Oswald name their faces "Oswald-Regular_Medium", so PostScript names do not match).
        func member(_ family: String) -> String? { memberExact(family)?.0 }
        func memberExact(_ family: String) -> (String, Bool)? {
            guard let members = fm.availableMembers(ofFontFamily: family), !members.isEmpty else { return nil }
            let want = norm(rawStyle.isEmpty ? "Regular" : rawStyle)
            if let m = members.first(where: { norm(($0.count > 1 ? $0[1] as? String : nil) ?? "") == want }), let n = m.first as? String { return (n, true) }
            func score(_ m: [Any]) -> Int {
                let w = (m.count > 2 ? (m[2] as? NSNumber)?.intValue : nil) ?? 5
                let t = NSFontTraitMask(rawValue: UInt((m.count > 3 ? (m[3] as? NSNumber)?.uintValue : nil) ?? 0))
                return abs(w - wantWeight) + (t.contains(.italicFontMask) == italic ? 0 : 20) + (t.contains(.condensedFontMask) || t.contains(.expandedFontMask) ? 3 : 0)
            }
            return (members.min { score($0) < score($1) }?.first as? String).map { ($0, false) }
        }

        // "MyriadPro" → "Myriad Pro": the same family under a spaced name, or without foundry suffixes
        var spaced = ""
        for (i, ch) in rawFamily.enumerated() {
            if i > 0, ch.isUppercase, let prev = spaced.last, prev.isLowercase || prev.isNumber { spaced.append(" ") }
            spaced.append(ch)
        }
        var candidates = [rawFamily, spaced]
        for suffix in [" MT", "MT", " PS", "PS", " Std", "Std", " Pro", "Pro", " LT"] {
            for c in [rawFamily, spaced] where c.hasSuffix(suffix) { candidates.append(String(c.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)) }
        }
        // the same family and style under another PostScript name is the font itself, not a substitute
        for (i, c) in candidates.enumerated() where !c.isEmpty { if let m = memberExact(c) { return (m.0, !(m.1 && i < 2)) } }

        let key = rawFamily.lowercased()
        let table: [(String, String)] = [
            ("myriad", "Helvetica Neue"), ("minion", "Times New Roman"), ("garamond", "Garamond"), ("arial", "Arial"), ("helvetica", "Helvetica Neue"),
            ("times", "Times New Roman"), ("courier", "Courier New"), ("georgia", "Georgia"), ("verdana", "Verdana"), ("tahoma", "Tahoma"),
            ("trebuchet", "Trebuchet MS"), ("segoe", "Helvetica Neue"), ("roboto", "Helvetica Neue"), ("opensans", "Helvetica Neue"),
            ("sourcesans", "Helvetica Neue"), ("sourcecode", "Menlo"), ("sourceserif", "Georgia"), ("calibri", "Helvetica Neue"), ("cambria", "Georgia"),
            ("futura", "Futura"), ("gill", "Gill Sans"), ("optima", "Optima"), ("palatino", "Palatino"), ("baskerville", "Baskerville"),
            ("didot", "Didot"), ("bodoni", "Bodoni 72"), ("caslon", "Big Caslon"), ("rockwell", "Rockwell"), ("impact", "Impact"),
            ("kozuka", "Hiragino Sans"), ("kozgo", "Hiragino Sans"), ("kozmin", "Hiragino Mincho ProN"),
        ]
        for (k, fam) in table where key.contains(k) { if let m = member(fam) { return (m, true) } }
        let serif = ["serif", "roman", "book", "antiqua", "century", "schoolbook"].contains { key.contains($0) } && !key.contains("sans")
        let mono = ["mono", "code", "consol", "typewriter"].contains { key.contains($0) }
        for fam in [mono ? "Menlo" : (serif ? "Times New Roman" : "Helvetica Neue"), "Helvetica"] { if let m = member(fam) { return (m, true) } }
        return ("Helvetica", true)
    }
}

extension PSDFontMatcher {
    /// Installed faces of about the weight / slant of `base` that are narrower (or wider) than ordinary text faces:
    /// candidates when a missing font's width does not match its substitute.
    static func widthCandidates(like base: String, narrower: Bool) -> [String] {
        managerLock.lock(); defer { managerLock.unlock() }
        let keys = narrower ? ["condensed", "narrow", "compressed", "cond", "impact", "oswald", "bebas", "anton"] : ["extended", "expanded", "wide"]
        let f = NSFont(name: base, size: 12)
        let tr = f.map { NSFontManager.shared.traits(of: $0) } ?? []
        let w = f.map { NSFontManager.shared.weight(of: $0) } ?? 5
        var out: [String] = []
        for n in NSFontManager.shared.availableFonts {
            let l = n.lowercased()
            guard keys.contains(where: { l.contains($0) }), (l.contains("italic") || l.contains("oblique")) == tr.contains(.italicFontMask) else { continue }
            let style = n.split(separator: "-", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            let cw = style.isEmpty ? (l.contains("impact") ? 9 : 5) : weight(style)
            if abs(cw - w) <= 3 { out.append(n) }
            if out.count >= 40 { break }
        }
        return out
    }
}

// MARK: - Type layers

enum PSDText {
    struct Run {
        var length: Int
        var style: CharacterStyle
        var leading: Double?
        var allCaps: Bool
    }

    /// Widest line's ink in document pixels.
    static func inkWidth(_ t: TextContent) -> Double {
        let L = TextRenderer.layout(t)
        var w: CGFloat = 0
        for pl in L.lines where !pl.isMarker { w = max(w, CTLineGetImageBounds(pl.line, nil).width) }
        return Double(w) * t.horizontalScale * Double(hypot(t.transform.a, t.transform.b))
    }

    /// A missing font's substitute should take the room the original did, or the text runs off its layout once it is
    /// edited: when the chosen face is clearly wider / narrower than the stored pixels, a condensed (extended) face of
    /// the same weight that matches better is used instead.
    static func fitSubstitute(_ t: inout TextContent, substitutes: Set<String>, width target: Double, substituted: inout [String: String]) {
        func with(_ font: String) -> TextContent {
            var x = t
            if substitutes.contains(x.fontName) { x.fontName = font }
            for i in x.runs.indices where x.runs[i].style.fontName.map(substitutes.contains) == true { x.runs[i].style.fontName = font }
            return x
        }
        let base = substitutes.contains(t.fontName) ? t.fontName : (t.runs.compactMap(\.style.fontName).first(where: substitutes.contains) ?? t.fontName)
        let w0 = inkWidth(t)
        guard w0 > 1 else { return }
        let e0 = abs(log(w0 / target))
        guard e0 > 0.04 else { return }
        var best = (name: base, err: e0)
        for c in PSDFontMatcher.widthCandidates(like: base, narrower: w0 > target) where c != base {
            let w = inkWidth(with(c))
            guard w > 1 else { continue }
            let e = abs(log(w / target))
            if e < best.err { best = (c, e) }
        }
        guard best.name != base, best.err < e0 * 0.7 else { return }
        t = with(best.name)
        for (k, v) in substituted where substitutes.contains(v) { substituted[k] = best.name }
    }

    static let warpStyles: [String: WarpStyle] = [
        "warpNone": .none, "warpArc": .arc, "warpArcLower": .arcLower, "warpArcUpper": .arcUpper, "warpArch": .arch, "warpBulge": .bulge,
        "warpShellLower": .shellLower, "warpShellUpper": .shellUpper, "warpFlag": .flag, "warpWave": .wave, "warpFish": .fish, "warpRise": .rise,
        "warpFisheye": .fisheye, "warpInflate": .inflate, "warpSqueeze": .squeeze, "warpTwist": .twist,
    ]

    /// 'TySh' → a live text layer. Throws when the block is too damaged to describe the text.
    /// `pixelWidth`: width of the pixels Photoshop stored for the layer (picks the substitute for a missing font).
    static func content(_ c0: PSDCursor, _ imp: PSDImporter, layer: String, pixelWidth: Int? = nil) throws -> TextContent {
        var c = c0
        guard try c.u16() == 1 else { throw PSDImportError.unsupported("type tool version") }
        var m: [Double] = []
        for _ in 0..<6 { m.append(try c.f64()) }
        guard m.allSatisfy({ $0.isFinite && abs($0) < 1e7 }) else { throw PSDImportError.invalid("text transform") }
        _ = try c.u16()   // text version (50)
        var dr = PSDDescriptorReader(c.data(c.pos..<c.end))
        guard try dr.u32() == 16 else { throw PSDImportError.invalid("text descriptor version") }
        let td = try dr.descriptor()
        var wd: PSDDescriptor? = nil
        if (try? dr.skip(2)) != nil, (try? dr.u32()) == 16 { wd = try? dr.descriptor() }   // warp version, descriptor version, warp

        var t = TextContent()
        var notes: [String] = []
        var plain = td.string("Txt ") ?? ""
        // without the engine data nothing is known about fonts and sizes: better the stored pixels than a guess
        guard case .data(_, let ed)? = td["EngineData"], let engine = try? PSDEngineParser.parse([UInt8](ed)), engine["EngineDict"] != nil else {
            throw PSDImportError.invalid("engine data")
        }
        let dict = engine["EngineDict"]
        let res = engine["ResourceDict"] ?? engine["DocumentResources"]
        if let s = dict?["Editor"]?["Text"]?.string { plain = s }
        // Photoshop ends the text with a paragraph mark that is not part of what the user typed
        var units = Array(plain.utf16)
        if units.last == 13 || units.last == 10 { units.removeLast() }
        units = units.map { $0 == 13 ? 10 : ($0 == 3 ? 0x2028 : $0) }
        t.text = String(decoding: units, as: UTF16.self)

        // Sizes are stored in text space; the transform's scale turns them into pixels. Fold that scale into the
        // values so the panel shows real sizes, and keep rotation / skew in the layer transform.
        var s = (m[2] * m[2] + m[3] * m[3]).squareRoot()
        if !(s.isFinite && s > 1e-6) { s = 1 }
        t.transform = CGAffineTransform(a: CGFloat(m[0] / s), b: CGFloat(m[1] / s), c: CGFloat(m[2] / s), d: CGFloat(m[3] / s), tx: CGFloat(m[4]), ty: CGFloat(m[5]))

        // Character styles
        let fonts = (res?["FontSet"]?.array ?? []).map { $0["Name"]?.string ?? "" }
        let normalSheet = res?["StyleSheetSet"]?[res?["TheNormalStyleSheet"]?.int ?? 0]?["StyleSheetData"]
        let superSize = res?["SuperscriptSize"]?.double ?? 0.583, superPos = res?["SuperscriptPosition"]?.double ?? 0.333
        let subSize = res?["SubscriptSize"]?.double ?? 0.583, subPos = res?["SubscriptPosition"]?.double ?? 0.333
        var substituted: [String: String] = [:]
        var stroked = false

        func run(_ sheet: PSDEngineValue?) -> Run {
            func v(_ k: String) -> PSDEngineValue? { sheet?[k] ?? normalSheet?[k] }
            var cs = CharacterStyle()
            let ps = fonts.indices.contains(v("Font")?.int ?? 0) ? fonts[v("Font")?.int ?? 0] : ""
            if ps.isEmpty { cs.fontName = "Helvetica" } else {
                let f = PSDFontMatcher.resolve(ps)
                cs.fontName = f.name
                if f.substituted { substituted[ps] = f.name }
            }
            var size = clamp((v("FontSize")?.double ?? 12) * s, 0.1, 20000)
            var shift = (v("BaselineShift")?.double ?? 0) * s
            switch v("FontBaseline")?.int ?? 0 {
            case 1: shift += size * superPos; size *= superSize
            case 2: shift -= size * subPos; size *= subSize
            default: break
            }
            cs.fontSize = size
            cs.baselineShift = clamp(shift, -20000, 20000)
            let col = v("FillColor")?["Values"]?.doubles ?? []
            if col.count >= 4 { cs.color = RGBA(r: clamp(col[1], 0, 1), g: clamp(col[2], 0, 1), b: clamp(col[3], 0, 1), a: clamp(col[0], 0, 1)) } else { cs.color = .black }
            if v("FillFlag")?.bool == false { cs.color?.a = 0 }
            if v("StrokeFlag")?.bool == true { stroked = true }
            cs.tracking = clamp(v("Tracking")?.double ?? 0, -1000, 10000)
            cs.fauxBold = v("FauxBold")?.bool ?? false
            cs.fauxItalic = v("FauxItalic")?.bool ?? false
            cs.underline = v("Underline")?.bool ?? false
            cs.strikethrough = v("Strikethrough")?.bool ?? false
            cs.horizontalScale = clamp(v("HorizontalScale")?.double ?? 1, 0.01, 100)
            cs.verticalScale = clamp(v("VerticalScale")?.double ?? 1, 0.01, 100)
            var f = OpenTypeFeatures()
            f.standardLigatures = v("Ligatures")?.bool ?? true
            f.discretionaryLigatures = v("DLigatures")?.bool ?? false
            let caps = v("FontCaps")?.int ?? 0
            f.smallCaps = caps == 1
            cs.features = f
            let auto = v("AutoLeading")?.bool ?? true
            let lead = (v("Leading")?.double ?? 0) * s
            return Run(length: 0, style: cs, leading: auto || lead <= 0 ? nil : min(lead, 100000), allCaps: caps == 2)
        }

        let total = (t.text as NSString).length
        var runs: [Run] = []
        let styleRun = dict?["StyleRun"]
        let lengths = styleRun?["RunLengthArray"]?.array.compactMap(\.int) ?? []
        for (i, r) in (styleRun?["RunArray"]?.array ?? []).enumerated() where i < lengths.count && runs.count < 4096 {
            var x = run(r["StyleSheet"]?["StyleSheetData"])
            x.length = max(0, lengths[i])
            runs.append(x)
        }
        if runs.isEmpty { var x = run(nil); x.length = total; runs = [x] }
        // Emoji in Apple Color Emoji (Photoshop names the emoji font for emoji typed there, and so does the exporter):
        // Lumen draws emoji through font fallback, so those runs take the font of the text around them.
        var start = 0
        let ns = t.text as NSString
        for i in runs.indices {
            defer { start += runs[i].length }
            guard let f = runs[i].style.fontName, EmojiText.isColorFont(f) else { continue }
            let lo = min(start, ns.length), hi = min(start + runs[i].length, ns.length)
            guard hi > lo, EmojiText.isEmojiOnly(ns.substring(with: NSRange(location: lo, length: hi - lo))) else { continue }
            func plain(_ r: Run) -> Bool { !EmojiText.isColorFont(r.style.fontName ?? "") }
            if let j = runs[..<i].lastIndex(where: plain) ?? runs[(i + 1)...].firstIndex(where: plain) { runs[i].style.fontName = runs[j].style.fontName }
        }

        // Layer defaults = the style that covers the most characters; the others become style runs.
        var weight: [Int: Int] = [:]
        for (i, r) in runs.enumerated() {
            let k = runs.firstIndex { $0.style == r.style } ?? i
            weight[k, default: 0] += max(1, r.length)
        }
        let base = runs[weight.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0]
        t = t.applying(base.style)
        t.leading = base.leading
        t.allCaps = runs.allSatisfy(\.allCaps)
        var loc = 0
        for r in runs {
            let len = min(r.length, max(0, total - loc))
            if len > 0, r.style != base.style { t.runs.append(TextStyleRun(location: loc, length: len, style: r.style)) }
            loc += r.length
        }
        t.normalizeRuns()
        if Set(runs.map { $0.leading ?? -1 }).count > 1 { notes.append("Line spacing differs between runs; the most used value is applied to the whole layer.") }
        if !t.allCaps, runs.contains(where: \.allCaps) { notes.append("All Caps is set on part of the text only; it is not applied.") }
        if stroked { notes.append("The text outline (stroke) is not supported and was dropped.") }

        // Paragraph (Lumen keeps one paragraph style per layer: the first paragraph's)
        let paras = dict?["ParagraphRun"]?["RunArray"]?.array ?? []
        let normalPara = res?["ParagraphSheetSet"]?[res?["TheNormalParagraphSheet"]?.int ?? 0]?["Properties"]
        func pv(_ i: Int, _ k: String) -> PSDEngineValue? { paras.indices.contains(i) ? (paras[i]["ParagraphSheet"]?["Properties"]?[k] ?? normalPara?[k]) : normalPara?[k] }
        let just = pv(0, "Justification")?.int ?? 0
        t.alignment = [0: .left, 1: .right, 2: .center, 3: .justify, 4: .justifyRight, 5: .justifyCenter, 6: .justifyAll][just] ?? .left
        t.firstLineIndent = clamp((pv(0, "FirstLineIndent")?.double ?? 0) * s, -20000, 20000)
        t.leftIndent = clamp((pv(0, "StartIndent")?.double ?? 0) * s, 0, 20000)
        t.rightIndent = clamp((pv(0, "EndIndent")?.double ?? 0) * s, 0, 20000)
        t.spaceBefore = clamp((pv(0, "SpaceBefore")?.double ?? 0) * s, 0, 20000)
        t.spaceAfter = clamp((pv(0, "SpaceAfter")?.double ?? 0) * s, 0, 20000)
        // Lumen's automatic line spacing is always 120 %: another auto-leading factor becomes a fixed value
        if t.leading == nil, let k = pv(0, "AutoLeading")?.double, k > 0.1, k < 20, abs(k - 1.2) > 0.005 {
            t.leading = k * (runs.compactMap { $0.style.fontSize }.max() ?? t.fontSize)
        }
        if paras.count > 1, Set(paras.indices.map { pv($0, "Justification")?.int ?? 0 }).count > 1 {
            notes.append("Paragraphs use different alignments; the first paragraph's is applied to all.")
        }

        t.orientation = td.enumValue("Ornt") == "Vrtc" ? .vertical : .horizontal
        t.antialias = td.enumValue("AntA") != "Anno"

        t.missingFonts = substituted.keys.sorted()
        if let w = pixelWidth, w > 4, !substituted.isEmpty { fitSubstitute(&t, substitutes: Set(substituted.values), width: Double(w), substituted: &substituted) }

        // Point or paragraph (box) text
        let shape = dict?["Rendered"]?["Shapes"]?["Children"]?[0]?["Cookie"]?["Photoshop"]
        let box = shape?["BoxBounds"]?.doubles ?? []
        if shape?["ShapeType"]?.int == 1, box.count == 4, box[2] > box[0], box[3] > box[1], box.allSatisfy({ abs($0) < 1e7 }) {
            t.hyphenate = pv(0, "AutoHyphenate")?.bool ?? false
            t.boxSize = CGSize(width: min(1e6, (box[2] - box[0]) * s / t.horizontalScale), height: min(1e6, (box[3] - box[1]) * s / t.verticalScale))
            t.position = CGPoint(x: box[0] * s, y: box[1] * s)
        } else if t.orientation == .vertical {
            // vertical point text hangs from the top centre of its first column
            t.position = CGPoint(x: t.fontSize * t.horizontalScale / 2, y: 0)
        } else {
            // Point text: Photoshop's origin is on the first baseline — at the start, middle or end of the line
            // according to the alignment. Put Lumen's layout so that point lands on the origin.
            let L = TextRenderer.layout(t)
            if let first = L.lines.first(where: { !$0.isMarker }) {
                let ax = PSDExportText.alignmentX(t, first)   // without the tracking after the last character
                t.position = CGPoint(x: -ax * CGFloat(t.horizontalScale), y: -first.transform.ty * CGFloat(t.verticalScale))
            }
        }

        // Warp Text
        if let wd, let style = wd.enumValue("warpStyle"), style != "warpNone" {
            if let ws = warpStyles[style] {
                let w = TextWarp(style: ws, bend: clamp(wd.double("warpValue") ?? 0, -100, 100), horizontalDistortion: clamp(wd.double("warpPerspective") ?? 0, -100, 100),
                                 verticalDistortion: clamp(wd.double("warpPerspectiveOther") ?? 0, -100, 100))
                if !w.isIdentity { t.warp = w }
                if wd.enumValue("warpRotate") == "Vrtc" { notes.append("The warp is vertical in Photoshop; ImageCrat applies it horizontally.") }
            } else {
                notes.append("Warp style “\(style)” has no equivalent; the text is not warped.")
            }
        }

        var detail = "“\(t.text.prefix(40).replacingOccurrences(of: "\n", with: " "))” — \(t.fontName), \(PSDImportReport.num(t.fontSize)) px"
        if t.boxSize != nil { detail += ", paragraph box" }
        if t.runs.count > 0 { detail += ", \(t.runs.count + 1) styles" }
        if t.warp != nil { detail += ", warped" }
        imp.report.add(.editable, layer: layer, feature: "Type", detail: detail)
        for (ps, sub) in substituted.sorted(by: { $0.key < $1.key }) {
            let shown = pixelWidth != nil ? " The layer shows the pixels Photoshop rendered until its text is edited; then" : ""
            imp.report.add(.substituted, layer: layer, feature: "Font", detail: "“\(ps)” is not installed.\(shown) “\(sub)” is used instead.")
            imp.report.missingFonts.insert(ps)
        }
        for n in notes { imp.report.add(.substituted, layer: layer, feature: "Type", detail: n) }
        return t
    }
}
