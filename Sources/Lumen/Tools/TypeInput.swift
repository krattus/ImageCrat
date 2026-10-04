import AppKit
import CoreText
import ImageCratCore

// Text that reaches the canvas from outside the on-canvas type editor: characters picked in the macOS Character
// Viewer (Edit ▸ Emoji & Symbols, the 🌐 key) or dictated, text and emoji dragged from other apps, ⌘V of text and
// glyphs from the Glyphs panel. With a type layer being edited the text goes in at the caret; otherwise it becomes a
// new point-type layer (see `TypeInput.insert`).

// MARK: - Emoji helpers

enum EmojiText {
    /// A character drawn as an emoji (emoji presentation, an emoji with VS16, keycaps, flags, tag and ZWJ sequences).
    static func isEmoji(_ ch: Character) -> Bool {
        let sc = ch.unicodeScalars
        guard let first = sc.first else { return false }
        if sc.contains(where: { $0.properties.isEmojiPresentation }) { return true }
        if sc.count > 1, first.properties.isEmoji, sc.contains(where: { $0.value == 0xFE0F || $0.value == 0x20E3 || $0.value == 0x200D || (0x1F3FB...0x1F3FF).contains($0.value) }) { return true }
        return false
    }

    /// Only emoji (white space aside), and at least one.
    static func isEmojiOnly(_ s: String) -> Bool {
        var any = false
        for ch in s where !ch.isWhitespace {
            guard isEmoji(ch) else { return false }
            any = true
        }
        return any
    }

    private nonisolated(unsafe) static var colorFonts: [String: Bool] = [:]
    private static let lock = NSLock()

    /// A colour (bitmap) font such as Apple Color Emoji.
    static func isColorFont(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if let v = colorFonts[name] { return v }
        let v = FontLookup.installed(name) && CTFontGetSymbolicTraits(TextRenderer.makeFont(name: name, size: 12)).contains(.traitColorGlyphs)
        colorFonts[name] = v
        return v
    }

    /// UTF-16 ranges of the layer text that Core Text draws with a colour font through font fallback (emoji in a text
    /// font), with that font's PostScript name. Ranges are in text order.
    static func colorRuns(_ t: TextContent) -> [(range: NSRange, font: String)] {
        guard t.text.unicodeScalars.contains(where: { $0.value > 0x2000 }) else { return [] }
        let line = CTLineCreateWithAttributedString(TextRenderer.attributedString(t))
        var out: [(range: NSRange, font: String)] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] where TextRenderer.isColorRun(run) {
            let r = CTRunGetStringRange(run)
            let f = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName as String] as! CTFont
            let name = CTFontCopyPostScriptName(f) as String
            let nr = NSRange(location: r.location, length: r.length)
            if let last = out.last, last.font == name, NSMaxRange(last.range) == nr.location {
                out[out.count - 1].range.length += nr.length
            } else {
                out.append((nr, name))
            }
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The character sequence a colour font draws as `glyph` when the glyph has no code point of its own (flags,
    /// keycaps, skin tones, ZWJ sequences), worked out from its glyph name ("u1F1EF_u1F1F5", "u1F44D.3",
    /// "u1F9D1_u1F4BB.3", "u1F3C4.0.M") and confirmed by shaping. Nil for anything else.
    static func sequence(for glyph: CGGlyph, fontName: String) -> String? {
        guard isColorFont(fontName), let name = GlyphCatalog.glyphName(glyph, fontName: fontName) else { return nil }
        let parts = name.split(separator: ".").map(String.init)
        guard let head = parts.first else { return nil }
        var comps: [Unicode.Scalar] = []
        for c in head.split(separator: "_") {
            guard c.hasPrefix("u"), let v = UInt32(c.dropFirst(), radix: 16), let u = Unicode.Scalar(v) else { return nil }
            comps.append(u)
        }
        guard !comps.isEmpty else { return nil }
        var tones: [Int: Unicode.Scalar] = [:]      // component index → skin tone modifier
        var gender: Unicode.Scalar? = nil
        func tone(_ k: Character) -> Unicode.Scalar? { k.wholeNumberValue.flatMap { (1...5).contains($0) ? Unicode.Scalar(0x1F3FA + UInt32($0)) : nil } }
        for p in parts.dropFirst() {
            if p.count == 1, p.first?.isNumber == true { if let t = tone(p.first!) { tones[0] = t } }              // ".3": the person's tone
            else if p.count == 2, p.allSatisfy(\.isNumber) { tones[0] = tone(p.first!); tones[comps.count - 1] = tone(p.last!) }   // ".25": two people
            else if p == "M" { gender = Unicode.Scalar(0x2642) } else if p == "W" { gender = Unicode.Scalar(0x2640) }
            else { return nil }        // a piece of a multi-glyph emoji (".L" / ".R"), or an unknown variant
        }
        let zwj = Unicode.Scalar(0x200D)!, vs16 = Unicode.Scalar(0xFE0F)!
        func comp(_ i: Int, vs: Bool) -> [Unicode.Scalar] {
            if let t = tones[i] { return [comps[i], t] }
            return vs && !comps[i].properties.isEmojiPresentation && comps[i].value != 0x20E3 ? [comps[i], vs16] : [comps[i]]
        }
        var candidates: [[Unicode.Scalar]] = [
            comps.indices.flatMap { comp($0, vs: false) },                                               // flags, keycaps, tags
            comps.indices.flatMap { i in (i > 0 ? [zwj] : []) + comp(i, vs: false) },                    // ZWJ sequences
            comps.indices.flatMap { i in (i > 0 ? [zwj] : []) + comp(i, vs: true) },
        ]
        if comps.count == 2, comps[1].value == 0x20E3 { candidates.append([comps[0], vs16, comps[1]]) }   // keycaps
        if let g = gender { candidates = candidates.map { $0 + [zwj, g, vs16] } }
        let font = TextRenderer.makeFont(name: fontName, size: 40)
        for c in candidates {
            var s = ""
            s.unicodeScalars.append(contentsOf: c)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            guard runs.count == 1, CTRunGetGlyphCount(runs[0]) == 1 else { continue }
            var g: CGGlyph = 0
            CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &g)
            if g == glyph { return s }
        }
        return nil
    }
}

// MARK: - Text arriving on the canvas

enum TypeInput {
    /// Text of a drag that started in the Glyphs panel (other drags from inside the app, such as Layers panel rows,
    /// carry ids as text and are not typed into the document).
    static var glyphDragText: String?

    /// The layer the last picked character went to (the next one is placed beside it until the canvas is clicked).
    private static var chain: (doc: UUID, layer: UUID, click: Int)?

    /// Plain text of a pasteboard (plain text, else RTF / RTFD).
    static func text(from pb: NSPasteboard) -> String? {
        if let s = pb.string(forType: .string), !s.isEmpty { return s }
        if let d = pb.data(forType: .rtf), let a = NSAttributedString(rtf: d, documentAttributes: nil), a.length > 0 { return a.string }
        if let d = pb.data(forType: .rtfd), let a = NSAttributedString(rtfd: d, documentAttributes: nil), a.length > 0 { return a.string }
        return nil
    }

    /// Text a drop onto the canvas should type: drags from other apps (the Character Viewer, Notes, Safari…) and
    /// from the Glyphs panel.
    static func droppedText(_ sender: NSDraggingInfo) -> String? {
        guard let s = text(from: sender.draggingPasteboard) else { return nil }
        if sender.draggingSource != nil, s != glyphDragText { return nil }
        return s
    }

    /// A drag from inside the app that only carries text the canvas doesn't take (a Layers panel row, a panel tab): no
    /// drop highlight. Component, library and clipboard-history drags (see `ComponentCommands`) and glyphs are taken.
    static func refusesDrag(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        guard sender.draggingSource != nil, !(pb.types ?? []).contains(where: { [.fileURL, .png, .tiff].contains($0) }),
              let s = pb.string(forType: .string) else { return false }
        let ours = [ComponentCommands.dragPrefix, ComponentCommands.libraryDragPrefix, ClipboardHistory.dragPrefix]
        return s != glyphDragText && !ours.contains { s.hasPrefix($0) }
    }

    /// Is `s` worth a layer: not empty or white space only.
    private static func normalized(_ raw: String) -> String? {
        let s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// Types `raw` into the document on canvas `c`:
    /// - a type layer is being edited: inserted at the caret (a drop elsewhere ends that edit first);
    /// - `typed` (Character Viewer, dictation) with the Type tool selected: a new type layer opens in the editor with
    ///   the text, so the following characters go into the same layer;
    /// - otherwise: a new point-type layer with the Type tool's font, size and colour (made readable at the current
    ///   zoom), centred on `point`, else on the last canvas click (`typed`; following picks line up beside it), else on
    ///   the centre of the view; selected, one history step.
    /// `fontName` / `features`: the font of a glyph from the Glyphs panel (colour emoji fonts are left to fallback).
    @discardableResult
    static func insert(_ raw: String, canvas c: CanvasView, at point: CGPoint? = nil, typed: Bool = false,
                       fontName: String? = nil, features: [String: Int] = [:], actionName: String = "Type Layer") -> Bool {
        guard let s = normalized(raw), let d = c.document else { return false }
        let app = AppModel.shared
        if let tool = TextTool.editing, tool.canvas === c, let id = tool.editingID, d.state.layer(id) != nil {
            let over = point.map { p -> Bool in
                guard let m = tool.currentModel else { return false }
                return TextRenderer.docBounds(m).insetBy(dx: -8 / max(0.01, c.zoom), dy: -8 / max(0.01, c.zoom)).contains(p)
            } ?? true
            if over {
                tool.insertGlyphText(s, extra: features.isEmpty ? nil : features, fontName: fontName.flatMap { EmojiText.isColorFont($0) ? nil : $0 })
                return true
            }
            tool.endEditing(commit: true)
        }
        var t = TextContent()
        let ts = app.textTool
        t.text = s
        t.fontName = ts.fontName
        if let f = fontName, !EmojiText.isColorFont(f), FontLookup.installed(f) { t.fontName = f }
        if !features.isEmpty { t.features.extra = features }
        t.fontSize = ts.fontSize
        t.alignment = ts.alignment
        t.color = ts.color ?? app.foreground
        t.orientation = app.tool == .verticalText ? .vertical : .horizontal
        // tiny type at a low zoom would look like nothing happened
        let z = max(0.01, Double(c.zoom))
        let minSize = (EmojiText.isEmojiOnly(s) ? 64 : 24) / z
        if t.fontSize < minSize { t.fontSize = minSize.rounded(.up) }
        // a long run of text becomes paragraph text that fits the canvas
        let canvasW = CGFloat(d.state.width)
        if t.orientation == .horizontal, TextRenderer.layoutSize(t).width > canvasW * 0.8 {
            let w = max(120, canvasW * 0.6)
            t.boxSize = CGSize(width: w, height: 100_000)
            let used = TextRenderer.layout(t).lines.map(\.bounds.maxY).max() ?? CGFloat(t.fontSize)
            t.boxSize = CGSize(width: w, height: ceil(used + CGFloat(t.fontSize) * 0.4))
        }
        // placement
        let canvasRect = CGRect(x: 0, y: 0, width: d.state.width, height: d.state.height)
        func clamped(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, canvasRect.minX), canvasRect.maxX), y: min(max(p.y, canvasRect.minY), canvasRect.maxY)) }
        let b0 = TextRenderer.docBounds(t)
        var shift: CGPoint
        if let p = point {
            shift = CGPoint(x: p.x - b0.midX, y: p.y - b0.midY)
        } else if typed, let ch = chain, ch.doc == d.id, ch.click == c.clickSerial, d.activeLayerID == ch.layer,
                  let prev = d.state.layer(ch.layer)?.text {
            let pb = TextRenderer.docBounds(prev)
            shift = CGPoint(x: pb.maxX + CGFloat(t.fontSize) * 0.1 - b0.minX, y: pb.midY - b0.midY)
        } else {
            var a = c.viewToDoc(CGPoint(x: c.bounds.midX, y: c.bounds.midY))
            if typed, let lc = c.lastClick, lc.docID == d.id, c.bounds.contains(c.docToView(lc.point)) { a = lc.point }
            a = clamped(a)
            shift = CGPoint(x: a.x - b0.midX, y: a.y - b0.midY)
        }
        t.position = CGPoint(x: (t.position.x + shift.x).rounded(), y: (t.position.y + shift.y).rounded())

        if typed, point == nil, app.tool == .text || app.tool == .verticalText, let tool = c.tool(for: app.tool) as? TextTool {
            tool.beginNewLayer(t)
            chain = nil
            return true
        }
        let firstLine = s.split(separator: "\n").first.map(String.init) ?? s
        let layer = Layer(name: String(firstLine.prefix(40)), content: .text(t))
        d.addLayer(layer)
        d.commit(actionName)
        d.setNeedsRender()
        c.overlay.needsDisplay = true
        chain = typed ? (d.id, layer.id, c.clickSerial) : nil
        return true
    }
}

// MARK: - The canvas as a text input client

/// The canvas takes text input so the Character Viewer, the 🌐 / fn emoji picker, dictation and text Services have a
/// target when no type layer is being edited (the on-canvas editor is an NSTextView and handles its own input).
/// Key presses still go to the tools: they are never passed to the input context, so no input method sees them.
extension CanvasView: NSTextInputClient, NSServicesMenuRequestor {
    private static let noRange = NSRange(location: NSNotFound, length: 0)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        TypeInput.insert(s, canvas: self, typed: true)
    }

    override func insertText(_ insertString: Any) { insertText(insertString, replacementRange: CanvasView.noRange) }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
    func unmarkText() {}
    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange { CanvasView.noRange }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the emoji picker pops up: the last click on this document's canvas, or the centre of the view.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        var p = CGPoint(x: bounds.midX, y: bounds.midY)
        if let lc = lastClick, lc.docID == document?.id, bounds.contains(docToView(lc.point)) { p = docToView(lc.point) }
        let r = convert(CGRect(x: p.x, y: p.y - 10, width: 1, height: 20), to: nil)
        return window?.convertToScreen(r) ?? r
    }

    // Services that return text (e.g. a text snippet service) insert it like a picked character.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let r = returnType, [.string, .rtf].contains(r), document != nil { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let s = TypeInput.text(from: pboard) else { return false }
        return TypeInput.insert(s, canvas: self, typed: true)
    }

    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool { false }
}

// MARK: - Glyphs panel drags

extension GlyphInsert {
    /// Drag payload of a Glyphs panel cell: its text, accepted by the canvas (a new type layer, or into the layer
    /// being edited) and by the on-canvas editor.
    static func dragProvider(fontName: String, glyph: CGGlyph, text: String?) -> NSItemProvider {
        let s = text ?? EmojiText.sequence(for: glyph, fontName: fontName) ?? GlyphAlternates.resolveUnencoded(glyph, fontName: fontName)?.0 ?? ""
        TypeInput.glyphDragText = s
        return NSItemProvider(object: s as NSString)
    }
}
