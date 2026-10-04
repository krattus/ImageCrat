import AppKit
import ImageCratCore

/// Selection Brush: paints the selection mask directly with a soft/hard brush (Option or the Subtract mode erases).
/// The selected area is shown as a colored overlay while the tool is active.
final class SelectionBrushTool: Tool {
    private var accum: PixelBuffer?
    private var placer = DabPlacer(spacing: 2, smoothing: 0)
    private var subtract = false

    override var cursor: NSCursor { .crosshair }

    override func mouseDown(_ e: ToolEvent) {
        guard let d = doc else { return }
        let s = ToolsSettings.shared.selectionBrush
        subtract = ToolsSettings.shared.selectionBrushSubtract != e.option
        accum = d.committedState.selection?.copy() ?? PixelBuffer(width: d.state.width, height: d.state.height, format: .gray)
        placer = DabPlacer(spacing: max(1, s.size * max(0.05, s.spacing)), smoothing: s.smoothing)
        for (p, pr) in placer.begin(e.doc, pressure: e.pressure) { SelectionBrushTool.dab(accum!, at: p, settings: s, pressure: pr, subtract: subtract) }
        preview()
    }

    override func mouseDragged(_ e: ToolEvent) {
        guard let a = accum else { return }
        let s = ToolsSettings.shared.selectionBrush
        for (p, pr) in placer.move(e.doc, pressure: e.pressure) { SelectionBrushTool.dab(a, at: p, settings: s, pressure: pr, subtract: subtract) }
        preview()
    }

    override func mouseUp(_ e: ToolEvent) {
        guard let d = doc, let a = accum else { return }
        let s = ToolsSettings.shared.selectionBrush
        for (p, pr) in placer.move(e.doc, pressure: e.pressure, final: true) { SelectionBrushTool.dab(a, at: p, settings: s, pressure: pr, subtract: subtract) }
        a.markDirty()
        d.revertUncommitted()
        d.setSelection(a, commitName: "Selection Brush")
        accum = nil
    }

    private func preview() {
        guard let d = doc, let a = accum else { return }
        a.markDirty()
        d.state.selection = a
        d.setNeedsOverlay()
    }

    /// Paints one dab into a canvas-size gray selection mask.
    static func dab(_ m: PixelBuffer, at p: CGPoint, settings s: BrushSettings, pressure: Double = 1, subtract: Bool) {
        var size = s.size
        if s.pressureSize { size *= max(0.05, pressure) }
        guard let tip = BrushTips.mask(diameter: size, hardness: s.hardness, roundness: s.roundness, angle: s.angle, tipID: s.tipID) else { return }
        let w = CGFloat(tip.width), h = CGFloat(tip.height)
        let r = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
        let ctx = m.context
        ctx.saveGState()
        m.clip(toMask: tip, in: r)
        ctx.setFillColor(gray: subtract ? 0 : 1, alpha: CGFloat(clamp(s.flow * s.opacity, 0, 1)))
        ctx.fill(r)
        ctx.restoreGState()
    }

    override func drawOverlay(_ ctx: CGContext) {
        let s = ToolsSettings.shared
        if let d = doc {
            let c = s.selectionOverlayColor
            let color = NSColor(calibratedRed: c.r, green: c.g, blue: c.b, alpha: s.selectionOverlayOpacity)
            if let sel = d.state.selection {
                ExtraOverlays.tint(ctx, canvas: canvas, doc: d, mask: sel.makeCGImage(), color: color)
            }
        }
        drawBrushCursor(ctx, size: s.selectionBrush.size, hardness: s.selectionBrush.hardness)
    }

    override func keyDown(_ e: NSEvent) -> Bool { BrushTool.handleBracketKeys(e) }
}
