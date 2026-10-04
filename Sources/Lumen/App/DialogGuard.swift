import AppKit
import CoreImage

/// Cleans up after dialogs that go away without their own OK / Cancel having run for the document they were editing.
///
/// Dialogs are in-window overlays driven by `AppModel.dialog`. Their previews live on the document
/// (`contentOverrides`, `displayOverride`, uncommitted live edits in `state`), and each dialog removes its own preview
/// in its OK / Cancel handler — for the *currently active* layer and document. Whenever the dialog is replaced by
/// another one, or the active layer / document changed while it was open (floating panels, scripts, plug-ins), that
/// clean-up missed its target and the canvas kept showing a preview of something that was never applied.
enum DialogGuard {
    /// Where the open dialog's live preview (`AppActions.setPreview`) sits.
    private static weak var previewDoc: Document?
    private static var previewLayer: UUID?

    static func notePreview(_ d: Document, _ layer: UUID) { previewDoc = d; previewLayer = layer }

    /// Removes the recorded dialog preview, wherever it was set.
    static func dropPreview() {
        if let d = previewDoc, let id = previewLayer, d.contentOverrides[id] != nil || d.maskOverrides[id] != nil {
            d.contentOverrides.removeValue(forKey: id)
            d.maskOverrides.removeValue(forKey: id)
            d.setNeedsRender()
        }
        previewDoc = nil; previewLayer = nil
    }

    /// True while a canvas session owns uncommitted state or previews of its own (text being typed, pending transform).
    private static var toolSessionActive: Bool {
        guard let c = AppActions.canvas else { return false }
        return c.currentTool.isBusy || PendingEdits.busyMoveTool != nil
    }

    /// Called whenever `AppModel.dialog` changes.
    static func dialogChanged(from old: ActiveDialog?, to new: ActiveDialog?) {
        guard let old, old.id != new?.id else { return }
        // Text typed into a field and never confirmed goes with the dialog (OK commits it before it runs).
        FieldEdits.discard()
        LayerStyleDialog.openingSection = nil
        if new == nil { DialogFocus.dialogClosed() }
        // The dialog is gone: so is its preview (a no-op after a normal OK / Cancel).
        dropPreview()
        CanvasSampler.shared.disarm()
        // Display-only previews of Select and Mask and the colour-mode dialogs, on whichever document they were set.
        var usesDisplayOverride = false
        if case .selectAndMask = old { usesDisplayOverride = true }
        if case .custom(let id) = old, id.hasPrefix("imaging.") { usesDisplayOverride = true }
        if usesDisplayOverride {
            for d in AppModel.shared.documents where d.displayOverride != nil {
                d.displayOverride = nil
                d.showSelectionEdges = true
                d.setNeedsRender()
            }
        }
        guard new != nil else { return }
        // Replaced by another dialog without OK / Cancel: that is a Cancel. Drop the blur gallery's pins and any
        // uncommitted live edits (smart-filter preview, layer style, global light, preview selections).
        if case .blurGallery = old, let st = AppActions.blurGallery {
            AppActions.blurGallery = nil
            if let mt = AppActions.canvas?.tool(for: .move) as? MoveTool, mt.interactive is BlurGallerySession { mt.interactive = nil }
            _ = st
        }
        if !toolSessionActive { AppActions.doc?.revertUncommitted() }
    }
}

/// Keyboard focus around dialogs. Dialogs are overlays inside the main window, so AppKit's key-view loop runs on into the
/// panels behind them: Tab from a dialog field moved focus to a panel field (Brush Settings Size, Properties X), which kept
/// it after OK — ⌘Z then edited that field's text instead of undoing the dialog's change (QA B03) — and a panel field
/// committing on blur baked the dialog's live preview into the document history (QA B10).
enum DialogFocus {
    /// The background view of the dialog card on screen (`DialogCardMarker`).
    static weak var marker: NSView?

    /// The view holding keyboard focus (for a text field being edited: the field, not the shared field editor).
    static func focusedView(_ w: NSWindow) -> NSView? {
        if let fe = w.firstResponder as? NSTextView, fe.isFieldEditor { return fe.delegate as? NSView }
        return w.firstResponder as? NSView
    }

    /// True if `v` belongs to the open dialog. The dialog layer is drawn above everything else in the window, and views
    /// are ordered back to front among their siblings, so `v` is part of it when its branch comes after the marker's
    /// branch below their common ancestor (a panel field under the card is not).
    static func inDialog(_ v: NSView) -> Bool {
        guard let m = marker, m.window != nil, m.window === v.window else { return false }
        var chain: [NSView] = []
        var x: NSView? = m
        while let y = x { chain.append(y); x = y.superview }
        var branch = v
        var up = v.superview
        while let s = up, !chain.contains(where: { $0 === s }) { branch = s; up = s.superview }
        guard let lca = up, let i = chain.firstIndex(where: { $0 === lca }), i > 0 else { return false }
        let markerBranch = chain[i - 1]
        guard let bi = lca.subviews.firstIndex(where: { $0 === branch }), let mi = lca.subviews.firstIndex(where: { $0 === markerBranch }) else { return false }
        return bi >= mi
    }

    /// The dialog's editable text fields, top to bottom, left to right.
    static func fields(_ w: NSWindow) -> [NSTextField] {
        var out: [NSTextField] = []
        func walk(_ v: NSView) {
            if let t = v as? NSTextField, t.isEditable, t.acceptsFirstResponder, !t.isHiddenOrHasHiddenAncestor { out.append(t) }
            for s in v.subviews { walk(s) }
        }
        if let c = w.contentView { walk(c) }
        func f(_ t: NSTextField) -> NSRect { t.convert(t.bounds, to: nil) }
        return out.filter(inDialog).sorted { abs(f($0).maxY - f($1).maxY) > 3 ? f($0).maxY > f($1).maxY : f($0).minX < f($1).minX }
    }

    /// Tab / ⇧Tab while a dialog is open cycle through the dialog's own controls. Returns true if it handled the key.
    static func handleTab(_ e: NSEvent) -> Bool {
        guard e.type == .keyDown, e.keyCode == 48, e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              AppModel.shared.dialog != nil, let w = marker?.window, e.window == nil || e.window === w else { return false }
        let back = e.modifierFlags.contains(.shift)
        if let v = focusedView(w), inDialog(v) {
            w.sendEvent(e)                                    // the dialog's own order (SwiftUI's focus loop)…
            if let v2 = focusedView(w), v2 !== v, inDialog(v2) { return true }
        }
        // …wrapping around instead of leaving the dialog; from outside the dialog Tab enters it
        let fs = fields(w)
        guard let target = back ? fs.last : fs.first else { return true }
        w.makeFirstResponder(target)
        target.scrollToVisible(target.bounds)
        return true
    }

    /// The dialog went away: a text field that kept keyboard focus (a dialog field being removed, or a panel field
    /// focus had escaped to) hands it back to the canvas, so ⌘Z / ⇧⌘Z act on the document straight away.
    static func dialogClosed() {
        guard let w = marker?.window ?? AppActions.canvas?.window, let fe = w.firstResponder as? NSTextView, fe.isFieldEditor else { return }
        if let c = AppActions.canvas, c.window === w { w.makeFirstResponder(c) } else { w.makeFirstResponder(nil) }
    }
}
