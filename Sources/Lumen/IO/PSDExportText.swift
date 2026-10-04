import AppKit
import CoreText
import ImageCratCore

// MARK: - Type layers ('TySh')
//
// The block is the inverse of PSDText: version 1, the text transform, a 'TxLr' descriptor carrying the EngineData
// (the text, style runs, paragraph runs, fonts and the ResourceDict / DocumentResources Photoshop's text engine
// reads), then the warp descriptor. The engine data copies the key set and layout of files written by Photoshop 2026
// (all-layer-types.psd, Default Type Styles.psp) so the text engine finds every value it looks up.

/// EngineData value, serialized with Photoshop's own layout (tabs, one key per line, inline scalar arrays).
indirect enum PSDEngineOut {
    case dict([(String, PSDEngineOut)])
    case array([PSDEngineOut])
    case int(Int)
    case num(Double)
    case bool(Bool)
    case str(String)

    static func number(_ d: Double) -> String {
        let v = d.isFinite ? d : 0
        if v == v.rounded(), abs(v) < 1e9 { return String(format: "%.1f", v) }
        var s = String(format: "%.5f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.append("0") }
        if s.hasPrefix("0.") { s.removeFirst() } else if s.hasPrefix("-0.") { s = "-" + s.dropFirst(2) }
        return s
    }

    static func string(_ s: String) -> [UInt8] {
        var out: [UInt8] = [0x28, 0xFE, 0xFF]
        for u in s.utf16 {
            for b in [UInt8(u >> 8), UInt8(u & 0xff)] {
                if b == 0x28 || b == 0x29 || b == 0x5C { out.append(0x5C) }
                out.append(b)
            }
        }
        out.append(0x29)
        return out
    }

    private var isDict: Bool { if case .dict = self { return true }; return false }

    func emit(_ level: Int, _ out: inout [UInt8]) {
        func put(_ s: String) { out += Array(s.utf8) }
        func tabs(_ n: Int) { out += [UInt8](repeating: 0x09, count: max(0, n)) }
        switch self {
        case .dict(let items):
            put("<<\n")
            for (k, v) in items {
                tabs(level + 1); put("/" + k)
                switch v {
                case .dict:
                    put("\n"); tabs(level + 1); v.emit(level + 1, &out)
                case .array(let a) where a.first?.isDict == true:
                    put(" [\n")
                    for e in a { tabs(level + 1); e.emit(level + 1, &out); put("\n") }
                    tabs(level + 1); put("]")
                default:
                    put(" "); v.emit(level + 1, &out)
                }
                put("\n")
            }
            tabs(level); put(">>")
        case .array(let a):
            put("[")
            for e in a { put(" "); e.emit(level, &out) }
            put(" ]")
        case .int(let i): put("\(i)")
        case .num(let d): put(PSDEngineOut.number(d))
        case .bool(let b): put(b ? "true" : "false")
        case .str(let s): out += PSDEngineOut.string(s)
        }
    }

    var bytes: [UInt8] {
        var out: [UInt8] = [0x0A, 0x0A]
        emit(0, &out)
        return out
    }
}

enum PSDExportText {
    typealias E = PSDEngineOut

    struct Encoded {
        var data: Data
        var notes: [String]
        /// The layer for the document's 'Txt2'.
        var story = Story()
    }

    static let warpKeys: [WarpStyle: String] = Dictionary(uniqueKeysWithValues: PSDText.warpStyles.map { ($0.value, $0.key) })

    private static func fin(_ v: Double, _ d: Double = 0) -> Double { v.isFinite ? v : d }

    /// PostScript name and Photoshop's FontType (1 TrueType outlines, 0 PostScript / CFF) of an installed font.
    static func fontInfo(_ name: String) -> (ps: String, type: Int, installed: Bool) {
        guard !name.isEmpty, NSFont(name: name, size: 12) != nil else { return (name.isEmpty ? "Helvetica" : name, 0, false) }
        // the face Lumen actually draws with (a family or display name resolves to one of its faces)
        let f = TextRenderer.makeFont(name: name, size: 12)
        let fmt = (CTFontCopyAttribute(f, kCTFontFormatAttribute) as? NSNumber)?.intValue ?? 0
        // kCTFontFormatOpenTypeTrueType = 2, kCTFontFormatTrueType = 3
        return (CTFontCopyPostScriptName(f) as String, fmt == 2 || fmt == 3 ? 1 : 0, true)
    }

    static func color(_ c: RGBA) -> E {
        .dict([("Type", .int(1)), ("Values", .array([.num(1), .num(clamp(fin(c.r), 0, 1)), .num(clamp(fin(c.g), 0, 1)), .num(clamp(fin(c.b), 0, 1))]))])
    }

    static let black = color(.black)

    /// Character style sheet (every key Photoshop 2026 writes for a run).
    static func styleSheet(_ s: TextContent, font: Int, leading: Double?, vertical: Bool) -> E {
        let caps = s.allCaps ? 2 : (s.features.smallCaps ? 1 : 0)
        let col = s.color
        return .dict([
            ("Font", .int(font)), ("FontSize", .num(clamp(fin(s.fontSize, 12), 0.01, 20000))),
            ("FauxBold", .bool(s.fauxBold)), ("FauxItalic", .bool(s.fauxItalic)),
            ("AutoLeading", .bool(leading == nil)), ("Leading", .num(leading ?? 0)),
            ("HorizontalScale", .num(clamp(fin(s.horizontalScale, 1), 0.01, 100))), ("VerticalScale", .num(clamp(fin(s.verticalScale, 1), 0.01, 100))),
            ("Tracking", .int(Int(clamp(fin(s.tracking), -1000, 10000).rounded()))), ("AutoKerning", .bool(true)), ("Kerning", .int(0)),
            ("BaselineShift", .num(clamp(fin(s.baselineShift), -20000, 20000))), ("FontCaps", .int(caps)), ("FontBaseline", .int(0)),
            ("Underline", .bool(s.underline)), ("Strikethrough", .bool(s.strikethrough)),
            ("Ligatures", .bool(s.features.standardLigatures)), ("DLigatures", .bool(s.features.discretionaryLigatures)),
            ("BaselineDirection", .int(vertical ? 1 : 2)), ("Tsume", .num(0)), ("StyleRunAlignment", .int(2)), ("Language", .int(0)), ("NoBreak", .bool(false)),
            ("FillColor", color(col)), ("StrokeColor", black), ("FillFlag", .bool(col.a > 0.001)), ("StrokeFlag", .bool(false)), ("FillFirst", .bool(true)),
            ("YUnderline", .int(1)), ("OutlineWidth", .num(1)), ("CharacterDirection", .int(0)), ("HindiNumbers", .bool(false)), ("Kashida", .int(1)),
            ("DiacriticPos", .int(2)),
        ])
    }

    static func paragraphProperties(_ t: TextContent?) -> E {
        let just: Int
        switch t?.alignment ?? .left {
        case .left: just = 0
        case .right: just = 1
        case .center: just = 2
        case .justify: just = 3
        case .justifyRight: just = 4
        case .justifyCenter: just = 5
        case .justifyAll: just = 6
        }
        func n(_ v: Double?) -> E { .num(clamp(fin(v ?? 0), -20000, 20000)) }
        return .dict([
            ("Justification", .int(just)), ("FirstLineIndent", n(t?.firstLineIndent)), ("StartIndent", n(t?.leftIndent)), ("EndIndent", n(t?.rightIndent)),
            ("SpaceBefore", n(t?.spaceBefore)), ("SpaceAfter", n(t?.spaceAfter)), ("AutoHyphenate", .bool(t?.hyphenate ?? true)),
            ("HyphenatedWordSize", .int(6)), ("PreHyphen", .int(2)), ("PostHyphen", .int(2)), ("ConsecutiveHyphens", .int(8)), ("Zone", .num(36)),
            ("WordSpacing", .array([.num(0.8), .num(1), .num(1.33)])), ("LetterSpacing", .array([.num(0), .num(0), .num(0)])),
            ("GlyphSpacing", .array([.num(1), .num(1), .num(1)])), ("AutoLeading", .num(1.2)), ("LeadingType", .int(0)), ("Hanging", .bool(false)),
            ("Burasagari", .bool(false)), ("KinsokuOrder", .int(0)), ("EveryLineComposer", .bool(false)),
        ])
    }

    static let adjustments: E = .dict([("Axis", .array([.num(1), .num(0), .num(1)])), ("XY", .array([.num(0), .num(0)]))])

    /// `fonts` ends with AdobeInvisFont and the Normal style's font (MyriadPro-Regular), as Photoshop lists them.
    static func resources(fonts: [(String, Int)]) -> E {
        let hardNoStart = "\u{3001}\u{3002}\u{ff0c}\u{ff0e}\u{30fb}\u{ff1a}\u{ff1b}\u{ff1f}\u{ff01}\u{30fc}\u{2015}\u{2019}\u{201d}\u{ff09}\u{3015}\u{ff3d}\u{ff5d}\u{3009}\u{300b}\u{300d}\u{300f}\u{3011}\u{30fd}\u{30fe}\u{309d}\u{309e}\u{3005}\u{3041}\u{3043}\u{3045}\u{3047}\u{3049}\u{3063}\u{3083}\u{3085}\u{3087}\u{308e}\u{30a1}\u{30a3}\u{30a5}\u{30a7}\u{30a9}\u{30c3}\u{30e3}\u{30e5}\u{30e7}\u{30ee}\u{30f5}\u{30f6}\u{309b}\u{309c}?!)]},.:;\u{2103}\u{2109}\u{a2}\u{ff05}\u{2030}"
        let hardNoEnd = "\u{2018}\u{201c}\u{ff08}\u{3014}\u{ff3b}\u{ff5b}\u{3008}\u{300a}\u{300c}\u{300e}\u{3010}([{\u{ffe5}\u{ff04}\u{a3}\u{ff20}\u{a7}\u{3012}\u{ff03}"
        let softNoStart = "\u{3001}\u{3002}\u{ff0c}\u{ff0e}\u{30fb}\u{ff1a}\u{ff1b}\u{ff1f}\u{ff01}\u{2019}\u{201d}\u{ff09}\u{3015}\u{ff3d}\u{ff5d}\u{3009}\u{300b}\u{300d}\u{300f}\u{3011}\u{30fd}\u{30fe}\u{309d}\u{309e}\u{3005}"
        let softNoEnd = "\u{2018}\u{201c}\u{ff08}\u{3014}\u{ff3b}\u{ff5b}\u{3008}\u{300a}\u{300c}\u{300e}\u{3010}"
        let keep = "\u{2015}\u{2025}", hanging = "\u{3001}\u{3002}.,"
        var normal = TextContent()
        normal.fontSize = 12
        let fontSet: [E] = fonts.map { .dict([("Name", .str($0.0)), ("Script", .int(0)), ("FontType", .int($0.1)), ("Synthetic", .int(0))]) }
        return .dict([
            ("KinsokuSet", .array([
                .dict([("Name", .str("PhotoshopKinsokuHard")), ("NoStart", .str(hardNoStart)), ("NoEnd", .str(hardNoEnd)), ("Keep", .str(keep)), ("Hanging", .str(hanging))]),
                .dict([("Name", .str("PhotoshopKinsokuSoft")), ("NoStart", .str(softNoStart)), ("NoEnd", .str(softNoEnd)), ("Keep", .str(keep)), ("Hanging", .str(hanging))]),
            ])),
            ("MojiKumiSet", .array((1...4).map { .dict([("InternalName", .str("Photoshop6MojiKumiSet\($0)"))]) })),
            ("TheNormalStyleSheet", .int(0)), ("TheNormalParagraphSheet", .int(0)),
            ("ParagraphSheetSet", .array([.dict([("Name", .str("Normal RGB")), ("DefaultStyleSheet", .int(0)), ("Properties", paragraphProperties(nil))])])),
            ("StyleSheetSet", .array([.dict([("Name", .str("Normal RGB")), ("StyleSheetData", styleSheet(normal, font: max(0, fonts.count - 1), leading: nil, vertical: false))])])),
            ("FontSet", .array(fontSet)),
            ("SuperscriptSize", .num(0.583)), ("SuperscriptPosition", .num(0.333)), ("SubscriptSize", .num(0.583)), ("SubscriptPosition", .num(0.333)),
            ("SmallCapSize", .num(0.7)),
        ])
    }

    /// Lumen's local point that becomes Photoshop's text origin: the first baseline at the alignment anchor (point
    /// text), the top centre of the first column (vertical point text) or the box corner (paragraph text).
    static func anchor(_ t: TextContent, box: Bool) -> CGPoint {
        let hs = CGFloat(clamp(fin(t.horizontalScale, 1), 0.01, 100)), vs = CGFloat(clamp(fin(t.verticalScale, 1), 0.01, 100))
        if let p = t.pathText {
            // type on a path is written as point text where the path starts
            let L = TextRenderer.layout(t)
            if let first = L.lines.first(where: { !$0.isMarker }) { return CGPoint(x: first.transform.tx, y: first.transform.ty) }
            return p.path.subpaths.first?.points.first?.anchor ?? .zero
        }
        if box { return t.position }
        if t.orientation == .vertical { return CGPoint(x: t.position.x - CGFloat(fin(t.fontSize, 12)) * hs / 2, y: t.position.y) }
        let L = TextRenderer.layout(t)
        guard let first = L.lines.first(where: { !$0.isMarker }) else { return t.position }
        return CGPoint(x: t.position.x + alignmentX(t, first) * hs, y: t.position.y + first.transform.ty * vs)
    }

    /// Where a point-text line meets its origin (local px): its start, middle or end by the alignment. Photoshop
    /// measures the line without the tracking after its last character.
    static func alignmentX(_ t: TextContent, _ line: PlacedLine) -> CGFloat {
        let b = line.bounds
        switch t.alignment {
        case .center, .justifyCenter: return b.minX + (b.width - trailingTracking(t, line)) / 2
        case .right, .justifyRight: return b.maxX - trailingTracking(t, line)
        default: return b.minX
        }
    }

    /// Photoshop's text engine does no font fallback: emoji that Lumen draws in Apple Color Emoji through fallback get
    /// runs in that font, as Photoshop writes them for emoji typed there (PSD import folds them back, see PSDText).
    static func splitColorGlyphRuns(_ runs: [(len: Int, style: CharacterStyle)], _ t: TextContent) -> [(len: Int, style: CharacterStyle)] {
        let color = EmojiText.colorRuns(t)
        guard !color.isEmpty else { return runs }
        var out: [(len: Int, style: CharacterStyle)] = []
        func add(_ len: Int, _ st: CharacterStyle) {
            guard len > 0 else { return }
            if let l = out.last, l.style == st { out[out.count - 1].len += len } else { out.append((len, st)) }
        }
        var loc = 0
        for r in runs {
            let end = loc + r.len
            var p = loc
            for c in color where c.range.location < end && NSMaxRange(c.range) > p {
                let a = max(p, c.range.location), b = min(end, NSMaxRange(c.range))
                add(a - p, r.style)
                var st = r.style
                st.fontName = c.font
                add(b - a, st)
                p = b
            }
            add(end - p, r.style)
            loc = end
        }
        return out.isEmpty ? runs : out
    }

    static func block(_ t: TextContent, index: Int) -> Encoded {
        var notes: [String] = []
        let box = t.boxSize != nil && t.pathText == nil
        let vertical = t.orientation == .vertical && t.pathText == nil
        let hs = clamp(fin(t.horizontalScale, 1), 0.01, 100), vs = clamp(fin(t.verticalScale, 1), 0.01, 100)

        // Text: paragraphs end with CR, forced line breaks are ETX, and the text ends with a paragraph mark.
        var units = Array(t.text.utf16).map { $0 == 10 || $0 == 0x2029 ? UInt16(13) : ($0 == 0x2028 ? UInt16(3) : $0) }
        let typed = String(decoding: units, as: UTF16.self)
        units.append(13)
        let full = String(decoding: units, as: UTF16.self)

        // Style runs (the last one also covers the closing paragraph mark)
        var runs: [(len: Int, style: CharacterStyle)] = []
        for seg in t.styleSegments() where seg.length > 0 {
            if let last = runs.last, last.style == seg.style { runs[runs.count - 1].len += seg.length } else { runs.append((seg.length, seg.style)) }
        }
        if runs.isEmpty { runs = [(0, CharacterStyle())] }
        runs[runs.count - 1].len += 1
        runs = splitColorGlyphRuns(runs, t)    // (after: the closing paragraph mark stays in the text's own font)

        // Fonts
        var fonts: [(String, Int)] = []
        var missing: [String] = []
        func fontIndex(_ name: String) -> Int {
            let info = fontInfo(name)
            if !info.installed, !missing.contains(name) { missing.append(name) }
            if let i = fonts.firstIndex(where: { $0.0 == info.ps }) { return i }
            fonts.append((info.ps, info.type))
            return fonts.count - 1
        }
        let leading = t.leading.map { clamp(fin($0), 0.01, 100000) }
        var runArray: [E] = []
        var storyStyles: [(Int, Story.Style)] = []
        for r in runs {
            let eff = t.applying(r.style)
            runArray.append(.dict([("StyleSheet", .dict([("StyleSheetData", styleSheet(eff, font: fontIndex(eff.fontName), leading: leading, vertical: vertical))]))]))
            let info = fontInfo(eff.fontName)
            storyStyles.append((r.len, storyStyle(eff, font: Story.Font(ps: info.ps, type: info.type, installed: info.installed), leading: leading, vertical: vertical)))
        }
        fonts.append(("AdobeInvisFont", 0))
        fonts.append(("MyriadPro-Regular", 0))
        if !missing.isEmpty { notes.append("Font\(missing.count == 1 ? "" : "s") \(missing.map { "“\($0)”" }.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") not installed; Photoshop will ask for a substitute.") }

        // Paragraph runs: one per paragraph, all with the layer's paragraph settings
        var paraLengths: [Int] = []
        var count = 0
        for u in units { count += 1; if u == 13 { paraLengths.append(count); count = 0 } }
        if count > 0 { paraLengths.append(count) }
        let para: E = .dict([("ParagraphSheet", .dict([("DefaultStyleSheet", .int(0)), ("Properties", paragraphProperties(t))])), ("Adjustments", adjustments)])

        // Geometry: Photoshop's origin is our anchor; sizes stay in text-space units (the transform keeps any scale).
        let a = anchor(t, box: box)
        let m = CGAffineTransform(translationX: a.x, y: a.y).concatenating(t.transform)
        let storyBox = box ? t.boxSize.map { CGSize(width: clamp(fin(Double($0.width)), 0, 1e6) * hs, height: clamp(fin(Double($0.height)), 0, 1e6) * vs) } : nil
        let story = Self.story(t, units: units, styles: storyStyles, paragraphs: paraLengths, box: storyBox, anchor: a)
        let shapeType = box ? 1 : 0
        let wd = vertical ? 2 : 0
        var cookie: [(String, E)] = [("ShapeType", .int(shapeType))]
        var bounds = CGRect.zero
        if box, let b = t.boxSize {
            let w = clamp(fin(Double(b.width)), 0, 1e6) * hs, h = clamp(fin(Double(b.height)), 0, 1e6) * vs
            cookie.append(("BoxBounds", .array([.num(0), .num(0), .num(w), .num(h)])))
            bounds = CGRect(x: 0, y: 0, width: w, height: h)
        } else {
            cookie.append(("PointBase", .array([.num(0), .num(0)])))
            let L = TextRenderer.layout(t)
            let r = L.baseRect
            if !r.isNull, !r.isInfinite {
                bounds = CGRect(x: t.position.x + r.minX * CGFloat(hs) - a.x, y: t.position.y + r.minY * CGFloat(vs) - a.y, width: r.width * CGFloat(hs), height: r.height * CGFloat(vs))
            }
        }
        cookie.append(("Base", .dict([("ShapeType", .int(shapeType)), ("TransformPoint0", .array([.num(1), .num(0)])),
                                      ("TransformPoint1", .array([.num(0), .num(1)])), ("TransformPoint2", .array([.num(0), .num(0)]))])))
        let shape: E = .dict([
            ("ShapeType", .int(shapeType)), ("Procession", .int(0)),
            ("Lines", .dict([("WritingDirection", .int(wd)), ("Children", .array([]))])),
            ("Cookie", .dict([("Photoshop", .dict(cookie))])),
        ])

        let res = resources(fonts: fonts)
        let engine: E = .dict([
            ("EngineDict", .dict([
                ("Editor", .dict([("Text", .str(full))])),
                ("ParagraphRun", .dict([
                    ("DefaultRunData", .dict([("ParagraphSheet", .dict([("DefaultStyleSheet", .int(0)), ("Properties", .dict([]))])), ("Adjustments", adjustments)])),
                    ("RunArray", .array(paraLengths.map { _ in para })),
                    ("RunLengthArray", .array(paraLengths.map { .int($0) })),
                    ("IsJoinable", .int(1)),
                ])),
                ("StyleRun", .dict([
                    ("DefaultRunData", .dict([("StyleSheet", .dict([("StyleSheetData", .dict([]))]))])),
                    ("RunArray", .array(runArray)),
                    ("RunLengthArray", .array(runs.map { .int($0.len) })),
                    ("IsJoinable", .int(2)),
                ])),
                ("GridInfo", .dict([
                    ("GridIsOn", .bool(false)), ("ShowGrid", .bool(false)), ("GridSize", .num(18)), ("GridLeading", .num(22)),
                    ("GridColor", .dict([("Type", .int(1)), ("Values", .array([.num(0), .num(0), .num(0), .num(1)]))])),
                    ("GridLeadingFillColor", .dict([("Type", .int(1)), ("Values", .array([.num(0), .num(0), .num(0), .num(1)]))])),
                    ("AlignLineHeightToGridFlags", .bool(false)),
                ])),
                ("AntiAlias", .int(t.antialias ? 4 : 0)),
                ("UseFractionalGlyphWidths", .bool(true)),
                ("Rendered", .dict([
                    ("Version", .int(1)),
                    ("Shapes", .dict([("WritingDirection", .int(wd)), ("Children", .array([shape]))])),
                ])),
            ])),
            ("ResourceDict", res),
            ("DocumentResources", res),
        ])

        func rect(_ cls: String, _ r: CGRect) -> PSDDescriptorValue {
            func p(_ v: CGFloat) -> PSDDescriptorValue { .unitFloat(unit: "#Pnt", value: fin(Double(v))) }
            return .object(PSDDescriptor(classID: cls, [("Left", p(r.minX)), ("Top ", p(r.minY)), ("Rght", p(r.maxX)), ("Btom", p(r.maxY))]))
        }
        let txlr = PSDDescriptor(classID: "TxLr", [
            ("Txt ", .string(typed)),
            ("textGridding", .enumerated(type: "textGridding", value: "None")),
            ("Ornt", .enumerated(type: "Ornt", value: vertical ? "Vrtc" : "Hrzn")),
            ("AntA", .enumerated(type: "Annt", value: t.antialias ? "antiAliasSharp" : "Anno")),
            ("TxMP", .bool(false)),
            ("bounds", rect("bounds", story.bounds ?? bounds)),
            ("boundingBox", rect("boundingBox", story.ink ?? bounds)),
            ("TextIndex", .integer(Int32(index))),
            ("EngineData", .data(osType: "tdta", Data(engine.bytes))),
        ])
        var warp = TextWarp(style: .none, bend: 0)
        if let w = t.warp, !w.isIdentity { warp = w }
        let wdesc = PSDDescriptor(classID: "warp", [
            ("warpStyle", .enumerated(type: "warpStyle", value: warpKeys[warp.style] ?? "warpNone")),
            ("warpValue", .double(clamp(fin(warp.bend), -100, 100))),
            ("warpPerspective", .double(clamp(fin(warp.horizontalDistortion), -100, 100))),
            ("warpPerspectiveOther", .double(clamp(fin(warp.verticalDistortion), -100, 100))),
            ("warpRotate", .enumerated(type: "Ornt", value: "Hrzn")),
        ])

        var w = BinaryWriter()
        w.u16(1)
        for v in [m.a, m.b, m.c, m.d, m.tx, m.ty] { w.u64(fin(Double(v)).bitPattern) }
        w.u16(50)
        w.raw(txlr.serializedVersioned())
        w.u16(1)
        w.raw(wdesc.serializedVersioned())
        for _ in 0..<4 { w.u32(0) }

        if t.pathText != nil { notes.append("Type on a path is written as point text at the start of the path (Photoshop shows the stored pixels until the text is edited).") }
        if t.area != nil { notes.append("Text inside a shape is written as paragraph text in its bounding box.") }
        if t.list != nil { notes.append("Bullets / numbering have no Photoshop equivalent; the editable text has no list markers.") }
        if t.fitToBox != nil { notes.append("Dynamic Text sizing is not a Photoshop feature; the current font size is written.") }
        if !t.variations.isEmpty || t.runs.contains(where: { $0.style.variations != nil }) { notes.append("Variable-font axis settings are not written.") }
        if t.direction == .rtl { notes.append("Right-to-left paragraph direction is not written.") }
        let f = t.features
        if f.oldStyleFigures || f.fractions || f.ordinals || f.swash || f.stylisticAlternates || !f.extra.isEmpty {
            notes.append("OpenType features other than ligatures and small caps are not written.")
        }
        if t.color.a < 0.999 || t.runs.contains(where: { ($0.style.color?.a ?? 1) < 0.999 }) { notes.append("Text colour opacity is not part of Photoshop's character colour; it is written opaque.") }
        return Encoded(data: w.data, notes: notes, story: story)
    }
}
