import AppKit
import CoreImage
import ImageCratCore

/// How an artboard document is shown: every visible artboard is a page (shadow, checkerboard under transparent
/// backgrounds) on the pasteboard; the rest of the canvas is pasteboard too, with layers outside the artboards drawn
/// straight onto it. Names sit above the pages: click one to select the artboard, drag it to move the artboard,
/// double-click it to rename, right-click it for the artboard menu.
enum ArtboardCanvas {
    /// Page backdrop in drawable pixels: (checkerboard inside the pages, soft shadow around them — or nothing, see
    /// Preferences ▸ Artboards ▸ Border —, the pasteboard colour). Nil when the document has no artboards (the whole
    /// canvas is the page then).
    static func pages(_ doc: Document, transform t: CGAffineTransform, scale s: CGFloat, size: CGSize, checkerOrigin: CGPoint) -> (checker: CIImage, shadow: CIImage)? {
        let boards = ArtboardOps.boards(doc.state)
        guard !boards.isEmpty else { return nil }
        let full = CGRect(origin: .zero, size: size)
        let H = CGFloat(doc.state.height)
        var shape = CIImage.empty()
        for l in boards where l.isVisible {
            guard let r = l.artboard?.rect, r.width > 0, r.height > 0 else { continue }
            let ci = CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
            shape = CIImage(color: .white).cropped(to: ci).transformed(by: t).composited(over: shape)
        }
        shape = shape.cropped(to: full)
        let checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: checkerOrigin.x, y: checkerOrigin.y),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8),
            "inputWidth": CGFloat(AppModel.shared.prefs.checkerSize) * s,
            "inputSharpness": 1,
        ])!.outputImage!.cropped(to: full).masked(byAlphaOf: shape)
        let prefs = ArtboardSettings.shared.prefs
        var shadow = prefs.border == .dropShadow
            ? CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.55)).cropped(to: full).masked(byAlphaOf: shape).applyingGaussianBlur(sigma: 4 * s).cropped(to: full)
            : CIImage.empty()
        // Preferences ▸ Artboards ▸ Color: the pasteboard around the artboards (Default: the workspace grey)
        if let m = prefs.matteColor {
            shadow = shadow.composited(over: CIImage(color: CIColor(red: m.r, green: m.g, blue: m.b)).cropped(to: full))
        }
        return (checker, shadow)
    }

    // MARK: Names, selection highlight

    static let labelFont = NSFont.systemFont(ofSize: 11)
    static let labelFontActive = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let labelHeight: CGFloat = 16

    /// An artboard counts as selected (highlighted) when it is in the layer selection.
    static func isSelected(_ l: Layer, _ d: Document) -> Bool { d.selectedLayerIDs.contains(l.id) }

    /// View rectangle of the artboard's name (above its top-left corner, at most as wide as the artboard).
    static func labelRect(_ l: Layer, canvas: CanvasView) -> CGRect? {
        guard let ab = l.artboard else { return nil }
        let p = canvas.docToView(CGPoint(x: ab.rect.minX, y: ab.rect.minY))
        let q = canvas.docToView(ab.rect)
        let w = NSString(string: l.name).size(withAttributes: [.font: labelFontActive]).width + 4
        return CGRect(x: p.x, y: p.y - labelHeight - 3, width: max(24, min(w, max(q.width, 24))), height: labelHeight)
    }

    /// View ▸ Show ▸ Artboard Names.
    static var namesShown: Bool { ArtboardSettings.shared.prefs.showNames }

    /// Topmost visible artboard whose name is under view point `v` (none while names are hidden).
    static func labelHit(_ v: CGPoint, canvas: CanvasView) -> Layer? {
        guard let d = canvas.document, namesShown else { return nil }
        return ArtboardOps.boards(d.state).reversed().first { $0.isVisible && (labelRect($0, canvas: canvas)?.insetBy(dx: -2, dy: -2).contains(v) ?? false) }
    }

    static func drawOverlay(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let boards = ArtboardOps.boards(doc.state).filter(\.isVisible)
        guard !boards.isEmpty else { return }
        let prefs = ArtboardSettings.shared.prefs
        for l in boards {
            guard let ab = l.artboard, let lr = labelRect(l, canvas: canvas) else { continue }
            let active = isSelected(l, doc)
            let outline = canvas.docToViewPath(ab.rect)
            ctx.saveGState()
            var stroke = true
            if active {   // (the selection highlight shows whatever the border style)
                ctx.setStrokeColor(OverlayStyle.accent.cgColor)
                ctx.setLineWidth(1.5)
            } else {
                switch prefs.border {
                case .dropShadow: ctx.setStrokeColor(NSColor(white: 0, alpha: 0.35).cgColor); ctx.setLineWidth(1)
                case .line: ctx.setStrokeColor(NSColor(white: 0, alpha: 0.85).cgColor); ctx.setLineWidth(1)
                case .none: stroke = false
                }
            }
            if stroke {
                ctx.addPath(outline)
                ctx.strokePath()
            }
            ctx.restoreGState()
            if renaming?.id == l.id || !prefs.showNames { continue }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let attrs: [NSAttributedString.Key: Any] = [.font: active ? labelFontActive : labelFont, .paragraphStyle: para,
                                                        .foregroundColor: active ? NSColor.white : NSColor(white: 0.72, alpha: 1)]
            NSGraphicsContext.saveGraphicsState()
            NSString(string: l.name).draw(with: lr.insetBy(dx: 1, dy: 0), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: Rename in place (double-click a name)

    final class RenameField: NSTextField, NSTextFieldDelegate {
        var id = UUID()
        weak var doc: Document?
        var done = false
        func finish(commit: Bool) {
            guard !done else { return }
            done = true
            if commit, let d = doc { ArtboardOps.rename(d, id, stringValue) }
            let sv = superview
            removeFromSuperview()
            if ArtboardCanvas.renaming === self { ArtboardCanvas.renaming = nil }
            sv?.needsDisplay = true
            (sv as? CanvasView)?.overlay.needsDisplay = true
        }
        func controlTextDidEndEditing(_ obj: Notification) {
            let move = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
            finish(commit: move != NSTextMovement.cancel.rawValue)
        }
        override func cancelOperation(_ sender: Any?) { finish(commit: false) }
    }

    nonisolated(unsafe) static weak var renaming: RenameField?

    @discardableResult
    static func beginRename(_ id: UUID, canvas: CanvasView) -> RenameField? {
        guard let d = canvas.document, let l = d.state.layer(id), l.isArtboard, let r = labelRect(l, canvas: canvas) else { return nil }
        renaming?.finish(commit: true)
        let f = RenameField(frame: CGRect(x: r.minX - 2, y: r.minY - 2, width: max(140, r.width + 40), height: r.height + 4))
        f.id = id
        f.doc = d
        f.stringValue = l.name
        f.font = labelFontActive
        f.isBordered = true
        f.focusRingType = .none
        f.delegate = f
        f.target = f
        f.action = #selector(RenameField.commitAction)
        canvas.addSubview(f)
        renaming = f
        canvas.window?.makeFirstResponder(f)
        f.currentEditor()?.selectAll(nil)
        canvas.overlay.needsDisplay = true
        return f
    }

    // MARK: Canvas hooks (called from CanvasView)

    /// Mouse-down on an artboard's name with the Move or Artboard tool: the Artboard tool takes the gesture (select,
    /// drag to move, double-click to rename).
    static func toolForLabelClick(_ e: ToolEvent, canvas: CanvasView) -> Tool? {
        let k = AppModel.shared.tool
        guard k == .move || k == .artboard, !canvas.currentTool.isBusy, labelHit(e.view, canvas: canvas) != nil else { return nil }
        return canvas.tool(for: .artboard)
    }

    /// Right-click on an artboard's name (any tool), or inside an artboard with the Artboard tool.
    static func contextMenu(_ e: ToolEvent, canvas: CanvasView) -> NSMenu? {
        guard let d = canvas.document else { return nil }
        let hit = labelHit(e.view, canvas: canvas) ?? (AppModel.shared.tool == .artboard ? ArtboardOps.artboard(at: e.doc, d.state) : nil)
        guard let l = hit else { return nil }
        if !d.selectedLayerIDs.contains(l.id) { d.selectLayer(l.id); AppModel.shared.sessionTick += 1 }
        return ArtboardMenu.nsMenu(ArtboardMenu.items(d, l.id, rename: { _ = beginRename(l.id, canvas: canvas) }))
    }
}

extension ArtboardCanvas.RenameField {
    @objc func commitAction() { finish(commit: true) }
}
