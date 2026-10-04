import AppKit
import CoreText
import CoreImage
import ImageCratCore

extension NSAttributedString.Key {
    /// Carries a range's `CharacterStyle` overrides through the on-canvas editor (read back into runs on commit).
    static let lumenCharStyle = NSAttributedString.Key("LumenCharStyle")
}

/// Object wrapper so a `CharacterStyle` can live in an attributed string.
final class CharStyleBox: NSObject {
    let style: CharacterStyle
    init(_ s: CharacterStyle) { style = s; super.init() }
    override func isEqual(_ object: Any?) -> Bool { (object as? CharStyleBox)?.style == style }
    override var hash: Int { (style.fontName?.hashValue ?? 0) ^ Int(style.fontSize ?? 0) }
}

/// Part of a glyph run (type on a path places glyph clusters of one shaped line individually).
struct RunSlice {
    let run: CTRun
    let range: CFRange
}

/// One positioned CTLine. `transform` maps line space (y-up, origin on the baseline) to local text space (y-down).
struct PlacedLine {
    var line: CTLine
    var transform: CGAffineTransform
    /// Typographic bounds in local space.
    var bounds: CGRect
    /// UTF-16 range of the layer text shown by this line (NSNotFound for list markers).
    var textRange = NSRange(location: NSNotFound, length: 0)
    /// List bullet / number.
    var isMarker = false
    /// When set, only these glyphs of `line` are drawn (shaping of the whole line is kept, e.g. Arabic joining on a path).
    var slices: [RunSlice]? = nil

    /// Glyph runs (with glyph ranges) this placed line draws.
    var drawnRuns: [RunSlice] {
        if let s = slices { return s }
        return (CTLineGetGlyphRuns(line) as! [CTRun]).map { RunSlice(run: $0, range: CFRange(location: 0, length: CTRunGetGlyphCount($0))) }
    }
}

/// Result of laying out a text layer in local space (before warp and `docTransform`).
final class TypeLayout {
    let lines: [PlacedLine]
    /// Layout box in local space (text box / point-text extent / glyph extent on a path).
    let baseRect: CGRect
    /// Extra space TextKit puts above the first line compared to our layout (editor alignment), local px.
    let firstLineExtra: CGFloat
    /// Largest font size used (px).
    let maxFontSize: CGFloat
    /// Text did not fit the box / shape (lines dropped).
    var overflowed = false
    /// A line had to break inside a word (or a word is wider than the box).
    var brokeWords = false
    /// Font scale applied by Dynamic Text (1 = none) and extra tracking (1/1000 em).
    var fitScale: CGFloat = 1
    var fitTracking: Double = 0

    init(lines: [PlacedLine], baseRect: CGRect, firstLineExtra: CGFloat, maxFontSize: CGFloat) {
        self.lines = lines; self.baseRect = baseRect; self.firstLineExtra = firstLineExtra; self.maxFontSize = maxFontSize
    }
}

private final class TypeLayoutCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(TextContent, TypeLayout)] = []
    func get(_ t: TextContent, _ make: () -> TypeLayout) -> TypeLayout {
        lock.lock()
        if let i = entries.firstIndex(where: { $0.0 == t }) {
            let l = entries[i].1
            lock.unlock()
            return l
        }
        lock.unlock()
        let l = make()
        lock.lock()
        entries.append((t, l))
        if entries.count > 48 { entries.removeFirst(entries.count - 48) }
        lock.unlock()
        return l
    }
}

private final class FontNameCache: @unchecked Sendable {
    private let lock = NSLock()
    private var valid: [String: String] = [:]
    func resolve(_ name: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let v = valid[name] { return v }
        let r = FontLookup.installed(name) ? name : NSFont.systemFont(ofSize: 12).fontName
        valid[name] = r
        return r
    }
}

enum FontLookup {
    /// A font is installed under this PostScript name: AppKit knows it, or Core Text resolves the name to itself
    /// (fonts activated for Core Text only are not always NSFont names).
    static func installed(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        if NSFont(name: name, size: 12) != nil { return true }
        let f = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: name] as CFDictionary), 12, nil)
        return (CTFontCopyPostScriptName(f) as String).caseInsensitiveCompare(name) == .orderedSame
    }
}

enum TextRenderer {
    private static let layoutCache = TypeLayoutCache()
    private static let fontNames = FontNameCache()

    // MARK: Fonts & attributes

    static func makeFont(name: String, size: CGFloat, features: OpenTypeFeatures = OpenTypeFeatures(),
                         hScale: CGFloat = 1, vScale: CGFloat = 1, italic: Bool = false, variations: [String: Double] = [:]) -> CTFont {
        var attrs: [CFString: Any] = [kCTFontNameAttribute: fontNames.resolve(name)]
        var settings: [[CFString: Any]] = features.tagSettings.map { [kCTFontOpenTypeFeatureTag: $0.0, kCTFontOpenTypeFeatureValue: $0.1] }
        for (k, _) in features.extra.sorted(by: { $0.key < $1.key }) where k.hasPrefix("aat:") {
            let parts = k.split(separator: ":")
            if parts.count == 3, let ty = Int(parts[1]), let se = Int(parts[2]) {
                settings.append([kCTFontFeatureTypeIdentifierKey: ty, kCTFontFeatureSelectorIdentifierKey: se])
            }
        }
        if !settings.isEmpty { attrs[kCTFontFeatureSettingsAttribute] = settings }
        if !variations.isEmpty {
            var v: [NSNumber: NSNumber] = [:]
            for (tag, value) in variations { v[NSNumber(value: FontAxisTag.id(tag))] = NSNumber(value: value) }
            attrs[kCTFontVariationAttribute] = v
        }
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let size = max(0.5, size)
        if abs(hScale - 1) < 1e-6 && abs(vScale - 1) < 1e-6 && !italic { return CTFontCreateWithFontDescriptor(desc, size, nil) }
        var m = CGAffineTransform(a: hScale, b: 0, c: italic ? 0.21 * vScale : 0, d: vScale, tx: 0, ty: 0)
        return CTFontCreateWithFontDescriptor(desc, size, &m)
    }

    /// Layer-default font (no scale, no faux italic).
    static func font(_ t: TextContent) -> NSFont {
        makeFont(name: t.fontName, size: CGFloat(t.fontSize), features: t.features, variations: t.variations) as NSFont
    }

    /// Whether the layer-level horizontal/vertical scale is baked into the fonts (path text) rather than `docTransform`.
    static func fontsCarryLayerScale(_ t: TextContent) -> Bool { t.pathText != nil }

    /// Character attributes for effective style `eff` of layer `t`.
    /// `layerScaleInFont`: bake the layer's horizontal/vertical scale into the font matrix (editor, path text).
    static func characterAttributes(_ eff: TextContent, layer t: TextContent, scale: CGFloat, layerScaleInFont: Bool) -> [NSAttributedString.Key: Any] {
        var hs = CGFloat(eff.horizontalScale), vs = CGFloat(eff.verticalScale)
        if !layerScaleInFont {
            hs /= CGFloat(max(0.01, t.horizontalScale)); vs /= CGFloat(max(0.01, t.verticalScale))
        }
        let size = CGFloat(eff.fontSize) * scale
        let f = makeFont(name: eff.fontName, size: size, features: eff.features, hScale: hs, vScale: vs, italic: eff.fauxItalic, variations: eff.variations)
        var a: [NSAttributedString.Key: Any] = [
            .font: f as NSFont,
            .foregroundColor: eff.color.nsColor,
        ]
        // any .kern value (0 included) switches the font's pair kerning off; Photoshop's default is the font's kerning
        if eff.tracking != 0 { a[.kern] = CGFloat(eff.tracking / 1000 * eff.fontSize) * scale * hs }
        if eff.fauxBold {
            a[.strokeWidth] = -3.0
            a[.strokeColor] = eff.color.nsColor
        }
        if eff.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if eff.strikethrough { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if eff.baselineShift != 0 {
            a[.baselineOffset] = CGFloat(eff.baselineShift) * scale
            a[NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)] = CGFloat(eff.baselineShift) * scale
        }
        return a
    }

    static let autoLeadingFactor: CGFloat = 1.2

    static func paragraphStyle(_ t: TextContent, scale: CGFloat, forEditor: Bool) -> NSParagraphStyle {
        let para = NSMutableParagraphStyle()
        switch t.alignment {
        case .left: para.alignment = .left
        case .center: para.alignment = .center
        case .right: para.alignment = .right
        case .justify, .justifyCenter, .justifyRight, .justifyAll: para.alignment = t.boxSize == nil ? .left : .justified
        }
        if let lead = t.leading {
            para.minimumLineHeight = CGFloat(lead) * scale
            para.maximumLineHeight = CGFloat(lead) * scale
        } else if forEditor {
            para.minimumLineHeight = CGFloat(t.fontSize) * autoLeadingFactor * scale
        }
        para.headIndent = CGFloat(t.leftIndent) * scale
        para.firstLineHeadIndent = CGFloat(t.leftIndent + t.firstLineIndent) * scale
        para.tailIndent = -CGFloat(t.rightIndent) * scale
        para.paragraphSpacingBefore = CGFloat(t.spaceBefore) * scale
        para.paragraphSpacing = CGFloat(t.spaceAfter) * scale
        para.hyphenationFactor = t.hyphenate ? 1 : 0
        if t.composer == .worldReady {
            switch t.direction {
            case .auto: para.baseWritingDirection = .natural
            case .ltr: para.baseWritingDirection = .leftToRight
            case .rtl: para.baseWritingDirection = .rightToLeft
            }
        }
        return para
    }

    /// Uppercases without changing UTF-16 offsets (so style runs stay valid).
    static func upperPreservingLength(_ s: String) -> String {
        var out = ""
        for ch in s {
            let c = String(ch), u = c.uppercased()
            out += (u as NSString).length == (c as NSString).length ? u : c
        }
        return out
    }

    /// Styled string for the layer: layer defaults + style runs.
    /// - scale: multiplies all px values (editor zoom).
    /// - forEditor: tags ranges with `.lumenCharStyle`, keeps case, and bakes layer scale into the fonts.
    static func attributedString(_ t: TextContent, overrideText: String? = nil, scale: CGFloat = 1, forEditor: Bool = false,
                                 singleLine: Bool = false) -> NSAttributedString {
        var s = overrideText ?? t.text
        let origLen = (s as NSString).length
        if t.allCaps && !forEditor { s = upperPreservingLength(s) }
        if singleLine { s = s.replacingOccurrences(of: "\r\n", with: " \u{200B}").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        if s.isEmpty && !forEditor { s = " " }
        let layerScaleInFont = forEditor || fontsCarryLayerScale(t)
        let m = NSMutableAttributedString(string: s)
        let n = m.length
        let para = paragraphStyle(t, scale: scale, forEditor: forEditor)
        let segs = (overrideText == nil && n == origLen) ? t.styleSegments() : []
        if segs.isEmpty {
            var a = characterAttributes(t, layer: t, scale: scale, layerScaleInFont: layerScaleInFont)
            a[.paragraphStyle] = para
            if forEditor { a[.lumenCharStyle] = CharStyleBox(CharacterStyle()) }
            if n > 0 { m.setAttributes(a, range: NSRange(location: 0, length: n)) }
        } else {
            for seg in segs {
                var a = characterAttributes(t.applying(seg.style), layer: t, scale: scale, layerScaleInFont: layerScaleInFont)
                a[.paragraphStyle] = para
                if forEditor { a[.lumenCharStyle] = CharStyleBox(seg.style) }
                m.setAttributes(a, range: seg.range)
            }
        }
        return m
    }

    /// Typing/empty-string attributes for the editor.
    static func editorBaseAttributes(_ t: TextContent, style: CharacterStyle = CharacterStyle(), scale: CGFloat) -> [NSAttributedString.Key: Any] {
        var a = characterAttributes(t.applying(style), layer: t, scale: scale, layerScaleInFont: true)
        a[.paragraphStyle] = paragraphStyle(t, scale: scale, forEditor: true)
        a[.lumenCharStyle] = CharStyleBox(style)
        return a
    }

    /// Reads a text layer back from an editor string (text + `.lumenCharStyle` runs), keeping `base`'s defaults.
    static func content(from astr: NSAttributedString, base: TextContent) -> TextContent {
        var t = base
        t.text = astr.string
        var runs: [TextStyleRun] = []
        astr.enumerateAttribute(.lumenCharStyle, in: NSRange(location: 0, length: astr.length), options: []) { v, r, _ in
            guard let box = v as? CharStyleBox, !box.style.isEmpty, r.length > 0 else { return }
            runs.append(TextStyleRun(location: r.location, length: r.length, style: box.style))
        }
        t.runs = runs
        t.normalizeRuns()
        return t
    }

    // MARK: Layout

    static func layout(_ t: TextContent) -> TypeLayout {
        // Layout does not depend on where the layer sits: share it across moves/transforms.
        var k = t
        k.position = .zero; k.transform = .identity; k.antialias = true
        return layoutCache.get(k) { buildLayout(k) }
    }

    private static func buildLayout(_ t: TextContent) -> TypeLayout {
        if let p = t.pathText, !p.path.isEmpty { return pathLayout(t, p) }
        if t.orientation == .vertical { return verticalLayout(t) }
        if t.fitToBox != nil, t.boxSize != nil || t.area != nil { return fittedLayout(t) }
        return horizontalLayout(t)
    }

    static func isNewline(_ c: unichar) -> Bool { c == 10 || c == 13 || c == 0x2029 || c == 0x2028 }

    static func lineMetrics(_ line: CTLine) -> (asc: CGFloat, desc: CGFloat, width: CGFloat, trailing: CGFloat, maxSize: CGFloat) {
        var a: CGFloat = 0, d: CGFloat = 0, l: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &a, &d, &l))
        let tr = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
        var ms: CGFloat = 0
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let f = attrs[kCTFontAttributeName as String] {
                ms = max(ms, CTFontGetSize(f as! CTFont))
            }
        }
        return (a, d, w, tr, ms)
    }

    private static let hyphenLocale = Locale(identifier: "en_US") as CFLocale

    /// Tries to break the word starting at `wordStart` with a hyphen so that [lineStart, h) + "-" fits `avail`.
    static func hyphenatedLine(_ astr: NSAttributedString, lineStart: Int, wordStart: Int, avail: CGFloat) -> ((CTLine, NSAttributedString), Int)? {
        let ns = astr.string as NSString
        let n = ns.length
        var we = wordStart
        while we < n, let sc = UnicodeScalar(ns.character(at: we)), !CharacterSet.whitespacesAndNewlines.contains(sc) { we += 1 }
        let wordLen = we - wordStart
        guard wordLen >= 5 else { return nil }
        let cfs = astr.string as CFString
        var before = we
        while true {
            let h = CFStringGetHyphenationLocationBeforeIndex(cfs, before, CFRange(location: wordStart, length: wordLen), 0, hyphenLocale, nil)
            if h == kCFNotFound || h < wordStart + 2 || h >= before { return nil }
            if we - h >= 2 {
                let sub = NSMutableAttributedString(attributedString: astr.attributedSubstring(from: NSRange(location: lineStart, length: h - lineStart)))
                sub.append(NSAttributedString(string: "-", attributes: astr.attributes(at: h - 1, effectiveRange: nil)))
                let hl = CTLineCreateWithAttributedString(sub)
                let m = lineMetrics(hl)
                if m.width - m.trailing <= avail + 0.01 { return ((hl, sub), h) }
            }
            before = h
        }
    }

    /// Justifies by widening interior word spaces only (Photoshop's default: no letter spacing).
    static func justifiedLine(_ text: NSAttributedString, extra: CGFloat) -> CTLine? {
        guard extra > 0.01 else { return nil }
        let ns = text.string as NSString
        var end = ns.length
        while end > 0, let sc = UnicodeScalar(ns.character(at: end - 1)), CharacterSet.whitespacesAndNewlines.contains(sc) { end -= 1 }
        var spaces: [Int] = []
        for i in 0..<end where ns.character(at: i) == 32 || ns.character(at: i) == 0xA0 || ns.character(at: i) == 9 { spaces.append(i) }
        guard !spaces.isEmpty else { return nil }
        let per = extra / CGFloat(spaces.count)
        let m = NSMutableAttributedString(attributedString: text)
        for i in spaces {
            let k = (m.attribute(.kern, at: i, effectiveRange: nil) as? CGFloat) ?? 0
            m.addAttribute(.kern, value: k + per, range: NSRange(location: i, length: 1))
        }
        return CTLineCreateWithAttributedString(m)
    }

    /// Horizontal layout: point text, paragraph boxes and area type (text inside a closed path), with list markers
    /// and world-ready paragraph direction. Each paragraph gets its own typesetter so bidi levels are per paragraph.
    static func horizontalLayout(_ t: TextContent) -> TypeLayout {
        let astr = attributedString(t)
        let ns = astr.string as NSString
        let n = ns.length
        let box = t.boxSize
        let areaGeo = t.area.flatMap { AreaGeometry($0) }
        let x0: CGFloat = 1
        let W: CGFloat = box.map { max(1, $0.width - 1) } ?? 1_000_000
        let li = CGFloat(t.leftIndent), ri = CGFloat(t.rightIndent), fi = CGFloat(t.firstLineIndent)
        let worldReady = t.composer == .worldReady
        let checkBreaks = t.fitToBox != nil

        // Paragraphs (terminator included; "\r\n" is one terminator).
        var paras: [NSRange] = []
        var ps = 0
        for i in 0..<n where isNewline(ns.character(at: i)) {
            if ns.character(at: i) == 13, i + 1 < n, ns.character(at: i + 1) == 10 { continue }
            paras.append(NSRange(location: ps, length: i + 1 - ps)); ps = i + 1
        }
        if ps < n { paras.append(NSRange(location: ps, length: n - ps)) }

        // List markers
        var markers: [Int: CTLine] = [:]
        var hang: CGFloat = 0
        if let list = t.list {
            var k = 0
            var maxW: CGFloat = 0
            for (pi, r) in paras.enumerated() {
                let body = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty { continue }
                var a = astr.attributes(at: r.location, effectiveRange: nil)
                a[.paragraphStyle] = nil; a[.underlineStyle] = nil; a[.strikethroughStyle] = nil; a[.kern] = nil
                if let c = list.markerColor { a[.foregroundColor] = c.nsColor; if a[.strokeColor] != nil { a[.strokeColor] = c.nsColor } }
                let ml = CTLineCreateWithAttributedString(NSAttributedString(string: list.marker(k), attributes: a))
                maxW = max(maxW, CGFloat(CTLineGetTypographicBounds(ml, nil, nil, nil)))
                markers[pi] = ml
                k += 1
            }
            let em = CGFloat(t.fontSize)
            hang = list.hangingIndent.map { CGFloat($0) } ?? max(ceil(maxW + em * 0.5), em)
        }

        struct L { var line: CTLine; var text: NSAttributedString; var asc: CGFloat; var desc: CGFloat; var width: CGFloat; var maxSize: CGFloat
                   var paraStart: Bool; var paraEnd: Bool; var indent: CGFloat; var rtl: Bool; var marker: CTLine?
                   var bandX: CGFloat; var bandW: CGFloat; var baseline: CGFloat; var range: NSRange }
        var lines: [L] = []
        var y: CGFloat = 0
        var first = true
        var overflow = false, broke = false
        outer: for (pi, pr) in paras.enumerated() {
            let pstr = astr.attributedSubstring(from: pr)
            let pns = pstr.string as NSString
            let plen = pns.length
            let ts = CTTypesetterCreateWithAttributedString(pstr)
            let paraText = pns as String
            let rtl: Bool = {
                if worldReady && t.direction == .rtl { return true }
                if worldReady && t.direction == .ltr { return false }
                return ScriptDirection.isRTL(paraText) ?? false
            }()
            let mirror = worldReady && rtl
            let breaks: Set<Int>? = (checkBreaks || areaGeo != nil) ? lineBreakOpportunities(paraText) : nil
            var p = 0
            var paraStartLine = true
            while p < plen {
                let startIndent = li + (paraStartLine ? fi : 0) + (markers.isEmpty && t.list == nil ? 0 : hang)
                let gap: CGFloat = (!first && paraStartLine) ? CGFloat(t.spaceBefore) + CGFloat(t.spaceAfter) : 0
                var bandX = x0, bandW = W
                var baselineGuess: CGFloat? = nil
                var count = 0
                if let g = areaGeo {
                    // Walk down the shape to the first band wide enough for the next words (narrow tips are skipped
                    // rather than breaking words; a word wider than 60% of the shape may still break).
                    let (ea, ed, elh) = estimatedMetrics(pstr, at: p, t)
                    var base = first ? g.top + ea : y + gap + elh
                    var found = false
                    let minW = startIndent + ri + max(ea * 1.2, 6)
                    while base + ed <= g.bottom + 0.5 {
                        if let iv = g.widestInterval(top: base - ea, bottom: base + ed, minWidth: minW) {
                            let av = max(1, iv.hi - iv.lo - startIndent - ri)
                            let c = max(1, CTTypesetterSuggestLineBreak(ts, p, Double(av)))
                            let nx = min(plen, p + c)
                            let m0 = lineMetrics(CTTypesetterCreateLine(ts, CFRange(location: p, length: nx - p)))
                            let wordOK = nx >= plen || (breaks?.contains(nx) ?? true)
                            if (wordOK && m0.width - m0.trailing <= av + 0.5) || iv.hi - iv.lo >= g.maxWidth * 0.6 {
                                bandX = iv.lo; bandW = iv.hi - iv.lo; count = c; found = true; break
                            }
                        }
                        base += max(1, elh / 6)
                    }
                    if !found { overflow = true; break outer }
                    baselineGuess = base
                }
                let avail = max(1, bandW - startIndent - ri)
                if count <= 0 { count = CTTypesetterSuggestLineBreak(ts, p, Double(avail)) }
                if count <= 0 { count = 1 }
                var next = min(plen, p + count)
                var line = CTTypesetterCreateLine(ts, CFRange(location: p, length: next - p))
                var lineText = pstr.attributedSubstring(from: NSRange(location: p, length: next - p))
                let endsWithNewline = isNewline(pns.character(at: next - 1))
                if t.hyphenate, box != nil, !endsWithNewline, next < plen,
                   let (hl, h) = hyphenatedLine(pstr, lineStart: p, wordStart: next, avail: avail) {
                    line = hl.0; lineText = hl.1; next = h
                } else if let b = breaks, next < plen, !b.contains(next) {
                    broke = true
                }
                let m = lineMetrics(line)
                if m.width - m.trailing > avail + 0.5 { broke = true }
                let lh = t.leading.map { CGFloat($0) } ?? m.maxSize * autoLeadingFactor
                let baseline = baselineGuess ?? (first ? m.asc : y + gap + lh)
                if areaGeo == nil, let b = box, baseline + m.desc > b.height + 0.5 {
                    overflow = true
                    if !first { break outer }
                }
                lines.append(L(line: line, text: lineText, asc: m.asc, desc: m.desc, width: m.width - m.trailing, maxSize: m.maxSize,
                               paraStart: paraStartLine, paraEnd: endsWithNewline || next >= plen, indent: startIndent, rtl: mirror,
                               marker: paraStartLine ? markers[pi] : nil, bandX: bandX, bandW: bandW, baseline: baseline,
                               range: NSRange(location: pr.location + p, length: next - p)))
                y = baseline
                first = false
                paraStartLine = false
                p = next
            }
        }

        let contentW: CGFloat = box != nil ? W : (lines.map { $0.indent + $0.width + ri }.max() ?? 0)
        var placed: [PlacedLine] = []
        var bottom: CGFloat = 0
        var firstExtra: CGFloat = 0
        var maxSize: CGFloat = CGFloat(t.fontSize)
        for (i, l) in lines.enumerated() {
            let lh = t.leading.map { CGFloat($0) } ?? l.maxSize * autoLeadingFactor
            if i == 0 { firstExtra = max(0, lh - l.asc - l.desc) }
            maxSize = max(maxSize, l.maxSize)
            let regionX = areaGeo != nil ? l.bandX : x0
            let regionW = areaGeo != nil ? l.bandW : contentW
            let avail = max(1, regionW - l.indent - ri)
            var line = l.line
            var width = l.width
            let left = regionX + (l.rtl ? ri : l.indent)
            var x = left
            var align = t.alignment
            if box == nil {
                switch align {
                case .justify, .justifyAll: align = l.rtl ? .right : .left
                case .justifyCenter: align = .center
                case .justifyRight: align = .right
                default: break
                }
            }
            switch align {
            case .left: break
            case .center: x += (avail - width) / 2
            case .right: x += avail - width
            case .justify, .justifyCenter, .justifyRight, .justifyAll:
                if !l.paraEnd || align == .justifyAll {
                    if let j = justifiedLine(l.text, extra: avail - width) {
                        line = j; width = avail
                    }
                } else if align == .justifyCenter {
                    x += (avail - width) / 2
                } else if align == .justifyRight || (align == .justify && l.rtl) {
                    x += avail - width
                }
            }
            let tr = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: l.baseline)
            placed.append(PlacedLine(line: line, transform: tr, bounds: CGRect(x: x, y: l.baseline - l.asc, width: width, height: l.asc + l.desc),
                                     textRange: l.range))
            if let mk = l.marker {
                let mw = CGFloat(CTLineGetTypographicBounds(mk, nil, nil, nil))
                let mx = l.rtl ? x + width + hang - mw : x - hang
                let mtr = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: mx, ty: l.baseline)
                placed.append(PlacedLine(line: mk, transform: mtr, bounds: CGRect(x: mx, y: l.baseline - l.asc, width: mw, height: l.asc + l.desc), isMarker: true))
            }
            bottom = l.baseline + l.desc
        }
        let size: CGSize = box ?? CGSize(width: ceil(contentW) + 2, height: ceil(bottom) + 2)
        let out = TypeLayout(lines: placed, baseRect: CGRect(origin: .zero, size: size), firstLineExtra: firstExtra, maxFontSize: maxSize)
        out.overflowed = overflow
        out.brokeWords = broke
        return out
    }

    /// Ascent, descent and line height of the font at `index` (area type band estimation).
    private static func estimatedMetrics(_ s: NSAttributedString, at index: Int, _ t: TextContent) -> (CGFloat, CGFloat, CGFloat) {
        let f = (s.attribute(.font, at: max(0, min(s.length - 1, index)), effectiveRange: nil) as? NSFont) ?? font(t)
        let ct = f as CTFont
        let a = CTFontGetAscent(ct), d = CTFontGetDescent(ct)
        let lh = t.leading.map { CGFloat($0) } ?? CTFontGetSize(ct) * autoLeadingFactor
        return (a, d, lh)
    }

    /// UTF-16 offsets where a line may break (Unicode line-break opportunities, dictionary based for Thai etc.).
    static func lineBreakOpportunities(_ s: String) -> Set<Int> {
        var out = Set<Int>()
        let cf = s as CFString
        let len = CFStringGetLength(cf)
        guard len > 0, let tok = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: len), kCFStringTokenizerUnitLineBreak, nil) else { return out }
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            out.insert(r.location); out.insert(r.location + r.length)
        }
        return out
    }

    /// `t` with all sizes scaled by `s` and `dt` added to tracking (Dynamic Text), fit option removed.
    static func fitScaled(_ t: TextContent, _ s: Double, _ dt: Double) -> TextContent {
        var r = t
        r.fitToBox = nil
        r.fontSize *= s
        r.leading = r.leading.map { $0 * s }
        r.baselineShift *= s
        r.spaceBefore *= s; r.spaceAfter *= s
        if var l = r.list, let h = l.hangingIndent { l.hangingIndent = h * s; r.list = l }
        r.tracking += dt
        r.runs = r.runs.map { run in
            var x = run
            if let f = x.style.fontSize { x.style.fontSize = f * s }
            if let b = x.style.baselineShift { x.style.baselineShift = b * s }
            if dt != 0, let tr = x.style.tracking { x.style.tracking = tr + dt }
            return x
        }
        return r
    }

    /// Dynamic Text: largest uniform size scale (then optional extra tracking) at which the text fits its box / shape
    /// without dropping lines or breaking words.
    private static func fittedLayout(_ t: TextContent) -> TypeLayout {
        let fit = t.fitToBox ?? TextFit()
        func scaled(_ s: Double, _ dt: Double) -> TextContent { fitScaled(t, s, dt) }
        func trial(_ s: Double, _ dt: Double = 0) -> TypeLayout { horizontalLayout(scaled(s, dt)) }
        func ok(_ L: TypeLayout) -> Bool { !L.overflowed && !L.brokeWords }
        let sizes = [t.fontSize] + t.runs.compactMap { $0.style.fontSize }
        let big = max(0.01, sizes.max() ?? t.fontSize), small = max(0.01, sizes.min() ?? t.fontSize)
        let sLo = max(0.005, fit.minSize / small)
        let sHi = max(sLo, fit.maxSize / big)
        var lo = sLo, hi = sLo
        if !ok(trial(sLo)) {
            let L = trial(sLo); L.fitScale = CGFloat(sLo); return L
        }
        // bracket
        var s = min(sHi, max(sLo, 1))
        if ok(trial(s)) {
            lo = s
            while lo < sHi {
                s = min(sHi, lo * 2)
                if ok(trial(s)) { lo = s; if s >= sHi { break } } else { hi = s; break }
            }
            if hi <= lo { hi = lo }
        } else {
            hi = s
            while hi / 2 > sLo {
                s = hi / 2
                if ok(trial(s)) { lo = s; break } else { hi = s }
            }
            if lo > hi { lo = sLo }
        }
        if hi > lo {
            for _ in 0..<16 {
                let mid = (lo + hi) / 2
                if ok(trial(mid)) { lo = mid } else { hi = mid }
                if hi - lo < lo * 0.002 { break }
            }
        }
        var best = trial(lo)
        var dtBest = 0.0
        if fit.adjustTracking {
            let n0 = best.lines.filter { !$0.isMarker }.count
            var a = 0.0, b = 1000.0
            for _ in 0..<12 {
                let mid = (a + b) / 2
                let L = trial(lo, mid)
                if ok(L) && L.lines.filter({ !$0.isMarker }).count <= n0 { a = mid } else { b = mid }
            }
            if a > 0.5 { best = trial(lo, a); dtBest = a }
        }
        best.fitScale = CGFloat(lo)
        best.fitTracking = dtBest
        return best
    }

    /// Vertical type: characters stacked upright top-to-bottom, columns progressing right-to-left.
    /// Point text is anchored at its top-right corner (local x ≤ 0); box text fills the box from the right.
    private static func verticalLayout(_ t: TextContent) -> TypeLayout {
        let astr = attributedString(t)
        let ns = astr.string as NSString
        let n = ns.length
        let box = t.boxSize
        let colW = CGFloat(t.leading ?? t.fontSize * Double(autoLeadingFactor))
        let li = CGFloat(t.leftIndent), ri = CGFloat(t.rightIndent), fi = CGFloat(t.firstLineIndent)
        let maxLen = box.map { $0.height } ?? .infinity

        struct Ch { var line: CTLine; var y: CGFloat; var adv: CGFloat; var w: CGFloat; var asc: CGFloat; var desc: CGFloat; var visible: Bool }
        struct Col { var chars: [Ch] = []; var length: CGFloat = 0; var paraStart = false; var paraEnd = false; var start: CGFloat = 0; var size: CGFloat = 0 }
        var cols: [Col] = []
        var cur = Col(); cur.paraStart = true; cur.start = li + fi
        var y = cur.start
        var maxSize = CGFloat(t.fontSize)
        ns.enumerateSubstrings(in: NSRange(location: 0, length: n), options: .byComposedCharacterSequences) { sub, r, _, _ in
            let c0 = ns.character(at: r.location)
            if isNewline(c0) {
                cur.paraEnd = true; cur.length = y
                cols.append(cur)
                cur = Col(); cur.paraStart = true; cur.start = li + fi; y = cur.start
                return
            }
            let line = CTLineCreateWithAttributedString(astr.attributedSubstring(from: r))
            let m = lineMetrics(line)
            maxSize = max(maxSize, m.maxSize)
            let kern = (astr.attribute(.kern, at: r.location, effectiveRange: nil) as? CGFloat) ?? 0
            let isSpace = (sub ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let adv = (isSpace ? (m.asc + m.desc) * 0.5 : (m.asc + m.desc)) + kern
            if y + adv > maxLen - ri, !cur.chars.isEmpty, !isSpace {
                // wrap at the last word boundary of the column when possible
                var carry: [Ch] = []
                if let k = cur.chars.lastIndex(where: { !$0.visible }), k < cur.chars.count - 1, k > 0 {
                    carry = Array(cur.chars[(k + 1)...])
                    cur.length = cur.chars[k].y
                    cur.chars.removeSubrange(k...)
                } else {
                    cur.length = y
                }
                cols.append(cur)
                cur = Col(); cur.start = li; y = li
                if let f = carry.first {
                    let shift = f.y - li
                    for var c in carry { c.y -= shift; cur.chars.append(c); cur.size = max(cur.size, c.asc + c.desc) }
                    y = (cur.chars.last.map { $0.y + $0.adv }) ?? li
                }
            }
            cur.size = max(cur.size, m.maxSize)
            cur.chars.append(Ch(line: line, y: y, adv: adv, w: m.width - kern, asc: m.asc, desc: m.desc, visible: !isSpace))
            y += adv
        }
        cur.length = y
        if !cur.chars.isEmpty || cols.isEmpty || cur.paraStart { cols.append(cur) }

        let longest = cols.map { $0.length + ri }.max() ?? 0
        let colLen: CGFloat = box?.height ?? longest
        // x of the right edge of the first column
        var right: CGFloat = box.map { $0.width } ?? 0
        var placed: [PlacedLine] = []
        var minX = right
        for (i, c) in cols.enumerated() {
            if i > 0 && c.paraStart { right -= CGFloat(t.spaceBefore) + CGFloat(cols[i - 1].paraEnd ? t.spaceAfter : 0) }
            let w = t.leading != nil ? colW : max(colW, c.size * autoLeadingFactor)
            if box != nil, right - w < -0.5, i > 0 { break }
            let xc = right - w / 2
            let used = c.length - c.start
            let avail = colLen - c.start - ri
            var off: CGFloat = 0
            switch t.alignment {
            case .center, .justifyCenter: off = (avail - used) / 2
            case .right, .justifyRight: off = avail - used
            default: off = 0
            }
            if box == nil && t.alignment == .center { off = (longest - ri - c.start - used) / 2 }
            for ch in c.chars where ch.visible {
                let x = xc - ch.w / 2
                let top = ch.y + off
                let tr = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: top + ch.asc)
                placed.append(PlacedLine(line: ch.line, transform: tr, bounds: CGRect(x: x, y: top, width: ch.w, height: ch.asc + ch.desc)))
            }
            right -= w
            minX = right
        }
        let rect: CGRect
        if let b = box { rect = CGRect(origin: .zero, size: b) }
        else { rect = CGRect(x: floor(minX) - 1, y: 0, width: ceil(-minX) + 2, height: ceil(colLen) + 2) }
        return TypeLayout(lines: placed, baseRect: rect, firstLineExtra: 0, maxFontSize: maxSize)
    }

    /// Type on a path: the whole string is shaped once (keeps kerning, ligatures and Arabic / Indic joining), then
    /// each glyph cluster is placed at its arc-length position, rotated to the path tangent.
    private static func pathLayout(_ t: TextContent, _ p: TextOnPath) -> TypeLayout {
        let astr = attributedString(t, singleLine: true)
        let ns = astr.string as NSString
        let full = CTLineCreateWithAttributedString(astr)
        let fm = lineMetrics(full)
        let total = fm.width
        let sampler = PathSampler(p.path, flipped: p.flipped)
        var start = CGFloat(p.startOffset)
        switch t.alignment {
        case .center, .justifyCenter: start -= (total - fm.trailing) / 2
        case .right, .justifyRight: start -= total - fm.trailing
        default: break
        }
        // Group glyphs into clusters (by composed character sequence of their string index).
        struct Cluster { var minX: CGFloat = .infinity; var maxX: CGFloat = -.infinity; var slices: [RunSlice] = []; var loc: Int = 0 }
        var clusters: [Int: Cluster] = [:]
        for run in CTLineGetGlyphRuns(full) as! [CTRun] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var idx = [CFIndex](repeating: 0, count: count)
            var pos = [CGPoint](repeating: .zero, count: count)
            var adv = [CGSize](repeating: .zero, count: count)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &idx)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &pos)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &adv)
            for g in 0..<count {
                let si = max(0, min(ns.length - 1, idx[g]))
                let cr = ns.rangeOfComposedCharacterSequence(at: si)
                let sub = ns.substring(with: cr)
                if sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                var c = clusters[cr.location] ?? Cluster()
                c.loc = cr.location
                c.minX = min(c.minX, pos[g].x)
                c.maxX = max(c.maxX, pos[g].x + adv[g].width)
                if let last = c.slices.last, last.run === run, last.range.location + last.range.length == g {
                    c.slices[c.slices.count - 1] = RunSlice(run: run, range: CFRange(location: last.range.location, length: last.range.length + 1))
                } else {
                    c.slices.append(RunSlice(run: run, range: CFRange(location: g, length: 1)))
                }
                clusters[cr.location] = c
            }
        }
        var placed: [PlacedLine] = []
        var rect = CGRect.null
        for c in clusters.values.sorted(by: { $0.minX < $1.minX }) {
            let half = max(0, c.maxX - c.minX) / 2
            guard let (pt, ang) = sampler.sample(start + c.minX + half) else { continue }
            let tr = CGAffineTransform(translationX: -(c.minX + half), y: 0)
                .concatenating(CGAffineTransform(scaleX: 1, y: -1))
                .concatenating(CGAffineTransform(rotationAngle: ang))
                .concatenating(CGAffineTransform(translationX: pt.x, y: pt.y))
            let lb = CGRect(x: c.minX, y: -fm.desc, width: c.maxX - c.minX, height: fm.asc + fm.desc).applying(tr)
            rect = rect.union(lb)
            placed.append(PlacedLine(line: full, transform: tr, bounds: lb, textRange: ns.rangeOfComposedCharacterSequence(at: c.loc), slices: c.slices))
        }
        if rect.isNull { rect = sampler.bounds }
        return TypeLayout(lines: placed, baseRect: rect.integral, firstLineExtra: 0, maxFontSize: max(fm.maxSize, CGFloat(t.fontSize)))
    }

    // MARK: Geometry

    /// Local layout size (before position/transform). Box size for paragraph text.
    static func layoutSize(_ t: TextContent) -> CGSize {
        if let b = t.boxSize, t.pathText == nil { return b }
        return layout(t).baseRect.size
    }

    /// Local → doc transform.
    static func docTransform(_ t: TextContent) -> CGAffineTransform {
        if t.pathText != nil { return t.transform }
        return CGAffineTransform(scaleX: CGFloat(t.horizontalScale), y: CGFloat(t.verticalScale))
            .concatenating(CGAffineTransform(translationX: t.position.x, y: t.position.y))
            .concatenating(t.transform)
    }

    static func activeWarp(_ t: TextContent) -> TextWarp? {
        guard let w = t.warp, !w.isIdentity else { return nil }
        return w
    }

    /// Maps a local point through the text warp. Styles are evaluated on the text box (`base`), with displacements
    /// scaled so wide, short text still bends visibly (like Photoshop's envelope, which is not height-bound).
    /// Radial styles (fisheye, twist) use a square domain so they stay round.
    static func warpPoint(_ p: CGPoint, _ w: TextWarp, base: CGRect) -> CGPoint {
        guard base.width > 0, base.height > 0 else { return p }
        let b = w.bend / 100, h = w.horizontalDistortion / 100, vd = w.verticalDistortion / 100
        switch w.style {
        case .fisheye, .twist:
            let side = max(base.width, base.height)
            let u = 0.5 + Double((p.x - base.midX) / side), v = 0.5 + Double((p.y - base.midY) / side)
            let (x, y) = w.style.map(u, v, bend: b, h: h, vd: vd)
            return CGPoint(x: base.midX + CGFloat(x - 0.5) * side, y: base.midY + CGFloat(y - 0.5) * side)
        default:
            let u = Double((p.x - base.minX) / base.width), v = Double((p.y - base.minY) / base.height)
            let (x, y) = w.style.map(u, v, bend: b, h: h, vd: vd)
            let wd = max(base.width, base.height * 0.5), hd = max(base.height, base.width * 0.5)
            return CGPoint(x: p.x + CGFloat(x - u) * wd, y: p.y + CGFloat(y - v) * hd)
        }
    }

    /// Visual rect in local space (warped extent when a warp is set).
    static func localRect(_ t: TextContent) -> CGRect {
        let L = layout(t)
        guard let w = activeWarp(t) else { return L.baseRect }
        let base = L.baseRect
        var pts: [CGPoint] = []
        let k = 16
        for j in 0...k {
            for i in 0...k {
                let p = CGPoint(x: base.minX + base.width * CGFloat(i) / CGFloat(k), y: base.minY + base.height * CGFloat(j) / CGFloat(k))
                pts.append(warpPoint(p, w, base: base))
            }
        }
        return CGRect.bounding(pts)
    }

    /// Text box corners in doc space.
    static func docQuad(_ t: TextContent) -> Quad {
        Quad(rect: localRect(t)).applying(docTransform(t))
    }

    static func docBounds(_ t: TextContent) -> CGRect {
        if t.showsStoredPixels, let b = t.storedPixelsBounds { return b }
        return docQuad(t).bounds
    }

    // MARK: Rendering

    /// Draws the laid-out text into a CG context whose CTM maps local text coords (y-down) to device.
    /// `only`: draw just the glyph runs it accepts (e.g. the colour emoji, see `isColorRun`).
    static func draw(_ t: TextContent, in ctx: CGContext, only: ((CTRun) -> Bool)? = nil) {
        let L = layout(t)
        ctx.saveGState()
        ctx.setShouldAntialias(t.antialias)
        ctx.setShouldSmoothFonts(false)
        ctx.textMatrix = .identity
        for pl in L.lines {
            ctx.saveGState()
            ctx.concatenate(pl.transform)
            ctx.textPosition = .zero
            if let only {
                for x in pl.drawnRuns where only(x.run) { CTRunDraw(x.run, ctx, x.range) }
            } else if let sl = pl.slices {
                for x in sl { CTRunDraw(x.run, ctx, x.range) }
            } else {
                CTLineDraw(pl.line, ctx)
            }
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// Rasterizes local rect `local` (padded) of the text into a CI-space image placed in the document.
    private static func rasterize(_ t: TextContent, local: CGRect, limit: CGRect, space: CanvasSpace, only: ((CTRun) -> Bool)? = nil) -> CIImage {
        let m = docTransform(t)
        var bounds = Quad(rect: local).applying(m).bounds
        bounds = bounds.intersection(limit)
        guard !bounds.isNull else { return CIImage.clearImage.cropped(to: .zero) }
        let r = IRect(enclosing: bounds)
        if r.isEmpty { return CIImage.clearImage.cropped(to: .zero) }
        guard let ctx = CGContext(data: nil, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGBSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return CIImage.clearImage.cropped(to: .zero) }
        ctx.translateBy(x: 0, y: CGFloat(r.height))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -CGFloat(r.x), y: -CGFloat(r.y))
        ctx.concatenate(m)
        draw(t, in: ctx, only: only)
        guard let img = ctx.makeImage() else { return CIImage.clearImage.cropped(to: .zero) }
        return space.place(CIImage(cgImage: img), docOrigin: r.origin, size: (r.width, r.height))
    }

    /// Renders the text layer into a CI-space image (`only`: just the glyph runs it accepts, see `draw`).
    static func render(_ t: TextContent, space: CanvasSpace, only: ((CTRun) -> Bool)? = nil) -> CIImage {
        if only == nil, let img = t.storedPixelsImage(space: space) { return img }   // missing font: Photoshop's pixels until edited
        let L = layout(t)
        let pad = L.maxFontSize * 0.35 + 4
        let local = L.baseRect.insetBy(dx: -pad, dy: -pad)
        guard let w = activeWarp(t) else {
            let limit = CGRect(x: 0, y: 0, width: space.width, height: space.height).insetBy(dx: -64, dy: -64)
            return rasterize(t, local: local, limit: limit, space: space, only: only)
        }
        // Warp Text: rasterize unwarped (generous limit), then mesh-warp in local space.
        let limit = CGRect(x: -space.width, y: -space.height, width: space.width * 3, height: space.height * 3)
        let img = rasterize(t, local: local, limit: limit, space: space, only: only)
        let m = docTransform(t)
        let base = L.baseRect
        let cols = 48, rows = 32
        let from = MeshGrid.regular(local, cols: cols, rows: rows)
        let to = MeshGrid(cols: cols, rows: rows, positions: from.positions.map { warpPoint($0, w, base: base).applying(m) })
        let fromDoc = MeshGrid(cols: cols, rows: rows, positions: from.positions.map { $0.applying(m) })
        return MeshWarp.warp(img, from: fromDoc, to: to, space: space)
    }

    /// A run drawn with a colour font (Apple Color Emoji: bitmap glyphs, no outlines).
    static func isColorRun(_ run: CTRun) -> Bool {
        guard let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] else { return false }
        return CTFontGetSymbolicTraits(f as! CTFont).contains(.traitColorGlyphs)
    }

    /// The layer draws colour glyphs (emoji), which `outlinePath` can't include.
    static func hasColorGlyphs(_ t: TextContent) -> Bool {
        layout(t).lines.contains { $0.drawnRuns.contains { isColorRun($0.run) } }
    }

    /// Glyph outlines in doc space (for Convert to Shape / Create Work Path). Colour glyphs have none.
    static func outlinePath(_ t: TextContent) -> CGPath {
        let L = layout(t)
        let local = CGMutablePath()
        for pl in L.lines {
            for sl in pl.drawnRuns {
                let run = sl.run
                let attrs = CTRunGetAttributes(run) as NSDictionary
                guard let fo = attrs[kCTFontAttributeName as String] else { continue }
                let runFont = fo as! CTFont
                let count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
                let gEnd = sl.range.length > 0 ? min(count, sl.range.location + sl.range.length) : count
                for g in sl.range.location..<gEnd {
                    guard let gp = CTFontCreatePathForGlyph(runFont, glyphs[g], nil) else { continue }
                    let tr = CGAffineTransform(translationX: positions[g].x, y: positions[g].y).concatenating(pl.transform)
                    local.addPath(gp, transform: tr)
                }
            }
        }
        var path: CGPath = local
        if let w = activeWarp(t) {
            let base = L.baseRect
            path = mapPath(local) { warpPoint($0, w, base: base) }
        }
        let out = CGMutablePath()
        out.addPath(path, transform: docTransform(t))
        return out
    }

    /// Maps every point of a path (control points included); straight segments are subdivided so they can bend.
    static func mapPath(_ p: CGPath, maxSegment: CGFloat = 4, _ f: (CGPoint) -> CGPoint) -> CGPath {
        let out = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        func line(to b: CGPoint) {
            let n = max(1, Int(ceil(cur.distance(to: b) / maxSegment)))
            for i in 1...n {
                let u = CGFloat(i) / CGFloat(n)
                out.addLine(to: f(CGPoint(x: cur.x + (b.x - cur.x) * u, y: cur.y + (b.y - cur.y) * u)))
            }
            cur = b
        }
        p.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                cur = e.points[0]; start = cur
                out.move(to: f(cur))
            case .addLineToPoint: line(to: e.points[0])
            case .addQuadCurveToPoint:
                out.addQuadCurve(to: f(e.points[1]), control: f(e.points[0])); cur = e.points[1]
            case .addCurveToPoint:
                out.addCurve(to: f(e.points[2]), control1: f(e.points[0]), control2: f(e.points[1])); cur = e.points[2]
            case .closeSubpath:
                if cur.distance(to: start) > 0.01 { line(to: start) }
                out.closeSubpath(); cur = start
            @unknown default: break
            }
        }
        return out
    }
}

// MARK: - Path sampling (type on a path)

/// Arc-length parameterization of a vector path's first open/closed subpath.
struct PathSampler {
    private(set) var points: [CGPoint] = []
    private(set) var cumulative: [CGFloat] = []
    private(set) var closed = false
    var total: CGFloat { cumulative.last ?? 0 }

    init(_ vp: VectorPath, flipped: Bool = false) {
        guard let sp = vp.subpaths.first(where: { $0.points.count >= 2 }) else { return }
        closed = sp.closed
        var pts: [CGPoint] = [sp.points[0].anchor]
        func seg(_ a: PathPoint, _ b: PathPoint) {
            if a.outControl == a.anchor && b.inControl == b.anchor {
                pts.append(b.anchor)
                return
            }
            let steps = 32
            for i in 1...steps {
                let u = CGFloat(i) / CGFloat(steps), v = 1 - u
                let p0 = a.anchor, p1 = a.outControl, p2 = b.inControl, p3 = b.anchor
                let x = v * v * v * p0.x + 3 * v * v * u * p1.x + 3 * v * u * u * p2.x + u * u * u * p3.x
                let y = v * v * v * p0.y + 3 * v * v * u * p1.y + 3 * v * u * u * p2.y + u * u * u * p3.y
                pts.append(CGPoint(x: x, y: y))
            }
        }
        for i in 1..<sp.points.count { seg(sp.points[i - 1], sp.points[i]) }
        if sp.closed { seg(sp.points[sp.points.count - 1], sp.points[0]) }
        if flipped { pts.reverse() }
        // drop duplicates
        var clean: [CGPoint] = []
        for p in pts where clean.last.map({ $0.distance(to: p) > 1e-4 }) ?? true { clean.append(p) }
        points = clean
        var c: [CGFloat] = [0]
        for i in 1..<max(1, clean.count) { c.append(c[i - 1] + clean[i - 1].distance(to: clean[i])) }
        cumulative = c
    }

    var bounds: CGRect { points.isEmpty ? .zero : CGRect.bounding(points) }

    /// Point and tangent angle at arc length `s` (wraps on closed paths; nil beyond the ends of open paths).
    func sample(_ s: CGFloat) -> (CGPoint, CGFloat)? {
        guard points.count >= 2, total > 0 else { return nil }
        var s = s
        if closed {
            s = s.truncatingRemainder(dividingBy: total)
            if s < 0 { s += total }
        } else if s < -0.5 || s > total + 0.5 {
            return nil
        }
        s = min(max(s, 0), total)
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let segLen = cumulative[hi] - cumulative[lo]
        let f = segLen > 0 ? (s - cumulative[lo]) / segLen : 0
        let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
        // smooth the tangent over a small window
        let w: CGFloat = 2
        let pa = point(at: s - w) ?? a, pb = point(at: s + w) ?? b
        let ang = atan2(pb.y - pa.y, pb.x - pa.x)
        return (p, ang)
    }

    private func point(at s: CGFloat) -> CGPoint? {
        var s = s
        if closed {
            s = s.truncatingRemainder(dividingBy: total)
            if s < 0 { s += total }
        } else if s < 0 || s > total { return nil }
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if cumulative[mid] <= s { lo = mid } else { hi = mid }
        }
        let a = points[lo], b = points[hi]
        let segLen = cumulative[hi] - cumulative[lo]
        let f = segLen > 0 ? (s - cumulative[lo]) / segLen : 0
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }

    /// Arc length of the point on the path nearest `p`, and its distance.
    func nearest(_ p: CGPoint) -> (s: CGFloat, distance: CGFloat) {
        var best: (CGFloat, CGFloat) = (0, .infinity)
        guard points.count >= 2 else { return best }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let l2 = ab.x * ab.x + ab.y * ab.y
            var f: CGFloat = 0
            if l2 > 0 { f = min(1, max(0, ((p.x - a.x) * ab.x + (p.y - a.y) * ab.y) / l2)) }
            let q = CGPoint(x: a.x + ab.x * f, y: a.y + ab.y * f)
            let d = q.distance(to: p)
            if d < best.1 { best = (cumulative[i - 1] + (cumulative[i] - cumulative[i - 1]) * f, d) }
        }
        return best
    }
}
