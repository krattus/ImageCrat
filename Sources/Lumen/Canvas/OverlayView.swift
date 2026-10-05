import AppKit
import ImageCratCore

final class OverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, let doc = canvas.document, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let z = canvas.zoom
        let canvasRect = canvas.docToView(doc.state.canvasCGRect)

        // Pixel grid
        if doc.showPixelGrid && z >= 12 {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(white: 0.5, alpha: 0.35).cgColor)
            ctx.setLineWidth(0.5)
            let vis = canvasRect.intersection(bounds)
            if !vis.isNull {
                // Visible doc range from all four corners: with a rotated view (Rotate View tool) the top-left /
                // bottom-right corners are not ordered, and `a...b` traps when a > b.
                let corners = [CGPoint(x: vis.minX, y: vis.minY), CGPoint(x: vis.maxX, y: vis.minY), CGPoint(x: vis.maxX, y: vis.maxY), CGPoint(x: vis.minX, y: vis.maxY)].map { canvas.viewToDoc($0) }
                let W = CGFloat(doc.state.width), H = CGFloat(doc.state.height)
                let x0 = max(0, floor(corners.map(\.x).min() ?? 0)), x1 = min(W, ceil(corners.map(\.x).max() ?? 0))
                let y0 = max(0, floor(corners.map(\.y).min() ?? 0)), y1 = min(H, ceil(corners.map(\.y).max() ?? 0))
                if x0.isFinite, x1.isFinite, y0.isFinite, y1.isFinite, x0 <= x1, y0 <= y1, (x1 - x0) + (y1 - y0) < 20_000 {
                    ctx.clip(to: vis)
                    for x in Int(x0)...Int(x1) {
                        ctx.move(to: canvas.docToView(CGPoint(x: CGFloat(x), y: y0))); ctx.addLine(to: canvas.docToView(CGPoint(x: CGFloat(x), y: y1)))
                    }
                    for y in Int(y0)...Int(y1) {
                        ctx.move(to: canvas.docToView(CGPoint(x: x0, y: CGFloat(y)))); ctx.addLine(to: canvas.docToView(CGPoint(x: x1, y: CGFloat(y))))
                    }
                    ctx.strokePath()
                }
            }
            ctx.restoreGState()
        }

        // Grid (spacing in ruler units, colour and subdivisions from Preferences)
        if doc.showGrid {
            let prefs = AppModel.shared.prefs
            ctx.saveGState()
            ctx.clip(to: canvasRect)
            let pu = CGFloat(prefs.rulerUnits == .percent ? 1 : prefs.rulerUnits.toPixels(1, ppi: doc.state.resolution))
            let s = max(2, CGFloat(prefs.gridSpacing) * pu)
            let sub = max(1, prefs.gridSubdivisions)
            let gc = prefs.gridColor
            let dense = s / CGFloat(sub) * z >= 6
            let stepPx = dense ? s / CGFloat(sub) : s
            func color(_ i: Int) -> CGColor {
                NSColor(calibratedRed: gc.r, green: gc.g, blue: gc.b, alpha: (!dense || i % sub == 0) ? 0.75 : 0.35).cgColor
            }
            ctx.setLineWidth(1)
            var x: CGFloat = 0, i = 0
            while x <= CGFloat(doc.state.width) {
                let vx = canvas.docToView(CGPoint(x: x, y: 0)).x
                ctx.setStrokeColor(color(i))
                ctx.move(to: CGPoint(x: vx, y: canvasRect.minY)); ctx.addLine(to: CGPoint(x: vx, y: canvasRect.maxY)); ctx.strokePath()
                x += stepPx; i += 1
            }
            var y: CGFloat = 0
            i = 0
            while y <= CGFloat(doc.state.height) {
                let vy = canvas.docToView(CGPoint(x: 0, y: y)).y
                ctx.setStrokeColor(color(i))
                ctx.move(to: CGPoint(x: canvasRect.minX, y: vy)); ctx.addLine(to: CGPoint(x: canvasRect.maxX, y: vy)); ctx.strokePath()
                y += stepPx; i += 1
            }
            ctx.restoreGState()
        }

        // Artboard outlines, names and selection highlight
        ArtboardCanvas.drawOverlay(ctx, canvas: canvas, doc: doc)

        // Guides
        if doc.showGuides {
            ctx.saveGState()
            let guideC = AppModel.shared.prefs.guideColor
            ctx.setStrokeColor(NSColor(calibratedRed: guideC.r, green: guideC.g, blue: guideC.b, alpha: 1).cgColor)
            ctx.setLineWidth(1)
            for g in doc.state.guides {
                if g.isVertical {
                    let vx = round(canvas.docToView(CGPoint(x: g.position, y: 0)).x) + 0.5
                    ctx.move(to: CGPoint(x: vx, y: 0)); ctx.addLine(to: CGPoint(x: vx, y: bounds.maxY))
                } else {
                    let vy = round(canvas.docToView(CGPoint(x: 0, y: g.position)).y) + 0.5
                    ctx.move(to: CGPoint(x: 0, y: vy)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: vy))
                }
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        if let gp = canvas.guidePreview {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(calibratedRed: 0, green: 0.85, blue: 1, alpha: 0.9).cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            if gp.vertical {
                let vx = canvas.docToView(CGPoint(x: gp.position, y: 0)).x
                ctx.move(to: CGPoint(x: vx, y: 0)); ctx.addLine(to: CGPoint(x: vx, y: bounds.maxY))
            } else {
                let vy = canvas.docToView(CGPoint(x: 0, y: gp.position)).y
                ctx.move(to: CGPoint(x: 0, y: vy)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: vy))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }

        // Selection marching ants
        if let sel = doc.state.selection, doc.showSelectionEdges, !doc.quickMask {
            let path = SelectionOps.outline(sel)
            var t = canvas.docToViewTransform
            if let p = path.copy(using: &t) {
                drawAnts(ctx, p, phase: canvas.antsPhase)
            }
        }

        // Feature-module overlays (slices, notes, count, color samplers, frames, symmetry axes, smart guides)
        ExtraOverlays.draw(ctx, canvas: canvas, doc: doc)
        AssistOverlay.draw(ctx, canvas: canvas, doc: doc)
        ArrangeGuide.draw(ctx, canvas: canvas)
        LayoutOverlays.draw(ctx, canvas: canvas, doc: doc)
        ArtistOverlays.draw(ctx, canvas: canvas, doc: doc)   // drawing guides, rulers, rope leash, eyedropper ring

        // The active path (Paths panel): a thin non-printing outline whatever the tool, until it is deselected
        PathOverlay.draw(ctx, canvas: canvas, doc: doc)

        // Tool overlay
        canvas.currentTool.drawOverlay(ctx)
        BrushHUD.shared.draw(ctx, canvas: canvas)   // ⌃⌥-drag resize / hardness circle, key readouts

        // Rulers
        if doc.showRulers { drawRulers(ctx, canvas: canvas, doc: doc) }
    }

    func drawAnts(_ ctx: CGContext, _ path: CGPath, phase: CGFloat) {
        ctx.saveGState()
        ctx.setLineWidth(1)
        ctx.setShouldAntialias(false)
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor.black.cgColor)
        ctx.setLineDash(phase: phase, lengths: [4, 4])
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawRulers(_ ctx: CGContext, canvas: CanvasView, doc: Document) {
        let rs = CanvasView.rulerSize
        ctx.saveGState()
        let bg = NSColor(white: 0.19, alpha: 1).cgColor
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: rs))
        ctx.fill(CGRect(x: 0, y: 0, width: rs, height: bounds.height))
        ctx.setStrokeColor(NSColor(white: 0.35, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 0, y: rs - 0.5)); ctx.addLine(to: CGPoint(x: bounds.width, y: rs - 0.5))
        ctx.move(to: CGPoint(x: rs - 0.5, y: 0)); ctx.addLine(to: CGPoint(x: rs - 0.5, y: bounds.height))
        ctx.strokePath()

        // choose tick step (in the preferred ruler unit)
        let z = canvas.zoom
        let unit = AppModel.shared.prefs.rulerUnits
        let ppi = doc.state.resolution
        let steps: [CGFloat] = [0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10000]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.7, alpha: 1)]
        ctx.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
        func label(_ v: CGFloat) -> String {
            abs(v - v.rounded()) < 0.001 ? "\(Int(v.rounded()))" : String(format: v * 10 == (v * 10).rounded() ? "%.1f" : "%.2f", v)
        }

        // zero point: the active artboard's top-left corner in an artboard document (as in Photoshop), else the canvas
        // corner; percentages refer to that artboard's size
        let o = ArtboardCoords.rulerOrigin(doc), span = ArtboardCoords.rulerSpan(doc)
        // horizontal
        let puX = CGFloat(unit.toPixels(1, ppi: ppi, total: Double(span.width)))
        // a zero / non-finite unit size (resolution 0) would make the tick loops below run forever
        guard puX > 0, puX.isFinite, CGFloat(unit.toPixels(1, ppi: ppi, total: Double(span.height))) > 0, z > 0, z.isFinite else { ctx.restoreGState(); return }
        let majorX = steps.first { $0 * puX * z >= 60 } ?? 10000
        let minorX = majorX / 10 * puX * z >= 5 ? majorX / 10 : majorX / 2
        let d0 = (canvas.viewToDoc(CGPoint(x: rs, y: 0)).x - o.x) / puX, d1 = (canvas.viewToDoc(CGPoint(x: bounds.width, y: 0)).x - o.x) / puX
        var x = floor(min(d0, d1) / minorX) * minorX
        while x <= max(d0, d1) {   // min / max: the view may be mirrored (View ▸ Flip Canvas View)
            let vx = round(canvas.docToView(CGPoint(x: o.x + x * puX, y: 0)).x) + 0.5
            let r = (x / majorX).rounded()
            let isMajor = abs(x - r * majorX) < minorX * 0.01
            ctx.move(to: CGPoint(x: vx, y: isMajor ? 2 : rs - 5)); ctx.addLine(to: CGPoint(x: vx, y: rs))
            if isMajor && vx > rs { NSString(string: label(x)).draw(at: CGPoint(x: vx + 2, y: 1), withAttributes: attrs) }
            x += minorX
        }
        // vertical
        let puY = CGFloat(unit.toPixels(1, ppi: ppi, total: Double(span.height)))
        let majorY = steps.first { $0 * puY * z >= 60 } ?? 10000
        let minorY = majorY / 10 * puY * z >= 5 ? majorY / 10 : majorY / 2
        let e0 = (canvas.viewToDoc(CGPoint(x: 0, y: rs)).y - o.y) / puY, e1 = (canvas.viewToDoc(CGPoint(x: 0, y: bounds.height)).y - o.y) / puY
        var y = floor(e0 / minorY) * minorY
        while y <= e1 {
            let vy = round(canvas.docToView(CGPoint(x: 0, y: o.y + y * puY)).y) + 0.5
            let r = (y / majorY).rounded()
            let isMajor = abs(y - r * majorY) < minorY * 0.01
            ctx.move(to: CGPoint(x: isMajor ? 2 : rs - 5, y: vy)); ctx.addLine(to: CGPoint(x: rs, y: vy))
            if isMajor && vy > rs {
                ctx.saveGState()
                ctx.translateBy(x: 1, y: vy + 2)
                ctx.rotate(by: .pi / 2)
                NSGraphicsContext.saveGraphicsState()
                NSString(string: label(y)).draw(at: CGPoint(x: 0, y: -rs + 3), withAttributes: attrs)
                NSGraphicsContext.restoreGraphicsState()
                ctx.restoreGState()
            }
            y += minorY
        }
        ctx.strokePath()

        // cursor markers
        if let m = canvas.lastMouseView {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.move(to: CGPoint(x: m.x, y: 0)); ctx.addLine(to: CGPoint(x: m.x, y: rs))
            ctx.move(to: CGPoint(x: 0, y: m.y)); ctx.addLine(to: CGPoint(x: rs, y: m.y))
            ctx.strokePath()
        }
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: rs, height: rs))
        ctx.restoreGState()
    }
}

// MARK: - Overlay drawing helpers

enum OverlayStyle {
    static let accent = NSColor(calibratedRed: 0.25, green: 0.6, blue: 1, alpha: 1)

    static func handle(_ ctx: CGContext, at p: CGPoint, size: CGFloat = 7, filled: Bool = false) {
        let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        ctx.setFillColor(filled ? accent.cgColor : NSColor.white.cgColor)
        ctx.fill(r)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
    }

    static func circleHandle(_ ctx: CGContext, at p: CGPoint, size: CGFloat = 7, filled: Bool = false) {
        let r = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        ctx.setFillColor(filled ? accent.cgColor : NSColor.white.cgColor)
        ctx.fillEllipse(in: r)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: r)
    }

    /// Double-stroke (black + white) path for visibility on any background.
    static func contrastStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat = 1, dashed: Bool = false) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width + 1.5)
        ctx.setStrokeColor(NSColor(white: 0, alpha: 0.6).cgColor)
        ctx.strokePath()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(NSColor.white.cgColor)
        if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func accentStroke(_ ctx: CGContext, _ path: CGPath, width: CGFloat = 1) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.setStrokeColor(accent.cgColor)
        ctx.strokePath()
        ctx.restoreGState()
    }

    static func label(_ text: String, at p: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        let sz = s.size()
        let r = CGRect(x: p.x + 14, y: p.y + 14, width: sz.width + 10, height: sz.height + 4)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        s.draw(at: CGPoint(x: r.minX + 5, y: r.minY + 2))
    }
}
