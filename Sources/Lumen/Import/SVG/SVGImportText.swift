import AppKit
import CoreText
import ImageCratCore

// SVG import, part 8: text.
//
// Plain runs of text (one or more lines, each starting at an absolute position, solid fill) become editable text
// layers placed so that the baseline lands where SVG puts it. Text with per-character positioning, rotation, stroke
// or a gradient fill is laid out here with Core Text following the SVG rules and becomes outline shapes. Text on a
// path, vertical and right-to-left text are rasterized.

extension SVGImportBuilder {
    struct TextChar {
        var s: String
        var run: Int
        var x: Double? = nil, y: Double? = nil
        var dx = 0.0, dy = 0.0
        var rotate: Double? = nil
    }
    struct TextRun {
        var style: SVGImportStyle
        var node: SVGImportNode
        /// Upward shift of the baseline, user units.
        var baselineShift = 0.0
    }
    struct TextModel {
        var chars: [TextChar] = []
        var runs: [TextRun] = []
        var hasTextPath = false
        var hasTextLength = false
        /// Indices where a new text chunk starts (absolute x or y).
        var chunkStarts: [Int] {
            var out = [0]
            for (i, c) in chars.enumerated() where i > 0 && (c.x != nil || c.y != nil) { out.append(i) }
            return out
        }
        var string: String { chars.map(\.s).joined() }
    }

    // MARK: Model

    func textModel(_ n: SVGImportNode, _ ctx: Context) -> TextModel {
        var m = TextModel()
        struct Raw { var s: String; var run: Int; var preserve: Bool }
        var raw: [Raw] = []
        struct Span { var node: SVGImportNode; var start: Int; var end: Int; var style: SVGImportStyle }
        var spans: [Span] = []
        func walk(_ e: SVGImportNode, _ style: SVGImportStyle, _ shift: Double, _ depth: Int) {
            guard depth < 32, raw.count < 200_000 else { return }
            let start = raw.count
            var run: Int? = nil
            for c in e.children {
                if c.isText {
                    if run == nil { m.runs.append(TextRun(style: style, node: e, baselineShift: shift)); run = m.runs.count - 1 }
                    for ch in c.text { raw.append(Raw(s: String(ch), run: run!, preserve: style.preserveSpace)) }
                } else if c.isSVG, c.tag == "tspan" || c.tag == "a" || c.tag == "textPath" || c.tag == "tref" {
                    if c.tag == "textPath" { m.hasTextPath = true }
                    var st = style
                    st.apply(c, viewport: ctx.viewport)
                    if st.own(c, "display")?.lowercased() == "none" { continue }
                    var sh = shift
                    if let bs = st.own(c, "baseline-shift")?.lowercased() {
                        let f = TextRenderer.makeFont(name: SVGImportFonts.resolve(st.fontFamilies, weight: st.fontWeight, italic: st.italic).postScriptName, size: CGFloat(st.fontSize))
                        let height = Double(CTFontGetAscent(f) + CTFontGetDescent(f))
                        switch bs {
                        case "sub": sh -= height / 2
                        case "super": sh += height / 2
                        case "baseline": break
                        default: if let l = SVGImportValue.length(bs) { sh += l.resolve(percentOf: st.fontSize, fontSize: st.fontSize) }
                        }
                    }
                    walk(c, st, sh, depth + 1)
                    run = nil       // text after the child is a new run of this element
                }
            }
            spans.append(Span(node: e, start: start, end: raw.count, style: style))
            if e.attrs["textLength"] != nil { m.hasTextLength = true }
        }
        walk(n, ctx.style, 0, 0)

        // white space: sequences collapse to one space and the ends are trimmed, unless preserved
        var keep = [Int?](repeating: nil, count: raw.count)
        var lastSpace = true
        var lastCollapsible: Int? = nil
        for (i, r) in raw.enumerated() {
            let isSpace = r.s == " " || r.s == "\t" || r.s == "\n" || r.s == "\r" || r.s == "\r\n"
            if isSpace && !r.preserve {
                if lastSpace { continue }
                lastSpace = true
                lastCollapsible = m.chars.count
            } else {
                lastSpace = false
                lastCollapsible = nil
            }
            keep[i] = m.chars.count
            m.chars.append(TextChar(s: isSpace ? " " : r.s, run: r.run))
        }
        if let l = lastCollapsible, l == m.chars.count - 1 {
            m.chars.removeLast()
            for i in keep.indices where keep[i] == l { keep[i] = nil }
        }

        // positioning lists: the innermost element that gives a value for a character wins
        // (spans are in post-order, so inner elements come first)
        for sp in spans {
            let idx = (sp.start..<sp.end).compactMap { keep[$0] }
            guard !idx.isEmpty else { continue }
            let em = sp.style.fontSize
            func list(_ name: String, _ ref: CGFloat) -> [Double] {
                SVGImportValue.lengths(sp.node.attrs[name]).map { $0.resolve(percentOf: Double(ref), fontSize: em) }
            }
            let xs = list("x", ctx.viewport.width), ys = list("y", ctx.viewport.height)
            let dxs = list("dx", ctx.viewport.width), dys = list("dy", ctx.viewport.height)
            let rots = SVGImportValue.numbers(sp.node.attrs["rotate"])
            for (k, ci) in idx.enumerated() {
                if k < xs.count, m.chars[ci].x == nil { m.chars[ci].x = xs[k] }
                if k < ys.count, m.chars[ci].y == nil { m.chars[ci].y = ys[k] }
                // relative shifts of nested elements add up
                if k < dxs.count { m.chars[ci].dx += dxs[k] }
                if k < dys.count { m.chars[ci].dy += dys[k] }
                if !rots.isEmpty, m.chars[ci].rotate == nil { m.chars[ci].rotate = rots[min(k, rots.count - 1)] }
            }
        }
        return m
    }

    /// Natural advance of a run of characters (user units), as Core Text sets them with the runs' fonts and spacing.
    private func advance(_ m: TextModel, _ range: Range<Int>) -> Double {
        var total = 0.0
        var i = range.lowerBound
        while i < range.upperBound {
            let run = m.chars[i].run
            var j = i
            var str = ""
            while j < range.upperBound, m.chars[j].run == run { str += m.chars[j].s; j += 1 }
            let st = m.runs[run].style
            let (f, _) = font(st)
            let a = NSAttributedString(string: st.upper ? str.uppercased() : str, attributes: [.font: f as NSFont, .kern: CGFloat(st.letterSpacing)])
            total += CTLineGetTypographicBounds(CTLineCreateWithAttributedString(a), nil, nil, nil)
            i = j
        }
        return total
    }

    /// Illustrator and other exporters break a line into several positioned `<tspan>`s that simply continue where the
    /// previous one ended. Those positions are dropped so the line is one chunk again.
    private func joiningContinuations(_ model: TextModel) -> TextModel {
        var m = model
        let starts = m.chunkStarts
        guard starts.count > 1, starts.count < 2000 else { return m }
        var penX = 0.0, penY = 0.0
        for (k, s) in starts.enumerated() {
            let e = k + 1 < starts.count ? starts[k + 1] : m.chars.count
            let c = m.chars[s]
            let st = m.runs[c.run].style
            let y = (c.y ?? penY) + c.dy
            if k > 0, let x = c.x, st.anchor == 0, abs(c.dx) < 1e-9, abs(y - penY) < 0.01, abs(x - penX) <= max(0.5, st.fontSize * 0.04) {
                m.chars[s].x = nil; m.chars[s].y = nil; m.chars[s].dy = 0
                penX += advance(m, s..<e)
            } else {
                penX = (c.x ?? penX) + c.dx + advance(m, s..<e)
                penY = y
            }
        }
        return m
    }

    private func isSimple(_ m: TextModel) -> Bool {
        let starts = Set(m.chunkStarts)
        for (i, c) in m.chars.enumerated() {
            if let r = c.rotate, abs(r) > 1e-6 { return false }
            if !starts.contains(i) && (abs(c.dx) > 1e-6 || abs(c.dy) > 1e-6) { return false }
            // a chunk that only moves vertically continues at the pen position, which a text layer cannot express
            if i > 0, starts.contains(i), c.x == nil { return false }
        }
        for r in m.runs {
            let st = r.style
            if st.stroke != .none && st.strokeWidth > 0 && st.strokeOpacity > 0 { return false }
            switch st.fill {
            case .server(let id, _): if doc.ids[id] != nil { return false }
            default: break
            }
            if abs(st.wordSpacing) > 1e-6 { return false }
        }
        return true
    }

    private func hasEmoji(_ m: TextModel) -> Bool {
        m.chars.contains { $0.s.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F } }
    }

    func textRasterReason(_ n: SVGImportNode, _ ctx: Context) -> String? {
        let m = textModel(n, ctx)
        if m.chars.isEmpty { return nil }
        if m.hasTextPath { return "text on a path" }
        if m.runs.contains(where: { $0.style.vertical }) { return "vertical text" }
        if m.runs.contains(where: { $0.style.rtl }) { return "right-to-left text" }
        if m.hasTextLength { return "text with textLength" }
        for r in m.runs {
            for p in [r.style.fill, r.style.stroke] { if case .server(let id, _) = p, doc.ids[id]?.tag == "pattern" { return "pattern-filled text" } }
        }
        if !isSimple(m) && hasEmoji(m) { return "positioned emoji" }
        return nil
    }

    // MARK: Fonts and metrics

    private func font(_ st: SVGImportStyle, size: Double? = nil) -> (CTFont, SVGImportFontMatch) {
        let match = SVGImportFonts.resolve(st.fontFamilies, weight: st.fontWeight, italic: st.italic)
        return (TextRenderer.makeFont(name: match.postScriptName, size: CGFloat(size ?? st.fontSize), italic: match.fauxItalic), match)
    }

    /// Downward offset of the alphabetic baseline for `dominant-baseline`, in font units at the font's size.
    private func baselineOffset(_ st: SVGImportStyle, _ f: CTFont) -> Double {
        let asc = Double(CTFontGetAscent(f)), desc = Double(CTFontGetDescent(f))
        switch st.baseline {
        case "middle": return Double(CTFontGetXHeight(f)) / 2
        case "central": return (asc - desc) / 2
        case "hanging": return asc * 0.8
        case "mathematical": return asc / 2
        case "text-before-edge", "before-edge", "text-top": return asc
        case "text-after-edge", "after-edge", "text-bottom", "ideographic": return -desc
        default: return 0
        }
    }

    // MARK: Building

    func text(_ n: SVGImportNode, _ ctx: Context) -> [Layer] {
        let m = textModel(n, ctx)
        guard !m.chars.isEmpty, !m.string.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        // nothing to see: no fill and no stroke anywhere
        let painted = m.runs.contains { r in
            let st = r.style
            guard st.visible else { return false }
            let stroked = st.stroke != .none && st.strokeWidth > 0 && st.strokeOpacity > 0
            return stroked || (st.fill != .none && st.fillOpacity > 0)
        }
        guard painted else { report.invisible += 1; return [] }
        let joined = joiningContinuations(m)
        if isSimple(joined), let layers = textLayers(joined, ctx), !layers.isEmpty { return layers }
        return outlineLayers(n, m, ctx)
    }

    private func noteFont(_ match: SVGImportFontMatch) {
        if !match.found, !match.requested.isEmpty { report.missingFonts[match.requested] = match.postScriptName }
    }

    /// Editable text layers: one for the whole element when its chunks are evenly spaced lines, else one per chunk.
    private func textLayers(_ m: TextModel, _ ctx: Context) -> [Layer]? {
        struct Chunk { var range: Range<Int>; var x: Double; var y: Double; var anchor: Int }
        var chunks: [Chunk] = []
        let starts = m.chunkStarts
        var penY = 0.0
        for (k, s) in starts.enumerated() {
            let e = k + 1 < starts.count ? starts[k + 1] : m.chars.count
            let c = m.chars[s]
            penY = (c.y ?? penY) + c.dy
            chunks.append(Chunk(range: s..<e, x: (c.x ?? 0) + c.dx, y: penY, anchor: m.runs[c.run].style.anchor))
        }
        chunks = chunks.filter { !$0.range.isEmpty }
        guard !chunks.isEmpty else { return nil }
        // evenly spaced lines with a common anchor point form one paragraph
        var lines = true
        if chunks.count > 1 {
            let step = chunks[1].y - chunks[0].y
            let size = m.runs[m.chars[chunks[0].range.lowerBound].run].style.fontSize
            if step < size * 0.5 || step > size * 4 { lines = false }
            for i in 1..<chunks.count {
                if abs(chunks[i].x - chunks[0].x) > 0.01 || chunks[i].anchor != chunks[0].anchor || abs((chunks[i].y - chunks[i - 1].y) - step) > 0.02 { lines = false }
            }
            // a line that ends in a preserved space would shift centred / right-aligned lines
        }
        // positioned single letters are per-glyph layout, not text anyone would edit piece by piece
        if !lines, chunks.count >= 3, chunks.contains(where: { r in m.chars[r.range].filter { $0.s != " " }.count <= 1 }) { return nil }
        if !lines, chunks.count > 40 { return nil }
        let groups: [[Chunk]] = lines ? [chunks] : chunks.map { [$0] }
        var out: [Layer] = []
        for g in groups {
            guard let l = textLayer(m, g.map(\.range), x: g[0].x, y: g[0].y, step: g.count > 1 ? g[1].y - g[0].y : nil, ctx) else { return nil }
            out.append(l)
        }
        report.texts += out.count
        return out
    }

    private func textLayer(_ m: TextModel, _ lines: [Range<Int>], x: Double, y: Double, step: Double?, _ ctx: Context) -> Layer? {
        let ctm = ctx.ctm
        let s = Double(ctm.meanScale)
        guard s > 1e-9 else { return nil }
        let first = m.runs[m.chars[lines[0].lowerBound].run]
        let base = first.style
        let (baseFont, baseMatch) = font(base)
        noteFont(baseMatch)
        guard case let fillColor? = color(of: base) else { return nil }
        var t = TextContent()
        t.fontName = baseMatch.postScriptName
        t.fontSize = base.fontSize * s
        guard t.fontSize >= 0.1 else { return nil }
        t.color = fillColor
        t.tracking = base.fontSize > 0 ? base.letterSpacing / base.fontSize * 1000 : 0
        t.fauxBold = baseMatch.fauxBold
        t.fauxItalic = baseMatch.fauxItalic
        t.underline = base.underline
        t.strikethrough = base.strike
        t.allCaps = base.upper
        t.features.smallCaps = base.smallCaps
        t.alignment = base.anchor == 1 ? .center : (base.anchor == 2 ? .right : .left)
        if let st = step { t.leading = st * s }
        // text and style runs
        var text = ""
        var runs: [TextStyleRun] = []
        for (li, r) in lines.enumerated() {
            if li > 0 { text += "\n" }
            var i = r.lowerBound
            // trailing collapsed space of a line is not drawn and would offset centred lines
            var end = r.upperBound
            while end > i, m.chars[end - 1].s == " ", lines.count > 1 { end -= 1 }
            while i < end {
                let run = m.chars[i].run
                var j = i
                var piece = ""
                while j < end, m.chars[j].run == run { piece += m.chars[j].s; j += 1 }
                let loc = (text as NSString).length
                text += piece
                let rs = m.runs[run].style
                var cs = CharacterStyle()
                let (_, match) = font(rs)
                noteFont(match)
                if match.postScriptName != t.fontName { cs.fontName = match.postScriptName }
                if abs(rs.fontSize - base.fontSize) > 1e-6 { cs.fontSize = rs.fontSize * s }
                guard let c = color(of: rs) else { return nil }
                if c != t.color { cs.color = c }
                let tr = rs.fontSize > 0 ? rs.letterSpacing / rs.fontSize * 1000 : 0
                if abs(tr - t.tracking) > 1e-6 { cs.tracking = tr }
                if match.fauxBold != t.fauxBold { cs.fauxBold = match.fauxBold }
                if match.fauxItalic != t.fauxItalic { cs.fauxItalic = match.fauxItalic }
                if rs.underline != t.underline { cs.underline = rs.underline }
                if rs.strike != t.strikethrough { cs.strikethrough = rs.strike }
                let shift = (m.runs[run].baselineShift - first.baselineShift) * s
                if abs(shift) > 1e-6 { cs.baselineShift = shift }
                if !cs.isEmpty { runs.append(TextStyleRun(location: loc, length: (piece as NSString).length, style: cs)) }
                i = j
            }
        }
        guard !text.isEmpty else { return nil }
        t.text = text
        t.runs = runs
        t.normalizeRuns()
        // placement: the anchor point on the first baseline goes to (x, y)
        let L = TextRenderer.layout(t)
        guard let pl = L.lines.first(where: { !$0.isMarker }) else { return nil }
        let origin = CGPoint.zero.applying(pl.transform)
        let frac: CGFloat = base.anchor == 1 ? 0.5 : (base.anchor == 2 ? 1 : 0)
        let anchor = CGPoint(x: origin.x + pl.bounds.width * frac, y: origin.y)
        let yAdj = y + baselineOffset(base, baseFont) - first.baselineShift
        let target = CGPoint(x: x * s, y: yAdj * s)
        let linear = CGAffineTransform(a: ctm.a / CGFloat(s), b: ctm.b / CGFloat(s), c: ctm.c / CGFloat(s), d: ctm.d / CGFloat(s), tx: ctm.tx, ty: ctm.ty)
        if abs(linear.a - 1) < 1e-9, abs(linear.d - 1) < 1e-9, abs(linear.b) < 1e-9, abs(linear.c) < 1e-9 {
            t.position = CGPoint(x: target.x - anchor.x + linear.tx, y: target.y - anchor.y + linear.ty)
        } else {
            t.position = CGPoint(x: target.x - anchor.x, y: target.y - anchor.y)
            t.transform = linear
        }
        let name = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return Layer(name: name.isEmpty ? "Text" : String(name.prefix(40)), content: .text(t))
    }

    /// Solid text colour of a run; nil when its fill is not a plain colour.
    private func color(of st: SVGImportStyle) -> RGBA? {
        switch st.fill {
        case .color(let c): return c.withAlpha(c.a * st.fillOpacity)
        case .currentColor: return st.color.withAlpha(st.color.a * st.fillOpacity)
        case .none: return RGBA.clear
        case .server(_, let fb):
            // only reached for references that do not exist
            var f = st
            f.fill = fb ?? .none
            return color(of: f)
        }
    }

    // MARK: Outlines (SVG text layout)

    struct TextPiece { var run: Int; var path: CGPath }

    /// Lays the text out by the SVG rules. Paths and the bounding box are in the text element's user space.
    func textGeometry(_ m: TextModel) -> (pieces: [TextPiece], bbox: CGRect) {
        var pieces: [TextPiece] = []
        var box = CGRect.null
        var pen = CGPoint.zero
        let starts = m.chunkStarts
        for (k, s) in starts.enumerated() {
            let e = k + 1 < starts.count ? starts[k + 1] : m.chars.count
            guard s < e else { continue }
            var chunk: [(run: Int, path: CGPath, box: CGRect)] = []
            var startX: CGFloat = 0
            var i = s
            while i < e {
                let c = m.chars[i]
                if i == s {
                    if let x = c.x { pen.x = CGFloat(x) }
                    if let y = c.y { pen.y = CGFloat(y) }
                }
                pen.x += CGFloat(c.dx); pen.y += CGFloat(c.dy)
                if i == s { startX = pen.x }
                // a segment: same run, no further positioning inside
                let rotated = c.rotate.map { abs($0) > 1e-6 } ?? false
                var j = i + 1
                if !rotated {
                    while j < e, m.chars[j].run == c.run, abs(m.chars[j].dx) < 1e-9, abs(m.chars[j].dy) < 1e-9, !(m.chars[j].rotate.map { abs($0) > 1e-6 } ?? false) { j += 1 }
                }
                let run = m.runs[c.run]
                let st = run.style
                let (f, match) = font(st)
                noteFont(match)
                var str = m.chars[i..<j].map(\.s).joined()
                if st.upper { str = str.uppercased() }
                let a = NSMutableAttributedString(string: str, attributes: [.font: f as NSFont, .kern: CGFloat(st.letterSpacing)])
                if abs(st.wordSpacing) > 1e-9 {
                    let ns = str as NSString
                    for q in 0..<ns.length where ns.character(at: q) == 32 { a.addAttribute(.kern, value: CGFloat(st.letterSpacing + st.wordSpacing), range: NSRange(location: q, length: 1)) }
                }
                let line = CTLineCreateWithAttributedString(a)
                var asc: CGFloat = 0, desc: CGFloat = 0
                let adv = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
                let baseY = pen.y + CGFloat(baselineOffset(st, f) - run.baselineShift)
                var place = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: pen.x, ty: baseY)
                if rotated, let r = c.rotate {
                    place = place.concatenating(CGAffineTransform(translationX: -pen.x, y: -baseY)).concatenating(CGAffineTransform(rotationAngle: CGFloat(r * .pi / 180)))
                        .concatenating(CGAffineTransform(translationX: pen.x, y: baseY))
                }
                let p = CGMutablePath()
                for ctRun in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
                    let attrs = CTRunGetAttributes(ctRun) as NSDictionary
                    guard let fo = attrs[kCTFontAttributeName as String] else { continue }
                    let runFont = fo as! CTFont
                    let count = CTRunGetGlyphCount(ctRun)
                    guard count > 0 else { continue }
                    var glyphs = [CGGlyph](repeating: 0, count: count)
                    var positions = [CGPoint](repeating: .zero, count: count)
                    CTRunGetGlyphs(ctRun, CFRange(location: 0, length: count), &glyphs)
                    CTRunGetPositions(ctRun, CFRange(location: 0, length: count), &positions)
                    for g in 0..<count {
                        guard let gp = CTFontCreatePathForGlyph(runFont, glyphs[g], nil) else { continue }
                        p.addPath(gp, transform: CGAffineTransform(translationX: positions[g].x, y: positions[g].y).concatenating(place))
                    }
                }
                // decorations as thin bars
                func bar(_ offsetUp: CGFloat, _ thickness: CGFloat) {
                    let r = CGRect(x: 0, y: offsetUp - thickness / 2, width: adv, height: thickness)
                    p.addPath(CGPath(rect: r, transform: nil), transform: place)
                }
                if st.underline { bar(CTFontGetUnderlinePosition(f), max(CTFontGetUnderlineThickness(f), 0.5)) }
                if st.strike { bar(CTFontGetXHeight(f) / 2, max(CTFontGetUnderlineThickness(f), 0.5)) }
                let cell = CGRect(x: 0, y: -desc, width: adv, height: asc + desc).applying(place)
                chunk.append((c.run, p, cell))
                pen.x += adv
                i = j
            }
            // text-anchor moves the whole chunk
            let anchor = m.runs[m.chars[s].run].style.anchor
            let shift: CGFloat = anchor == 1 ? -(pen.x - startX) / 2 : (anchor == 2 ? -(pen.x - startX) : 0)
            for c in chunk {
                var t = CGAffineTransform(translationX: shift, y: 0)
                if let moved = c.path.copy(using: &t), !moved.isEmpty { pieces.append(TextPiece(run: c.run, path: moved)) }
                box = box.union(c.box.offsetBy(dx: shift, dy: 0))
            }
            pen.x += shift
        }
        return (pieces, box)
    }

    /// Glyph outlines of a text element through `ctx.ctm` (clip paths, bounding boxes).
    func textOutline(_ n: SVGImportNode, _ ctx: Context) -> CGPath? {
        let m = textModel(n, ctx)
        guard !m.chars.isEmpty else { return nil }
        let p = CGMutablePath()
        for piece in textGeometry(m).pieces { p.addPath(piece.path, transform: ctx.ctm) }
        return p.isEmpty ? nil : p
    }

    private func outlineLayers(_ n: SVGImportNode, _ m: TextModel, _ ctx: Context) -> [Layer] {
        let (pieces, bbox) = textGeometry(m)
        guard !pieces.isEmpty else { return [] }
        // consecutive pieces painted alike become one shape
        var out: [Layer] = []
        var i = 0
        let label = m.string.trimmingCharacters(in: .whitespaces)
        while i < pieces.count {
            let st = m.runs[pieces[i].run].style
            let p = CGMutablePath()
            var j = i
            while j < pieces.count {
                let s2 = m.runs[pieces[j].run].style
                guard s2.fill == st.fill, s2.stroke == st.stroke, s2.fillOpacity == st.fillOpacity, s2.strokeOpacity == st.strokeOpacity,
                      s2.strokeWidth == st.strokeWidth, s2.color == st.color else { break }
                p.addPath(pieces[j].path)
                j += 1
            }
            var c = ctx
            c.style = st
            // glyph outlines are wound for the non-zero rule whatever the text's fill-rule says
            c.style.evenOdd = false
            out += shapeLayers(SVGImportShape(path: p, kind: .path, defaultName: "Text"), c, name: label.isEmpty ? "Text" : String(label.prefix(40)),
                               bboxOverride: bbox.isNull ? nil : bbox)
            i = j
        }
        if !out.isEmpty {
            report.outlinedTexts += 1
            report.note(.substituted, "Text with per-character positioning, a stroke or a gradient fill converted to outline shapes")
        }
        return out
    }
}
