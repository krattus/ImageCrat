import AppKit
import CoreImage
import ImageCratCore

enum FillContents: String, CaseIterable, Identifiable {
    case foreground = "Foreground Color", background = "Background Color", color = "Color…", pattern = "Pattern", black = "Black", gray = "50% Gray", white = "White", contentAware = "Content-Aware"
    var id: String { rawValue }
}

enum StrokeLocation: String, CaseIterable, Identifiable { case inside = "Inside", center = "Center", outside = "Outside"; var id: String { rawValue } }

struct ClipboardContent {
    var buffer: PixelBuffer
    var origin: IPoint
    var changeCount: Int
}

extension AppActions {
    static var clipboard: ClipboardContent?
    /// Pasteboard behind Copy / Cut / Paste (the self tests swap in a private one so they never touch the user's clipboard).
    static var pasteboard: NSPasteboard = .general

    static var isTextEditing: Bool {
        if let r = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder, r is NSText { return true }
        return false
    }

    // MARK: Undo

    static func undo() {
        if isTextEditing { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil); return }
        if let c = canvas, c.currentTool.isBusy, c.currentTool.undoPending() { return }
        doc?.undo()
    }

    static func redo() {
        if isTextEditing { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil); return }
        doc?.redo()
    }

    static func stepBackward() { undo() }
    static func stepForward() { redo() }

    // MARK: Clipboard

    static func copy(merged: Bool = false) {
        if isTextEditing { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil); return }
        guard let d = doc else { return }
        let sp = space(d)
        var img: CIImage
        if merged {
            img = Compositor.shared.composite(d)
        } else {
            guard let l = d.activeLayer else { return }
            if d.editTarget == .mask, let m = l.mask {
                img = sp.place(m.buffer, at: m.origin)
            } else {
                img = Compositor.shared.contentImage(l, space: sp) ?? CIImage.clearImage
            }
        }
        var rect: IRect
        if let sel = d.state.selection, let b = sel.opaqueBounds() {
            img = img.masked(byGray: sel.ciImage.composited(over: CIImage.color(.black, img.extent.union(sp.ciCanvas))))
            rect = b
        } else {
            rect = IRect(enclosing: sp.docRect(img.extent)).intersection(d.state.canvasRect)
            if !merged, let l = d.activeLayer, let cb = Compositor.shared.contentBounds(l, state: d.state) {
                rect = IRect(enclosing: cb).intersection(d.state.canvasRect)
            }
        }
        guard !rect.isEmpty else { Beep.play(); return }
        let buf = RenderEngine.renderBuffer(img, docRect: rect, space: sp)
        let pb = pasteboard
        pb.clearContents()
        if let png = buf.pngData() { pb.setData(png, forType: .png) }
        clipboard = ClipboardContent(buffer: buf, origin: rect.origin, changeCount: pb.changeCount)
        ClipboardHistory.shared.noteInternalCopy(merged: merged)   // Clipboard History (layers keep full fidelity)
        app.setStatus("Copied \(rect.width) × \(rect.height) px")
    }

    static func cut() {
        if isTextEditing { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil); return }
        copy()
        clearSelectionPixels(name: "Cut")
    }

    static func paste(inPlace: Bool = false) {
        if isTextEditing { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil); return }
        if ClipboardHistory.shared.handlePaste(inPlace: inPlace) { return }   // copied layers (text, shapes, instances…) paste as layers
        if SVGImportUI.handlePaste(pasteboard) { return }                      // SVG markup (Figma, Illustrator, Sketch) pastes as editable artwork
        if PDFVectorImport.pasteVector(from: pasteboard, inPlace: inPlace) { return }   // vector PDF from Illustrator & co. pastes as editable layers
        let pb = pasteboard
        var buf: PixelBuffer?
        var origin: IPoint?
        if let c = clipboard, c.changeCount == pb.changeCount {
            buf = c.buffer
            origin = c.origin
        } else if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            buf = PixelBuffer(cgImage: cg)
        }
        guard let b = buf else {
            // text (from Notes, Safari, the Character Viewer…) pastes as a new type layer in the centre of the view
            if let s = TypeInput.text(from: pb), let c = canvas, c.document != nil, TypeInput.insert(s, canvas: c, actionName: "Paste") { return }
            Beep.play()
            return
        }
        guard let d = doc else {
            let nd = Document.newBlank(width: b.width, height: b.height, background: nil, name: "Untitled")
            nd.state.layers = [Layer.raster(name: "Layer 1", buffer: b.copy())]
            nd.commit("Paste")
            app.add(nd)
            return
        }
        var o: IPoint
        if inPlace, let org = origin {
            o = org
        } else if let c = canvas {
            let center = c.viewToDoc(CGPoint(x: c.bounds.midX, y: c.bounds.midY))
            let cc = CGPoint(x: clamp(center.x, 0, CGFloat(d.state.width)), y: clamp(center.y, 0, CGFloat(d.state.height)))
            o = IPoint(x: Int(cc.x) - b.width / 2, y: Int(cc.y) - b.height / 2)
            if let org = origin, !inPlace { o = org }
        } else {
            o = IPoint(x: (d.state.width - b.width) / 2, y: (d.state.height - b.height) / 2)
        }
        let layer = Layer.raster(name: d.nextLayerName(), buffer: b.copy(), origin: o)
        d.addLayer(layer)
        d.state.selection = nil
        d.commit("Paste")
    }

    /// Delete key / Edit > Clear: erase selected pixels (or delete layer if no selection).
    static func clearSelectionPixels(name: String = "Clear", commit: Bool = true) {
        if let d = doc, d.quickMask {   // clearing a channel fills it with the background colour (as in Photoshop)
            fill(.background, opacity: 1, mode: .normal, preserveTransparency: false, name: name, commit: commit)
            return
        }
        guard let d = doc, let id = d.activeLayerID, let l = d.state.layer(id) else { return }
        guard let sel = d.state.selection else {
            if name == "Clear" && !l.isRaster { deleteLayers() }
            else if name == "Clear" { deleteLayers() }
            return
        }
        let target: EditTarget = d.editTarget == .mask && l.mask != nil ? .mask : .content
        if target == .content && !l.isRaster { offerRasterize(layer: id); return }
        if l.locks.pixelsLocked || !l.isVisible {       // like the painting tools
            app.setStatus(l.isVisible ? "The layer is locked." : "The layer is hidden.")
            Beep.play()
            return
        }
        guard let (w, o) = d.beginPixelEdit(layerID: id, target: target) else { return }
        let ctx = w.context
        ctx.saveGState()
        w.clip(toMask: sel.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: d.state.width, height: d.state.height))
        if target == .mask {
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w.width, height: w.height))
        } else if l.locks.transparency {
            ctx.setFillColor(app.background.cgColor)
            ctx.setBlendMode(.sourceAtop)
            ctx.fill(CGRect(x: 0, y: 0, width: w.width, height: w.height))
        } else {
            ctx.setBlendMode(.destinationOut)
            ctx.setFillColor(RGBA.black.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w.width, height: w.height))
        }
        ctx.restoreGState()
        w.markDirty()
        if commit { d.commit(name) }
    }

    // MARK: Fill / Stroke

    static func fill(_ contents: FillContents, color: RGBA? = nil, patternID: String? = nil, opacity: Double, mode: BlendMode, preserveTransparency: Bool,
                     name: String = "Fill", commit: Bool = true) {
        guard let d = doc else { return }
        let target: EditTarget
        let l: Layer?
        if d.quickMask {            // Quick Mask mode fills the mask, whatever the layer
            target = .quickMask
            l = nil
            if contents == .contentAware { Beep.play(); return }
        } else {
            guard let id = d.activeLayerID, let al = d.state.layer(id) else { return }
            target = d.editTarget == .mask && al.mask != nil ? .mask : .content
            if target == .content && !al.isRaster { offerRasterize(layer: id); return }
            if contents == .contentAware {
                contentAwareFill()
                return
            }
            l = al
        }
        guard let (w, o) = d.beginPixelEdit(layerID: l?.id ?? UUID(), target: target) else { return }
        let ctx = w.context
        ctx.saveGState()
        if let sel = d.editSelection {
            w.clip(toMask: sel.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: d.state.width, height: d.state.height))
        }
        ctx.setAlpha(CGFloat(opacity))
        var cg = mode.cgBlendMode
        if target == .content, preserveTransparency || l?.locks.transparency == true { cg = .sourceAtop }
        ctx.setBlendMode(cg)
        let full = CGRect(x: 0, y: 0, width: w.width, height: w.height)
        var c: RGBA?
        switch contents {
        case .foreground: c = app.foreground
        case .background: c = app.background
        case .color: c = color ?? app.foreground
        case .black: c = .black
        case .white: c = .white
        case .gray: c = RGBA(gray: 0.5)
        case .pattern, .contentAware: c = nil
        }
        if let col = c {
            ctx.setFillColor((target.isMask ? RGBA(gray: col.luminance) : col).cgColor)
            ctx.fill(full)
        } else if let p = PatternLibrary.pattern(id: patternID ?? app.bucket.patternID, custom: app.customPatterns) {
            let img = p.image.makeCGImage()
            ctx.translateBy(x: CGFloat(-o.x), y: CGFloat(-o.y))
            ctx.scaleBy(x: 1, y: -1)   // undo the buffer flip so tiles are upright
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height), byTiling: true)
        }
        ctx.restoreGState()
        w.markDirty()
        if commit { d.commit(name) }
    }

    static func strokeSelection(width: Double, color: RGBA, location: StrokeLocation, opacity: Double, mode: BlendMode) {
        guard let d = doc, let sel = d.editSelection, let id = d.activeLayerID, let l = d.state.layer(id) else { Beep.play(); return }
        if !l.isRaster { offerRasterize(layer: id); return }
        let region: PixelBuffer
        switch location {
        case .inside: region = SelectionOps.combine(sel, SelectionOps.contract(sel, by: width), mode: .subtract)
        case .center: region = SelectionOps.combine(SelectionOps.expand(sel, by: width / 2), SelectionOps.contract(sel, by: width / 2), mode: .subtract)
        case .outside: region = SelectionOps.combine(SelectionOps.expand(sel, by: width), sel, mode: .subtract)
        }
        guard let (w, o) = d.beginPixelEdit(layerID: id, target: .content) else { return }
        let ctx = w.context
        ctx.saveGState()
        w.clip(toMask: region.makeCGImage(), in: CGRect(x: -o.x, y: -o.y, width: d.state.width, height: d.state.height))
        ctx.setAlpha(CGFloat(opacity))
        ctx.setBlendMode(mode.cgBlendMode)
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w.width, height: w.height))
        ctx.restoreGState()
        w.markDirty()
        d.commit("Stroke")
    }

    /// Simple content-aware fill: iterative diffusion from surrounding pixels plus texture from a nearby patch.
    static func contentAwareFill() {
        guard let d = doc, let sel = d.editSelection, let id = d.activeLayerID, let l = d.state.layer(id), l.isRaster else { Beep.play(); return }
        Healing.contentAwareFill(d, layerID: id, hole: SelectionOps.expand(sel, by: 2), sampleAll: false, name: "Content-Aware Fill")
    }

    // MARK: Transform commands

    /// Edit ▸ Free Transform / Transform ▸ … / Puppet, Perspective Warp, Content-Aware Scale have something to act on.
    static var canFreeTransform: Bool {
        guard let d = doc else { return false }
        return TransformSession.canStart(doc: d, layerIDs: MoveTool.transformLayerIDs(d))
    }

    static func freeTransform() {
        guard let c = canvas, doc != nil else { return }
        c.commitCurrentTool()
        app.tool = .move
        (c.tool(for: .move) as? MoveTool)?.startTransform()
    }

    static func transformSelectedLayers(_ make: (CGRect) -> Homography, name: String) {
        guard let d = doc else { return }
        // like Free Transform: linked layers transform together, a group transforms its children itself
        let ids = d.withoutDescendants(d.withLinked(d.orderedSelection)).filter { d.state.layer($0).map { !$0.locks.positionLocked } ?? false }
        var u: CGRect? = nil
        for id in ids { if let l = d.state.layer(id), let b = Compositor.shared.contentBounds(l, state: d.state) { u = u.map { $0.union(b) } ?? b } }
        guard let bounds = u else { Beep.play(); return }
        let h = make(bounds)
        let sp = space(d)
        for id in ids {
            guard let l = d.state.layer(id) else { continue }
            let nl = LayerTransformer.apply(h, to: l, space: sp, nearest: true)
            d.updateLayer(id) { $0 = nl }
        }
        d.commit(name)
    }

    static func flipLayers(horizontal: Bool) {
        transformSelectedLayers({ b in
            let c = b.center
            let t = CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: horizontal ? -1 : 1, y: horizontal ? 1 : -1).translatedBy(x: -c.x, y: -c.y)
            return Homography(affine: t)
        }, name: horizontal ? "Flip Horizontal" : "Flip Vertical")
    }

    static func rotateLayers(degrees: Double) {
        transformSelectedLayers({ b in
            // 90° turns pivot on a whole pixel so pixel layers stay on the grid; a half turn is on the grid around the
            // exact centre (rounding it would shift the layer by a pixel or two each time).
            let half = abs(abs(degrees) - 180) < 0.001
            let c = half ? b.center : CGPoint(x: b.midX.rounded(), y: b.midY.rounded())
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: CGFloat(degrees * .pi / 180)).translatedBy(x: -c.x, y: -c.y)
            return Homography(affine: t)
        }, name: "Rotate \(Int(abs(degrees)))°")
    }

    // MARK: Define brush / pattern

    static func definePattern() {
        guard let d = doc else { return }
        let sp = space(d)
        let rect = d.state.selection?.opaqueBounds() ?? d.state.canvasRect
        let buf = RenderEngine.renderBuffer(Compositor.shared.composite(d), docRect: rect, space: sp)
        let id = "custom-\(UUID().uuidString.prefix(8))"
        app.customPatterns.append(PatternDef(id: id, name: "Pattern \(app.customPatterns.count + 1)", image: buf))
        app.bucket.patternID = id
        app.setStatus("Pattern defined (\(rect.width)×\(rect.height)).")
    }

    /// Edit ▸ Define Brush Preset…: the selection (any shape) or the visible image becomes a brush in the library.
    static func defineBrush() { DefineBrush.run(.visible) }

}
