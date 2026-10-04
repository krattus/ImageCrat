import AppKit
import CoreText
import ImageCratCore

/// Emoji input end to end: the macOS Character Viewer (its `insertText` reaches the canvas or the type editor through
/// the text input system), text and emoji dragged onto the canvas from other apps, ⌘V of text, the Glyphs panel, and
/// what happens to emoji afterwards (grapheme-correct editing, colour rendering, exports, .imagecrat and PSD round
/// trips, Warp Text, Convert to Shape). The canvas is the real one, hosted in an offscreen window; drags use a private
/// pasteboard and paste swaps in a private one, so the user's clipboard is never touched.
/// `LUMEN_SELFTEST_ONLY=emoji Lumen --selftest <dir>`
enum EmojiSelfTest {
    static func register() { FeatureModules.selfTests.append(("emoji", { run($0) })) }

    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let d = ok ? "" : detail()
        print("\(ok ? "PASS" : "FAIL") emoji: \(name)\(d.isEmpty ? "" : " — " + d)")
    }

    // MARK: Harness

    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    /// A drag as AppKit hands it to `performDragOperation` (`source` nil: the drag comes from another app).
    final class FakeDrag: NSObject, NSDraggingInfo {
        let pb: NSPasteboard
        let location: NSPoint
        let source: AnyObject?
        weak var window: NSWindow?
        init(_ pb: NSPasteboard, at windowPoint: NSPoint, source: AnyObject? = nil, window: NSWindow?) {
            self.pb = pb; location = windowPoint; self.source = source; self.window = window
        }
        var draggingDestinationWindow: NSWindow? { window }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
        var draggingLocation: NSPoint { location }
        var draggedImageLocation: NSPoint { location }
        var draggedImage: NSImage? { nil }
        var draggingPasteboard: NSPasteboard { pb }
        var draggingSource: Any? { source }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    struct Env {
        let window: NSWindow
        let canvas: CanvasView
        let doc: Document
    }

    static let fontName = "Helvetica"

    /// White background (colour detection: only emoji are saturated) and one black type layer.
    static func makeDoc(_ name: String) -> Document {
        var st = DocumentState(width: 800, height: 500)
        let bg = PixelBuffer(width: 800, height: 500)
        bg.context.setFillColor(CGColor(gray: 1, alpha: 1))
        bg.context.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        bg.markDirty()
        st.layers = [Layer.raster(name: "Background", buffer: bg)]
        let d = Document(state: st, name: name)
        d.commit("Open")
        return d
    }

    static func setUp(_ d: Document) -> Env {
        let app = AppModel.shared
        app.add(d)
        let w = KeyableWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        w.contentView = canvas
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        canvas.document = d
        d.zoom = 1
        d.viewOffset = CGPoint(x: 100, y: 100)     // doc (0,0) at view (100,100)
        d.needsFitOnScreen = false
        AppActions.canvas = canvas
        app.tool = .hand
        app.textTool.fontName = fontName
        app.textTool.fontSize = 40
        app.textTool.color = RGBA(hex: "111111")!
        w.makeFirstResponder(canvas)
        return Env(window: w, canvas: canvas, doc: d)
    }

    static func tearDown(_ e: Env) {
        if let t = TextTool.editing { t.endEditing(commit: true) }
        e.window.makeFirstResponder(nil)
        e.window.orderOut(nil)
        e.window.contentView = nil
        AppModel.shared.close(e.doc)
        AppModel.shared.tool = .move
    }

    /// Window point of a document point.
    static func windowPoint(_ e: Env, _ p: CGPoint) -> NSPoint { e.canvas.convert(e.canvas.docToView(p), to: nil) }

    static func click(_ e: Env, _ p: CGPoint) {
        let wp = windowPoint(e, p)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let ev = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: e.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
            if type == .leftMouseDown { e.canvas.mouseDown(with: ev) } else { e.canvas.mouseUp(with: ev) }
        }
    }

    /// What the Character Viewer does with a picked character: `insertText(_:replacementRange:)` on the key window's
    /// first responder, through its text input context (an attributed string naming the emoji font, as the viewer sends).
    @discardableResult
    static func pick(_ e: Env, _ s: String) -> Bool {
        guard let r = e.window.firstResponder as? NSView, let ctx = r.inputContext else { return false }
        let a = NSAttributedString(string: s, attributes: [.font: NSFont(name: "AppleColorEmoji", size: 12) ?? NSFont.systemFont(ofSize: 12)])
        ctx.client.insertText(a, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }

    static func textLayers(_ d: Document) -> [Layer] { d.state.allLayers.filter { $0.text != nil } }

    static func privatePasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("app.lumen.selftest.emoji.\(UUID().uuidString)")) }

    // MARK: Pixels

    /// Strongly coloured (emoji) pixels of the composite inside `rect` (doc space), and how many of them lie outside `inside`.
    static func colourPixels(_ st: DocumentState, in rect: CGRect? = nil, inside: CGRect? = nil) -> (count: Int, outside: Int) {
        let sp = CanvasSpace(width: st.width, height: st.height)
        let r = IRect(enclosing: (rect ?? st.canvasRect.cgRect).intersection(st.canvasRect.cgRect))
        guard !r.isEmpty else { return (0, 0) }
        let buf = RenderEngine.renderBuffer(Compositor.shared.composite(st), docRect: r, space: sp)
        return saturated(buf, origin: CGPoint(x: r.x, y: r.y), inside: inside)
    }

    static func saturated(_ buf: PixelBuffer, origin: CGPoint = .zero, inside: CGRect? = nil) -> (count: Int, outside: Int) {
        var n = 0, out = 0
        for y in 0..<buf.height { for x in 0..<buf.width {
            let (r, g, b, a) = buf.pixel(x, y)
            let mx = max(r, g, b), mn = min(r, g, b)
            if a > 128, Int(mx) - Int(mn) > 90 {
                n += 1
                if let i = inside, !i.insetBy(dx: -1, dy: -1).contains(CGPoint(x: origin.x + CGFloat(x) + 0.5, y: origin.y + CGFloat(y) + 0.5)) { out += 1 }
            }
        } }
        return (n, out)
    }

    static func saturated(_ cg: CGImage) -> Int { saturated(PixelBuffer(cgImage: cg)).count }

    // MARK: Run

    static func run(_ out: URL) {
        failures = 0
        let dir = out.appendingPathComponent("emoji")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let savedPasteboard = AppActions.pasteboard
        let savedText = AppModel.shared.textTool
        defer { AppActions.pasteboard = savedPasteboard; AppModel.shared.textTool = savedText }
        pickerWithoutEditor(dir)
        pickerWithTypeTool(dir)
        pickerWhileEditing(dir)
        drops(dir)
        paste(dir)
        glyphsPanel(dir)
        roundTrips(dir)
        warpAndShape(dir)
        print("emoji: \(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")")
    }

    // MARK: Character Viewer, no type layer being edited

    static func pickerWithoutEditor(_ dir: URL) {
        let e = setUp(makeDoc("picker"))
        defer { tearDown(e) }
        let d = e.doc
        check(e.window.firstResponder === e.canvas, "canvas is first responder after a click / by default")
        check(e.canvas.inputContext != nil, "canvas has a text input context (Character Viewer / 🌐 key target)",
              "inputContext nil: the canvas is not an NSTextInputClient, so picked characters have nowhere to go")
        click(e, CGPoint(x: 200, y: 150))
        check(e.window.firstResponder === e.canvas, "a canvas click keeps the canvas first responder")
        let before = textLayers(d).count, hist = d.historyIndex
        let delivered = pick(e, "😀")
        let made = textLayers(d)
        check(delivered && made.count == before + 1, "picked emoji with nothing being edited creates a type layer", "delivered \(delivered), text layers \(made.count)")
        guard let l = made.last, let t = l.text else { return }
        check(t.text == "😀" && d.activeLayerID == l.id && d.selectedLayerIDs == [l.id], "the new layer holds the emoji and is selected", "\(t.text)")
        let b = TextRenderer.docBounds(t)
        check(abs(b.midX - 200) < 3 && abs(b.midY - 150) < 3, "placed centred on the last canvas click", "\(b)")
        check(d.historyIndex == hist + 1 && d.history[d.historyIndex].name == "Type Layer", "one history step", "\(d.historyIndex - hist) \(d.history.last?.name ?? "")")
        check(TextTool.editing == nil && AppModel.shared.tool == .hand, "no tool switch or editor for other tools")
        let px = colourPixels(d.state, in: b.insetBy(dx: -4, dy: -4), inside: b)
        check(px.count > 300 && px.outside == 0, "emoji drawn in colour inside its bounding box", "\(px)")
        // a second pick lands beside the first, not on top of it
        pick(e, "🎉")
        if let l2 = textLayers(d).last, l2.id != l.id, let t2 = l2.text {
            let b2 = TextRenderer.docBounds(t2)
            check(b2.minX >= b.maxX - 1 && abs(b2.midY - b.midY) < 3, "next pick is placed beside the previous one", "\(b) \(b2)")
        } else { check(false, "next pick is placed beside the previous one", "no second layer") }
        // undo removes exactly that layer
        let n = textLayers(d).count
        d.undo()
        check(textLayers(d).count == n - 1 && textLayers(d).last?.id == l.id, "undo removes the picked emoji in one step")
        d.redo()
        // a new click starts a new row there
        click(e, CGPoint(x: 600, y: 400))
        pick(e, "🍀")
        if let t4 = textLayers(d).last?.text {
            let b4 = TextRenderer.docBounds(t4)
            check(t4.text == "🍀" && abs(b4.midX - 600) < 3 && abs(b4.midY - 400) < 3, "a new click moves the insertion point", "\(b4)")
        }
        SelfTest.save(d.state, "emoji_picker", dir)
        // another document in the canvas, not clicked yet: the centre of the view
        let d2 = makeDoc("picker2")
        AppModel.shared.add(d2)
        defer { AppModel.shared.close(d2) }
        e.canvas.document = d2
        d2.zoom = 0.5
        d2.viewOffset = CGPoint(x: 300, y: 200)
        let center = e.canvas.viewToDoc(CGPoint(x: e.canvas.bounds.midX, y: e.canvas.bounds.midY))
        e.window.makeFirstResponder(e.canvas)
        pick(e, "🚀")
        if let t3 = textLayers(d2).last?.text {
            let b3 = TextRenderer.docBounds(t3)
            check(t3.text == "🚀" && abs(b3.midX - center.x) < 3 && abs(b3.midY - center.y) < 3, "without a click the pick lands in the centre of the view", "\(b3) \(center)")
            check(t3.fontSize >= 128, "at 50 % zoom the emoji is made big enough to see", "\(t3.fontSize)")
        } else { check(false, "without a click the pick lands in the centre of the view", "no layer") }
        e.canvas.document = d
    }

    // MARK: Character Viewer with the Type tool (no editor open yet)

    static func pickerWithTypeTool(_ dir: URL) {
        let e = setUp(makeDoc("typetool"))
        defer { tearDown(e) }
        let d = e.doc
        AppModel.shared.tool = .text
        e.window.makeFirstResponder(e.canvas)
        let hist = d.historyIndex
        pick(e, "🎉")
        check(TextTool.editing != nil, "with the Type tool a pick opens a new type layer in the editor")
        pick(e, "👍🏽")        // goes into the open editor
        TextTool.editing?.endEditing(commit: true)
        let tl = textLayers(d)
        check(tl.count == 1 && tl.first?.text?.text == "🎉👍🏽", "following picks are typed into that layer", "\(tl.map { $0.text?.text ?? "" })")
        check(d.historyIndex == hist + 1, "the new layer is one history step", "\(d.historyIndex - hist)")
    }

    // MARK: Character Viewer while editing

    static func pickerWhileEditing(_ dir: URL) {
        let d = makeDoc("editing")
        var t = TextContent()
        t.text = "Hello "; t.fontName = fontName; t.fontSize = 48; t.color = RGBA(hex: "111111")!; t.position = CGPoint(x: 40, y: 40)
        let layer = Layer(name: "Hello", content: .text(t))
        d.addLayer(layer, commitName: "Add")
        let e = setUp(d)
        defer { tearDown(e) }
        AppModel.shared.tool = .text
        guard let tool = e.canvas.tool(for: .text) as? TextTool else { return }
        tool.beginEditing(layer.id, isNew: false)
        guard let tv = tool.editorTextView else { check(false, "editor opens"); return }
        check(e.window.firstResponder === tv, "the type editor is first responder while editing")
        tool.testSelect(NSRange(location: 6, length: 0))
        let hist = d.historyIndex
        pick(e, "👨‍👩‍👧")
        check(tv.string == "Hello 👨‍👩‍👧", "picked emoji inserted at the caret", tv.string)
        // the editor shows it with the emoji font (Core Text / TextKit fallback); the model keeps the layer's font
        let ns = tv.string as NSString
        let shownFont = (tv.textStorage?.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.fontName ?? ""
        check(shownFont == "AppleColorEmoji", "editor draws the emoji with Apple Color Emoji", shownFont)
        let sel = tool.shownContent
        tool.testSelect(NSRange(location: 6, length: ns.length - 6))
        check(tool.shownContent?.fontName == fontName, "Character panel / font menu show the layer font for an emoji selection", tool.shownContent?.fontName ?? "nil")
        _ = sel
        // grapheme-correct editing
        tool.testSelect(NSRange(location: ns.length, length: 0))
        tv.moveLeft(nil)
        check(tv.selectedRange().location == 6, "caret moves over a ZWJ sequence in one step", "\(tv.selectedRange())")
        tv.moveRight(nil)
        tv.deleteBackward(nil)
        check(tv.string == "Hello ", "backspace removes a whole ZWJ family", tv.string.unicodeScalars.map { String(format: "%X", $0.value) }.joined(separator: " "))
        for s in ["🇪🇪", "👍🏽", "1️⃣", "❤️", "🏳️‍🌈"] {
            tool.testSelect(NSRange(location: (tv.string as NSString).length, length: 0))
            pick(e, s)
            tv.deleteBackward(nil)
            check(tv.string == "Hello ", "backspace removes \(s) whole", tv.string.unicodeScalars.map { String(format: "%X", $0.value) }.joined(separator: " "))
        }
        tool.testSelect(NSRange(location: 6, length: 0))
        pick(e, "👋🏽🌍")
        tv.insertText("!", replacementRange: tv.selectedRange())
        // Character panel: a size set on a selection with emoji applies to them (still drawn in colour)
        tool.testSelect(NSRange(location: 6, length: 4))
        if let shown = tool.shownContent {
            var big = shown; big.fontSize = 72
            tool.applyEdit(from: shown, to: big)
        }
        check(tool.currentModel?.runs.contains { $0.location == 6 && $0.length == 4 && $0.style.fontSize == 72 && $0.style.fontName == nil } ?? false,
              "Character panel size change on an emoji selection", "\(tool.currentModel?.runs ?? [])")
        tool.endEditing(commit: true)
        guard let r = d.state.layer(layer.id)?.text else { return }
        check(r.text == "Hello 👋🏽🌍!", "committed text", r.text)
        check(r.runs.allSatisfy { $0.style.fontName == nil || $0.style.fontName == fontName }, "no emoji-font runs stored in the layer (fallback stays automatic)", "\(r.runs)")
        check(d.historyIndex == hist + 1, "the edit is one history step", "\(d.historyIndex - hist)")
        // width grows by the emoji; colour stays inside the box
        var plain = r; plain.text = "Hello !"
        let wE = TextRenderer.layoutSize(r).width, wP = TextRenderer.layoutSize(plain).width
        check(wE > wP + 60, "text measurement includes the emoji advances", "\(wE) vs \(wP)")
        let b = TextRenderer.docBounds(r)
        let px = colourPixels(d.state, inside: b)
        check(px.count > 500 && px.outside == 0, "colour emoji rendered inside the layer's bounding box", "\(px)")
        SelfTest.save(d.state, "emoji_editing", dir)
    }

    // MARK: Drag and drop

    static func drops(_ dir: URL) {
        let e = setUp(makeDoc("drops"))
        defer { tearDown(e) }
        let d = e.doc
        let types = e.canvas.registeredDraggedTypes
        check(types.contains(.string), "canvas registers for text drags", "\(types.map(\.rawValue))")
        // plain text (what the Character Viewer, Notes and Safari put on a drag pasteboard)
        let pb = privatePasteboard()
        pb.clearContents(); pb.setString("🌈", forType: .string)
        var n = textLayers(d).count
        let hist = d.historyIndex
        let ok = e.canvas.performDragOperation(FakeDrag(pb, at: windowPoint(e, CGPoint(x: 600, y: 300)), window: e.window))
        check(ok && textLayers(d).count == n + 1 && textLayers(d).last?.text?.text == "🌈", "emoji dropped from another app creates a type layer", "ok \(ok)")
        if let t = textLayers(d).last?.text {
            let b = TextRenderer.docBounds(t)
            check(abs(b.midX - 600) < 3 && abs(b.midY - 300) < 3, "dropped at the drop point", "\(b)")
            check(d.historyIndex == hist + 1, "drop is one history step")
        }
        // RTF only (rich text from TextEdit / Notes)
        let rtfSource = NSAttributedString(string: "Hi 🦄", attributes: [.font: NSFont(name: "Times-Roman", size: 30)!])
        if let rtf = rtfSource.rtf(from: NSRange(location: 0, length: rtfSource.length), documentAttributes: [:]) {
            pb.clearContents(); pb.setData(rtf, forType: .rtf)
            n = textLayers(d).count
            _ = e.canvas.performDragOperation(FakeDrag(pb, at: windowPoint(e, CGPoint(x: 200, y: 400)), window: e.window))
            let t = textLayers(d).last?.text
            check(textLayers(d).count == n + 1 && t?.text == "Hi 🦄" && t?.fontName == fontName, "rich text drop: the text, in the Type tool's font", "\(t?.text ?? "nil") \(t?.fontName ?? "")")
        }
        // a drag that started inside the app (a Layers panel row carries its layer id as text) is not text
        pb.clearContents(); pb.setString(UUID().uuidString, forType: .string)
        n = textLayers(d).count
        let inApp = e.canvas.performDragOperation(FakeDrag(pb, at: windowPoint(e, CGPoint(x: 300, y: 300)), source: NSView(), window: e.window))
        check(!inApp && textLayers(d).count == n, "in-app drags (layer rows, panel tabs) don't become text")
        check(e.canvas.draggingEntered(FakeDrag(pb, at: .zero, source: NSView(), window: e.window)) == [], "…and get no drop highlight")
        pb.clearContents(); pb.setString(ComponentCommands.dragPrefix + UUID().uuidString, forType: .string)
        check(e.canvas.draggingEntered(FakeDrag(pb, at: .zero, source: NSView(), window: e.window)) == .copy, "component drags are still accepted")
        pb.clearContents(); pb.setString("🌈", forType: .string)
        check(e.canvas.draggingEntered(FakeDrag(pb, at: .zero, window: e.window)) == .copy, "text from another app is accepted")
        // dropped onto the type layer being edited: inserted at the caret
        guard let target = textLayers(d).last, let tool = e.canvas.tool(for: .text) as? TextTool else { return }
        AppModel.shared.tool = .text
        tool.beginEditing(target.id, isNew: false)
        tool.testSelect(NSRange(location: 2, length: 0))
        pb.clearContents(); pb.setString("✨", forType: .string)
        let tb = TextRenderer.docBounds(target.text!)
        let ok2 = e.canvas.performDragOperation(FakeDrag(pb, at: windowPoint(e, CGPoint(x: tb.midX, y: tb.midY)), window: e.window))
        tool.endEditing(commit: true)
        check(ok2 && d.state.layer(target.id)?.text?.text == "Hi✨ 🦄", "drop onto the type layer being edited inserts at the caret", d.state.layer(target.id)?.text?.text ?? "nil")
        SelfTest.save(d.state, "emoji_drops", dir)
    }

    // MARK: ⌘V

    static func paste(_ dir: URL) {
        let e = setUp(makeDoc("paste"))
        defer { tearDown(e) }
        let d = e.doc
        let pb = privatePasteboard()
        AppActions.pasteboard = pb
        pb.clearContents(); pb.setString("Paste 😎", forType: .string)
        let n = textLayers(d).count, hist = d.historyIndex
        AppActions.paste()
        check(textLayers(d).count == n + 1 && textLayers(d).last?.text?.text == "Paste 😎" && d.historyIndex == hist + 1,
              "⌘V of text with nothing being edited pastes a type layer", "\(textLayers(d).count - n)")
        // while editing: the editor pastes (rich text from another app takes the layer's style)
        guard let target = textLayers(d).last, let tool = e.canvas.tool(for: .text) as? TextTool else { return }
        AppModel.shared.tool = .text
        tool.beginEditing(target.id, isNew: false)
        tool.testSelect(NSRange(location: 5, length: 0))
        let rich = NSAttributedString(string: " 🍕", attributes: [.font: NSFont(name: "Courier", size: 9)!])
        pb.clearContents()
        pb.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]), forType: .rtf)
        pb.setString(" 🍕", forType: .string)
        let pasted = tool.editorTextView?.readSelection(from: pb) ?? false
        tool.endEditing(commit: true)
        let t = d.state.layer(target.id)?.text
        check(pasted && t?.text == "Paste 🍕 😎" && (t?.runs.allSatisfy { $0.style.fontName == nil } ?? false), "paste into the editor keeps the layer font", "\(t?.text ?? "nil") \(t?.runs ?? [])")
    }

    // MARK: Glyphs panel

    static func glyphsPanel(_ dir: URL) {
        let e = setUp(makeDoc("glyphs"))
        defer { tearDown(e) }
        let d = e.doc
        let emojiFont = "AppleColorEmoji"
        let grin = GlyphCatalog.shared.glyph(for: 0x1F600, fontName: emojiFont) ?? 0
        // nothing being edited and no type layer: a new layer
        let n = textLayers(d).count
        let ok = GlyphInsert.insert(fontName: emojiFont, glyph: grin, text: "😀")
        check(ok && textLayers(d).count == n + 1 && textLayers(d).last?.text?.text == "😀", "Glyphs panel insert with no type layer creates one", "ok \(ok)")
        if let t = textLayers(d).last?.text { check(t.fontName != emojiFont && t.runs.isEmpty, "the new layer keeps the Type tool font (emoji by fallback)", t.fontName) }
        // into an editor: no emoji-font run (typing after it would come out in the emoji font)
        guard let target = textLayers(d).last, let tool = e.canvas.tool(for: .text) as? TextTool else { return }
        AppModel.shared.tool = .text
        tool.beginEditing(target.id, isNew: false)
        tool.testSelect(NSRange(location: 2, length: 0))
        GlyphInsert.insert(fontName: emojiFont, glyph: GlyphCatalog.shared.glyph(for: 0x1F525, fontName: emojiFont) ?? 0, text: "🔥")
        tool.testType("ok")
        // unencoded glyphs of the emoji font (flags, skin tones, ZWJ sequences) can be inserted too
        let flag = GlyphAlternates.shapedGlyph("🇯🇵", TextRenderer.makeFont(name: emojiFont, size: 40)) ?? 0
        let flagOK = GlyphInsert.insert(fontName: emojiFont, glyph: flag, text: nil)
        tool.endEditing(commit: true)
        let t = d.state.layer(target.id)?.text
        check(t?.text == "😀🔥ok🇯🇵", "glyph inserts in the editor", t?.text ?? "nil")
        check(flagOK, "unencoded emoji glyph (flag) resolves to its sequence")
        check(t?.runs.allSatisfy { $0.style.fontName != emojiFont } ?? false, "no Apple Color Emoji run after a Glyphs panel emoji", "\(t?.runs ?? [])")
        // every unencoded single-glyph emoji sequence of the font can be inserted (sampled)
        let unenc = GlyphCatalog.shared.glyphs(emojiFont).filter { $0.scalars.isEmpty }
        var resolved = 0, tried = 0, failed: [String] = []
        for g in unenc where g.glyph % 7 == 0 {
            guard let n = GlyphCatalog.glyphName(g.glyph, fontName: emojiFont), n.hasPrefix("u"), !n.hasSuffix(".L"), !n.hasSuffix(".R"), !n.contains(".u") else { continue }
            tried += 1
            if GlyphAlternates.resolveUnencoded(g.glyph, fontName: emojiFont) != nil { resolved += 1 } else if failed.count < 8 { failed.append(n) }
        }
        print("emoji: unencoded emoji glyphs resolved \(resolved)/\(tried) \(failed)")
        check(tried > 50 && resolved * 100 >= tried * 90, "unencoded emoji glyphs (skin tones, ZWJ, flags) resolve to sequences", "\(resolved)/\(tried) e.g. \(failed)")
        // the Emoji category of a text font lists Apple Color Emoji instead of nothing
        check(GlyphsPanel.catalogFont(fontName, .emoji) == emojiFont && GlyphsPanel.catalogFont(fontName, .letters) == fontName, "Emoji category falls back to the emoji font")
        // a cell dragged from the panel onto the canvas (an in-app drag, unlike layer rows)
        let provider = GlyphInsert.dragProvider(fontName: emojiFont, glyph: flag, text: nil)
        _ = provider
        let pb = privatePasteboard()
        pb.clearContents(); pb.setString(TypeInput.glyphDragText ?? "", forType: .string)
        let n2 = textLayers(d).count
        let dropped = e.canvas.performDragOperation(FakeDrag(pb, at: windowPoint(e, CGPoint(x: 500, y: 350)), source: NSView(), window: e.window))
        check(dropped && textLayers(d).count == n2 + 1 && textLayers(d).last?.text?.text == "🇯🇵", "Glyphs panel cell dragged onto the canvas", "\(TypeInput.glyphDragText ?? "nil")")
        SelfTest.save(d.state, "emoji_glyphs", dir)
    }

    // MARK: Round trips and exports

    static func sample() -> DocumentState {
        var st = makeDoc("rt").state
        var a = TextContent()
        a.text = "Emoji 😀 👨‍👩‍👧 🇪🇪 1️⃣ ❤️"; a.fontName = fontName; a.fontSize = 44; a.color = RGBA(hex: "1B1F3A")!; a.position = CGPoint(x: 30, y: 40)
        a.applyStyle(CharacterStyle(fontSize: 60), to: NSRange(location: 6, length: 2))
        var b = TextContent()
        b.text = "🚀 Launch\nsecond line 🌈"; b.fontName = "Georgia"; b.fontSize = 36; b.color = RGBA(hex: "C0392B")!; b.position = CGPoint(x: 30, y: 200)
        b.boxSize = CGSize(width: 500, height: 160)
        st.layers.append(Layer(name: "A", content: .text(a)))
        st.layers.append(Layer(name: "B", content: .text(b)))
        return st
    }

    static func roundTrips(_ dir: URL) {
        let st = sample()
        let ref = colourPixels(st).count
        check(ref > 2000, "sample renders colour emoji", "\(ref)")
        // .imagecrat
        let nat = dir.appendingPathComponent("emoji_roundtrip.imagecrat")
        let d = Document(state: st, name: "rt")
        do {
            try DocumentIO.saveNative(d, to: nat)
            let back = try DocumentIO.load(url: nat)
            let a = st.allLayers.compactMap(\.text), b = back.state.allLayers.compactMap(\.text)
            check(a.map(\.text) == b.map(\.text) && a.map(\.runs) == b.map(\.runs), ".imagecrat round trip keeps text and runs")
            check(abs(colourPixels(back.state).count - ref) < ref / 50, ".imagecrat round trip renders the same colour")
        } catch { check(false, ".imagecrat round trip", "\(error)") }
        // PSD: engine data names the emoji font for the emoji runs, as Photoshop writes it
        let psd = dir.appendingPathComponent("emoji_roundtrip.psd")
        do {
            try PSDExport.write(st, to: psd)
            let data = try Data(contentsOf: psd)
            let layers = PSDExportSelfTest.typeLayers(data)
            var emojiRuns = 0, emojiRunsRight = 0
            var odd: [String] = []
            for (_, en) in layers {
                let fonts = (en["ResourceDict"]?["FontSet"]?.array ?? []).map { $0["Name"]?.string ?? "" }
                let text = en["EngineDict"]?["Editor"]?["Text"]?.string ?? ""
                let lens = en["EngineDict"]?["StyleRun"]?["RunLengthArray"]?.array.compactMap(\.int) ?? []
                let sheets = en["EngineDict"]?["StyleRun"]?["RunArray"]?.array ?? []
                var loc = 0
                let ns = text as NSString
                for (i, len) in lens.enumerated() where i < sheets.count {
                    let fi = sheets[i]["StyleSheet"]?["StyleSheetData"]?["Font"]?.int ?? -1
                    let f = fonts.indices.contains(fi) ? fonts[fi] : ""
                    let sub = ns.substring(with: NSRange(location: loc, length: min(len, ns.length - loc)))
                    // (Core Text keeps a space between emoji in the emoji font; so does the PSD, for the same advance)
                    if f == "AppleColorEmoji" {
                        emojiRuns += 1
                        if sub.unicodeScalars.allSatisfy({ EmojiSelfTest.isEmojiScalar($0) || $0 == " " }) { emojiRunsRight += 1 } else { odd.append(sub) }
                    }
                    loc += len
                }
            }
            check(emojiRuns >= 6 && emojiRuns == emojiRunsRight, "PSD style runs of emoji use AppleColorEmoji (and only emoji)", "\(emojiRunsRight)/\(emojiRuns) \(odd.map { $0.unicodeScalars.map { String($0.value, radix: 16) } })")
            check(PSDExportSelfTest.txt2Problems(data).isEmpty, "PSD Txt2 consistent with the layers", "\(PSDExportSelfTest.txt2Problems(data))")
            let back = try PSDImporter.read(url: psd).state
            let a = st.allLayers.compactMap(\.text), b = back.allLayers.compactMap(\.text)
            check(a.map(\.text) == b.map(\.text), "PSD round trip keeps the text", "\(b.map(\.text))")
            check(a.map(\.fontName) == b.map(\.fontName) && b.allSatisfy { $0.runs.allSatisfy { $0.style.fontName != "AppleColorEmoji" } },
                  "PSD import folds AppleColorEmoji runs back into the layer font", "\(b.map(\.fontName)) \(b.map(\.runs))")
            check(a.map { $0.runs.count } == b.map { $0.runs.count }, "PSD round trip keeps the style runs", "\(a.map(\.runs)) vs \(b.map(\.runs))")
            let px = colourPixels(back).count
            check(px > ref * 8 / 10, "PSD round trip renders colour emoji", "\(px) vs \(ref)")
            if let cg = DocumentIO.loadImage(url: psd)?.0 { check(saturated(cg) > ref * 8 / 10, "PSD composite pixels have colour emoji", "\(saturated(cg))") }
        } catch { check(false, "PSD round trip", "\(error)") }
        // PNG / JPEG
        for (fmt, ext) in [(ExportFormat.png, "png"), (.jpeg, "jpg")] {
            let u = dir.appendingPathComponent("emoji_export.\(ext)")
            do {
                try DocumentIO.export(st, to: u, format: fmt, quality: 0.95, scale: 1)
                let n = DocumentIO.loadImage(url: u).map { saturated($0.0) } ?? 0
                check(n > ref * 8 / 10, "\(ext.uppercased()) export has colour emoji", "\(n) vs \(ref)")
            } catch { check(false, "\(ext) export", "\(error)") }
        }
        // HTML export: the emoji reach the page (live text the browser draws, or pixels)
        let res = HTMLExporter.export(st, options: HTMLExportOptions())
        check(["😀", "👨‍👩‍👧 🇪🇪 1️⃣ ❤️", "🚀 Launch", "🌈"].allSatisfy { res.html.contains($0) }, "HTML export keeps the emoji as live text (the browser draws them in colour)", "\(res.textCount) text nodes")
        // layer thumbnail
        let td = Document(state: st, name: "thumb")
        if let l = st.layers.last, let cg = Thumbnails.shared.layer(l, doc: td, size: 120) {
            check(saturated(cg) > 20, "layer thumbnail shows colour emoji", "\(saturated(cg))")
        } else { check(false, "layer thumbnail") }
        SelfTest.save(st, "emoji_roundtrip", dir)
    }

    static func isEmojiScalar(_ u: Unicode.Scalar) -> Bool {
        u.properties.isEmoji || u.properties.isEmojiPresentation || u.value == 0x200D || u.value == 0xFE0F || u.value == 0x20E3
            || (0x1F3FB...0x1F3FF).contains(u.value) || (0xE0020...0xE007F).contains(u.value)
    }

    // MARK: Warp Text, Convert to Shape

    static func warpAndShape(_ dir: URL) {
        var st = makeDoc("warp").state
        var t = TextContent()
        t.text = "Arc 🍩🎈"; t.fontName = fontName; t.fontSize = 54; t.color = RGBA(hex: "2E86DE")!; t.position = CGPoint(x: 60, y: 120)
        var w = TextWarp(); w.style = .arc; w.bend = 50
        t.warp = w
        st.layers.append(Layer(name: "Warp", content: .text(t)))
        let b = TextRenderer.docBounds(t)
        let px = colourPixels(st, inside: b)
        // (the blue letters are saturated too: at least some emoji colour must be there, i.e. more than the letters)
        var lettersOnly = st
        lettersOnly.layers[1].text?.text = "Arc"
        check(px.count > colourPixels(lettersOnly).count + 400 && px.outside == 0, "Warp Text keeps colour emoji inside the warped bounds", "\(px)")
        SelfTest.save(st, "emoji_warp", dir)

        // Convert to Shape: outlines can't carry colour bitmaps
        var s2 = makeDoc("shape").state
        var m = TextContent()
        m.text = "Hi 😀"; m.fontName = fontName; m.fontSize = 60; m.color = RGBA(hex: "111111")!; m.position = CGPoint(x: 40, y: 40)
        var only = m
        only.text = "😀🎉"; only.position = CGPoint(x: 40, y: 200)
        let mixed = Layer(name: "Mixed", content: .text(m)), emojiOnly = Layer(name: "Only", content: .text(only))
        s2.layers += [mixed, emojiOnly]
        let d = Document(state: s2, name: "shape")
        d.commit("Open")
        AppModel.shared.add(d)
        defer { AppModel.shared.close(d) }
        let before = colourPixels(d.state).count
        d.selectLayer(mixed.id)
        AppModel.shared.statusMessage = ""
        AppActions.convertTextToShape()
        let afterMixed = colourPixels(d.state).count
        check(d.state.layer(mixed.id)?.shape != nil, "mixed text converts to a shape")
        check(afterMixed > before / 3 && !AppModel.shared.statusMessage.isEmpty, "the colour emoji are kept (as pixels) and the user is told", "\(before) → \(afterMixed) “\(AppModel.shared.statusMessage)”")
        d.selectLayer(emojiOnly.id)
        let hist = d.historyIndex
        AppModel.shared.statusMessage = ""
        AppActions.convertTextToShape()
        check(d.state.layer(emojiOnly.id)?.text != nil && d.historyIndex == hist && !AppModel.shared.statusMessage.isEmpty,
              "emoji-only text is not turned into an empty shape", "“\(AppModel.shared.statusMessage)”")
        SelfTest.save(d.state, "emoji_shape", dir)
    }
}
