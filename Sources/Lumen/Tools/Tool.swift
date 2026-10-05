import AppKit
import ImageCratCore

class Tool {
    unowned let canvas: CanvasView
    let kind: ToolKind

    init(kind: ToolKind, canvas: CanvasView) {
        self.kind = kind
        self.canvas = canvas
    }

    var doc: Document? { canvas.document }
    var app: AppModel { AppModel.shared }

    var cursor: NSCursor { .arrow }

    func activate() {}
    func deactivate() { commit() }
    func documentWillChange(_ old: Document) { cancel() }

    func mouseDown(_ e: ToolEvent) {}
    func mouseDragged(_ e: ToolEvent) {}
    func mouseUp(_ e: ToolEvent) {}
    func mouseMoved(_ e: ToolEvent) {}
    func keyDown(_ e: NSEvent) -> Bool { false }
    func flagsChanged(_ m: NSEvent.ModifierFlags) {}
    func drawOverlay(_ ctx: CGContext) {}
    func commit() {}
    func cancel() {}
    func contextMenu(_ e: ToolEvent) -> NSMenu? { nil }

    /// Whether the tool has an uncommitted interactive session (e.g. transform, crop).
    var isBusy: Bool { false }

    /// What happens to a busy tool's unconfirmed edit when another command is about to change the document
    /// (see `PendingEdits`).
    enum PendingPolicy {
        /// The edit stays open (it does not depend on the document, or the tool re-validates itself).
        case keep
        /// The edit is applied first, like Photoshop's "Apply the transformation?".
        case commit
        /// Applied first, except for commands that belong to the text editor itself (Edit / Type menus, context
        /// menus, panels such as Character and Paragraph).
        case commitExceptTextCommands
    }
    var pendingPolicy: PendingPolicy { .keep }

    /// Edit ▸ Undo while the tool is busy. The default cancels the pending edit (like Esc) and consumes the undo;
    /// tools that record every step in the history return false so the document undoes one step.
    func undoPending() -> Bool { cancel(); return true }

    /// The document was changed underneath a busy tool (another command recorded a step, or the history jumped):
    /// drop previews and handles that no longer match it, without touching the document.
    func abandonPending() {}

    /// Refuses edits of a fully locked layer (`position`: also of a position-locked one). Returns false after telling the user.
    func canModify(_ layer: Layer, position: Bool = false) -> Bool {
        if layer.locks.all || (position && layer.locks.position) {
            status("The layer is locked.")
            Beep.play()
            return false
        }
        return true
    }

    func status(_ s: String) { app.setStatus(s) }

    func refuseInQuickMask() {
        status("The \(kind.displayName.replacingOccurrences(of: " Tool", with: "")) can't paint in Quick Mask mode. Press Q to leave it.")
        Beep.play()
    }

    static func make(_ k: ToolKind, canvas: CanvasView) -> Tool {
        switch k {
        case .move: return MoveTool(kind: k, canvas: canvas)
        case .marqueeRect, .marqueeEllipse, .marqueeRow, .marqueeColumn: return MarqueeTool(kind: k, canvas: canvas)
        case .lasso: return LassoTool(kind: k, canvas: canvas)
        case .polygonLasso: return PolygonLassoTool(kind: k, canvas: canvas)
        case .magneticLasso: return MagneticLassoTool(kind: k, canvas: canvas)
        case .objectSelect: return ObjectSelectTool(kind: k, canvas: canvas)
        case .patch: return PatchTool(kind: k, canvas: canvas)
        case .contentAwareMove: return ContentAwareMoveTool(kind: k, canvas: canvas)
        case .removeTool: return RemoveTool(kind: k, canvas: canvas)
        case .redEye: return RedEyeTool(kind: k, canvas: canvas)
        case .colorReplacement: return ColorReplacementTool(kind: k, canvas: canvas)
        case .mixerBrush: return MixerBrushTool(kind: k, canvas: canvas)
        case .rotateView: return RotateViewTool(kind: k, canvas: canvas)
        case .magicWand: return MagicWandTool(kind: k, canvas: canvas)
        case .quickSelect: return QuickSelectTool(kind: k, canvas: canvas)
        case .crop: return StraightenCropTool(kind: k, canvas: canvas)
        case .eyedropper: return EyedropperTool(kind: k, canvas: canvas)
        case .brush, .pencil, .eraser, .historyBrush: return BrushTool(kind: k, canvas: canvas)
        case .cloneStamp, .healing, .spotHealing: return CloneTool(kind: k, canvas: canvas)
        case .magicEraser: return MagicEraserTool(kind: k, canvas: canvas)
        case .gradient: return GradientTool(kind: k, canvas: canvas)
        case .paintBucket: return PaintBucketTool(kind: k, canvas: canvas)
        case .blur, .sharpen, .smudge, .dodge, .burn, .sponge: return RetouchTool(kind: k, canvas: canvas)
        case .pen, .freeformPen: return PenTool(kind: k, canvas: canvas)
        case .directSelect, .pathSelect: return PathSelectTool(kind: k, canvas: canvas)
        case .text, .verticalText: return TextTool(kind: k, canvas: canvas)
        case .rectangle, .roundedRect, .ellipse, .polygon, .line, .customShape, .libraryShape: return ShapeTool(kind: k, canvas: canvas)
        case .hand: return HandTool(kind: k, canvas: canvas)
        case .zoom: return ZoomTool(kind: k, canvas: canvas)
        default: return ExtraToolInfo.makeTool(k, canvas: canvas)
        }
    }

    // MARK: Shared helpers

    /// Draws the painting cursor at the mouse location: the brush tip's outline (shape, angle, roundness) at `size`,
    /// scaled by the zoom and view rotation (see `BrushCursor`).
    func drawBrushCursor(_ ctx: CGContext, size: Double, hardness: Double = 1) {
        let s: BrushSettings? = AppModel.hasBrush(kind) ? app.brushSettings(for: kind) : nil
        BrushCursor.draw(ctx, canvas: canvas, size: size, hardness: hardness, settings: s)
    }

    /// True when the pixels of `layer` may be edited: not pixel-locked and not hidden. Tells the user otherwise.
    func pixelsEditable(_ layer: Layer) -> Bool {
        if layer.locks.pixelsLocked {
            status("The layer is locked.")
            Beep.play()
            return false
        }
        if !layer.isVisible {
            status("The layer is hidden.")
            Beep.play()
            return false
        }
        return true
    }

    /// Active layer id, ensuring there is an editable pixel target; shows a message otherwise.
    func requirePixelTarget() -> (Document, UUID, EditTarget)? {
        if let d = doc, d.quickMask {
            // Quick Mask mode: the mask is painted whatever the layer (it needs no pixel layer, and locks don't apply)
            guard kind.editsQuickMask else { refuseInQuickMask(); return nil }
            return (d, d.activeLayerID ?? d.state.layers.last?.id ?? UUID(), .quickMask)
        }
        guard let d = doc, let id = d.activeLayerID, let layer = d.state.layer(id) else {
            status("No layer selected.")
            return nil
        }
        if d.editTarget == .mask && layer.mask != nil {
            // the mask of a fully locked or hidden layer can't be painted either
            if layer.locks.all { status("The layer is locked."); Beep.play(); return nil }
            if !layer.isVisible { status("The layer is hidden."); Beep.play(); return nil }
            return (d, id, .mask)
        }
        if !layer.isRaster {
            if layer.isText || layer.isShape || layer.isSmartObject || layer.isFill {
                AppActions.offerRasterize(layer: id)
            } else {
                status("The selected layer can't be painted on. Select a pixel layer.")
            }
            return nil
        }
        if layer.locks.pixelsLocked {
            status("The layer is locked.")
            Beep.play()
            return nil
        }
        if !layer.isVisible {
            status("The layer is hidden.")
            Beep.play()
            return nil
        }
        return (d, id, .content)
    }
}

// MARK: - Navigation tools

final class HandTool: Tool {
    private var last: CGPoint?
    override var cursor: NSCursor { last == nil ? .openHand : .closedHand }
    override func mouseDown(_ e: ToolEvent) {
        last = e.view
        if e.clickCount == 2 { canvas.fitOnScreen() }
        NSCursor.closedHand.set()
    }
    override func mouseDragged(_ e: ToolEvent) {
        guard let l = last else { return }
        canvas.pan(by: e.view - l)
        last = e.view
    }
    override func mouseUp(_ e: ToolEvent) {
        last = nil
        NSCursor.openHand.set()
    }
}

final class ZoomTool: Tool {
    private var start: CGPoint?
    private var current: CGPoint?
    override var cursor: NSCursor { NSCursor.crosshair }

    override func mouseDown(_ e: ToolEvent) {
        start = e.view
        current = e.view
    }
    override func mouseDragged(_ e: ToolEvent) { current = e.view }
    override func mouseUp(_ e: ToolEvent) {
        defer { start = nil; current = nil }
        guard let s = start, let c = current, let d = doc else { return }
        if s.distance(to: c) > 8 && !e.option {
            // Zoom so the dragged view rectangle fills the view, centred. Done in view space, so it is also right when
            // the view is rotated (two doc-space corners of the box do not describe it then).
            let r = CGRect(p1: s, p2: c)
            let k = min(canvas.bounds.width / max(r.width, 0.001), canvas.bounds.height / max(r.height, 0.001))
            let center = CGPoint(x: r.midX, y: r.midY)
            canvas.setZoom(d.zoom * Double(k), anchorView: center)
            canvas.pan(by: CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY) - center)
        } else if e.option {
            canvas.zoomOut(at: e.view)
        } else {
            canvas.zoomIn(at: e.view)
        }
    }
    override func drawOverlay(_ ctx: CGContext) {
        guard let s = start, let c = current, s.distance(to: c) > 8 else { return }
        OverlayStyle.contrastStroke(ctx, CGPath(rect: CGRect(p1: s, p2: c), transform: nil), dashed: true)
    }
}

final class EyedropperTool: Tool {
    override var cursor: NSCursor { .crosshair }
    private var sampleBuffer: PixelBuffer?

    override func mouseDown(_ e: ToolEvent) {
        sampleBuffer = AppActions.sampleSource(allLayers: app.eyedropperAllLayers)
        sample(e)
    }
    override func mouseDragged(_ e: ToolEvent) { sample(e) }
    override func mouseUp(_ e: ToolEvent) {
        sample(e)
        app.pushRecent(e.option ? app.background : app.foreground)
        sampleBuffer = nil
    }

    private func sample(_ e: ToolEvent) {
        guard let b = sampleBuffer, let c = EyedropperTool.average(b, at: e.doc, size: app.eyedropperSample) else { return }
        if e.option { app.background = c } else { app.foreground = c }
    }

    static func average(_ b: PixelBuffer, at p: CGPoint, size: Int) -> RGBA? {
        let x = Int(floor(p.x)), y = Int(floor(p.y))
        guard x >= 0, y >= 0, x < b.width, y < b.height else { return nil }
        let r = size / 2
        var sr = 0.0, sg = 0.0, sb = 0.0, sa = 0.0, n = 0.0
        for yy in (y - r)...(y + r) {
            for xx in (x - r)...(x + r) where xx >= 0 && yy >= 0 && xx < b.width && yy < b.height {
                let (pr, pg, pb, pa) = b.pixel(xx, yy)
                sr += Double(pr); sg += Double(pg); sb += Double(pb); sa += Double(pa); n += 1
            }
        }
        guard n > 0 else { return nil }
        return RGBA(r: sr / n / 255, g: sg / n / 255, b: sb / n / 255, a: 1)
    }

    override func drawOverlay(_ ctx: CGContext) {
        guard let m = canvas.lastMouseView else { return }
        let r = CGRect(x: m.x - 14, y: m.y - 14, width: 28, height: 28)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(3)
        ctx.strokeEllipse(in: r)
        ctx.setStrokeColor(app.foreground.cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: r.insetBy(dx: 2, dy: 2))
    }
}
