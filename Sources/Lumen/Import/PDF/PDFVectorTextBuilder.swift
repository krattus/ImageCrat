import AppKit
import CoreText
import ImageCratCore

/// Turns a text block of the display list into the most editable thing that still looks like the PDF:
/// a type layer (font installed, layout reproduced), glyph outlines from the embedded font, or pixels.
/// Each candidate is rendered and compared with the PDF's own rendering of the block before it is accepted.
struct PDFVectorTextBuilder {
    let builder: PDFVectorBuilder
    static let debug = ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_DEBUG"] != nil

    private struct Line {
        /// (run index, glyph index) in reading order.
        var glyphs: [(run: Int, glyph: Int)] = []
        var text = ""
        /// UTF-16 offset in `text` of each glyph's first character.
        var offsets: [Int] = []
        /// Runs of equal style: UTF-16 range → run index.
        var spans: [(range: NSRange, run: Int)] = []
    }

    func resolve(_ t: PDFVectorText, item: PDFVectorItem, page: Int) -> PDFVectorBuilder.Resolved? {
        let fontName = t.runs.first?.font.baseName ?? "?"
        func pixels(_ why: String) -> PDFVectorBuilder.Resolved? {
            guard var (layer, b) = builder.rasterLayer(page: page, bounds: item.bounds, name: "Text (rasterized)") else { return nil }
            builder.apply(item, to: &layer)
            if !t.slice.opaque { layer.opacity = 1 }   // the pixels already carry the text's alpha
            builder.report.raster(why)
            return PDFVectorBuilder.Resolved(layers: [layer], bounds: b)
        }
        if !t.reason.isEmpty || !t.positioned { return pixels(t.reason.isEmpty ? "text without usable metrics" : t.reason) }
        guard let first = t.runs.first, !first.glyphs.isEmpty else { return nil }

        // reference rendering of the block, enlarged for small type so stems are more than a pixel wide
        let em = max(1, hypot(first.basis.c, first.basis.d))
        let region = item.bounds.intersection(builder.interp.canvas.insetBy(dx: -4, dy: -4)).integral
        guard region.width >= 1, region.height >= 1 else { return nil }
        var zoom = max(1, min(6, 48 / em))
        while zoom > 1, region.width * zoom * region.height * zoom > 24_000_000 { zoom = max(1, zoom / 2) }
        guard let ref = PDFVectorOutliner.context(region, zoom: zoom) else { return pixels("very large text block") }
        builder.partial.draw(page, in: ref)
        func matches(_ draw: (CGContext) -> Void) -> Bool {
            guard let c = PDFVectorOutliner.context(region, zoom: zoom) else { return false }
            if t.slice.opaque { draw(c) } else {
                // the reference has the text's alpha in it: fade the candidate the way its layer will be faded
                c.setAlpha(CGFloat(item.opacity))
                c.beginTransparencyLayer(auxiliaryInfo: nil)
                draw(c)
                c.endTransparencyLayer()
            }
            let m = PDFVectorOutliner.mismatch(ref, c)
            if PDFVectorTextBuilder.debug {
                print("DEBUG text raster mismatch \(m) zoom \(zoom) font \(fontName)")
                if m > 0.05, let a = ref.makeImage(), let b = c.makeImage(), let dir = ProcessInfo.processInfo.environment["LUMEN_PDFIMPORT_DEBUG"] {
                    let n = Int(m * 100000)
                    FilesSelfTest.writePNG(a, URL(fileURLWithPath: dir + "/textdbg_\(n)_pdf.png")); FilesSelfTest.writePNG(b, URL(fileURLWithPath: dir + "/textdbg_\(n)_lumen.png"))
                }
            }
            return m < 0.08
        }

        let lines = self.lines(t)
        let label = lines.map { $0.map(\.text).joined(separator: " ") }
        if let label, label.allSatisfy({ $0 == " " || $0 == "\u{00A0}" }) { return nil }   // only spaces: nothing is drawn

        // 1. editable text
        var textFailure = ""
        if builder.options.editableText, let lines, t.runs.allSatisfy({ $0.mode == 0 }) {
            let installed = t.runs.allSatisfy { $0.font.installedName != nil }
            if installed {
                func looksRight(_ tc: TextContent) -> Bool {
                    matches { c in
                        c.concatenate(TextRenderer.docTransform(tc))
                        TextRenderer.draw(tc, in: c)
                    }
                }
                if let tc = textContent(t, lines: lines, substitute: false, accept: looksRight) { return textLayer(tc, item: item) }
                // lines that do not form one paragraph (different indents or spacing) may still work one by one
                if lines.count > 1 {
                    let singles = lines.compactMap { textContent(t, lines: [$0], substitute: false, accept: { _ in true }) }
                    if singles.count == lines.count, matches({ c in
                        for tc in singles {
                            c.saveGState()
                            c.concatenate(TextRenderer.docTransform(tc))
                            TextRenderer.draw(tc, in: c)
                            c.restoreGState()
                        }
                    }) {
                        var out = PDFVectorBuilder.Resolved(layers: [], bounds: .null)
                        for tc in singles {
                            let r = textLayer(tc, item: item)
                            out.layers += r.layers
                            out.bounds = out.bounds.union(r.bounds)
                        }
                        return out
                    }
                }
                textFailure = "installed, but its layout differs from the PDF"
            } else if builder.options.substituteFonts, let tc = textContent(t, lines: lines, substitute: true, accept: { _ in true }) {
                for r in t.runs where r.font.installedName == nil {
                    builder.report.fonts[r.font.baseName] = "not installed — text kept editable in \(tc.fontName) (appearance differs)"
                }
                return textLayer(tc, item: item)
            } else {
                textFailure = "not installed"
            }
        }

        // 2. outlines of the embedded glyphs
        let pieces = PDFVectorOutliner.outlines(t)
        if let pieces, pieces.isEmpty { return nil }   // every glyph is blank
        if let pieces {
            let points = pieces.reduce(0) { $0 + PDFVectorGeometry.elementCount($1.path) }
            if points <= 60_000, matches({ c in
                for p in pieces {
                    if case .color = p.fill, let col = builder.paintStyle(p.fill).solidColor { c.addPath(p.path); c.setFillColor(col.cgColor); c.fillPath() }
                    if let st = p.stroke, let col = builder.paintStyle(p.strokePaint).solidColor {
                        c.addPath(p.path); c.setStrokeColor(col.cgColor); c.setLineWidth(CGFloat(st.width))
                        c.setLineCap([.butt, .round, .square][max(0, min(2, st.cap))]); c.setLineJoin([.miter, .round, .bevel][max(0, min(2, st.join))])
                        c.strokePath()
                    }
                }
            }) {
                var layers: [Layer] = []
                var bounds = CGRect.null
                for p in pieces {
                    var vp = PDFVectorGeometry.vectorPath(p.path)
                    for k in vp.subpaths.indices { vp.subpaths[k].closed = true }
                    guard !vp.subpaths.isEmpty else { continue }
                    var sc = ShapeContent(geometry: .path(vp), fill: builder.paintStyle(p.fill))
                    if let st = p.stroke {
                        sc.stroke = StrokeStyle(paint: builder.paintStyle(p.strokePaint), width: max(0.01, st.width), alignment: .center,
                                                cap: [.butt, .round, .square][max(0, min(2, st.cap))], join: [.miter, .round, .bevel][max(0, min(2, st.join))])
                    }
                    var name = (label ?? "Text")
                    if name.count > 40 { name = String(name.prefix(40)) + "…" }
                    var layer = Layer(name: "\(name) (outlines)", content: .shape(sc))
                    builder.apply(item, to: &layer)
                    layers.append(layer)
                    bounds = bounds.union(p.path.boundingBoxOfPath)
                }
                if !layers.isEmpty {
                    builder.report.outlinedText += 1
                    if !textFailure.isEmpty { builder.report.fonts[fontName] = textFailure + " — text converted to outlines" }
                    return PDFVectorBuilder.Resolved(layers: layers, bounds: bounds)
                }
            }
        }

        // 3. pixels
        let why = first.font.isEmbedded ? "text in a font that could not be outlined" : "text in a font that is neither installed nor embedded"
        builder.report.fonts[fontName] = (textFailure.isEmpty ? "not usable" : textFailure) + " — text rasterized"
        return pixels(why)
    }

    private func textLayer(_ tc: TextContent, item: PDFVectorItem) -> PDFVectorBuilder.Resolved {
        var name = tc.text.replacingOccurrences(of: "\n", with: " ")
        if name.count > 40 { name = String(name.prefix(40)) + "…" }
        var layer = Layer(name: name.isEmpty ? "Text" : name, content: .text(tc))
        builder.apply(item, to: &layer)
        builder.report.textLayers += 1
        // ink extent (the layout box is taller than the glyphs), so clips that only frame the text can be dropped
        let ink = TextRenderer.outlinePath(tc).boundingBoxOfPath
        return PDFVectorBuilder.Resolved(layers: [layer], bounds: ink.isNull ? TextRenderer.docBounds(tc) : ink)
    }

    // MARK: Lines

    /// Splits the block into lines and decodes them. nil when a character has no Unicode value.
    private func lines(_ t: PDFVectorText) -> [Line]? {
        var lines: [Line] = []
        var cur = Line()
        var prevEnd: CGPoint? = nil
        var prevBasis = CGAffineTransform.identity
        var units = 0
        var spanStart = 0
        var spanRun = -1
        func closeSpan() {
            if spanRun >= 0, units > spanStart { cur.spans.append((NSRange(location: spanStart, length: units - spanStart), spanRun)) }
        }
        for (ri, r) in t.runs.enumerated() {
            for (gi, g) in r.glyphs.enumerated() {
                guard var u = r.font.unicode(for: Int(g.code)), !u.isEmpty else { return nil }
                if u == "\u{00AD}" { u = "-" }
                for s in u.unicodeScalars where s.value < 32 || s.value == 0xFFFD || (s.value >= 0xE000 && s.value <= 0xF8FF) { _ = s; return nil }
                let size = max(0.01, hypot(r.basis.c, r.basis.d))
                if let pe = prevEnd {
                    let (along, across, _) = PDFVectorGeometry.offset(from: pe, to: g.origin, basis: prevBasis)
                    if abs(across) > size * 0.35 || along < -size * 0.75 {
                        closeSpan()
                        lines.append(cur)
                        cur = Line(); units = 0; spanStart = 0; spanRun = -1
                    } else if along.isFinite, along > size * 0.17, !cur.text.hasSuffix(" "), u != " " {
                        // a gap where a space would be: producers often position words instead of writing spaces
                        let sw = max(0.12, r.font.width(32) / 1000) * size
                        let n = max(1, min(40, Int((along / sw).rounded())))
                        cur.text += String(repeating: " ", count: n)
                        units += n
                    }
                }
                if spanRun != ri { closeSpan(); spanStart = units; spanRun = ri }
                cur.glyphs.append((ri, gi))
                cur.offsets.append(units)
                cur.text += u
                units += u.utf16.count
                prevEnd = g.end
                prevBasis = r.basis
            }
        }
        closeSpan()
        if !cur.glyphs.isEmpty { lines.append(cur) }
        return lines.isEmpty ? nil : lines
    }

    // MARK: Type layer

    /// A type layer that reproduces the block, or nil when the block is not plain enough (skewed / mirrored text)
    /// or the installed font lays the text out differently.
    private func textContent(_ t: PDFVectorText, lines: [Line], substitute: Bool, accept: (TextContent) -> Bool) -> TextContent? {
        guard let firstRef = lines.first?.glyphs.first else { return nil }
        let first = t.runs[firstRef.run]
        let b = first.basis
        let ux = hypot(b.a, b.b), uy = hypot(b.c, b.d)
        guard ux > 0.01, uy > 0.2 else { return nil }
        // upright glyphs on a straight baseline: x and y axes perpendicular, not mirrored
        guard abs(b.a * b.c + b.b * b.d) < ux * uy * 0.01, b.a * b.d - b.b * b.c < 0 else { return nil }
        let angle = atan2(b.b, b.a)
        func fontName(_ f: PDFVectorFont) -> String? {
            if let n = f.installedName { return n }
            guard substitute else { return nil }
            let lower = f.baseName.lowercased()
            let traits: CTFontSymbolicTraits = [lower.contains("bold") ? .traitBold : [], lower.contains("italic") || lower.contains("oblique") ? .traitItalic : []]
            let base = CTFontCreateWithName((lower.contains("courier") || lower.contains("mono") ? "Menlo-Regular" : lower.contains("times") || lower.contains("serif") || lower.contains("garamond") || lower.contains("minion") ? "TimesNewRomanPSMT" : "HelveticaNeue") as CFString, 12, nil)
            let styled = CTFontCreateCopyWithSymbolicTraits(base, 12, nil, traits, [.traitBold, .traitItalic]) ?? base
            return CTFontCopyPostScriptName(styled) as String
        }
        guard let baseFont = fontName(first.font), let baseColor = builder.paintStyle(first.fill).solidColor else { return nil }

        var tc = TextContent()
        tc.text = lines.map(\.text).joined(separator: "\n")
        tc.fontName = baseFont
        tc.fontSize = Double(uy)
        tc.color = baseColor
        tc.horizontalScale = Double(ux / uy)
        tc.tracking = first.tracking
        tc.transform = abs(angle) < 1e-6 ? .identity : CGAffineTransform(rotationAngle: angle)
        tc.features.standardLigatures = t.runs.contains { $0.font.mapsLigatures } || tc.text.unicodeScalars.contains { $0.value >= 0xFB00 && $0.value <= 0xFB04 }
        // per-run overrides
        var offset = 0
        for l in lines {
            for sp in l.spans {
                let r = t.runs[sp.run]
                var st = CharacterStyle()
                guard let fn = fontName(r.font), let col = builder.paintStyle(r.fill).solidColor else { return nil }
                guard PDFVectorGeometry.sameDirection(r.basis, b) else { return nil }
                let size = Double(hypot(r.basis.c, r.basis.d))
                if fn != baseFont { st.fontName = fn }
                if abs(size - tc.fontSize) > 0.01 { st.fontSize = size }
                if col != baseColor { st.color = col }
                if abs(r.tracking - tc.tracking) > 0.5 { st.tracking = r.tracking }
                let hs = Double(hypot(r.basis.a, r.basis.b)) / max(0.01, size)
                if abs(hs - tc.horizontalScale) > 0.005 { st.horizontalScale = hs }
                if !st.isEmpty { tc.runs.append(TextStyleRun(location: offset + sp.range.location, length: sp.range.length, style: st)) }
            }
            offset += (l.text as NSString).length + 1
        }
        tc.normalizeRuns()
        // line pitch
        let origins: [CGPoint] = lines.compactMap { l in l.glyphs.first.map { t.runs[$0.run].glyphs[$0.glyph].origin } }
        guard origins.count == lines.count else { return nil }
        if lines.count > 1 {
            let (_, across, _) = PDFVectorGeometry.offset(from: origins[0], to: origins[1], basis: b)
            guard across < 0 else { return nil }
            tc.leading = Double(-across)
        }
        if substitute { return place(tc, origins: origins, lines: lines, t, check: false) }
        // Try the alignments a block can have, without and with pair kerning. Lumen's type engine kerns only when
        // tracking is non-zero (a zero kern attribute switches Core Text's kerning off), so "kerned" is expressed
        // as an imperceptible tracking value.
        let aligns: [TextAlign] = lines.count > 1 ? [.left, .center, .right] : [.left]
        for kerned in (tc.tracking == 0 ? [false, true] : [false]) {
            for a in aligns {
                var c = tc
                c.alignment = a
                if kerned { c.tracking = 0.01 }
                if let ok = place(c, origins: origins, lines: lines, t, check: true), accept(ok) { return ok }
            }
        }
        return nil
    }

    /// Positions the layer so its first baseline starts where the PDF's does, then (with `check`) compares where
    /// every glyph lands with the PDF.
    private func place(_ content: TextContent, origins: [CGPoint], lines: [Line], _ t: PDFVectorText, check: Bool) -> TextContent? {
        var tc = content
        tc.position = .zero
        let layout = TextRenderer.layout(tc)
        let placed = layout.lines.filter { !$0.isMarker }
        guard placed.count == lines.count, let l0 = placed.first else { return nil }
        let hs = CGFloat(tc.horizontalScale), vs = CGFloat(tc.verticalScale)
        let inv = tc.transform.inverted()
        // local baseline start of the first line → document origin of the first glyph
        let start0 = CGPoint(x: CTLineGetOffsetForStringIndex(l0.line, 0, nil), y: 0).applying(l0.transform)
        let target = origins[0].applying(inv)
        tc.position = CGPoint(x: target.x - start0.x * hs, y: target.y - start0.y * vs)
        guard check else { return tc }
        let m = TextRenderer.docTransform(tc)
        let em = CGFloat(tc.fontSize)
        let tol = max(0.75, em * 0.04)
        for (li, pl) in placed.enumerated() {
            let line = lines[li]
            for (k, ref) in line.glyphs.enumerated() {
                let x = CTLineGetOffsetForStringIndex(pl.line, line.offsets[k], nil)
                let p = CGPoint(x: x, y: 0).applying(pl.transform).applying(m)
                let g = t.runs[ref.run].glyphs[ref.glyph]
                if hypot(p.x - g.origin.x, p.y - g.origin.y) > tol {
                    if PDFVectorTextBuilder.debug { print("DEBUG text “\(line.text.prefix(30))” \(tc.fontName) tracking \(tc.tracking) align \(tc.alignment): glyph \(k) of \(line.glyphs.count) off by (\(p.x - g.origin.x), \(p.y - g.origin.y)) tol \(tol)") }
                    return nil
                }
            }
            // the line must also end where the PDF's does (a trailing mismatch means different advances)
            if let last = line.glyphs.last {
                let x = CTLineGetOffsetForStringIndex(pl.line, (line.text as NSString).length, nil)
                let p = CGPoint(x: x, y: 0).applying(pl.transform).applying(m)
                let e = t.runs[last.run].glyphs[last.glyph].end
                if hypot(p.x - e.x, p.y - e.y) > tol * 1.5 { return nil }
            }
        }
        return tc
    }
}
