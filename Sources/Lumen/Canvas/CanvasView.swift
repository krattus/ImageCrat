import AppKit
import MetalKit
import CoreImage
import ImageCratCore

struct ToolEvent {
    var doc: CGPoint
    var view: CGPoint
    var pressure: Double
    var modifiers: NSEvent.ModifierFlags
    var clickCount: Int
    var isTablet: Bool
    /// Tablet pen tilt (each axis -1...1), barrel rotation (degrees) and stylus wheel (-1...1); zero for mice.
    var tilt: CGPoint = .zero
    var rotation: Double = 0
    var tangentialPressure: Double = 0

    var shift: Bool { modifiers.contains(.shift) }
    var option: Bool { modifiers.contains(.option) }
    var command: Bool { modifiers.contains(.command) }
    var control: Bool { modifiers.contains(.control) }
}

final class PassthroughMTKView: MTKView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CanvasView: NSView {
    static let rulerSize: CGFloat = 18

    let metalView: PassthroughMTKView
    let overlay: OverlayView
    private let renderer: CanvasRenderer
    private var tools: [ToolKind: Tool] = [:]
    private var spaceDown = false
    private var dragTool: Tool?
    private var antsTimer: Timer?
    var antsPhase: CGFloat = 0
    var lastMouseView: CGPoint?
    private var trackingArea: NSTrackingArea?
    private var draggingGuide: (id: UUID?, vertical: Bool)?
    /// Where the canvas was last clicked (document point), and a count of clicks: characters picked in the Character
    /// Viewer with nothing being edited go there (see `TypeInput`).
    var lastClick: (docID: UUID, point: CGPoint)?
    private(set) var clickSerial = 0

    weak var document: Document? {
        didSet {
            if oldValue !== document {
                oldValue?.renderCallback = nil
                oldValue?.overlayCallback = nil
                if let old = oldValue { tools.values.forEach { $0.documentWillChange(old) } }
                if let t = dragTool, let old = oldValue {
                    // The mouse is still down: that drag belongs to the old document. Drop it together with whatever it
                    // left unrecorded there, so the mouse-up can't finish it in the wrong document.
                    old.revertUncommitted()
                    old.contentOverrides.removeAll(); old.hiddenLayers.removeAll(); old.displayOverride = nil
                    old.showSelectionEdges = true
                    if let k = tools.first(where: { $0.value === t })?.key { tools[k] = nil }     // a fresh tool next time
                    dragTool = nil
                }
                draggingGuide = nil
                attach()
            }
        }
    }

    override init(frame: NSRect) {
        metalView = PassthroughMTKView(frame: frame, device: RenderEngine.device)
        overlay = OverlayView(frame: frame)
        renderer = CanvasRenderer()
        super.init(frame: frame)
        wantsLayer = true
        metalView.framebufferOnly = false
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.autoResizeDrawable = true
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.clearColor = MTLClearColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 1)
        (metalView.layer as? CAMetalLayer)?.colorspace = sRGBSpace
        metalView.delegate = renderer
        renderer.canvas = self
        metalView.autoresizingMask = [.width, .height]
        overlay.autoresizingMask = [.width, .height]
        overlay.canvas = self
        addSubview(metalView)
        addSubview(overlay)
        antsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let d = self.document, d.state.selection != nil, d.showSelectionEdges else { return }
            self.antsPhase = (self.antsPhase + 1).truncatingRemainder(dividingBy: 8)
            self.overlay.needsDisplay = true
        }
        AppModel.shared.toolChanged = { [weak self] old, new in
            self?.toolSwitched(from: old, to: new)
        }
        registerForDraggedTypes([.fileURL, .png, .tiff, .string, .rtf])   // text: emoji / text dragged from other apps
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func attach() {
        guard let d = document else {
            metalView.needsDisplay = true
            overlay.needsDisplay = true
            return
        }
        d.renderCallback = { [weak self] in self?.setNeedsRender() }
        d.overlayCallback = { [weak self] in self?.overlay.needsDisplay = true }
        if d.needsFitOnScreen && bounds.width > 10 { fitOnScreen() }
        setNeedsRender()
        currentTool.activate()
    }

    func setNeedsRender() {
        metalView.needsDisplay = true
        overlay.needsDisplay = true
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        overlay.frame = bounds
        if let d = document, d.needsFitOnScreen, bounds.width > 10 { fitOnScreen() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setNeedsRender()
    }

    // MARK: View transform

    var zoom: CGFloat { CGFloat(document?.zoom ?? 1) }
    var offset: CGPoint { document?.viewOffset ?? .zero }

    var rotation: CGFloat { CGFloat(document?.viewRotation ?? 0) }

    /// Doc → view: rotate, scale, then offset (view is flipped, y-down).
    var docToViewTransform: CGAffineTransform {
        let c = cos(rotation) * zoom, sn = sin(rotation) * zoom
        let f: CGFloat = ArtistView.isFlipped(document) ? -1 : 1   // View ▸ Flip Canvas View (view only)
        return CGAffineTransform(a: c * f, b: sn * f, c: -sn, d: c, tx: offset.x, ty: offset.y)
    }
    func docToView(_ p: CGPoint) -> CGPoint { p.applying(docToViewTransform) }
    func viewToDoc(_ p: CGPoint) -> CGPoint { p.applying(docToViewTransform.inverted()) }
    /// Bounding box of a doc rect in view space (exact when the view isn't rotated).
    func docToView(_ r: CGRect) -> CGRect { r.applying(docToViewTransform) }
    /// Exact outline of a doc rect in view space (respects view rotation).
    func docToViewPath(_ r: CGRect) -> CGPath { Quad(rect: r).mapped { docToView($0) }.path }

    /// Linear part (rotation × zoom) applied to a doc vector.
    func linear(_ v: CGPoint, zoom z: CGFloat) -> CGPoint {
        let c = cos(rotation), sn = sin(rotation)
        let vx = ArtistView.isFlipped(document) ? -v.x : v.x
        return CGPoint(x: (vx * c - v.y * sn) * z, y: (vx * sn + v.y * c) * z)
    }

    func setRotation(_ a: Double) {
        guard let d = document else { return }
        ZoomAnimator.stop()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let docPt = viewToDoc(center)
        d.viewRotation = a
        d.viewOffset = center - linear(docPt, zoom: zoom)
        setNeedsRender()
    }

    var contentInsets: NSEdgeInsets {
        let r = (document?.showRulers ?? false) ? CanvasView.rulerSize : 0
        return NSEdgeInsets(top: r, left: r, bottom: 0, right: 0)
    }

    /// Whole canvas, centred in the area right of / below the rulers (rotated views fit their rotated outline).
    func fitOnScreen(animated: Bool = false) {
        guard let d = document, bounds.width > 10, bounds.height > 10 else { return }
        fit(fitTarget(d), mode: .fit, animated: animated)
        d.needsFitOnScreen = false
    }

    func centerCanvas() {
        guard let d = document else { return }
        let ins = contentInsets
        let viewCenter = CGPoint(x: ins.left + (bounds.width - ins.left) / 2, y: ins.top + (bounds.height - ins.top) / 2)
        let docCenter = CGPoint(x: CGFloat(d.state.width) / 2, y: CGFloat(d.state.height) / 2)
        d.viewOffset = viewCenter - linear(docCenter, zoom: CGFloat(d.zoom))
    }

    func setZoom(_ z: Double, anchorView: CGPoint? = nil) {
        guard let d = document else { return }
        ZoomAnimator.stop()
        let nz = ZoomMath.clamp(z)
        let anchor = anchorView ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let docPt = viewToDoc(anchor)
        d.zoom = nz
        d.viewOffset = anchor - linear(docPt, zoom: CGFloat(nz))
        setNeedsRender()
    }

    static let zoomSteps: [Double] = [0.01, 0.02, 0.03, 0.04, 0.05, 0.0625, 0.0833, 0.125, 0.1667, 0.25, 0.333, 0.5, 0.6667, 1, 2, 3, 4, 5, 6, 7, 8, 12, 16, 24, 32, 64]

    func zoomIn(at p: CGPoint? = nil) {
        let z = document?.zoom ?? 1
        setZoom(ZoomMath.stepIn(z), anchorView: p)
    }

    func zoomOut(at p: CGPoint? = nil) {
        let z = document?.zoom ?? 1
        setZoom(ZoomMath.stepOut(z), anchorView: p)
    }

    func pan(by d: CGPoint) {
        guard let doc = document else { return }
        ZoomAnimator.stop()
        doc.viewOffset = doc.viewOffset + d
        setNeedsRender()
    }

    // MARK: Tools

    var currentTool: Tool { tool(for: effectiveToolKind) }

    var effectiveToolKind: ToolKind {
        if spaceDown { return .hand }
        return AppModel.shared.tool
    }

    func tool(for k: ToolKind) -> Tool {
        if let t = tools[k] { return t }
        let t = Tool.make(k, canvas: self)
        tools[k] = t
        return t
    }

    private func toolSwitched(from old: ToolKind, to new: ToolKind) {
        tools[old]?.deactivate()
        tool(for: new).activate()
        overlay.needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Whether the primary mouse button is physically down (replaceable by headless tests).
    nonisolated(unsafe) static var primaryButtonDown: () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }

    /// True while the mouse button is held down on the canvas (a tool drag or a guide drag is in progress). The button
    /// state is checked too: a mouse-up swallowed by a modal alert opened from mouse-down must not leave this stuck.
    var isTrackingMouse: Bool { (dragTool != nil || draggingGuide != nil) && CanvasView.primaryButtonDown() }

    /// Tools where ⌘⌥-drag is free to mean "duplicate and move" (vector and type tools use ⌘/⌥ for their own editing).
    static func allowsQuickDuplicate(_ k: ToolKind) -> Bool {
        if k.isMarquee || k.isPainting || k.isShape { return true }
        switch k {
        case .magicWand, .quickSelect, .objectSelect, .eyedropper, .gradient, .paintBucket, .crop, .hand, .zoom: return true
        default: return false
        }
    }

    func commitCurrentTool() { currentTool.commit() }
    func cancelCurrentTool() { currentTool.cancel() }

    // MARK: Events

    private func makeEvent(_ e: NSEvent) -> ToolEvent {
        let v = convert(e.locationInWindow, from: nil)
        let tablet = e.subtype == .tabletPoint || e.subtype == .tabletProximity
        var pressure = Double(e.pressure)
        if !tablet || pressure <= 0 { pressure = 1 }
        var ev = ToolEvent(doc: viewToDoc(v), view: v, pressure: pressure, modifiers: e.modifierFlags, clickCount: e.clickCount, isTablet: tablet)
        if e.subtype == .tabletPoint {   // tilt/rotation are only valid on tablet point events
            ev.tilt = CGPoint(x: e.tilt.x, y: e.tilt.y)
            ev.rotation = Double(e.rotation)
            ev.tangentialPressure = Double(e.tangentialPressure)
        }
        return ev
    }

    private func rulerHit(_ v: CGPoint) -> Bool? {
        guard document?.showRulers == true else { return nil }
        if v.y < CanvasView.rulerSize && v.x > CanvasView.rulerSize { return false }  // horizontal guide
        if v.x < CanvasView.rulerSize && v.y > CanvasView.rulerSize { return true }   // vertical guide
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let doc = document else { return }
        let te = makeEvent(event)
        lastClick = (doc.id, te.doc)
        clickSerial += 1
        if CanvasSampler.shared.handle(te.doc, event.modifierFlags) { overlay.needsDisplay = true; return }   // adjustment eyedroppers
        if let vertical = rulerHit(te.view) {
            draggingGuide = (nil, vertical)
            return
        }
        if AppModel.shared.tool == .move || AppModel.shared.tool == .pathSelect, let d = document, d.showGuides, !spaceDown,
           let g = guideHit(te.view) {
            draggingGuide = (g.id, g.isVertical)
            return
        }
        // Quick Mask: pixel tools that can't paint the mask must not fall through to the layer's pixels
        if let d = document, d.quickMask, currentTool.kind.writesPixels, !currentTool.kind.editsQuickMask {
            currentTool.refuseInQuickMask()
            return
        }
        dragTool = currentTool
        // ⌘⌥-drag duplicates and moves the layer from any tool that doesn't use those modifiers itself
        if te.command, te.option, !currentTool.isBusy, !(currentTool is MoveTool), CanvasView.allowsQuickDuplicate(AppModel.shared.tool) {
            dragTool = tool(for: .move)
        }
        if let t = ArtboardCanvas.toolForLabelClick(te, canvas: self) { dragTool = t }   // an artboard's name: select / move / rename it
        dragTool?.mouseDown(te)
        lastMouseView = te.view
        overlay.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let te = makeEvent(event)
        lastMouseView = te.view
        if let g = draggingGuide {
            updateGuideDrag(g, te)
            return
        }
        dragTool?.mouseDragged(te)
        updateCursorInfo(te)
        overlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let te = makeEvent(event)
        if let g = draggingGuide {
            finishGuideDrag(g, te)
            draggingGuide = nil
            return
        }
        dragTool?.mouseUp(te)
        dragTool = nil
        overlay.needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard document != nil else { return }
        let te = makeEvent(event)
        if let menu = ArtboardCanvas.contextMenu(te, canvas: self) ?? currentTool.contextMenu(te) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let te = makeEvent(event)
        lastMouseView = te.view
        currentTool.mouseMoved(te)
        updateCursorInfo(te)
        overlay.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        lastMouseView = nil
        AppModel.shared.cursorDocPoint = nil
        overlay.needsDisplay = true
    }

    private func updateCursorInfo(_ te: ToolEvent) {
        guard let d = document else { return }
        let p = te.doc
        if p.x >= 0, p.y >= 0, p.x < CGFloat(d.state.width), p.y < CGFloat(d.state.height) {
            AppModel.shared.cursorDocPoint = CGPoint(x: floor(p.x), y: floor(p.y))
        } else {
            AppModel.shared.cursorDocPoint = nil
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func cursorUpdate(with event: NSEvent) {
        if CanvasSampler.shared.isArmed { NSCursor.crosshair.set(); return }
        currentTool.cursor.set()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: currentTool.cursor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard document != nil else { return }
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            let v = convert(event.locationInWindow, from: nil)
            let factor = pow(1.01, Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 1 : 5))
            setZoom((document?.zoom ?? 1) * factor, anchorView: v)
        } else {
            let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            pan(by: CGPoint(x: event.scrollingDeltaX * k, y: event.scrollingDeltaY * k))
        }
    }

    override func magnify(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        setZoom((document?.zoom ?? 1) * (1 + Double(event.magnification)), anchorView: v)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { // space
            if !spaceDown && dragTool == nil {
                spaceDown = true
                window?.invalidateCursorRects(for: self)
                NSCursor.openHand.set()
            }
            return
        }
        // Mid-drag only Return / Esc reach the tool (see KeyRouter): Delete or an arrow key must not clear pixels or
        // nudge the layer underneath a half-finished stroke.
        if isTrackingMouse && ![36, 76, 53].contains(event.keyCode) { return }
        if currentTool.keyDown(event) { overlay.needsDisplay = true; return }
        switch event.keyCode {
        case 36, 76: currentTool.commit()          // return / enter
        case 53: currentTool.cancel()              // escape
        case 51, 117:                               // delete
            AppActions.clearSelectionPixels()
        case 123, 124, 125, 126:                    // arrows: nudge
            let step: Double = event.modifierFlags.contains(.shift) ? 10 : 1
            let d: (Double, Double) = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)][event.keyCode] ?? (0, 0)
            AppActions.nudge(dx: d.0, dy: d.1)
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceDown = false
            window?.invalidateCursorRects(for: self)
            currentTool.cursor.set()
            return
        }
        super.keyUp(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        currentTool.flagsChanged(event.modifierFlags)
        overlay.needsDisplay = true
        currentTool.cursor.set()
    }

    // MARK: Guides

    func guideHit(_ v: CGPoint) -> Guide? {
        guard let d = document else { return nil }
        for g in d.state.guides {
            if g.isVertical {
                if abs(docToView(CGPoint(x: g.position, y: 0)).x - v.x) < 4 { return g }
            } else {
                if abs(docToView(CGPoint(x: 0, y: g.position)).y - v.y) < 4 { return g }
            }
        }
        return nil
    }

    var guidePreview: (vertical: Bool, position: Double)?

    private func updateGuideDrag(_ g: (id: UUID?, vertical: Bool), _ te: ToolEvent) {
        let pos = g.vertical ? te.doc.x : te.doc.y
        guidePreview = (g.vertical, Double(pos.rounded()))
        overlay.needsDisplay = true
    }

    private func finishGuideDrag(_ g: (id: UUID?, vertical: Bool), _ te: ToolEvent) {
        guard let d = document else { return }
        guidePreview = nil
        let pos = Double((g.vertical ? te.doc.x : te.doc.y).rounded())
        let outside = rulerHit(te.view) != nil || (g.vertical ? (pos < 0 || pos > Double(d.state.width)) : (pos < 0 || pos > Double(d.state.height)))
        if let id = g.id {
            if outside {
                d.state.guides.removeAll { $0.id == id }
                d.commit("Delete Guide")
            } else if let i = d.state.guides.firstIndex(where: { $0.id == id }) {
                d.state.guides[i].position = pos
                d.commit("Move Guide")
            }
        } else if !outside {
            d.state.guides.append(Guide(isVertical: g.vertical, position: pos))
            d.showGuides = true
            d.commit("New Guide")
        }
        overlay.needsDisplay = true
    }

    /// Snaps a doc point to guides / canvas edges / grid when enabled.
    func snap(_ p: CGPoint, threshold: CGFloat = 6) -> CGPoint {
        guard let d = document, d.snapEnabled else { return p }
        let t = threshold / zoom
        var r = p
        var xs: [CGFloat] = [0, CGFloat(d.state.width), CGFloat(d.state.width) / 2]
        var ys: [CGFloat] = [0, CGFloat(d.state.height), CGFloat(d.state.height) / 2]
        if d.showGuides {
            for g in d.state.guides { if g.isVertical { xs.append(CGFloat(g.position)) } else { ys.append(CGFloat(g.position)) } }
        }
        if d.showGrid {
            let s = CGFloat(d.gridSpacing)
            xs.append((p.x / s).rounded() * s); ys.append((p.y / s).rounded() * s)
        }
        if let x = xs.min(by: { abs($0 - p.x) < abs($1 - p.x) }), abs(x - p.x) < t { r.x = x }
        if let y = ys.min(by: { abs($0 - p.y) < abs($1 - p.y) }), abs(y - p.y) < t { r.y = y }
        return r
    }

    // MARK: Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { TypeInput.refusesDrag(sender) ? [] : .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if ComponentCommands.handleCanvasDrop(sender, canvas: self) { return true }   // component / clipboard-history drags
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            // Option-drag places linked (like Photoshop's Alt-drag); a plain drag places embedded.
            AppActions.place(urls, linked: NSEvent.modifierFlags.contains(.option))
            return true
        }
        // Text (the Character Viewer, Notes, Safari, the Glyphs panel) types into the layer being edited or becomes a
        // type layer at the drop point. An emoji wins over a picture of it that may come along; other text doesn't.
        let text = TypeInput.droppedText(sender)
        let at = viewToDoc(convert(sender.draggingLocation, from: nil))
        if let s = text, SVGImport.looksLikeSVG(s), SVGImportUI.handlePaste(pb) { return true }   // SVG markup is artwork, not text
        if let s = text, EmojiText.isEmojiOnly(s) { return TypeInput.insert(s, canvas: self, at: at) }
        if let img = NSImage(pasteboard: pb), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            AppActions.placeImage(cg, name: "Dropped Image")
            return true
        }
        if let s = text { return TypeInput.insert(s, canvas: self, at: at) }
        return false
    }
}

// MARK: - Renderer

final class CanvasRenderer: NSObject, MTKViewDelegate {
    weak var canvas: CanvasView?
    private let pasteboardColor = CIColor(red: 0.157, green: 0.157, blue: 0.157)

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cb = RenderEngine.commandQueue.makeCommandBuffer() else { return }
        let size = view.drawableSize
        let full = CGRect(origin: .zero, size: size)
        var output = CIImage(color: pasteboardColor).cropped(to: full)
        if let canvas, let doc = canvas.document {
            let s = view.bounds.width > 0 ? size.width / view.bounds.width : 2
            output = CanvasRenderer.frame(doc, docToView: canvas.docToViewTransform, viewHeight: view.bounds.height, scale: s, size: size).composited(over: output)
        }

        let dest = CIRenderDestination(width: Int(size.width), height: Int(size.height), pixelFormat: view.colorPixelFormat, commandBuffer: cb) {
            drawable.texture
        }
        dest.colorSpace = sRGBSpace
        _ = try? RenderEngine.context.startTask(toRender: output, from: full, to: dest, at: .zero)
        cb.present(drawable)
        cb.commit()
    }

    /// Canvas shadow, checkerboard and document in drawable pixels (y-up), transparent elsewhere.
    static func frame(_ doc: Document, docToView: CGAffineTransform, viewHeight viewH: CGFloat, scale s: CGFloat, size: CGSize) -> CIImage {
        let full = CGRect(origin: .zero, size: size)
        let H = CGFloat(doc.state.height), W = CGFloat(doc.state.width)
        // CI (y-up doc) → doc → view (rotation/zoom/offset) → drawable pixels (y-up)
        let ciToDoc = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: H)
        let viewToDrawable = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: 0, ty: s * viewH)
        let t = ciToDoc.concatenating(docToView).concatenating(viewToDrawable)
        let ciCanvas = CGRect(x: 0, y: 0, width: W, height: H)
        let rotated = abs(doc.viewRotation) > 0.0001
        let canvasRect = ciCanvas.applying(t)
        let canvasShape = CIImage(color: .white).cropped(to: ciCanvas).transformed(by: t)

        // checkerboard
        var checker = CIFilter(name: "CICheckerboardGenerator", parameters: [
            "inputCenter": CIVector(x: canvasRect.minX, y: canvasRect.maxY),
            "inputColor0": CIColor(red: 1, green: 1, blue: 1),
            "inputColor1": CIColor(red: 0.8, green: 0.8, blue: 0.8),
            "inputWidth": CGFloat(AppModel.shared.prefs.checkerSize) * s,
            "inputSharpness": 1,
        ])!.outputImage!.cropped(to: canvasRect)
        if rotated { checker = checker.masked(byAlphaOf: canvasShape) }

        let (comp, scaled) = documentImage(doc, transform: t, rotated: rotated, zoom: CGFloat(doc.zoom))
        // artboard document: each artboard is a page on the pasteboard; the rest of the canvas is pasteboard too
        if let pages = ArtboardCanvas.pages(doc, transform: t, scale: s, size: size, checkerOrigin: CGPoint(x: canvasRect.minX, y: canvasRect.maxY)) {
            return (rotated ? scaled : scaled.cropped(to: canvasRect)).composited(over: pages.checker).composited(over: pages.shadow)
        }
        // soft drop shadow around the canvas
        var output = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.5)).cropped(to: ciCanvas).transformed(by: t)
            .applyingGaussianBlur(sigma: 5 * s).cropped(to: full)
        if let tiles = PatternPreview.tiles(comp, doc: doc, transform: t, bounds: full) { output = tiles.composited(over: output) }   // View ▸ Pattern Preview
        return (rotated ? scaled : scaled.cropped(to: canvasRect)).composited(over: checker).composited(over: output)
    }

    /// The document as displayed: (doc-space display image, that image mapped through `t` into drawable pixels).
    /// Core Image fuses colour kernels with a following resample, which would blend the layers' downsampled inputs
    /// instead of downsampling the blended result (wrong wherever edges coincide: a stroke on its shape, a knocked-out
    /// shadow, a mask on its content). Unless pixels are enlarged as nearest-neighbour blocks, the composite is
    /// therefore evaluated on the document's pixel grid first.
    static func documentImage(_ doc: Document, transform t: CGAffineTransform, rotated: Bool, zoom z: CGFloat) -> (CIImage, CIImage) {
        let ciCanvas = CGRect(x: 0, y: 0, width: doc.state.width, height: doc.state.height)
        let base = cachedComposite(doc)
        let viewed = applyViewMode(base, doc: doc)
        let nearest = z >= 2 && !rotated
        var comp = viewed.cropped(to: ciCanvas)
        // (the settled texture is already such pixels)
        if exactResampling, !nearest, !(viewed === base && cache?.image === base) { comp = settled(comp) }
        let scale = (t.a * t.a + t.b * t.b).squareRoot()
        return (comp, nearest ? comp.samplingNearest().transformed(by: t) : comp.transformed(by: t, highQualityDownsample: scale < 0.999))
    }

    /// Off: resample the live composite graph directly (the old behaviour; accuracy tests compare against it).
    nonisolated(unsafe) static var exactResampling = true

    private static let unitClamp = CIColorKernel(source: "kernel vec4 unitClamp(__sample s) { return clamp(s, 0.0, 1.0); }")

    /// `img` as the document's pixels: evaluated on the document grid and clamped like an 8-bit render (overshoots of
    /// sharpening or bevel highlights would otherwise leak into neighbours when averaged by a downsample).
    static func settled(_ img: CIImage) -> CIImage {
        (unitClamp?.apply(extent: img.extent, arguments: [img]) ?? img).insertingIntermediate(cache: false)
    }

    // MARK: Composite cache (fast pan/zoom on large documents)

    private static var cache: (docID: UUID, version: Int, image: CIImage, texture: MTLTexture?)?
    private static var pending: (docID: UUID, version: Int, frames: Int)?
    /// The settled composite's GPU texture (tests).
    static var cachedTexture: MTLTexture? { cache?.texture ?? nil }

    /// Drops the materialized composite of a closed document (nil: whatever it holds).
    static func forget(_ docID: UUID?) {
        if docID == nil || cache?.docID == docID { cache = nil }
        if docID == nil || pending?.docID == docID { pending = nil }
    }

    /// Returns a materialized composite when the document hasn't changed for a couple of frames
    /// (so panning/zooming large documents doesn't recomposite every layer), else the live graph.
    static func cachedComposite(_ doc: Document) -> CIImage {
        let live = Compositor.shared.composite(doc)
        let prefs = AppModel.shared.prefs
        let mp = Double(doc.state.width * doc.state.height) / 1_000_000
        guard prefs.cacheLargeDocuments, mp >= prefs.largeDocumentThreshold else { return live }
        let v = doc.renderVersion
        if let c = cache, c.docID == doc.id, c.version == v { return c.image }
        if let p = pending, p.docID == doc.id, p.version == v {
            if p.frames >= 1 {
                let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
                let eight = doc.state.bitDepth == .eight, pixels = settled(live.cropped(to: space.ciCanvas))
                if let m = materialize(pixels, rect: space.ciCanvas, format: eight ? .rgba8Unorm : .rgba16Float) {
                    cache = (doc.id, v, m.image, m.texture)
                    pending = nil
                    return m.image
                }
                // beyond the GPU's texture size: a bitmap in memory (Core Image tiles it)
                if let img = bitmap(pixels, rect: space.ciCanvas, eight: eight) {
                    cache = (doc.id, v, img, nil)
                    pending = nil
                    return img
                }
            }
            pending = (doc.id, v, p.frames + 1)
        } else {
            pending = (doc.id, v, 0)
            // re-render soon so the cache kicks in even when nothing else redraws
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak doc] in
                if let d = doc, d.renderVersion == v { d.renderCallback?() }
            }
        }
        return live
    }

    /// Renders `img` over `rect` into a private GPU texture: no readback to the CPU and no upload when it is drawn.
    static func materialize(_ img: CIImage, rect: CGRect, format: MTLPixelFormat) -> (image: CIImage, texture: MTLTexture)? {
        let w = Int(rect.width), h = Int(rect.height), maxSide = 16384   // Apple GPUs' 2D texture limit
        guard w > 0, h > 0, w <= maxSide, h <= maxSide else { return nil }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]
        td.storageMode = .private
        guard let tex = RenderEngine.device.makeTexture(descriptor: td), let cb = RenderEngine.commandQueue.makeCommandBuffer() else { return nil }
        let dest = CIRenderDestination(mtlTexture: tex, commandBuffer: cb)
        dest.colorSpace = sRGBSpace
        guard (try? RenderEngine.context.startTask(toRender: img, from: rect, to: dest, at: .zero)) != nil else { return nil }
        cb.commit()
        cb.waitUntilCompleted()   // the canvas samples it from other queues (CI's own) too
        guard cb.status == .completed, let out = CIImage(mtlTexture: tex, options: [.colorSpace: sRGBSpace]) else { return nil }
        return (out.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY)), tex)
    }

    /// Renders `img` over `rect` into memory the image owns. Not `createCGImage`: past the texture limit, Core Image
    /// intermittently drops whole tiles when it draws a CGImage it rendered itself (bands of a wide PSB showed as
    /// transparent on the canvas); a plain bitmap is tiled reliably.
    static func bitmap(_ img: CIImage, rect: CGRect, eight: Bool) -> CIImage? {
        let w = Int(rect.width), h = Int(rect.height), rowBytes = w * (eight ? 4 : 8)
        guard w > 0, h > 0 else { return nil }
        var data = Data(count: rowBytes * h)
        data.withUnsafeMutableBytes { RenderEngine.context.render(img, toBitmap: $0.baseAddress!, rowBytes: rowBytes, bounds: rect, format: eight ? .RGBA8 : .RGBAh, colorSpace: sRGBSpace) }
        return CIImage(bitmapData: data, bytesPerRow: rowBytes, size: rect.size, format: eight ? .RGBA8 : .RGBAh, colorSpace: sRGBSpace)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }

    /// Channel view / quick mask presentation.
    static func applyViewMode(_ img: CIImage, doc: Document) -> CIImage {
        var out = img
        out = ImagingDisplay.apply(out, doc: doc)   // duotone / spot inks (Imaging module)
        if let o = doc.displayOverride { out = o(out) }
        let space = CanvasSpace(width: doc.state.width, height: doc.state.height)
        out = ColorConvert.displayImage(out, profile: doc.state.profileName)
        let proof = AppModel.shared.proof
        if doc.proofColors || doc.state.colorMode == .cmyk { out = ColorConvert.softProof(out, settings: proof) }
        if doc.gamutWarning { out = ColorConvert.gamutWarning(out, settings: proof) }
        switch doc.viewChannel {
        case .composite: break
        case .ink(let i):
            let flat = out.composited(over: CIImage.color(.white, space.ciCanvas)).cropped(to: space.ciCanvas)
            out = ColorConvert.cmykChannelKernel?.apply(extent: space.ciCanvas, arguments: [flat, Float(i)]) ?? out
        case .lab(let i):
            let flat = out.composited(over: CIImage.color(.white, space.ciCanvas)).cropped(to: space.ciCanvas)
            out = ColorConvert.labChannelKernel?.apply(extent: space.ciCanvas, arguments: [flat, Float(i)]) ?? out
        case .red, .green, .blue:
            let v: CIVector
            switch doc.viewChannel {
            case .red: v = CIVector(x: 1, y: 0, z: 0, w: 0)
            case .green: v = CIVector(x: 0, y: 1, z: 0, w: 0)
            default: v = CIVector(x: 0, y: 0, z: 1, w: 0)
            }
            out = out.composited(over: CIImage.color(.white, space.ciCanvas)).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": v, "inputGVector": v, "inputBVector": v])
        case .alpha(let id):
            if let ch = doc.state.alphaChannels.first(where: { $0.id == id }) {
                out = ch.buffer.ciImage
            }
        }
        if doc.quickMask {
            let sel = doc.state.selection?.ciImage ?? CIImage.color(.white, space.ciCanvas)   // no selection: nothing masked
            let red = CIImage.color(RGBA(r: 1, g: 0, b: 0, a: 0.5), space.ciCanvas).masked(byGray: sel.inverted())
            out = red.composited(over: out)
        }
        return ArtistView.apply(out, doc: doc)   // View ▸ Simulate (colour-vision / low-contrast / squint), view only
    }
}
