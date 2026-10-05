import AppKit
import CoreImage
import ImageCratCore

/// Liquify must not crop the object (bug report: “When I choose liquify it crops the object to its original size even
/// if it is larger”). Like Photoshop, the whole canvas is Liquify's working area: pixels pushed past the layer's old
/// bounds are kept (the layer grows), pixels of the layer outside the canvas survive unchanged, a scaled-up smart object
/// gets a Liquify smart filter whose result is not limited to its native or original size and follows later scaling,
/// and with a selection only the selected area changes. Every case goes through the real paths: Filter ▸ Liquify
/// (FilterLauncher) → the dialog's working source → brush strokes on the dialog's preview view → OK
/// (`AppActions.applyLiquify`), then undo / redo.
///
///     LUMEN_SELFTEST_ONLY=liquifybounds .build/debug/Lumen --selftest <dir>
enum LiquifyBoundsSelfTest {
    static func register() { FeatureModules.selfTests.append(("liquifybounds", { run($0) })) }

    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") liquifybounds: \(name)\(d.isEmpty ? "" : " — " + d)")
    }
    static func info(_ s: String) { print("INFO liquifybounds: \(s)") }

    static let W = 240, H = 180
    static var dir = URL(fileURLWithPath: NSTemporaryDirectory())

    static func run(_ out: URL) {
        failures = 0; passes = 0
        dir = ProcessInfo.processInfo.environment["LIQUIFY_PNG_DIR"].map { URL(fileURLWithPath: $0) } ?? out.appendingPathComponent("liquifybounds")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, tool: app.tool, dialog: app.dialog, canvas: AppActions.canvas,
                     button: CanvasView.primaryButtonDown, selection: app.selection, hook: AppActions.modalHook)
        app.dialog = nil
        app.documents = []; app.activeDocumentID = nil
        app.selection.feather = 0
        var modalAsked = 0
        AppActions.modalHook = { _, _ in modalAsked += 1; return true }
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        let r = ToolRobot(size: CGSize(width: 900, height: 640))
        defer {
            r.closeAll()
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active
            app.tool = saved.tool; app.selection = saved.selection
            AppActions.canvas = saved.canvas; CanvasView.primaryButtonDown = saved.button
            AppActions.modalHook = saved.hook
            app.dialog = saved.dialog
            print("liquifybounds: \(passes) checks passed, \(failures) failed")
        }
        pushOutward(r)
        bloatOutward(r)
        offCanvas(r)
        smartObject(r, modalAsked: { modalAsked })
        selectionLimited(r)
        smartObjectSelection(r)
    }

    // MARK: Fixtures & helpers

    static func fill(_ b: PixelBuffer, _ rect: IRect, _ c: (UInt8, UInt8, UInt8)) {
        let base = b.data.assumingMemoryBound(to: UInt8.self)
        for y in max(0, rect.y)..<min(b.height, rect.y + rect.height) {
            for x in max(0, rect.x)..<min(b.width, rect.x + rect.width) {
                let p = base + b.offset(x, y)
                p[0] = c.0; p[1] = c.1; p[2] = c.2; p[3] = 255
            }
        }
        b.markDirty()
    }

    /// A solid block with a darker 4 px border (so a warp shows) — the buffer is exactly as big as the content.
    static func block(_ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        fill(b, IRect(x: 0, y: 0, width: w, height: h), (40, 60, 160))
        fill(b, IRect(x: 4, y: 4, width: w - 8, height: h - 8), (230, 70, 50))
        return b
    }

    /// Stripes keyed to doc x (8 px wide, several colours) so any horizontal move is visible.
    static func stripes(_ w: Int, _ h: Int, originX: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let pal: [(UInt8, UInt8, UInt8)] = [(20, 30, 90), (240, 180, 40), (40, 160, 90), (200, 60, 120)]
        for x in 0..<w {
            let k = (((x + originX) / 8) % 4 + 4) % 4
            fill(b, IRect(x: x, y: 0, width: 1, height: h), pal[k])
        }
        return b
    }

    static func background() -> Layer {
        let b = PixelBuffer(width: W, height: H)
        fill(b, IRect(x: 0, y: 0, width: W, height: H), (245, 245, 240))
        var l = Layer.raster(name: "Background", buffer: b)
        l.name = "Background"
        return l
    }

    static func save(_ b: PixelBuffer, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: b.makeCGImage())
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    static func raw(_ b: PixelBuffer, _ x: Int, _ y: Int) -> SIMD4<Int> { BlurGallery2SelfTest.raw(b, x, y) }

    /// The active layer alone (content only), rendered over `rect` (doc pixels; may lie outside the canvas).
    static func layerPixels(_ d: Document, _ id: UUID, _ rect: IRect) -> PixelBuffer {
        let sp = CanvasSpace(width: d.state.width, height: d.state.height)
        guard let l = d.state.layer(id), let img = Compositor.shared.contentImage(l, space: sp) else { return PixelBuffer(width: rect.width, height: rect.height) }
        return RenderEngine.renderBuffer(img, docRect: rect, space: sp)
    }

    static var canvasRect: IRect { IRect(x: 0, y: 0, width: W, height: H) }
    static func covers(_ a: IRect, _ b: IRect) -> Bool { a.x <= b.x && a.y <= b.y && a.x + a.width >= b.x + b.width && a.y + a.height >= b.y + b.height }

    /// Filter ▸ Liquify, then the dialog's preview view with brush strokes dragged across it (the view is canvas-size,
    /// so view points are doc points). Returns the field OK would apply and what the preview shows (canvas-size).
    struct Session {
        var field: DisplacementField
        var view: LiquifyPreviewView
        var source: CIImage
        var smartLayer: UUID?
        /// The preview's image (warp kept to the selection like OK), rendered over the canvas.
        var preview: PixelBuffer
    }

    static func openLiquify(_ r: ToolRobot) -> (LiquifyPreviewView, CIImage, UUID?)? {
        let app = AppModel.shared
        guard let d = r.doc else { return nil }
        FilterLauncher.liquify()
        guard app.dialog == .liquify else { return nil }
        let src = LiquifyDialog.workingSource(d)
        let v = LiquifyPreviewView(frame: CGRect(x: 0, y: 0, width: W, height: H))
        v.source = src.image; v.space = CanvasSpace(width: W, height: H); v.field = src.field ?? DisplacementField(width: W, height: H)
        v.selection = src.selection; v.lockAlpha = src.lockAlpha; v.showMask = false
        return (v, src.image, src.smartLayer)
    }

    static func mouse(_ v: LiquifyPreviewView, _ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
        // no window: window coordinates are the (unflipped) view's
        NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: v.bounds.height - p.y), modifierFlags: [], timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    static func drag(_ v: LiquifyPreviewView, _ a: CGPoint, _ b: CGPoint, steps: Int = 12) {
        v.mouseDown(with: mouse(v, .leftMouseDown, a))
        for i in 1...steps { v.mouseDragged(with: mouse(v, .leftMouseDragged, a.lerp(b, CGFloat(i) / CGFloat(steps)))) }
        v.mouseUp(with: mouse(v, .leftMouseUp, b))
    }

    static func click(_ v: LiquifyPreviewView, _ p: CGPoint, times: Int) {
        for _ in 0..<times {
            v.mouseDown(with: mouse(v, .leftMouseDown, p))
            v.mouseUp(with: mouse(v, .leftMouseUp, p))
        }
    }

    /// What the preview view draws, before scaling to the screen: the warp of the dialog's source kept to the
    /// selection — the view's own `draw` pipeline.
    static func previewImage(_ v: LiquifyPreviewView) -> PixelBuffer {
        var warped = v.field?.warp(v.source, space: v.space) ?? v.source
        if v.selection != nil || v.lockAlpha {
            warped = AppActions.restrict(warped, original: v.source, selection: v.selection, lockAlpha: v.lockAlpha, canvas: v.space.ciCanvas)
        }
        return RenderEngine.renderBuffer(warped.cropped(to: v.space.ciCanvas), docRect: canvasRect, space: v.space)
    }

    /// The view itself drawn offscreen (at the backing scale): mean alpha-weighted colour of a doc rect.
    static func viewShot(_ v: LiquifyPreviewView) -> NSBitmapImageRep? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: rep)
        return rep
    }

    static func maxDiff(_ a: PixelBuffer, _ b: PixelBuffer) -> Int { BlurGallery2SelfTest.maxDiff(a, b) }

    static func count(_ b: PixelBuffer, where f: (Int, Int, SIMD4<Int>) -> Bool) -> Int {
        var n = 0
        for y in 0..<b.height { for x in 0..<b.width where f(x, y, raw(b, x, y)) { n += 1 } }
        return n
    }

    // MARK: (a) a small object pushed outward

    static func pushOutward(_ r: ToolRobot) {
        var st = DocumentState(width: W, height: H)
        let obj = Layer.raster(name: "Object", buffer: block(50, 40), origin: IPoint(x: 80, y: 70))
        st.layers = [background(), obj]
        let d = r.open(st, active: obj.id)
        let oldFrame = d.activeLayer!.raster!.frame
        let px0 = d.activeLayer!.raster!.buffer.copy()
        let before = r.liveComposite()
        guard let (v, source, smart) = openLiquify(r) else { check(false, "push: Filter ▸ Liquify opens the dialog"); r.close(d); return }
        check(smart == nil && source.extent.contains(CanvasSpace(width: W, height: H).ciCanvas),
              "push: the dialog works on the whole canvas, not just the layer's 50×40 buffer", "source \(source.extent)")
        v.brushSize = 50; v.pressure = 1
        v.mode = .forward
        for _ in 0..<4 { drag(v, CGPoint(x: 118, y: 90), CGPoint(x: 160, y: 90)) }
        guard let field = v.field, !field.isIdentity else { check(false, "push: the brush strokes on the preview change the field"); r.close(d); return }
        let preview = previewImage(v)
        let shot = viewShot(v)
        let steps = d.history.count
        AppModel.shared.dialog = nil
        check(AppActions.applyLiquify(field), "push: OK applies")
        let after = r.liveComposite()
        guard let rc = d.activeLayer?.raster else { check(false, "push: still a pixel layer"); r.close(d); return }
        let frame = rc.frame
        // content beyond the old right edge (x ≥ 130) on the object's rows
        let lp = layerPixels(d, obj.id, canvasRect)
        let beyond = count(lp) { x, y, p in x >= oldFrame.x + oldFrame.width + 3 && y > 75 && y < 105 && p.w > 200 }
        check(covers(frame, canvasRect) || (frame.x + frame.width > oldFrame.x + oldFrame.width),
              "push: the layer grows past its old bounds", "old \(oldFrame), new \(frame)")
        check(beyond > 150, "push: pushed pixels appear outside the old bounding box (not clipped)", "\(beyond) opaque px right of x=\(oldFrame.x + oldFrame.width)")
        if let ob = rc.buffer.opaqueBounds()?.offsetBy(dx: rc.origin.x, dy: rc.origin.y) {
            info("push: opaque bounds \(oldFrame) → \(ob)")
            check(ob.x + ob.width >= oldFrame.x + oldFrame.width + 10, "push: the object's opaque extent reaches ≥10 px past its old right edge", "\(ob)")
        }
        // preview equals commit
        let canvasAfter = layerPixels(d, obj.id, canvasRect)
        let pd = maxDiff(preview, canvasAfter)
        check(pd <= 2, "push: the preview shows exactly what OK applies (incl. the grown part)", "max Δ\(pd)")
        if let shot {
            let k = Double(shot.pixelsWide) / Double(W)
            var red = 0, n = 0
            for y in stride(from: 82, to: 98, by: 2) { for x in stride(from: 134, to: 142, by: 2) {
                guard let c = shot.colorAt(x: Int((Double(x) + 0.5) * k), y: Int((Double(y) + 0.5) * k)) else { continue }
                n += 1; if c.redComponent > 0.6 && c.blueComponent < 0.5 { red += 1 }
            } }
            check(n > 0 && red * 2 > n, "push: the preview view draws the pushed pixels past the old edge", "\(red)/\(n) sampled px red")
        }
        check(d.history.count == steps + 1 && d.history.last?.name == "Liquify", "push: one undo step named Liquify")
        save(before, "push_before"); save(preview, "push_preview"); save(after, "push_after")
        d.undo()
        let u = d.activeLayer!.raster!
        check(u.frame == oldFrame && maxDiff(u.buffer, px0) == 0, "push: undo restores the original 50×40 layer", "frame \(u.frame)")
        d.redo()
        let rd = layerPixels(d, obj.id, canvasRect)
        check(maxDiff(rd, canvasAfter) == 0, "push: redo brings the grown result back")
        r.close(d)
    }

    // MARK: (a) bloat bigger than the object

    static func bloatOutward(_ r: ToolRobot) {
        var st = DocumentState(width: W, height: H)
        let obj = Layer.raster(name: "Object", buffer: block(40, 40), origin: IPoint(x: 100, y: 70))
        st.layers = [background(), obj]
        let d = r.open(st, active: obj.id)
        let oldFrame = d.activeLayer!.raster!.frame
        let before = r.liveComposite()
        guard let (v, _, _) = openLiquify(r) else { check(false, "bloat: Filter ▸ Liquify opens the dialog"); r.close(d); return }
        v.brushSize = 110; v.pressure = 1; v.mode = .bloat
        click(v, CGPoint(x: 120, y: 90), times: 30)
        guard let field = v.field, !field.isIdentity else { check(false, "bloat: the brush changes the field"); r.close(d); return }
        let preview = previewImage(v)
        AppModel.shared.dialog = nil
        AppActions.applyLiquify(field)
        let after = r.liveComposite()
        guard let rc = d.activeLayer?.raster, let ob = rc.buffer.opaqueBounds(threshold: 128)?.offsetBy(dx: rc.origin.x, dy: rc.origin.y) else {
            check(false, "bloat: result has pixels"); r.close(d); return
        }
        info("bloat: opaque bounds \(oldFrame) → \(ob)")
        check(ob.x <= oldFrame.x - 4 && ob.y <= oldFrame.y - 4 && ob.x + ob.width >= oldFrame.x + oldFrame.width + 4 && ob.y + ob.height >= oldFrame.y + oldFrame.height + 4,
              "bloat: the object grows past its old bounds on all four sides", "old \(oldFrame), new \(ob)")
        let pd = maxDiff(preview, layerPixels(d, obj.id, canvasRect))
        check(pd <= 2, "bloat: preview equals commit", "max Δ\(pd)")
        save(before, "bloat_before"); save(after, "bloat_after")
        r.close(d)
    }

    // MARK: (b) a layer larger than the canvas, partly off-canvas

    static func offCanvas(_ r: ToolRobot) {
        var st = DocumentState(width: W, height: H)
        let origin = IPoint(x: -70, y: 20)
        let buf = stripes(W + 150, 120, originX: origin.x)   // x −70…320: 70 px off the left edge, 80 px off the right
        let obj = Layer.raster(name: "Wide", buffer: buf, origin: origin)
        st.layers = [background(), obj]
        let d = r.open(st, active: obj.id)
        let oldFrame = d.activeLayer!.raster!.frame
        let before = r.liveComposite()
        guard let (v, source, _) = openLiquify(r) else { check(false, "off-canvas: Filter ▸ Liquify opens the dialog"); r.close(d); return }
        let sp = CanvasSpace(width: W, height: H)
        check(source.extent.contains(sp.ciRect(oldFrame)), "off-canvas: the dialog keeps the layer's off-canvas pixels in its source", "source \(source.extent), layer \(sp.ciRect(oldFrame))")
        v.brushSize = 80; v.pressure = 1; v.mode = .forward
        for _ in 0..<3 { drag(v, CGPoint(x: 60, y: 80), CGPoint(x: 120, y: 80)) }
        // strokes right at the canvas edges too (the brush reaches across them)
        drag(v, CGPoint(x: 6, y: 100), CGPoint(x: 30, y: 100))
        drag(v, CGPoint(x: W - 6, y: 60), CGPoint(x: W - 30, y: 60))
        guard let field = v.field, !field.isIdentity else { check(false, "off-canvas: the brush changes the field"); r.close(d); return }
        let preview = previewImage(v)
        AppModel.shared.dialog = nil
        AppActions.applyLiquify(field)
        let after = r.liveComposite()
        guard let rc = d.activeLayer?.raster else { check(false, "off-canvas: still a pixel layer"); r.close(d); return }
        check(covers(rc.frame, oldFrame), "off-canvas: the layer is still larger than the canvas (not cropped to it)", "old \(oldFrame), new \(rc.frame)")
        // every off-canvas pixel unchanged
        var offMax = 0, offN = 0
        for y in oldFrame.y..<(oldFrame.y + oldFrame.height) {
            for x in oldFrame.x..<(oldFrame.x + oldFrame.width) where x < 0 || x >= W {
                let a = raw(buf, x - oldFrame.x, y - oldFrame.y), b = raw(rc.buffer, x - rc.origin.x, y - rc.origin.y)
                offMax = max(offMax, BlurGallery2SelfTest.dist(a, b)); offN += 1
            }
        }
        check(offN == 150 * 120 && offMax == 0, "off-canvas: all \(offN) off-canvas pixels survive unchanged", "max Δ\(offMax)")
        // the on-canvas part did warp
        let inside = layerPixels(d, obj.id, canvasRect)
        let orig = RenderEngine.renderBuffer(sp.place(buf, at: origin), docRect: canvasRect, space: sp)
        let changed = count(inside) { x, y, p in BlurGallery2SelfTest.dist(p, raw(orig, x, y)) > 30 }
        check(changed > 500, "off-canvas: the canvas part is warped", "\(changed) px changed")
        let pd = maxDiff(preview, inside)
        check(pd <= 2, "off-canvas: preview equals commit", "max Δ\(pd)")
        // a wider view of the layer (off-canvas parts included) for the record
        let wide = layerPixels(d, obj.id, IRect(x: -80, y: 0, width: W + 170, height: H))
        let wide0 = RenderEngine.renderBuffer(sp.place(buf, at: origin), docRect: IRect(x: -80, y: 0, width: W + 170, height: H), space: sp)
        save(before, "offcanvas_before"); save(after, "offcanvas_after"); save(wide0, "offcanvas_layer_before_wide"); save(wide, "offcanvas_layer_after_wide")
        d.undo()
        check(d.activeLayer?.raster?.frame == oldFrame && maxDiff(d.activeLayer!.raster!.buffer, buf) == 0, "off-canvas: undo restores the layer")
        d.redo()
        check(maxDiff(layerPixels(d, obj.id, canvasRect), inside) == 0, "off-canvas: redo")
        r.close(d)
    }

    // MARK: (c) a scaled-up smart object

    static func smartObject(_ r: ToolRobot, modalAsked: () -> Int) {
        var st = DocumentState(width: W, height: H)
        let native = block(40, 30)                                       // native size 40×30
        let quad = Quad(rect: CGRect(x: 60, y: 50, width: 100, height: 75))   // scaled up 2.5×
        let so = SmartObjectContent(source: .image(native), quad: quad)
        let obj = Layer(name: "Smart", content: .smartObject(so))
        st.layers = [background(), obj]
        let d = r.open(st, active: obj.id)
        let sp = CanvasSpace(width: W, height: H)
        let before = r.liveComposite()
        let asked0 = modalAsked()
        check(FilterLauncher.canRun(smartFilter: true, layerPixels: true), "smart: Liquify is enabled for a smart object")
        guard let (v, source, smart) = openLiquify(r) else { check(false, "smart: Filter ▸ Liquify opens the dialog"); r.close(d); return }
        check(modalAsked() == asked0 && d.activeLayer?.isSmartObject == true && smart == obj.id,
              "smart: Liquify opens as a smart filter (no rasterize prompt, still a smart object)", "asked \(modalAsked() - asked0), smart \(String(describing: smart))")
        let srcB = RenderEngine.renderBuffer(source.cropped(to: sp.ciCanvas), docRect: canvasRect, space: sp)
        if let ob = srcB.opaqueBounds(threshold: 128) {
            check(abs(ob.width - 100) <= 2 && abs(ob.height - 75) <= 2, "smart: the dialog works on the transformed (100×75) object, not its native 40×30", "\(ob)")
        }
        v.brushSize = 60; v.pressure = 1; v.mode = .forward
        for _ in 0..<2 { drag(v, CGPoint(x: 150, y: 88), CGPoint(x: 185, y: 88)) }
        guard let field = v.field, !field.isIdentity else { check(false, "smart: the brush changes the field"); r.close(d); return }
        let preview = previewImage(v)
        let steps = d.history.count
        AppModel.shared.dialog = nil
        check(AppActions.applyLiquify(field), "smart: OK applies")
        let after = r.liveComposite()
        guard let l = d.state.layer(obj.id), let so2 = l.smart else { check(false, "smart: still a smart object"); r.close(d); return }
        check(so2.filters.count == 1 && so2.filters[0].kind == .liquify && so2.filters[0].liquify != nil && so2.quad == quad,
              "smart: a Liquify smart filter is added; the object's transform and source stay as they were", "\(so2.filters.map(\.kind))")
        check(d.history.count == steps + 1 && d.history.last?.name == "Liquify", "smart: one undo step")
        let lp = layerPixels(d, obj.id, canvasRect)
        guard let ob = lp.opaqueBounds(threshold: 128) else { check(false, "smart: result has pixels"); r.close(d); return }
        info("smart: native 40×30, placed \(quad.bounds), result opaque bounds \(ob)")
        check(ob.width > 40 && ob.height > 30 && ob.width >= 100, "smart: the result is not cropped to the native 40×30 size", "\(ob)")
        check(ob.x + ob.width >= 160 + 15, "smart: the pushed pixels reach past the object's scaled bounds (x=160)", "right edge \(ob.x + ob.width)")
        check(abs(ob.x - 60) <= 2 && abs(ob.y - 50) <= 3 && abs(ob.y + ob.height - 125) <= 3, "smart: the rest of the object keeps its transformed extent (x 60, y 50…125)", "\(ob)")
        let pd = maxDiff(preview, lp)
        check(pd <= 2, "smart: preview equals commit", "max Δ\(pd)")
        save(before, "smart_before"); save(preview, "smart_preview"); save(after, "smart_after")
        // the filter is saved with the document
        if let f = so2.filters.first, let data = try? JSONEncoder().encode(f), let back = try? JSONDecoder().decode(FilterInstance.self, from: data) {
            check(back.kind == .liquify && back.liquify == f.liquify, "smart: the Liquify mesh survives encoding",
                  "kind \(back.kind), mesh equal \(back.liquify == f.liquify), dx equal \(back.liquify?.dx == f.liquify?.dx), quad \(String(describing: back.liquify?.reference)) vs \(String(describing: f.liquify?.reference))")
        } else { check(false, "smart: the Liquify filter encodes") }
        // re-editing starts from the effect, on the object without it
        if let fid = so2.filters.first?.id {
            let re = LiquifyDialog.workingSource(d, smartLayer: obj.id, editingFilter: fid)
            let reSrc = RenderEngine.renderBuffer(re.image.cropped(to: sp.ciCanvas), docRect: canvasRect, space: sp)
            check(re.smartLayer == obj.id && re.field.map { !$0.isIdentity } == true && maxDiff(reSrc, srcB) <= 1,
                  "smart: re-editing the smart filter opens on the unfiltered object with the mesh loaded")
            if let f2 = re.field {
                let rePreview = RenderEngine.renderBuffer(f2.warp(re.image, space: sp).cropped(to: sp.ciCanvas), docRect: canvasRect, space: sp)
                let rd = maxDiff(rePreview, lp)
                check(rd <= 8, "smart: the re-edit preview matches the applied effect", "max Δ\(rd)")
            }
        }
        // scaling the smart object afterwards keeps the effect (it follows the object)
        let big = Quad(rect: CGRect(x: 40, y: 30, width: 140, height: 105))   // 1.4× more
        d.updateLayer(obj.id) { $0.smart?.quad = big }
        d.commit("Scale")
        let scaled = layerPixels(d, obj.id, canvasRect)
        if let sb = scaled.opaqueBounds(threshold: 128) {
            info("smart: after scaling to \(big.bounds): opaque bounds \(sb)")
            let bulge = (ob.x + ob.width) - 160
            check(bulge < 40 && sb.x + sb.width >= 180 + Int(Double(bulge) * 1.25) && sb.x + sb.width < W,
                  "smart: after scaling the object 1.4× up, the Liquify bulge is still there and scaled with it",
                  "right edge \(sb.x + sb.width) (object edge 180), bulge was \(bulge) px")
            check(abs(sb.x - 40) <= 2 && abs(sb.y - 30) <= 3, "smart: after scaling, the object's other edges follow the new transform", "\(sb)")
        }
        save(scaled, "smart_scaled_after")
        d.undo()   // Scale
        d.undo()   // Liquify
        check(d.state.layer(obj.id)?.smart?.filters.isEmpty == true && maxDiff(layerPixels(d, obj.id, canvasRect), srcB) <= 1, "smart: undo removes the Liquify smart filter")
        d.redo()
        check(d.state.layer(obj.id)?.smart?.filters.first?.kind == .liquify && maxDiff(layerPixels(d, obj.id, canvasRect), lp) == 0, "smart: redo brings it back")
        // rasterizing keeps the liquified, grown result
        AppActions.rasterizeLayer(obj.id)
        if let rc = d.state.layer(obj.id)?.raster {
            let rp = layerPixels(d, obj.id, canvasRect)
            check(maxDiff(rp, lp) <= 2, "smart: rasterizing keeps the Liquify result (incl. beyond the object's bounds)", "frame \(rc.frame)")
        } else {
            info("smart: rasterize skipped (\(String(describing: d.state.layer(obj.id)?.content)))")
        }
        r.close(d)
    }

    // MARK: (d) a selection

    static func selectionLimited(_ r: ToolRobot) {
        var st = DocumentState(width: W, height: H)
        let obj = Layer.raster(name: "Object", buffer: block(50, 60), origin: IPoint(x: 80, y: 60))
        st.layers = [background(), obj]
        let d = r.open(st, active: obj.id)
        let oldFrame = d.activeLayer!.raster!.frame
        // the top half of the object (and the empty canvas right of it) selected with the Rectangular Marquee
        r.select(.marqueeRect)
        r.dragLine(CGPoint(x: 20, y: 20), CGPoint(x: 220, y: 90))
        guard let sel = d.state.selection?.copy() else { check(false, "selection: marquee made a selection"); r.close(d); return }
        let px0 = layerPixels(d, obj.id, canvasRect)
        let before = r.liveComposite()
        guard let (v, _, _) = openLiquify(r) else { check(false, "selection: Filter ▸ Liquify opens the dialog"); r.close(d); return }
        v.brushSize = 70; v.pressure = 1; v.mode = .forward
        for y in [70, 90, 110] { for _ in 0..<3 { drag(v, CGPoint(x: 125, y: CGFloat(y)), CGPoint(x: 175, y: CGFloat(y))) } }
        guard let field = v.field, !field.isIdentity else { check(false, "selection: the brush changes the field"); r.close(d); return }
        let preview = previewImage(v)
        AppModel.shared.dialog = nil
        AppActions.applyLiquify(field)
        let after = r.liveComposite()
        let lp = layerPixels(d, obj.id, canvasRect)
        var outMax = 0, outN = 0
        for y in 0..<H { for x in 0..<W where sel.alpha(x, y) == 0 { outMax = max(outMax, BlurGallery2SelfTest.dist(raw(lp, x, y), raw(px0, x, y))); outN += 1 } }
        check(outN > 1000 && outMax == 0, "selection: outside the selection nothing changes (the unselected bottom of the object is intact)", "max Δ\(outMax) over \(outN) px")
        let grown = count(lp) { x, y, p in sel.alpha(x, y) == 255 && x >= oldFrame.x + oldFrame.width + 3 && p.w > 200 }
        check(grown > 60, "selection: inside the selection the object is pushed past its old bounds (not cropped)", "\(grown) px right of x=\(oldFrame.x + oldFrame.width)")
        let pd = maxDiff(preview, lp)
        check(pd <= 2, "selection: preview equals commit", "max Δ\(pd)")
        save(before, "selection_before"); save(preview, "selection_preview"); save(after, "selection_after")
        d.undo()
        check(maxDiff(layerPixels(d, obj.id, canvasRect), px0) == 0, "selection: undo")
        r.close(d)
    }

    /// A selection on a smart object: the new Liquify smart filter takes it as its filter mask.
    static func smartObjectSelection(_ r: ToolRobot) {
        var st = DocumentState(width: W, height: H)
        let so = SmartObjectContent(source: .image(block(40, 40)), quad: Quad(rect: CGRect(x: 70, y: 50, width: 80, height: 80)))
        let obj = Layer(name: "Smart", content: .smartObject(so))
        st.layers = [background(), obj]
        let d = r.open(st, active: obj.id)
        r.select(.marqueeRect)
        r.dragLine(CGPoint(x: 20, y: 20), CGPoint(x: 220, y: 90))
        guard let sel = d.state.selection?.copy() else { check(false, "smart selection: marquee made a selection"); r.close(d); return }
        let px0 = layerPixels(d, obj.id, canvasRect)
        guard let (v, _, _) = openLiquify(r) else { check(false, "smart selection: Liquify opens"); r.close(d); return }
        v.brushSize = 60; v.pressure = 1; v.mode = .forward
        for y in [70, 110] { for _ in 0..<3 { drag(v, CGPoint(x: 140, y: CGFloat(y)), CGPoint(x: 190, y: CGFloat(y))) } }
        guard let field = v.field else { r.close(d); return }
        let preview = previewImage(v)
        AppModel.shared.dialog = nil
        AppActions.applyLiquify(field)
        let lp = layerPixels(d, obj.id, canvasRect)
        check(d.state.layer(obj.id)?.smart?.filters.first?.mask != nil, "smart selection: the Liquify smart filter takes the selection as its mask")
        var outMax = 0
        for y in 0..<H { for x in 0..<W where sel.alpha(x, y) == 0 { outMax = max(outMax, BlurGallery2SelfTest.dist(raw(lp, x, y), raw(px0, x, y))) } }
        check(outMax <= 1, "smart selection: outside the selection unchanged", "max Δ\(outMax)")
        let grown = count(lp) { x, y, p in sel.alpha(x, y) == 255 && x >= 153 && p.w > 200 }
        check(grown > 40, "smart selection: inside it the object is pushed past its bounds", "\(grown) px")
        let pd = maxDiff(preview, lp)
        check(pd <= 2, "smart selection: preview equals commit", "max Δ\(pd)")
        save(lp, "smart_selection_after")
        r.close(d)
    }
}
