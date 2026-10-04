import AppKit
import ImageCratCore

/// Horizontal / Vertical Type Mask tools: type as with the Type tool (a red quick-mask overlay shows the mask);
/// committing turns the type outline into a selection instead of creating a type layer.
/// Shift adds to / Option subtracts from an existing selection.
final class TypeMaskTool: Tool {
    private(set) lazy var inner: TextTool = {
        let t = TextTool(kind: kind == .typeMaskVertical ? .verticalText : .text, canvas: canvas)
        // however the edit ends (Esc / Enter in the editor, click away, tool or document switch), convert right away
        t.onEditingEnded = { [weak self] in self?.checkPending() }
        return t
    }()
    private var pendingLayer: UUID?
    /// Document the pending type layer lives in (the canvas may show another one when the edit ends).
    private weak var pendingDoc: Document?
    private var combine: SelectionCombine = .new

    override var cursor: NSCursor { .iBeam }
    override var isBusy: Bool { inner.isBusy }
    override var pendingPolicy: PendingPolicy { .commitExceptTextCommands }
    override func abandonPending() { inner.abandonPending(); if !inner.isBusy { pendingLayer = nil; pendingDoc = nil } }

    override func activate() { inner.activate() }
    override func deactivate() { inner.deactivate(); checkPending() }
    override func commit() { inner.commit(); checkPending() }
    override func cancel() { inner.cancel(); pendingLayer = nil; pendingDoc = nil }
    override func documentWillChange(_ old: Document) { inner.documentWillChange(old); checkPending() }

    override func mouseDown(_ e: ToolEvent) {
        let wasEditing = inner.isBusy
        if !wasEditing {
            combine = e.shift ? .add : (e.option ? .subtract : .new)
        }
        // never pick up existing type layers: Shift makes the Type tool create new type
        var ev = e
        ev.modifiers.insert(.shift)
        inner.mouseDown(ev)
        if wasEditing { checkPending(); return }
    }

    override func mouseDragged(_ e: ToolEvent) { inner.mouseDragged(e) }

    override func mouseUp(_ e: ToolEvent) {
        inner.mouseUp(e)
        if inner.isBusy, let d = doc { pendingLayer = inner.editingID ?? d.activeLayerID; pendingDoc = d; TypeMaskTool.active = self }
    }

    override func mouseMoved(_ e: ToolEvent) { inner.mouseMoved(e) }
    override func keyDown(_ e: NSEvent) -> Bool { inner.keyDown(e) }

    /// The tool waiting for its type layer to be committed.
    nonisolated(unsafe) static weak var active: TypeMaskTool?

    /// Called after commits: converts the committed type layer into a selection.
    func checkPending() {
        guard let id = pendingLayer, !inner.isBusy, let d = pendingDoc ?? doc else { return }
        pendingLayer = nil
        pendingDoc = nil
        guard let t = d.state.layer(id)?.text, d.committedState.layer(id) != nil else { return }   // cancelled / empty
        let path = TextRenderer.outlinePath(t)
        let mode = combine
        if d.historyIndex > 0, d.history[d.historyIndex].state.layer(id) != nil, d.history[d.historyIndex - 1].state.layer(id) == nil {
            // Replace the "Type Layer" history step by the selection.
            d.undo()
        } else {
            // Other commands were recorded while typing: just drop the helper layer together with the selection step.
            d.state.removeLayer(id)
            d.validateActiveLayer()
        }
        TypeMaskTool.applySelection(d, path: path, mode: mode)
    }

    /// Makes the selection from a type outline (also used by the self test).
    static func applySelection(_ d: Document, path: CGPath, mode: SelectionCombine) {
        let m = SelectionOps.mask(fromPath: path, width: d.state.width, height: d.state.height, antialias: true)
        let combined = SelectionOps.combine(d.state.selection, m, mode: mode)
        d.setSelection(combined, commitName: "Type Mask")
    }

    static func selection(for t: TextContent, in st: DocumentState) -> PixelBuffer {
        SelectionOps.mask(fromPath: TextRenderer.outlinePath(t), width: st.width, height: st.height, antialias: true)
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let d = doc else { return }
        if inner.isBusy {
            // quick-mask style: red over everything except the type
            let r = canvas.docToView(d.state.canvasCGRect)
            ctx.saveGState()
            ctx.addRect(r)
            if let id = pendingLayer ?? d.activeLayerID, let t = inner.currentModel ?? d.state.layer(id)?.text {
                var tr = canvas.docToViewTransform
                if let p = TextRenderer.outlinePath(t).copy(using: &tr) { ctx.addPath(p) }
            }
            ctx.setFillColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 0.4).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        inner.drawOverlay(ctx)
    }

    /// Commit hook: after the Type tool records its layer, turn it into a selection.
    static func handleCommit(_ d: Document) {
        guard let t = active, t.pendingLayer != nil, (t.pendingDoc ?? t.doc) === d else { return }
        DispatchQueue.main.async { t.checkPending() }
    }
}
