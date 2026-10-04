import AppKit
import CoreText
import ImageCratCore

// MARK: - Document text engine data ('Txt2')
//
// Photoshop keeps the text of a document twice: each type layer's 'TySh' (the layer's text, styles and geometry, for
// older readers) and one global 'Txt2' block holding the text engine's own model of every layer — the fonts, style
// sheets, frames, the stories (text, paragraph and character runs) and, per story, the composed lines with their
// glyphs and positions. A file whose type layers have no 'Txt2' is treated like one from an old version: Photoshop
// asks to update the text layers and re-composes them, which moves the text slightly.
//
// The block is written with the numeric-key syntax and the key set of files saved by Photoshop 2026 (the type sample
// re-saved by Photoshop: 08_everything.psd). Story n is the layer whose 'TextIndex' is n; frame n is its text frame.
// The composed lines describe Lumen's own layout (its line breaks, glyphs and caret positions), with Photoshop's line
// metrics: a line reaches (0.5 em + half the cap height) above the baseline (the em box of CJK fonts: the typographic
// ascender) and the font box's descent below it. Static tables (moji-kumi, kinsoku, list styles, document settings,
// default styles) are Photoshop's defaults. Vertical type, type on a path, area type and lists are not composed here:
// a document with such a layer gets no 'Txt2' (Photoshop then composes all its type layers itself, as before).

extension PSDExportText {
    /// One type layer for 'Txt2'.
    struct Story {
        struct Font: Hashable {
            var ps: String
            var type: Int
            var installed: Bool
            /// 2: synthesized bold (faux bold)
            var synthetic = 0
        }

        struct Style {
            var font: Font
            var size: Double
            var fauxBold = false, fauxItalic = false
            var leading: Double? = nil
            var hs = 1.0, vs = 1.0
            var tracking = 0
            var shift = 0.0
            var caps = 0
            var underline = false, strike = false
            var liga = true, dliga = false
            var vertical = false
            var color = RGBA.black
        }

        struct GlyphRun {
            var start = 0                   // first character, relative to the line
            var count = 0
            var x = 0.0                     // origin relative to the line origin
            var shift = 0.0                 // baseline shift (up)
            var style = 0                   // index into `runs`
            var glyphs: [Int] = []
            var positions: [Double] = []    // count + 1, relative to `x`
            var nominal: [Double] = []      // count + 1: advances and tracking without pair kerning
            var width = 0.0
            var whitespace: [(Int, Double)] = []
            var whitespaceEnd = 0.0
            var endsParagraph = false
            var size = 12.0
            var top = 0.0, bottom = 0.0     // the run's own font
        }

        struct Line {
            var start = 0
            var count = 0
            var x = 0.0
            var baseline = 0.0
            var top = 0.0, bottom = 0.0, ascent = 0.0, descent = 0.0              // with baseline shifts (line)
            var runTop = 0.0, runBottom = 0.0, runAscent = 0.0, runDescent = 0.0  // without (glyph runs)
            var advances: [Double] = []     // cumulative nominal advances, unscaled
            var runs: [GlyphRun] = []
            var width: Double { (runs.last.map { $0.x + $0.width } ?? 0) }
        }

        var text: [UInt16] = [13]
        var paragraphs: [Int] = [1]
        var justification = 0
        var firstIndent = 0.0, startIndent = 0.0, endIndent = 0.0, spaceBefore = 0.0, spaceAfter = 0.0
        var hyphenate = false
        var runs: [(Int, Style)] = []
        var box: CGSize? = nil
        /// nil: not composed here (the document then gets no 'Txt2')
        var lines: [Line]? = nil
        /// Photoshop's 'bounds' (line boxes, and the text box of paragraph text) and 'boundingBox' (glyph ink).
        var bounds: CGRect? = nil
        var ink: CGRect? = nil
    }

    // MARK: Fonts

    private static func os2Typo(_ f: CTFont) -> (asc: Double, desc: Double)? {
        guard let d = CTFontCopyTable(f, CTFontTableTag(kCTFontTableOS2), []) as Data?, d.count >= 72 else { return nil }
        func s16(_ o: Int) -> Double { Double(Int16(bitPattern: UInt16(d[d.startIndex + o]) << 8 | UInt16(d[d.startIndex + o + 1]))) }
        let upm = Double(CTFontGetUnitsPerEm(f)), size = Double(CTFontGetSize(f))
        guard upm > 0 else { return nil }
        return (s16(68) / upm * size, abs(s16(70)) / upm * size)
    }

    /// Photoshop's line metrics for `f` (at its size): top above the baseline, bottom below it, typographic ascender
    /// and descender.
    static func lineMetrics(_ f: CTFont) -> (top: Double, bottom: Double, asc: Double, desc: Double) {
        let size = Double(CTFontGetSize(f))
        let typo = os2Typo(f) ?? (Double(CTFontGetAscent(f)), Double(CTFontGetDescent(f)))
        let cjk = CTFontCopyTable(f, CTFontTableTag(kCTFontTableVhea), []) != nil
        let cap = Double(CTFontGetCapHeight(f))
        let top = cjk ? typo.asc : size / 2 + cap / 2
        let bottom = max(0, -Double(CTFontGetBoundingBox(f).minY))
        return (top, bottom, typo.asc, typo.desc)
    }

    /// The font's version string (name ID 5), as Photoshop lists it.
    static func fontVersion(_ ps: String) -> String? {
        guard FontLookup.installed(ps) else { return nil }
        let f = CTFontCreateWithName(ps as CFString, 12, nil)
        return CTFontCopyName(f, kCTFontVersionNameKey) as String?
    }

    // MARK: Story

    /// Tracking after the last visible character of `line` (local px): Photoshop measures a line without it.
    static func trailingTracking(_ t: TextContent, _ line: PlacedLine) -> CGFloat {
        let r = line.textRange
        guard r.location != NSNotFound, r.length > 0 else { return 0 }
        let units = Array(t.text.utf16)
        var i = min(units.count, r.location + r.length) - 1
        while i >= r.location, i < units.count, [9, 10, 13, 32, 0xA0, 0x2028, 0x2029, 0x3000].contains(units[i]) { i -= 1 }
        guard i >= r.location, i < units.count else { return 0 }
        let eff = t.applying(t.style(at: i))
        guard eff.tracking != 0 else { return 0 }
        return CGFloat(eff.tracking / 1000 * eff.fontSize * eff.horizontalScale / max(0.01, t.horizontalScale))
    }

    /// Whether this layer's lines are composed into 'Txt2'.
    static func composable(_ t: TextContent) -> Bool {
        t.pathText == nil && t.orientation != .vertical && t.area == nil && t.list == nil && t.fitToBox == nil
    }

    static func storyStyle(_ eff: TextContent, font: Story.Font, leading: Double?, vertical: Bool) -> Story.Style {
        func fin(_ v: Double, _ d: Double = 0) -> Double { PSDExport.fin(v, d) }
        var s = Story.Style(font: font, size: clamp(fin(eff.fontSize, 12), 0.01, 20000))
        s.fauxBold = eff.fauxBold; s.fauxItalic = eff.fauxItalic; s.leading = leading
        s.hs = clamp(fin(eff.horizontalScale, 1), 0.01, 100); s.vs = clamp(fin(eff.verticalScale, 1), 0.01, 100)
        s.tracking = Int(clamp(fin(eff.tracking), -1000, 10000).rounded())
        s.shift = clamp(fin(eff.baselineShift), -20000, 20000)
        s.caps = eff.allCaps ? 2 : (eff.features.smallCaps ? 1 : 0)
        s.underline = eff.underline; s.strike = eff.strikethrough
        s.liga = eff.features.standardLigatures; s.dliga = eff.features.discretionaryLigatures
        s.vertical = vertical
        s.color = eff.color
        return s
    }

    /// The story of `t` (text with the closing paragraph mark, paragraph and style runs) and, for horizontal point and
    /// paragraph text, its composed lines in text space (origin = the layer's text origin `a`, y down).
    static func story(_ t: TextContent, units: [UInt16], styles: [(Int, Story.Style)], paragraphs: [Int], box: CGSize?, anchor a: CGPoint) -> Story {
        func fin(_ v: Double, _ d: Double = 0) -> Double { PSDExport.fin(v, d) }
        var s = Story()
        s.text = units
        s.paragraphs = paragraphs
        s.runs = styles
        s.box = box
        switch t.alignment {
        case .left: s.justification = 0
        case .right: s.justification = 1
        case .center: s.justification = 2
        case .justify: s.justification = 3
        case .justifyRight: s.justification = 4
        case .justifyCenter: s.justification = 5
        case .justifyAll: s.justification = 6
        }
        s.firstIndent = clamp(fin(t.firstLineIndent), -20000, 20000); s.startIndent = clamp(fin(t.leftIndent), -20000, 20000)
        s.endIndent = clamp(fin(t.rightIndent), -20000, 20000); s.spaceBefore = clamp(fin(t.spaceBefore), -20000, 20000)
        s.spaceAfter = clamp(fin(t.spaceAfter), -20000, 20000)
        s.hyphenate = t.hyphenate
        guard composable(t), units.count < 200_000 else { return s }
        compose(&s, t, anchor: a)
        return s
    }

    private static func compose(_ s: inout Story, _ t: TextContent, anchor a: CGPoint) {
        let L = TextRenderer.layout(t)
        let placed = L.lines.filter { !$0.isMarker && $0.textRange.location != NSNotFound }
        let shown = Array(TextRenderer.attributedString(t).string.utf16)
        let hs = clamp(PSDExport.fin(t.horizontalScale, 1), 0.01, 100), vs = clamp(PSDExport.fin(t.verticalScale, 1), 0.01, 100)
        let total = s.text.count                         // with the closing paragraph mark
        let textLen = total - 1
        let inset: CGFloat = s.box != nil ? 1 : 0        // Lumen's paragraph layout starts 1 px inside the box
        // style run of each character
        var styleOf = [Int](repeating: max(0, s.runs.count - 1), count: total)
        var p = 0
        for (k, r) in s.runs.enumerated() { for i in p..<min(total, p + r.0) { styleOf[i] = k }; p += r.0 }

        func tx(_ localX: CGFloat) -> Double { Double(t.position.x + (localX - inset) * CGFloat(hs) - a.x) }
        func ty(_ localY: CGFloat) -> Double { Double(t.position.y + localY * CGFloat(vs) - a.y) }

        var lines: [Story.Line] = []
        var ink = CGRect.null
        for pl in placed {
            let r = pl.textRange
            guard r.location >= 0, r.location + r.length <= max(textLen, shown.count) else { continue }
            let sr = CTLineGetStringRange(pl.line)
            let ctRuns = CTLineGetGlyphRuns(pl.line) as! [CTRun]
            func ctFont(_ ci: Int) -> CTFont? {
                for run in ctRuns {
                    let rr = CTRunGetStringRange(run)
                    if ci >= rr.location && ci < rr.location + rr.length { return (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String].map { $0 as! CTFont } }
                }
                return nil
            }
            // where each character's glyph is drawn (line space), and where the shown characters end (the tracking
            // after the last one included, a hyphen added by hyphenation left out)
            let shownEnd = sr.location + min(r.length, sr.length)
            var glyphX: [Int: CGFloat] = [:]
            var lineEnd: CGFloat = 0
            for run in ctRuns {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                var idx = [CFIndex](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n), adv = [CGSize](repeating: .zero, count: n)
                CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
                CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
                CTRunGetAdvances(run, CFRange(location: 0, length: n), &adv)
                for q in 0..<n where idx[q] < shownEnd {
                    if glyphX[idx[q]] == nil { glyphX[idx[q]] = pos[q].x }
                    lineEnd = max(lineEnd, pos[q].x + adv[q].width)
                }
            }
            func offset(_ ci: Int) -> CGFloat {
                if ci >= shownEnd { return lineEnd }
                return glyphX[ci] ?? CTLineGetOffsetForStringIndex(pl.line, ci, nil)
            }
            var line = Story.Line()
            line.start = r.location
            // a line that ends the text also holds the closing paragraph mark
            var count = r.length
            let endsWithBreak = textLen > 0 && [3, 10, 13, 0x2028, 0x2029].contains(s.text[textLen - 1])
            if (r.location + r.length == textLen && !endsWithBreak) || (textLen == 0 && r.location == 0) { count = total - r.location }
            line.count = count
            let lineX = pl.transform.tx
            line.baseline = ty(pl.transform.ty)
            var xs: [Double] = [], glyphs: [Int] = [], fonts: [CTFont] = []
            var lastFont = ctFont(sr.location) ?? TextRenderer.makeFont(name: t.fontName, size: CGFloat(max(0.5, t.fontSize)))
            for j in 0..<count {
                let k = r.location + j
                let inLine = j < r.length && k < shown.count && textLen > 0
                let ci = sr.location + j
                let f = (inLine ? ctFont(ci) : nil) ?? lastFont
                lastFont = f
                fonts.append(f)
                xs.append(tx(lineX + offset(inLine ? ci : shownEnd)))
                var u = inLine ? shown[k] : 13
                if [3, 10, 13, 0x2028, 0x2029].contains(u) { u = 32 }
                var ch = [u], g: [CGGlyph] = [0]
                if UTF16.isTrailSurrogate(u) { glyphs.append(0); continue }
                if UTF16.isLeadSurrogate(u), k + 1 < shown.count { ch = [u, shown[k + 1]]; g = [0, 0] }
                _ = CTFontGetGlyphsForCharacters(f, &ch, &g, ch.count)
                glyphs.append(Int(g[0]))
            }
            // end of the last character: the paragraph mark of the text's end has the width of a space
            var endX = tx(lineX + lineEnd)
            if count > r.length || (count > 0 && [3, 10, 13, 0x2028, 0x2029].contains(s.text[r.location + count - 1])) {
                var sp: CGGlyph = 0, ch: UniChar = 32
                _ = CTFontGetGlyphsForCharacters(fonts.last ?? lastFont, &ch, &sp, 1)
                var adv = CGSize.zero
                CTFontGetAdvancesForGlyphs(fonts.last ?? lastFont, .horizontal, &sp, &adv, 1)
                endX = (xs.last ?? endX) + Double(adv.width) * hs
            }
            guard let x0 = xs.first else { continue }
            line.x = x0
            // segments: one glyph run per style run and font
            var segs: [(Int, Int)] = []
            for j in 0..<count {
                let k = r.location + j
                if let last = segs.last, styleOf[min(k, total - 1)] == styleOf[min(r.location + last.0, total - 1)], fonts[j] == fonts[last.0] { segs[segs.count - 1].1 += 1 } else { segs.append((j, 1)) }
            }
            var top = -Double.infinity, bottom = -Double.infinity, asc = -Double.infinity, desc = -Double.infinity
            var ltop = Double.infinity, lbottom = -Double.infinity, lasc = Double.infinity, ldesc = -Double.infinity
            var cum = 0.0
            for (j0, n) in segs {
                let k0 = r.location + j0
                let st = s.runs[styleOf[min(k0, total - 1)]].1
                let f = fonts[j0]
                let m = lineMetrics(f)
                top = max(top, m.top); bottom = max(bottom, m.bottom); asc = max(asc, m.asc); desc = max(desc, m.desc)
                ltop = min(ltop, -m.top - st.shift); lbottom = max(lbottom, m.bottom - st.shift)
                lasc = min(lasc, -m.asc - st.shift); ldesc = max(ldesc, m.desc - st.shift)
                var g = Story.GlyphRun()
                g.start = j0; g.count = n; g.style = styleOf[min(k0, total - 1)]
                g.x = xs[j0] - x0
                g.shift = st.shift
                g.size = st.size
                g.top = -m.top; g.bottom = m.bottom
                g.glyphs = Array(glyphs[j0..<(j0 + n)])
                let runEnd = j0 + n < count ? xs[j0 + n] : endX
                g.positions = (j0..<(j0 + n)).map { xs[$0] - xs[j0] } + [runEnd - xs[j0]]
                // nominal advances: the plain font's advances plus tracking, scaled
                let pf = TextRenderer.makeFont(name: CTFontCopyPostScriptName(f) as String, size: CGFloat(st.size))
                var gl = g.glyphs.map { CGGlyph(clamping: $0) }
                var adv = [CGSize](repeating: .zero, count: gl.count)
                CTFontGetAdvancesForGlyphs(pf, .horizontal, &gl, &adv, gl.count)
                var nominal = [0.0], unscaled: [Double] = []
                for (q, a) in adv.enumerated() {
                    let isMark = j0 + q < count && [3, 10, 13, 0x2028, 0x2029].contains(s.text[min(total - 1, k0 + q)])
                    let w = Double(a.width)
                    unscaled.append(w)
                    nominal.append(nominal.last! + (w + (isMark ? 0 : Double(st.tracking) / 1000 * st.size)) * st.hs)
                }
                g.nominal = nominal
                for w in unscaled { cum += w; line.advances.append(cum) }
                // width: without the closing paragraph mark and the tracking before it
                let lastIsMark = [3, 10, 13, 0x2028, 0x2029].contains(s.text[min(total - 1, k0 + n - 1)])
                g.endsParagraph = lastIsMark && j0 + n == count
                if g.endsParagraph {
                    let trk = n > 1 && st.tracking != 0 ? Double(st.tracking) / 1000 * st.size * st.hs : 0
                    g.width = max(0, g.positions[n - 1] - trk)
                } else {
                    g.width = g.positions[n]
                }
                // whitespace: spaces (114), paragraph marks inside the text (115) and the text's last mark (4)
                for q in 0..<n {
                    let k = k0 + q
                    let u = s.text[min(total - 1, k)]
                    let cls: Int?
                    if [32, 9, 0xA0, 0x3000].contains(u) { cls = 114 } else if [3, 10, 13, 0x2028, 0x2029].contains(u) { cls = k == total - 1 ? 4 : 115 } else { cls = nil }
                    if let c = cls { g.whitespace.append((c, g.positions[q])); g.whitespaceEnd = g.positions[q + 1] }
                }
                // glyph ink, for 'boundingBox'
                var rects = [CGRect](repeating: .zero, count: gl.count)
                CTFontGetBoundingRectsForGlyphs(f, .horizontal, &gl, &rects, gl.count)
                for (q, rc) in rects.enumerated() where !rc.isEmpty && !rc.isNull {
                    let gx = x0 + g.x + g.positions[q]
                    ink = ink.union(CGRect(x: gx + Double(rc.minX) * hs, y: line.baseline - st.shift - Double(rc.maxY), width: Double(rc.width) * hs, height: Double(rc.height)))
                }
                line.runs.append(g)
            }
            line.runTop = -top; line.runBottom = bottom; line.runAscent = -asc; line.runDescent = desc
            line.top = ltop; line.bottom = lbottom; line.ascent = lasc; line.descent = ldesc
            lines.append(line)
        }
        // a text that ends with a line break: the closing paragraph mark sits alone on the next line
        if let lastLine = lines.last, textLen > 0, lastLine.start + lastLine.count == textLen, var ln = lines.last, var g = ln.runs.last {
            let st = s.runs[styleOf[total - 1]].1
            ln.start = textLen; ln.count = 1
            ln.baseline += st.leading ?? st.size * Double(TextRenderer.autoLeadingFactor)
            ln.x = s.box == nil ? 0 : (lines.first?.x ?? 0)
            let adv = (g.positions.last ?? 0) - (g.positions.dropLast().last ?? 0)
            g.start = 0; g.count = 1; g.x = 0; g.style = styleOf[total - 1]; g.shift = st.shift
            g.glyphs = [g.glyphs.last ?? 3]; g.positions = [0, adv]; g.nominal = [0, adv]; g.width = 0
            g.whitespace = [(4, 0)]; g.whitespaceEnd = adv; g.endsParagraph = true
            ln.runs = [g]; ln.advances = [adv]
            lines.append(ln)
        }
        guard !lines.isEmpty, lines.allSatisfy({ ln in ln.runs.allSatisfy { $0.positions.allSatisfy(\.isFinite) } }) else { return }
        s.lines = lines
        var b = CGRect.null
        for ln in lines { b = b.union(CGRect(x: ln.x, y: ln.baseline + ln.top, width: max(0, ln.width), height: ln.bottom - ln.top)) }
        if let box = s.box { b = b.union(CGRect(x: 0, y: 0, width: box.width, height: box.height)) }
        s.bounds = b
        s.ink = ink.isNull ? b : ink
    }
}

enum PSDExportTxt2 {
    typealias Story = PSDExportText.Story

    // MARK: Serialization

    /// Engine-data value in the numeric-key syntax ("<< /0 … /1 … >>"), single spaces as Photoshop writes it.
    indirect enum V {
        case dict([(Int, V)])
        case obj(String, [(Int, V)])     // "<< /99 /Class /k v … >>"
        case array([V])
        case int(Int)
        case num(Double)
        case bool(Bool)
        case str(String)
        case name(String)
        case raw(String)                 // template text: (…) strings are unicode, other text is ASCII

        func emit(_ out: inout [UInt8]) {
            func put(_ s: String) { out += Array(s.utf8) }
            switch self {
            case .dict(let items):
                put("<<")
                for (k, v) in items { put(" /\(k) "); v.emit(&out) }
                put(" >>")
            case .obj(let cls, let items):
                put("<< /99 /\(cls)")
                for (k, v) in items { put(" /\(k) "); v.emit(&out) }
                put(" >>")
            case .array(let a):
                put("[")
                for v in a { put(" "); v.emit(&out) }
                put(" ]")
            case .int(let i): put("\(i)")
            case .num(let d): put(PSDEngineOut.number(d))
            case .bool(let b): put(b ? "true" : "false")
            case .str(let s): out += PSDEngineOut.string(s)
            case .name(let n): put("/" + n)
            case .raw(let s): PSDExportTxt2.template(s, &out)
            }
        }
    }

    /// Writes template text: "(…)" (with `\` escapes) becomes a UTF-16 engine string, the rest is copied.
    static func template(_ s: String, _ out: inout [UInt8]) {
        var it = Array(s.unicodeScalars)[...]
        while let c = it.popFirst() {
            if c == "(" {
                var str = ""
                while let d = it.popFirst(), d != ")" {
                    if d == "\\", let e = it.popFirst() { str.unicodeScalars.append(e) } else { str.unicodeScalars.append(d) }
                }
                out += PSDEngineOut.string(str)
            } else {
                out += Array(String(c).utf8)
            }
        }
    }

    // MARK: Block

    /// The document's 'Txt2' for `stories` (in 'TextIndex' order); nil when a story is not composed here.
    static func block(_ stories: [Story]) -> Data? {
        guard !stories.isEmpty, stories.allSatisfy({ $0.lines != nil }) else { return nil }
        // fonts: in order of use, then the invisible-characters font and the default (Normal style) font
        var fonts: [Story.Font] = []
        func index(_ f: Story.Font) -> Int {
            if let i = fonts.firstIndex(of: f) { return i }
            fonts.append(f); return fonts.count - 1
        }
        for s in stories { for (_, st) in s.runs { _ = index(st.font); if st.fauxBold { var f = st.font; f.synthetic = 2; _ = index(f) } } }
        let invis = index(Story.Font(ps: "AdobeInvisFont", type: 0, installed: false))
        let normal = index(Story.Font(ps: "MyriadPro-Regular", type: 0, installed: FontLookup.installed("MyriadPro-Regular")))
        _ = invis

        let version: V = .dict([(0, .int(7)), (1, .int(11)), (2, .int(0)), (3, .str("Photoshop"))])
        let fontList: V = .dict([(0, .array(fonts.map { f in
            var d: [(Int, V)] = [(0, .str(f.ps)), (2, .int(f.type))]
            if f.synthetic != 0 { d.append((3, .int(f.synthetic))) }
            if f.ps == "MyriadPro-Regular" && !f.installed {
                d.append((5, .str("Version 2.115;PS 2.000;hotconv 1.0.81;makeotf.lib2.5.63406")))   // the copy Photoshop ships
            } else if let v = f.installed ? PSDExportText.fontVersion(f.ps) : nil { d.append((5, .str(v))) }
            return .dict([(0, .obj("CoolTypeFont", [(0, .dict(d))]))])
        }))])
        let frames: V = .dict([(0, .array(stories.map(frame)))])
        let resources: V = .dict([
            (1, fontList), (2, .raw(Templates.section2)), (3, .raw(Templates.mojiKumi)), (4, .raw(Templates.kinsoku)),
            (5, .raw(Templates.normalStyleSheets.replacingOccurrences(of: "/6 << /0 10 /1 12.0", with: "/6 << /0 \(normal) /1 12.0"))),
            (9, .raw(Templates.listStyles)), (6, .raw(Templates.normalParagraphSheets)), (8, frames),
        ])
        // fonts the stories use (not the synthetic and default faces), with their versions
        var used: [Int] = []
        for s in stories { for (_, st) in s.runs { let i = index(st.font); if !used.contains(i) { used.append(i) } } }
        let fontVersions: V = .array([.dict([
            (0, .int(0)), (1, version),
            (2, .raw("0010000001001001111011100011100011101100000010000110000000")), (3, .raw("01110")),
            (4, .array(used.map { i in
                if fonts[i].installed, let v = PSDExportText.fontVersion(fonts[i].ps) { return .dict([(0, .int(i)), (1, .str(v))]) }
                return .dict([(0, .int(i))])
            })),
        ])])
        let objects: V = .dict([
            (4, version), (0, .raw(Templates.documentSettings)), (5, fontVersions),
            (1, .array(stories.enumerated().map { storyValue($0.element, frame: $0.offset, version: version, index: index) })),
            (2, .raw(Templates.defaultCharacterStyle.replacingOccurrences(of: "<< /0 10 /1 12.0", with: "<< /0 \(normal) /1 12.0"))),
            (3, .raw(Templates.defaultParagraphStyle)),
        ])
        var out: [UInt8] = []
        out += Array(" /98 ".utf8); V.dict([(0, .int(14))]).emit(&out)
        out += Array(" /0 ".utf8); resources.emit(&out)
        out += Array(" /1 ".utf8); objects.emit(&out)
        return Data(out)
    }

    static func frame(_ s: Story) -> V {
        guard let b = s.box else {
            return .dict([(0, .dict([(2, .dict([(6, .array([.num(-1), .num(-1)])), (11, .dict([(4, .int(-1)), (18, .num(-1)), (22, .num(0.025))]))]))]))])
        }
        let w = Double(b.width), h = Double(b.height)
        // the box outline as four straight Bézier segments (anchor, control, control, anchor)
        let c = [(0.0, 0.0), (w, 0.0), (w, h), (0.0, h)]
        var pts: [V] = []
        for i in 0..<4 { let p = c[i], q = c[(i + 1) % 4]; pts += [p, p, q, q].flatMap { [V.num($0.0), V.num($0.1)] } }
        return .dict([(0, .dict([
            (1, .dict([(0, .array(pts))])),
            (2, .dict([(0, .int(1)), (6, .array([.num(-2), .num(-2)])), (10, .dict([(0, .int(2)), (1, .num(0))])), (11, .dict([(4, .int(-2)), (18, .num(-2)), (22, .num(0.025))]))])),
        ]))])
    }

    static func paint(_ c: RGBA) -> V {
        .obj("SimplePaint", [(0, .dict([(0, .int(1)), (1, .array([.num(1), .num(clamp(c.r.isFinite ? c.r : 0, 0, 1)), .num(clamp(c.g.isFinite ? c.g : 0, 0, 1)), .num(clamp(c.b.isFinite ? c.b : 0, 0, 1))]))]))])
    }

    static func styleValue(_ st: Story.Style, font: Int) -> V {
        .dict([
            (0, .int(font)), (1, .num(st.size)), (2, .bool(st.fauxBold)), (3, .bool(st.fauxItalic)), (4, .bool(st.leading == nil)), (5, .num(st.leading ?? 0)),
            (6, .num(st.hs)), (7, .num(st.vs)), (8, .int(st.tracking)), (9, .num(st.shift)), (11, .int(1)), (12, .int(st.caps)), (13, .int(0)), (14, .int(0)),
            (15, .int(st.strike ? 1 : 0)), (16, .int(st.underline ? 1 : 0)), (18, .bool(st.liga)), (19, .bool(st.dliga)), (35, .int(st.vertical ? 1 : 2)),
            (36, .num(0)), (37, .int(2)), (38, .int(0)), (52, .bool(false)), (53, paint(st.color)), (54, paint(.black)), (56, .bool(st.color.a > 0.001)),
            (57, .bool(false)), (58, .bool(true)), (63, .num(1)), (68, .int(0)), (69, .int(0)), (70, .int(1)), (71, .int(2)), (92, .num(0)),
        ])
    }

    static func paragraphValue(_ s: Story) -> V {
        .dict([
            (0, .int(s.justification)), (1, .num(s.firstIndent)), (2, .num(s.startIndent)), (3, .num(s.endIndent)), (4, .num(s.spaceBefore)), (5, .num(s.spaceAfter)),
            (7, .num(1.2)), (8, .int(0)), (9, .bool(s.hyphenate)), (10, .int(6)), (11, .int(2)), (12, .int(2)), (13, .int(8)), (14, .num(36)),
            (17, .array([.num(0.8), .num(1), .num(1.33)])), (18, .array([.num(0), .num(0), .num(0)])), (19, .array([.num(1), .num(1), .num(1)])),
            (21, .bool(false)), (23, .bool(true)), (24, .int(0)), (25, .int(0)), (29, .bool(false)),
        ])
    }

    static func storyValue(_ s: Story, frame: Int, version: V, index: (Story.Font) -> Int) -> V {
        let text = String(decoding: s.text, as: UTF16.self)
        let paras: V = .dict([(0, .array(s.paragraphs.map { n in
            .dict([(0, .dict([(0, .dict([(0, .str("")), (5, paragraphValue(s)), (6, .int(0))]))])), (1, .int(n))])
        }))])
        let styles: V = .dict([(0, .array(s.runs.map { (n, st) in
            .dict([(0, .dict([(0, .dict([(0, .str("")), (5, .int(0)), (6, styleValue(st, font: index(st.font)))]))])), (1, .int(n))])
        }))])
        let model: V = .dict([(0, .str(text)), (5, paras), (6, styles), (10, .dict([(0, .int(4)), (2, .bool(true))]))])

        var view: [(Int, V)] = [(4, version), (5, .int(0)), (0, .array([.dict([(0, .int(frame))])]))]
        if s.box != nil || s.paragraphs.count > 1 {
            view.append((1, .dict([(0, .array(s.paragraphs.map { .dict([(0, .dict([(1, .int(s.box != nil ? 3 : 1))])), (1, .int($0))]) }))])))
        }
        let boxRect: V? = s.box.map { .array([.num(0), .num(0), .num(Double($0.width)), .num(Double($0.height))]) }
        let lines: [V] = (s.lines ?? []).map { lineValue($0, s, index: index) }
        var inner: [(Int, V)] = []
        if let b = boxRect { inner.append((1, b)) }
        inner += [(5, .int(2)), (6, .array(lines))]
        var region: [(Int, V)] = []
        if let b = boxRect { region.append((1, b)) }
        region.append((6, .array([.obj("R", inner)])))
        var fr: [(Int, V)] = [(10, .int(frame))]
        if let b = boxRect { fr.append((1, b)) }
        fr += [(5, .int(2)), (6, .array([.obj("R", region)]))]
        view.append((2, .array([.obj("PC", [(5, .int(0)), (6, .array([.obj("F", fr)]))])])))
        return .dict([(0, model), (1, .dict(view))])
    }

    static func lineValue(_ ln: Story.Line, _ s: Story, index: (Story.Font) -> Int) -> V {
        var d: [(Int, V)] = []
        if abs(ln.baseline) > 1e-9 { d.append((10, .num(ln.baseline))) }
        d += [(14, .num(ln.top)), (15, .num(ln.bottom)), (16, .num(ln.ascent)), (17, .num(ln.descent))]
        if abs(ln.baseline) > 1e-9 { d.append((0, .dict([(0, .array([.num(0), .num(ln.baseline)]))]))) }
        d.append((1, .array([.num(0), .num(ln.runTop), .num(Double(s.box?.width ?? 0)), .num(ln.runBottom)])))
        // the line's characters: style segments as (length, start) pairs, nominal advances
        let segs = ln.runs.map { ($0.count, $0.start) }
        let strike: V = .dict([
            (0, .int(ln.count)), (2, .int(ln.count)), (5, .bool(true)), (6, .int(0)),
            (7, .dict([
                (0, .int(ln.count)), (1, .int(ln.count)), (2, .int(ln.count)), (3, .array(segs.flatMap { [V.int($0.0), V.int($0.1)] })), (5, .int(ln.count)),
                (7, .array(ln.advances.map { .num($0) })), (13, .bool(false)), (14, .array([.int(209)])),
                (15, .dict([(0, .array(segs.map { .int($0.1) })), (1, .array(segs.map { .int($0.0) }))])), (17, .int(ln.count)),
            ])),
        ])
        var seg: [(Int, V)] = [(15, strike), (16, .int(ln.start))]
        if abs(ln.x) > 1e-9 { seg.append((0, .dict([(0, .array([.num(ln.x), .num(0)]))]))) }
        seg.append((6, .array(ln.runs.enumerated().map { glyphRunValue($0.element, ln, last: $0.offset == ln.runs.count - 1, s, index: index) })))
        d.append((6, .array([.obj("S", seg)])))
        return .obj("L", d)
    }

    static func glyphRunValue(_ g: Story.GlyphRun, _ ln: Story.Line, last: Bool, _ s: Story, index: (Story.Font) -> Int) -> V {
        let st = s.runs[min(g.style, s.runs.count - 1)].1
        var d: [(Int, V)] = []
        if abs(g.x) > 1e-9 || abs(g.shift) > 1e-9 { d.append((0, .dict([(0, .array([.num(g.x), .num(-g.shift)]))]))) }
        d.append((1, .array([.num(0), .num(g.top), .num(g.width), .num(g.bottom)])))
        d.append((24, .int(0)))
        let ax = ln.x + g.x, ay = ln.baseline - g.shift
        d.append((8, .array([.num(ax), .num(ay + ln.runTop), .num(ax + g.width), .num(ay + ln.runBottom)])))
        if g.endsParagraph {
            // with the paragraph mark (shown with invisible characters)
            d.append((9, .array([.num(ax), .num(ay + ln.runTop), .num(ax + (g.positions.last ?? g.width) + 0.183 * g.size), .num(ay + ln.runBottom)])))
        }
        var run: [(Int, V)] = []
        if g.start > 0 { run.append((0, .int(g.start))) }
        if st.fauxBold { var f = st.font; f.synthetic = 2; run.append((1, .int(index(f)))) }
        run += [(8, .bool(false)), (9, .int(0))]
        d.append((10, .dict([(0, .array([.dict(run)])), (1, .array([.int(g.count)]))])))
        if g.endsParagraph { d.append((11, .bool(true))) }
        d += [(12, .num(ln.runTop)), (13, .num(ln.runBottom)), (25, .num(ln.runAscent)), (26, .num(ln.runDescent)), (14, .bool(true)), (20, .int(0))]
        var glyphs: [(Int, V)] = [(0, .array(g.glyphs.map { .int($0) })), (1, .array(g.positions.map { .num($0) })), (2, .array([.num(-ln.runTop)]))]
        let kerned = zip(g.positions, g.nominal).contains { abs($0 - $1) > 0.005 }
        glyphs.append(kerned ? (4, .array(g.nominal.map { .num($0) })) : (5, .int(1)))
        d.append((21, .dict(glyphs)))
        if !g.whitespace.isEmpty {
            d.append((22, .dict([(0, .array(g.whitespace.map { .int($0.0) })), (1, .array(g.whitespace.map { .num($0.1) } + [.num(g.whitespaceEnd)])), (2, .array([.num(-ln.runTop)]))])))
        }
        if last { d.append((23, .bool(true))) }
        return .obj("G", d)
    }

    // MARK: Photoshop's default tables (from a file saved by Photoshop 2026)

    enum Templates {
        static let mojiKumi = "<< /0 [ << /0 << /0 (Photoshop6MojiKumiSet4) /5 << /0 0 /3 2 >> >> >> << /0 << /0 (Photoshop6MojiKumiSet3) /5 << /0 0 /3 4 >> >> >> << /0 << /0 "
            + "(Photoshop6MojiKumiSet2) /5 << /0 0 /3 3 >> >> >> << /0 << /0 (Photoshop6MojiKumiSet1) /5 << /0 0 /3 1 >> >> >> << /0 << /0 (YakumonoHankaku) /5 << /0 "
            + "0 /3 1 >> >> >> << /0 << /0 (GyomatsuYakumonoHankaku) /5 << /0 0 /3 3 >> >> >> << /0 << /0 (GyomatsuYakumonoZenkaku) /5 << /0 0 /3 4 >> >> >> << /0 << "
            + "/0 (YakumonoZenkaku) /5 << /0 0 /3 2 >> >> >> << /0 << /0 (GyomatsuYakumonoZenkakuOrHankaku) /5 << /0 0 /3 5 >> >> >> ] /1 [ << /0 0 >> << /0 1 >> << "
            + "/0 2 >> << /0 3 >> << /0 4 >> << /0 5 >> << /0 6 >> << /0 7 >> << /0 8 >> ] >>"

        static let kinsoku = "<< /0 [ << /0 << /0 (None) /5 << /0 () /1 () /2 () /3 () /4 0 >> >> >> << /0 << /0 (PhotoshopKinsokuHard) /5 << /0 "
            + "(!\\),.:;?]}\u{a2}\u{2014}\u{2019}\u{201d}\u{2030}\u{2103}\u{2109}\u{3001}\u{3002}\u{3005}\u{3009}\u{300b}\u{300d}\u{300f}\u{3011}\u{3015}\u{3041}\u{3043}\u{3045}\u{3047}\u{3049}\u{3063}\u{3083}\u{3085}\u{3087}\u{308e}\u{309b}\u{309c}\u{309d}\u{309e}\u{30a1}\u{30a3}\u{30a5}\u{30a7}\u{30a9}\u{30c3}\u{30e3}\u{30e5}\u{30e7}\u{30ee}\u{30f5}\u{30f6}\u{30fb}\u{30fc}\u{30fd}\u{30fe}\u{ff01}\u{ff05}\u{ff09}\u{ff0c}\u{ff0e}\u{ff1a}\u{ff1b}\u{ff1f}\u{ff3d}\u{ff5d}) "
            + "/1 (\\([{\u{a3}\u{a7}\u{2018}\u{201c}\u{3008}\u{300a}\u{300c}\u{300e}\u{3010}\u{3012}\u{3014}\u{ff03}\u{ff04}\u{ff08}\u{ff20}\u{ff3b}\u{ff5b}\u{ffe5}) "
            + "/2 (\u{2014}\u{2025}\u{2026}) /3 (\u{3001}\u{3002}\u{ff0c}\u{ff0e}) /4 1 >> >> >> << /0 << /0 (PhotoshopKinsokuSoft) /5 << /0 "
            + "(\u{2019}\u{201d}\u{3001}\u{3002}\u{3005}\u{3009}\u{300b}\u{300d}\u{300f}\u{3011}\u{3015}\u{309d}\u{309e}\u{30fb}\u{30fd}\u{30fe}\u{ff01}\u{ff09}\u{ff0c}\u{ff0e}\u{ff1a}\u{ff1b}\u{ff1f}\u{ff3d}\u{ff5d}) "
            + "/1 (\u{2018}\u{201c}\u{3008}\u{300a}\u{300c}\u{300e}\u{3010}\u{3014}\u{ff08}\u{ff3b}\u{ff5b}) /2 (\u{2014}\u{2025}\u{2026}) /3 "
            + "(\u{3001}\u{3002}\u{ff0c}\u{ff0e}) /4 2 >> >> >> << /0 << /0 (Hard) /5 << /0 "
            + "(!\\),.:;?]}\u{a2}\u{2014}\u{2019}\u{201d}\u{2030}\u{2103}\u{2109}\u{3001}\u{3002}\u{3005}\u{3009}\u{300b}\u{300d}\u{300f}\u{3011}\u{3015}\u{3041}\u{3043}\u{3045}\u{3047}\u{3049}\u{3063}\u{3083}\u{3085}\u{3087}\u{308e}\u{309b}\u{309c}\u{309d}\u{309e}\u{30a1}\u{30a3}\u{30a5}\u{30a7}\u{30a9}\u{30c3}\u{30e3}\u{30e5}\u{30e7}\u{30ee}\u{30f5}\u{30f6}\u{30fb}\u{30fc}\u{30fd}\u{30fe}\u{ff01}\u{ff05}\u{ff09}\u{ff0c}\u{ff0e}\u{ff1a}\u{ff1b}\u{ff1f}\u{ff3d}\u{ff5d}) "
            + "/1 (\\([{\u{a3}\u{a7}\u{2018}\u{201c}\u{3008}\u{300a}\u{300c}\u{300e}\u{3010}\u{3012}\u{3014}\u{ff03}\u{ff04}\u{ff08}\u{ff20}\u{ff3b}\u{ff5b}\u{ffe5}) "
            + "/2 (\u{2014}\u{2025}\u{2026}) /3 (\u{3001}\u{3002}\u{ff0c}\u{ff0e}) /4 1 >> >> >> << /0 << /0 (Soft) /5 << /0 "
            + "(\u{2019}\u{201d}\u{3001}\u{3002}\u{3005}\u{3009}\u{300b}\u{300d}\u{300f}\u{3011}\u{3015}\u{309d}\u{309e}\u{30fb}\u{30fd}\u{30fe}\u{ff01}\u{ff09}\u{ff0c}\u{ff0e}\u{ff1a}\u{ff1b}\u{ff1f}\u{ff3d}\u{ff5d}) "
            + "/1 (\u{2018}\u{201c}\u{3008}\u{300a}\u{300c}\u{300e}\u{3010}\u{3014}\u{ff08}\u{ff3b}\u{ff5b}) /2 (\u{2014}\u{2025}\u{2026}) /3 "
            + "(\u{3001}\u{3002}\u{ff0c}\u{ff0e}) /4 2 >> >> >> << /0 << /0 (Soft_v2) /5 << /0 "
            + "(\u{2019}\u{201d}\u{3001}\u{3002}\u{3005}\u{3009}\u{300b}\u{300d}\u{300f}\u{3011}\u{3015}\u{309d}\u{309e}\u{30fb}\u{30fd}\u{30fe}\u{ff01}\u{ff09}\u{ff0c}\u{ff0e}\u{ff1a}\u{ff1b}\u{ff1f}\u{ff3d}\u{ff5d}\u{3035}\u{301f}\u{3019}\u{3017}\\)]}\u{2986}\u{bb}.,) "
            + "/1 "
            + "(\u{2018}\u{201c}\\(\u{3014}[{\u{3008}\u{300a}\u{300c}\u{300e}\u{3010}\u{2985}\u{3018}\u{3016}\u{ab}\u{301d}\u{ff08}\u{ff3b}\u{ff5b}\u{3033}\u{3034}) "
            + "/2 (\u{2014}\u{2025}\u{2026}\u{2015}) /3 (\u{3001}\u{3002}\u{ff0c}\u{ff0e}\u{3000}) /4 3 >> >> >> ] /1 [ << /0 0 >> << /0 1 >> << /0 2 >> << /0 3 >> "
            + "<< /0 4 >> << /0 5 >> ] >>"

        static let listStyles = "<< /0 [ << /0 << /0 (kPredefinedNumericListStyleTag) /6 1 >> >> << /0 << /0 (kPredefinedUppercaseAlphaListStyleTag) /6 2 >> >> << /0 << /0 "
            + "(kPredefinedLowercaseAlphaListStyleTag) /6 3 >> >> << /0 << /0 (kPredefinedUppercaseRomanNumListStyleTag) /6 4 >> >> << /0 << /0 "
            + "(kPredefinedLowercaseRomanNumListStyleTag) /6 5 >> >> << /0 << /0 (kPredefinedBulletListStyleTag) /6 6 >> >> << /0 << /0 "
            + "(kPredefinedDashBulletListStyleTag) /6 6 >> >> << /0 << /0 (kPredefinedEmptyCircleBulletListStyleTag) /6 6 >> >> << /0 << /0 "
            + "(kPredefinedFilledSquareBulletListStyleTag) /6 6 >> >> << /0 << /0 (kPredefinedSingleZeroPrefixNumericListStyleTag) /6 7 >> >> << /0 << /0 "
            + "(kPredefinedDoubleZeroPrefixNumericListStyleTag) /6 8 >> >> ] /1 [ << /0 0 >> << /0 1 >> << /0 2 >> << /0 3 >> << /0 4 >> << /0 5 >> << /0 6 >> << /0 "
            + "7 >> << /0 8 >> << /0 9 >> << /0 10 >> ] >>"

        static let normalStyleSheets = "<< /0 [ << /0 << /0 (Normal RGB) /6 << /0 10 /1 12.0 /2 false /3 false /4 true /5 0.0 /6 1.0 /7 1.0 /8 0 /9 0.0 /10 0.0 /11 1 /12 0 /13 0 /14 0 /15 0 "
            + "/16 0 /17 0.0 /18 true /19 false /20 false /21 false /22 false /23 false /24 false /25 false /26 false /27 false /28 false /29 false /30 0 /31 false "
            + "/32 false /33 false /34 false /35 2 /36 0.0 /37 2 /38 0 /39 0 /40 false /41 2 /42 0 /43 << /0 .5 >> /44 2 /45 2 /46 7 /47 0 /48 0 /49 -1.0 /50 -1.0 "
            + "/51 0 /52 false /53 << /99 /SimplePaint /0 << /0 1 /1 [ 1.0 0.0 0.0 0.0 ] >> >> /54 << /99 /SimplePaint /0 << /0 1 /1 [ 1.0 0.0 0.0 0.0 ] >> >> /55 << "
            + "/99 /SimpleBlender >> /56 true /57 false /58 true /59 false /60 false /61 0 /62 0 /63 1.0 /64 4.0 /65 0.0 /66 [ ] /67 [ ] /68 0 /69 0 /70 0 /71 4 /72 "
            + "0.0 /73 0.0 /74 false /75 false /76 false /77 true /78 true /79 << /99 /SimplePaint /0 << /0 1 /1 [ 1.0 1.0 1.0 0.0 ] >> >> /80 false /81 0 /82 3.0 "
            + "/83 3.0 /84 false /85 0 /86 << /99 /SimpleCustomFeature >> /87 100.0 /88 true /91 10 /92 0.0 /95 << /0 0.0 /1 0 >> /96 true >> >> >> ] /1 [ << /0 0 >> "
            + "] >>"

        static let normalParagraphSheets = "<< /0 [ << /0 << /0 (Normal RGB) /5 << /0 0 /1 0.0 /2 0.0 /3 0.0 /4 0.0 /5 0.0 /6 1 /7 1.2 /8 0 /9 true /10 6 /11 2 /12 2 /13 0 /14 36.0 /15 true /16 "
            + ".5 /17 [ .8 1.0 1.33 ] /18 [ 0.0 0.0 0.0 ] /19 [ 1.0 1.0 1.0 ] /20 6 /21 false /22 0 /23 true /24 0 /25 0 /27 /nil /26 false /28 /nil /29 false /30 << "
            + ">> /31 36.0 /32 << >> /33 0 /34 7 /35 1 /36 /nil /37 0 /38 false /39 0 /40 2 /41 0 /47 false /48 /nil >> >> >> ] /1 [ << /0 0 >> ] >>"

        static let documentSettings = "<< /0 << /0 9 /1 [ << /0 ( ) /1 (1) >> << /0 (\u{d}) /1 (6) >> << /0 (\u{9}) /1 (0) >> << /0 (\u{2029}) /1 (5) >> << /0 (\u{3}) /1 (5) >> << /0 "
            + "(\u{3000}) /1 (1) >> << /0 (\u{ad}) /1 (3) >> ] >> /1 0 /2 0 /3 .583 /4 .333 /5 .583 /6 .333 /7 .7 /8 true /9 [ << /0 0 /1 (\u{201c}) /2 (\u{201d}) /3 "
            + "(\u{2018}) /4 (\u{2019}) >> << /0 1 /1 (\u{201d}) /2 (\u{201d}) /3 (\u{2019}) /4 (\u{2019}) >> << /0 2 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2018}) /4 "
            + "(\u{2019}) >> << /0 3 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 4 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> << /0 "
            + "5 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> << /0 6 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2039}) /4 (\u{203a}) >> << /0 7 /1 (\u{201c}) /2 "
            + "(\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 8 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 9 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2018}) "
            + "/4 (\u{2019}) >> << /0 10 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 11 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) "
            + ">> << /0 12 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 13 /1 (\u{201d}) /2 (\u{201d}) /3 (\u{2019}) /4 (\u{2019}) >> << /0 14 /1 "
            + "(\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 15 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 16 /1 (\u{201d}) /2 "
            + "(\u{201d}) /3 (\u{2019}) /4 (\u{2019}) >> << /0 17 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 18 /1 (\u{ab}) /2 (\u{bb}) /3 "
            + "(\u{2018}) /4 (\u{2019}) >> << /0 19 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 20 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 "
            + "(\u{2018}) >> << /0 21 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> << /0 22 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> "
            + "<< /0 23 /1 (\u{201e}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 24 /1 (\u{201e}) /2 (\u{201d}) /3 (\u{201a}) /4 (\u{2019}) >> << /0 25 /1 "
            + "(\u{ab}) /2 (\u{bb}) /3 (\u{2039}) /4 (\u{203a}) >> << /0 26 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 27 /1 (\u{201c}) /2 "
            + "(\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 28 /1 (\u{201e}) /2 (\u{201d}) /3 (\u{2019}) /4 (\u{2019}) >> << /0 29 /1 (\u{301d}) /2 (\u{301e}) >> "
            + "<< /0 30 /1 (\u{300c}) /2 (\u{300d}) >> << /0 31 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 32 /1 (\u{201c}) /2 (\u{201d}) /3 "
            + "(\u{2018}) /4 (\u{2019}) >> << /0 33 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> << /0 34 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2018}) /4 "
            + "(\u{2019}) >> << /0 35 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 36 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> "
            + "<< /0 37 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 38 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> << /0 39 /1 "
            + "(\u{ab}) /2 (\u{bb}) /3 (<) /4 (>) >> << /0 40 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> << /0 41 /1 (\u{ab}) /2 (\u{bb}) /3 (<) /4 "
            + "(>) >> << /0 42 /1 (\u{201e}) /2 (\u{201c}) /3 (\u{201a}) /4 (\u{2018}) >> << /0 43 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> << /0 "
            + "44 /1 (\u{ab}) /2 (\u{bb}) /3 (\u{2039}) /4 (\u{203a}) >> << /0 45 /1 (\u{201c}) /2 (\u{201d}) /3 (\u{2018}) /4 (\u{2019}) >> ] /15 << /0 () >> /16 "
            + "true /17 0 >>"

        static let defaultCharacterStyle = "<< /0 10 /1 12.0 /2 false /3 false /4 true /5 0.0 /6 1.0 /7 1.0 /8 0 /9 0.0 /10 0.0 /11 1 /12 0 /13 0 /14 0 /15 0 /16 0 /17 0.0 /18 true /19 false /20 "
            + "false /21 false /22 false /23 false /24 false /25 false /26 false /27 false /28 false /29 false /30 0 /31 false /32 false /33 false /34 false /35 2 "
            + "/36 0.0 /37 2 /38 0 /39 0 /40 false /41 2 /42 0 /43 << /0 .5 >> /44 2 /45 2 /46 7 /47 0 /48 0 /49 -1.0 /50 -1.0 /51 0 /52 false /53 << /99 "
            + "/SimplePaint /0 << /0 1 /1 [ 1.0 0.0 0.0 0.0 ] >> >> /54 << /99 /SimplePaint /0 << /0 1 /1 [ 1.0 0.0 0.0 0.0 ] >> >> /55 << /99 /SimpleBlender >> /56 "
            + "true /57 false /58 true /59 false /60 false /61 0 /62 0 /63 1.0 /64 4.0 /65 0.0 /66 [ ] /67 [ ] /68 0 /69 0 /70 0 /71 4 /72 0.0 /73 0.0 /74 false /75 "
            + "false /76 false /77 true /78 true /79 << /99 /SimplePaint /0 << /0 1 /1 [ 1.0 1.0 1.0 0.0 ] >> >> /80 false /81 0 /82 3.0 /83 3.0 /84 false /85 0 /86 "
            + "<< /99 /SimpleCustomFeature >> /87 100.0 /88 true /91 10 /92 0.0 /95 << /0 0.0 /1 0 >> /96 true >>"

        static let defaultParagraphStyle = "<< /0 0 /1 0.0 /2 0.0 /3 0.0 /4 0.0 /5 0.0 /6 1 /7 1.2 /8 0 /9 true /10 6 /11 2 /12 2 /13 0 /14 36.0 /15 true /16 .5 /17 [ .8 1.0 1.33 ] /18 [ 0.0 0.0 "
            + "0.0 ] /19 [ 1.0 1.0 1.0 ] /20 6 /21 false /22 0 /23 true /24 0 /25 0 /27 /nil /26 false /28 /nil /29 false /30 << >> /31 36.0 /32 << >> /33 0 /34 7 "
            + "/35 1 /36 /nil /37 0 /38 false /39 0 /40 2 /41 0 /47 false /48 /nil >>"

        static let section2 = "<< /0 [ << /0 << /0 () >> >> ] /1 [ << /0 0 >> ] >>"
    }
}
