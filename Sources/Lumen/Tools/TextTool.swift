import AppKit
import Observation
import ImageCratCore

final class CanvasTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCommit?(); return }                          // Esc commits (like clicking away)
        if event.keyCode == 76 { onCommit?(); return }                          // keypad Enter
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { onCommit?(); return }
        super.keyDown(with: event)
    }

    /// Context menu always offers Emoji & Symbols (the automatic Edit menu item is replaced by Lumen's own).
    override func menu(for event: NSEvent) -> NSMenu? {
        let m = super.menu(for: event) ?? NSMenu()
        let sel = #selector(NSApplication.orderFrontCharacterPalette(_:))
        if !m.items.contains(where: { $0.action == sel }) {
            m.addItem(.separator())
            m.addItem(NSMenuItem(title: "Emoji & Symbols", action: sel, keyEquivalent: ""))
        }
        return m
    }
}

final class TextViewDelegateProxy: NSObject, NSTextViewDelegate {
    var onChange: (() -> Void)?
    var onSelection: (() -> Void)?
    func textDidChange(_ notification: Notification) { onChange?() }
    func textViewDidChangeSelection(_ notification: Notification) { onSelection?() }
}

/// Observable tick so panels refresh while the on-canvas type editor changes (selection, text, styles).
@Observable
final class TypeEditState {
    static let shared = TypeEditState()
    var tick = 0
    var editingLayerID: UUID?
}

final class TextTool: Tool {
    /// The tool instance that currently has an open on-canvas editor.
    nonisolated(unsafe) static weak var editing: TextTool?

    private let proxy = TextViewDelegateProxy()
    private(set) var editingID: UUID?
    /// The document the editor was opened in (the canvas may already show another one when the edit ends).
    private weak var editDoc: Document?
    /// Layer selection before a new type layer was added (restored when that layer is discarded).
    private var selectionBefore: (active: UUID?, selected: Set<UUID>)?
    /// Called after an edit ended and its history step (if any) was recorded (type mask tools turn the layer into a selection).
    var onEditingEnded: (() -> Void)?
    private var textView: CanvasTextView?
    private var isNewLayer = false
    private var boxStart: CGPoint?
    private var boxCurrent: CGPoint?
    /// Layer-level settings of the layer being edited (text + runs live in the text view).
    private var base = TextContent()
    private var original = TextContent()
    /// Live mode: the layer stays visible and updates as you type; the editor floats beside it
    /// (vertical type, type on a path, warped or rotated text).
    private var liveMode = false
    private var editorScale: CGFloat = 1
    private var hoverPathHit = false
    private var hoverAreaHit = false
    /// ⌘ over type on a path: dragging moves the text along the path / flips it across (see `PathTextDrag`).
    private var hoverMoveHit = false
    /// Text box resize (handles shown while editing paragraph / area type).
    private var resizeHandle: Int?
    private var resizeStart: (position: CGPoint, box: CGSize, transform: CGAffineTransform, area: AreaTextShape?)?

    override var cursor: NSCursor { TypePathCursors.cursor(onPath: hoverPathHit, area: hoverAreaHit, move: hoverMoveHit) }
    override var isBusy: Bool { editingID != nil }
    override var pendingPolicy: PendingPolicy { .commitExceptTextCommands }
    /// Another command changed the document while typing: if it deleted (or rasterized / converted) the layer being
    /// edited, the editor is closed; otherwise typing simply continues.
    override func abandonPending() {
        guard let id = editingID, let d = editDoc ?? doc else { return }
        if d.state.layer(id)?.text == nil {
            endEditing(commit: false)
        } else if !liveMode {
            d.hiddenLayers.insert(id)      // a history jump resets the hidden layers: the layer under the editor stays hidden
        }
    }

    override func deactivate() {
        // a box drag still in progress (tool switched by a shortcut) must not open an editor behind the new tool's back
        boxStart = nil; boxCurrent = nil; resizeHandle = nil; resizeStart = nil
        PathTextDrag.cancel()                     // likewise a ⌘-drag of type on a path
        endEditing(commit: true)
    }
    override func commit() { endEditing(commit: true) }
    override func cancel() { endEditing(commit: false) }
    override func documentWillChange(_ old: Document) { endEditing(commit: true) }

    // MARK: Mouse

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        if PathTextDrag.begin(d, e, canvas: canvas, viaPathTool: false) { return }   // ⌘-drag type on a path
        if editingID != nil {
            if let h = boxHandleHit(e.doc), let id = editingID, let t = d.state.layer(id)?.text, let b = t.boxSize {
                resizeHandle = h
                resizeStart = (t.position, b, t.transform, t.area)
                // the click went to the canvas, which took the keyboard focus: give it back to the editor
                if let tv = textView { canvas.window?.makeFirstResponder(tv) }
                return
            }
            endEditing(commit: true)
            return
        }
        selectionBefore = (d.activeLayerID, d.selectedLayerIDs)
        // Click on existing text layer → edit it
        if !e.shift, let id = AppActions.layerAt(e.doc, textOnly: true) {
            d.selectLayer(id)
            if let l = d.state.layer(id), !canModify(l) { return }       // fully locked
            beginEditing(id, isNew: false)
            return
        }
        // Click on a path / shape outline → type on a path
        if let (path, s) = pathHit(e.doc) {
            beginTypeOnPath(path, at: s)
            return
        }
        // Click inside a closed path (active path / active shape layer) → area type
        if kind == .text, let area = closedPathHit(e.doc) {
            let t = TextContent.areaText(in: area, base: newContent())
            let layer = Layer(name: "Text", content: .text(t))
            d.addLayer(layer)
            beginEditing(layer.id, isNew: true)
            return
        }
        boxStart = e.doc
        boxCurrent = e.doc
    }

    override func mouseMoved(_ e: ToolEvent) { updateHover(e.doc, command: e.command) }

    override func flagsChanged(_ m: NSEvent.ModifierFlags) {
        if let v = canvas.lastMouseView { updateHover(canvas.viewToDoc(v), command: m.contains(.command)) }
    }

    /// Hover feedback: the type-on-a-path / area type cursors and status hints, ⌘ over type on a path to move it.
    private func updateHover(_ p: CGPoint, command: Bool) {
        let move = command && doc.map { PathTextDrag.hit($0, p, canvas: canvas) != nil } ?? false
        let hit = !move && editingID == nil && pathHit(p) != nil
        let areaHit = !move && !hit && editingID == nil && kind == .text && closedPathHit(p) != nil
        guard hit != hoverPathHit || areaHit != hoverAreaHit || move != hoverMoveHit else { return }
        hoverPathHit = hit
        hoverAreaHit = areaHit
        hoverMoveHit = move
        status(move ? "Drag along the path to move the type, across it to flip the type" :
               hit ? "Click to type on the path" : (areaHit ? "Click to create area type inside the path" : ""))
        canvas.window?.invalidateCursorRects(for: canvas)
        cursor.set()
    }

    override func mouseDragged(_ e: ToolEvent) {
        if PathTextDrag.drag(e, canvas: canvas) { return }
        if let h = resizeHandle { resizeBox(handle: h, to: e.doc); return }
        if boxStart != nil { boxCurrent = e.doc }
    }

    /// Closed outline of the active path (Paths panel) or the active shape layer containing `p`.
    private func closedPathHit(_ p: CGPoint) -> VectorPath? {
        guard let d = doc else { return nil }
        var candidates: [VectorPath] = []
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }) { candidates.append(np.path) }
        if let a = d.activeLayer, let s = a.shape { candidates.append(s.path) }
        for vp in candidates {
            let closed = VectorPath(subpaths: vp.subpaths.filter { $0.closed && $0.points.count >= 3 })
            guard !closed.isEmpty else { continue }
            let (cg, eo) = closed.resolved
            if cg.contains(p, using: eo ? .evenOdd : .winding), closed.bounds.width > 8, closed.bounds.height > 8 { return closed }
        }
        return nil
    }

    // MARK: Box handles

    private func boxHandlesLocal(_ b: CGSize) -> [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: b.width / 2, y: 0), CGPoint(x: b.width, y: 0), CGPoint(x: b.width, y: b.height / 2),
         CGPoint(x: b.width, y: b.height), CGPoint(x: b.width / 2, y: b.height), CGPoint(x: 0, y: b.height), CGPoint(x: 0, y: b.height / 2)]
    }

    private func boxHandleHit(_ p: CGPoint) -> Int? {
        guard let d = doc, let id = editingID, let t = d.state.layer(id)?.text, let b = t.boxSize, t.pathText == nil,
              t.orientation == .horizontal, TextRenderer.activeWarp(t) == nil else { return nil }
        let m = TextRenderer.docTransform(t)
        let vp = canvas.docToView(p)
        for (i, h) in boxHandlesLocal(b).enumerated() where canvas.docToView(h.applying(m)).distance(to: vp) <= 6 { return i }
        return nil
    }

    private func resizeBox(handle h: Int, to p: CGPoint) {
        guard let d = doc, let id = editingID, let st = resizeStart, var t = d.state.layer(id)?.text else { return }
        var o = t
        o.position = st.position; o.boxSize = st.box; o.transform = st.transform
        let local = p.applying(TextRenderer.docTransform(o).inverted())
        var r = CGRect(origin: .zero, size: st.box)
        var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
        if [0, 6, 7].contains(h) { minX = min(local.x, maxX - 10) }
        if [2, 3, 4].contains(h) { maxX = max(local.x, minX + 10) }
        if [0, 1, 2].contains(h) { minY = min(local.y, maxY - 10) }
        if [4, 5, 6].contains(h) { maxY = max(local.y, minY + 10) }
        r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let hs = CGFloat(t.horizontalScale), vs = CGFloat(t.verticalScale)
        t.position = CGPoint(x: st.position.x + r.minX * hs, y: st.position.y + r.minY * vs)
        t.boxSize = st.box
        t.area = st.area
        t.resizeBox(to: r.size)
        let nt = t
        d.updateLayer(id) { $0.text = nt }
        base.position = nt.position; base.boxSize = nt.boxSize; base.area = nt.area
        d.setNeedsRender()
        layoutTextView()
        canvas.overlay.needsDisplay = true
        TypeEditState.shared.tick += 1
    }

    private func newContent() -> TextContent {
        var t = TextContent()
        let ts = app.textTool
        t.text = ""
        t.fontName = ts.fontName
        t.fontSize = ts.fontSize
        t.alignment = ts.alignment
        t.color = ts.color ?? app.foreground
        t.orientation = kind == .verticalText ? .vertical : .horizontal
        return t
    }

    override func mouseUp(_ e: ToolEvent) {
        if PathTextDrag.end(e, canvas: canvas) { return }
        if resizeHandle != nil { resizeHandle = nil; resizeStart = nil; return }
        guard let d = doc, let s = boxStart, let c = boxCurrent else { return }
        defer { boxStart = nil; boxCurrent = nil }
        var t = newContent()
        if s.distance(to: c) * canvas.zoom > 8 {       // screen pixels: a jittery click is not a paragraph box at any zoom
            let r = CGRect(p1: s, p2: c)
            t.position = r.origin
            t.boxSize = r.size
        } else if t.orientation == .vertical {
            // click = top-center of the first (rightmost) column
            t.position = CGPoint(x: s.x + CGFloat(t.fontSize * 0.6), y: s.y)
        } else {
            let lineH = TextRenderer.font(t).ascender
            t.position = CGPoint(x: s.x, y: s.y - lineH)
        }
        let layer = Layer(name: "Text", content: .text(t))
        d.addLayer(layer)
        beginEditing(layer.id, isNew: true)
    }

    /// Nearest outline of the active path (Paths panel), the active shape layer, or any visible shape layer.
    private func pathHit(_ p: CGPoint) -> (VectorPath, CGFloat)? {
        guard let d = doc else { return nil }
        return TypeOnPath.hit(d, p, tolerance: 6 / max(0.01, canvas.zoom))
    }

    /// Starts type on `path` (one subpath, doc coordinates) at arc length `s`: a new type layer, editing.
    func beginTypeOnPath(_ path: VectorPath, at s: CGFloat) {
        guard let d = doc else { return }
        if editingID != nil { endEditing(commit: true) }
        selectionBefore = (d.activeLayerID, d.selectedLayerIDs)
        // linked to the path / shape it is made from: editing that re-flows the text (TypePathLink)
        let source = path.subpaths.count == 1 ? TypePathLink.source(for: path.subpaths[0], in: d) : nil
        // the type shows its own path from now on: the work path it was made from is deselected (kept in the Paths panel)
        if let pid = d.activePathID, let np = d.state.paths.first(where: { $0.id == pid }), let sp = path.subpaths.first,
           np.path.subpaths.contains(sp) { PathOps.deselectPath(d) }
        var t = newContent()
        t.pathText = TextOnPath(path: path, startOffset: Double(s), source: source)
        t.orientation = .horizontal
        let layer = Layer(name: "Text", content: .text(t))
        d.addLayer(layer)
        beginEditing(layer.id, isNew: true)
    }

    /// Type on a path moved / flipped (⌘-drag) while its layer is in the editor: the editor's layer settings follow.
    func updateEditingPathText(_ p: TextOnPath) {
        base.pathText = p
        modelChanged()
    }

    /// Gives the keyboard back to the open editor (a click on the canvas took it).
    func refocusEditor() {
        if let tv = textView { canvas.window?.makeFirstResponder(tv) }
    }

    // MARK: Editing

    /// Model of the layer currently in the editor (text + runs read back from the text view).
    var currentModel: TextContent? {
        guard editingID != nil, let tv = textView, let ts = tv.textStorage else { return nil }
        return TextRenderer.content(from: ts, base: base)
    }

    var selectedRange: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    func isEditing(_ id: UUID?) -> Bool { id != nil && editingID == id }

    /// Style overrides shown for the current selection (first selected character, or the typing attributes).
    var selectionStyle: CharacterStyle {
        guard let tv = textView, let ts = tv.textStorage else { return CharacterStyle() }
        let r = tv.selectedRange()
        if r.length > 0, r.location < ts.length, let b = ts.attribute(.lumenCharStyle, at: r.location, effectiveRange: nil) as? CharStyleBox { return b.style }
        if let b = tv.typingAttributes[.lumenCharStyle] as? CharStyleBox { return b.style }
        return CharacterStyle()
    }

    /// Effective character settings at the selection.
    var shownContent: TextContent? {
        guard let m = currentModel else { return nil }
        return m.applying(selectionStyle)
    }

    /// Applies an edit made to `shownContent` (Character / Paragraph panels, options bar):
    /// character changes go to the selection (or the typing attributes when nothing is selected; the whole text if
    /// it is empty), paragraph/layer settings go to the layer.
    func applyEdit(from shown: TextContent, to edited: TextContent) {
        guard let tv = textView, let ts = tv.textStorage, var model = currentModel else { return }
        let change = CharacterStyle.diff(shown, edited)
        // non-character settings → layer-level
        var nb = edited
        TypeEdit.copyCharacterFields(from: base, to: &nb)
        nb.text = base.text; nb.runs = base.runs
        base = nb
        TypeEdit.copyNonCharacterFields(from: nb, to: &model)
        let sel = tv.selectedRange()
        var typing: CharacterStyle? = nil
        if !change.isEmpty {
            if model.text.isEmpty {
                base = base.applying(change)
                model = model.applying(change)
            } else if sel.length > 0 {
                model.applyStyle(change, to: sel)
            } else {
                typing = selectionStyle.merging(change).normalized(against: model)
            }
        }
        if !liveMode && TextTool.needsLiveMode(model) { enterLiveMode() }
        restyle(model)
        tv.setSelectedRange(sel)
        if let ty = typing { tv.typingAttributes = TextRenderer.editorBaseAttributes(base, style: ty, scale: editorScale) }
        modelChanged()
        _ = ts
    }

    /// Re-applies display attributes from a model without touching the string or selection.
    private func restyle(_ model: TextContent) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let a = TextRenderer.attributedString(model, scale: editorScale, forEditor: true)
        guard a.string == ts.string else { return }
        let sel = tv.selectedRange()
        let typing = tv.typingAttributes
        ts.beginEditing()
        a.enumerateAttributes(in: NSRange(location: 0, length: a.length), options: []) { attrs, r, _ in ts.setAttributes(attrs, range: r) }
        ts.endEditing()
        tv.setSelectedRange(sel)
        let typingStyle = (typing[.lumenCharStyle] as? CharStyleBox)?.style ?? CharacterStyle()
        tv.typingAttributes = TextRenderer.editorBaseAttributes(base, style: ts.length == 0 ? CharacterStyle() : typingStyle, scale: editorScale)
    }

    private func modelChanged() {
        if liveMode, let d = doc, let id = editingID, let m = currentModel {
            d.updateLayer(id) { $0.text = m }
            d.setNeedsRender()
        }
        layoutTextView()
        canvas.overlay.needsDisplay = true
        TypeEditState.shared.tick += 1
    }

    private func textChanged() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        // Ranges without our style tag (e.g. pasted rich text) get the layer defaults.
        if !tv.hasMarkedText(), ts.length > 0 {
            var untagged = false
            ts.enumerateAttribute(.lumenCharStyle, in: NSRange(location: 0, length: ts.length), options: []) { v, _, stop in
                if v == nil { untagged = true; stop.pointee = true }
            }
            if untagged, let m = currentModel { restyle(m) }
        }
        modelChanged()
    }

    static func needsLiveMode(_ t: TextContent) -> Bool {
        let tr = t.transform
        let rotated = abs(tr.b) > 1e-6 || abs(tr.c) > 1e-6
        return t.orientation == .vertical || t.pathText != nil || TextRenderer.activeWarp(t) != nil || rotated || t.usesExtendedLayout
    }

    func beginEditing(_ id: UUID, isNew: Bool) {
        guard let d = doc, let layer = d.state.layer(id), let t = layer.text else { return }
        if editingID != nil { endEditing(commit: true) }
        editingID = id
        editDoc = d
        isNewLayer = isNew
        base = t
        original = t
        liveMode = TextTool.needsLiveMode(t)
        TextTool.editing = self
        TypeEditState.shared.editingLayerID = id
        if !liveMode { d.hiddenLayers.insert(id) }
        d.setNeedsRender()
        app.textEditingActive = true

        let z = canvas.zoom
        editorScale = liveMode ? min(2, max(0.25, 28 / CGFloat(max(1, t.fontSize)))) : z
        let tv = CanvasTextView(frame: .zero)
        proxy.onChange = { [weak self] in self?.textChanged() }
        proxy.onSelection = { [weak self] in
            TypeEditState.shared.tick += 1
            if let s = self { GlyphAlternatesPopup.shared.update(for: s) }
        }
        tv.delegate = proxy
        tv.isRichText = true
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.allowsUndo = true
        tv.textContainerInset = liveMode ? NSSize(width: 4, height: 4) : .zero
        tv.textContainer?.lineFragmentPadding = 1
        let boxed = t.boxSize != nil && t.orientation == .horizontal && t.pathText == nil
        tv.isHorizontallyResizable = !boxed
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = boxed
        if !boxed { tv.textContainer?.containerSize = NSSize(width: 100_000, height: 100_000) }
        if liveMode {
            tv.drawsBackground = true
            let lum = 0.299 * t.color.r + 0.587 * t.color.g + 0.114 * t.color.b
            tv.backgroundColor = lum > 0.6 ? NSColor(white: 0.15, alpha: 0.94) : NSColor(white: 0.97, alpha: 0.94)
            tv.wantsLayer = true
            tv.layer?.cornerRadius = 4
            tv.layer?.borderWidth = 1
            tv.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.7).cgColor
        } else {
            tv.drawsBackground = false
        }
        tv.insertionPointColor = .systemBlue
        tv.onCommit = { [weak self] in self?.endEditing(commit: true) }
        tv.onCancel = { [weak self] in self?.endEditing(commit: false) }
        tv.focusRingType = .none
        let astr = TextRenderer.attributedString(t, scale: editorScale, forEditor: true)
        tv.textStorage?.setAttributedString(astr)
        tv.typingAttributes = astr.length > 0 ? astr.attributes(at: 0, effectiveRange: nil) : TextRenderer.editorBaseAttributes(t, scale: editorScale)
        textView = tv
        canvas.addSubview(tv)
        layoutTextView()
        canvas.window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        canvas.overlay.needsDisplay = true
        TypeEditState.shared.tick += 1
    }

    /// Opens a new type layer made from `t` in the editor with the caret after its text (text that reached the canvas
    /// while the Type tool was selected, e.g. a character picked in the Character Viewer). One history step on commit.
    func beginNewLayer(_ t: TextContent) {
        guard let d = doc else { return }
        if editingID != nil { endEditing(commit: true) }
        selectionBefore = (d.activeLayerID, d.selectedLayerIDs)
        let layer = Layer(name: "Text", content: .text(t))
        d.addLayer(layer)
        beginEditing(layer.id, isNew: true)
        if let tv = textView { tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0)) }
    }

    /// Switches an open editor to live mode (the layer renders; the editor floats beside it), e.g. when a list,
    /// Dynamic Text or area settings are applied while typing.
    private func enterLiveMode() {
        guard let tv = textView, let d = doc, let id = editingID else { return }
        liveMode = true
        d.hiddenLayers.remove(id)
        editorScale = min(2, max(0.25, 28 / CGFloat(max(1, base.fontSize))))
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.isHorizontallyResizable = true
        tv.textContainer?.widthTracksTextView = false
        tv.drawsBackground = true
        let lum = 0.299 * base.color.r + 0.587 * base.color.g + 0.114 * base.color.b
        tv.backgroundColor = lum > 0.6 ? NSColor(white: 0.15, alpha: 0.94) : NSColor(white: 0.97, alpha: 0.94)
        tv.wantsLayer = true
        tv.layer?.cornerRadius = 4
        tv.layer?.borderWidth = 1
        tv.layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.7).cgColor
        d.setNeedsRender()
    }

    private func layoutTextView() {
        guard let tv = textView, let d = doc, let id = editingID, let lt = d.state.layer(id)?.text else { return }
        let z = canvas.zoom
        // Zoom changed while editing: rescale the editor's attributes.
        if !liveMode, abs(z - editorScale) > 1e-4, !tv.hasMarkedText(), let m = currentModel {
            editorScale = z
            restyle(m)
        }
        // Horizontal equivalent of the model, for the editor's own width.
        var h = currentModel ?? lt
        h.orientation = .horizontal; h.pathText = nil; h.warp = nil
        if lt.orientation == .vertical || lt.pathText != nil { h.boxSize = nil }
        let hs = CGFloat(liveMode ? 1 : lt.horizontalScale)
        if liveMode {
            let s = editorScale
            let w = max(60, TextRenderer.layoutSize(h).width * s + 12)
            let b = TextRenderer.docBounds(lt)
            var p = canvas.docToView(CGPoint(x: b.minX, y: b.maxY))
            p.y += 8
            tv.textContainer?.containerSize = NSSize(width: w, height: 100_000)
            let lm = tv.layoutManager!
            lm.ensureLayout(for: tv.textContainer!)
            let used = lm.usedRect(for: tv.textContainer!)
            let hgt = max(used.height, CGFloat(lt.fontSize) * s * 1.25) + 8
            if p.y + hgt > canvas.bounds.maxY { p.y = max(0, canvas.docToView(CGPoint(x: b.minX, y: b.minY)).y - hgt - 8) }
            p.x = min(max(0, p.x), max(0, canvas.bounds.maxX - w - 8))
            tv.frame = CGRect(x: p.x, y: p.y, width: w + 8, height: hgt)
            return
        }
        let extra = TextRenderer.layout(h).firstLineExtra
        let origin = canvas.docToView(CGPoint(x: lt.position.x + lt.transform.tx, y: lt.position.y + lt.transform.ty))
        let oy = origin.y - extra * z * CGFloat(lt.verticalScale)
        if let b = lt.boxSize {
            tv.frame = CGRect(x: origin.x, y: oy, width: b.width * z * hs, height: max(b.height * z * CGFloat(lt.verticalScale), 20))
        } else {
            let w = TextRenderer.layoutSize(h).width * z * hs + 6
            tv.textContainer?.containerSize = NSSize(width: w, height: 100_000)
            let lm = tv.layoutManager!
            lm.ensureLayout(for: tv.textContainer!)
            let used = lm.usedRect(for: tv.textContainer!)
            let minH = CGFloat(lt.fontSize) * z * 1.25
            tv.frame = CGRect(x: origin.x, y: oy, width: max(w, 20), height: max(used.height, minH))
        }
    }

    func endEditing(commit: Bool) {
        guard let id = editingID else { return }
        defer { onEditingEnded?() }
        // The edit belongs to the document it was started in, even if the canvas shows another one by now
        // (document switched or closed while typing).
        let target = editDoc ?? doc
        GlyphAlternatesPopup.shared.hide()
        let model = currentModel ?? base
        textView?.removeFromSuperview()
        textView = nil
        editingID = nil
        editDoc = nil
        if TextTool.editing === self { TextTool.editing = nil }
        TypeEditState.shared.editingLayerID = nil
        TypeEditState.shared.tick += 1
        app.textEditingActive = false
        canvas.window?.makeFirstResponder(canvas)
        guard let d = target else { return }
        d.hiddenLayers.remove(id)
        // The layer was deleted / rasterized / converted by another command meanwhile: nothing left to write.
        guard d.state.layer(id)?.text != nil else { d.setNeedsRender(); canvas.overlay.needsDisplay = true; return }
        if !commit {
            if isNewLayer { discardNewLayer(d, id) } else if liveMode { d.updateLayer(id) { $0.text = self.original } }
            d.setNeedsRender()
            return
        }
        let text = model.text
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isNewLayer { discardNewLayer(d, id) } else {
                d.state.removeLayer(id)
                d.commit("Delete Layer")
            }
            d.setNeedsRender()
            return
        }
        let isNew = isNewLayer
        // Nothing changed: leave the layer alone (renaming it here would stay uncommitted).
        if !isNew && model == original { d.setNeedsRender(); canvas.overlay.needsDisplay = true; return }
        d.updateLayer(id) { l in
            l.text = model
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
            if isNew || l.name == "Text" || l.name.hasPrefix("Text") { l.name = String(firstLine.prefix(40)) }
        }
        d.commit(isNew ? "Type Layer" : "Edit Type Layer")
        d.setNeedsRender()
        canvas.overlay.needsDisplay = true
    }

    /// Removes the type layer that was added for this edit and gives the previous layer selection back
    /// (otherwise the topmost layer would become active after an abandoned click with the Type tool).
    private func discardNewLayer(_ d: Document, _ id: UUID) {
        d.state.removeLayer(id)
        if let before = selectionBefore {
            d.activeLayerID = before.active.flatMap { d.state.layer($0) != nil ? $0 : nil }
            d.selectedLayerIDs = before.selected.filter { d.state.layer($0) != nil }
            if before.active != nil { d.validateActiveLayer() }      // (nothing was selected before: stays that way)
        } else {
            d.validateActiveLayer()
        }
        d.revision += 1
    }

    // MARK: Glyph insertion (Glyphs panel, alternates popup)

    /// The on-canvas editor (for positioning popups).
    var editorTextView: NSTextView? { textView }

    /// Inserts `s` at the selection. `extra` feature settings (glyph alternates) are applied to the inserted text.
    @discardableResult
    func insertGlyphText(_ s: String, extra: [String: Int]? = nil, fontName: String? = nil) -> Bool {
        guard let tv = textView else { return false }
        let sel = tv.selectedRange()
        tv.insertText(s, replacementRange: sel)
        let len = (s as NSString).length
        if (extra.map { !$0.isEmpty } ?? false) || fontName != nil {
            tv.setSelectedRange(NSRange(location: sel.location, length: len))
            if let shown = shownContent {
                var e = shown
                if let extra { e.features.extra = extra }
                if let f = fontName { e.fontName = f }
                applyEdit(from: shown, to: e)
            }
            tv.setSelectedRange(NSRange(location: sel.location + len, length: 0))
        }
        TypeEditState.shared.tick += 1
        return true
    }

    /// Applies alternate-glyph feature settings to the selected characters (replacing earlier alternates).
    func applyAlternate(_ extra: [String: Int]) {
        guard let shown = shownContent else { return }
        var e = shown
        e.features.extra = extra
        applyEdit(from: shown, to: e)
    }

    // MARK: Test hooks (self test)

    func testSelect(_ r: NSRange) { textView?.setSelectedRange(r); TypeEditState.shared.tick += 1 }
    func testType(_ s: String) { textView?.insertText(s, replacementRange: textView?.selectedRange() ?? NSRange(location: NSNotFound, length: 0)) }
    var testEditorFontSize: CGFloat? {
        guard let ts = textView?.textStorage, ts.length > 0 else { return nil }
        return (ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
    }

    override func drawOverlay(_ ctx: CGContext) {
        if let s = boxStart, let c = boxCurrent, s.distance(to: c) * canvas.zoom > 8 {
            OverlayStyle.contrastStroke(ctx, CGPath(rect: canvas.docToView(CGRect(p1: s, p2: c)), transform: nil), dashed: true)
        }
        if let id = editingID, let t = doc?.state.layer(id)?.text {
            if let p = t.pathText {
                let vp = p.path.applying(t.transform)
                let path = TextRenderer.mapPath(vp.cgPath, maxSegment: 1_000_000) { self.canvas.docToView($0) }
                OverlayStyle.contrastStroke(ctx, path)
                let sampler = PathSampler(p.path, flipped: p.flipped)      // start offset: arc length in layer space
                if let (pt, _) = sampler.sample(CGFloat(p.startOffset)) {
                    OverlayStyle.circleHandle(ctx, at: canvas.docToView(pt.applying(t.transform)), filled: true)
                }
            } else if t.boxSize != nil || liveMode {
                let m = TextRenderer.docTransform(t)
                if let a = t.area {
                    let path = TextRenderer.mapPath(a.path.cgPath, maxSegment: 1_000_000) { self.canvas.docToView($0.applying(m)) }
                    OverlayStyle.contrastStroke(ctx, path)
                }
                let q = TextRenderer.docQuad(t).mapped { canvas.docToView($0) }
                OverlayStyle.contrastStroke(ctx, q.path, dashed: true)
                if let b = t.boxSize, t.orientation == .horizontal, TextRenderer.activeWarp(t) == nil {
                    for h in boxHandlesLocal(b) { OverlayStyle.handle(ctx, at: canvas.docToView(h.applying(m))) }
                }
            }
            layoutTextView()
        }
    }
}
