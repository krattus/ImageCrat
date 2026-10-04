import AppKit
import SwiftUI
import CoreImage
import ImageCratCore

/// Regression checks for the document / layer bugs of the 30 Sept – 1 Oct QA report (B02 B04 B06 B08 B09 B12 B13).
///
///     LUMEN_SELFTEST_ONLY=docfixes .build/debug/Lumen --selftest <dir>
///
/// Every check runs on synthetic documents. `LUMEN_DOCFIXES_BASE=<path of the tester's base.lumen>` also replays the
/// report's own steps on that file (B08, B09, B12, B13).
enum DocFixesTests {
    static func register() { FeatureModules.selfTests.append(("docfixes", { run($0) })) }

    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = ok ? "" : detail()
        print("\(ok ? "PASS" : "FAIL") docfixes: \(name)\(d.isEmpty ? "" : " — " + d)")
    }
    static func info(_ s: String) { print("INFO docfixes: \(s)") }

    /// Tester's fixture, when given.
    static var baseURL: URL? {
        guard let p = ProcessInfo.processInfo.environment["LUMEN_DOCFIXES_BASE"], FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    static var modalLog: [String] = []
    static var modalAnswer = false

    static func run(_ out: URL) {
        failures = 0; passes = 0
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, tool: app.tool, fg: app.foreground, bg: app.background, brush: app.brush,
                     dialog: app.dialog, canvas: AppActions.canvas, hook: AppActions.modalHook, button: CanvasView.primaryButtonDown,
                     eraser: app.eraser, gradient: app.gradientTool, bucket: app.bucket, lastFilter: AppActions.lastFilter)
        app.dialog = nil
        app.documents = []; app.activeDocumentID = nil
        AppActions.modalHook = { title, _ in modalLog.append(title); return modalAnswer }
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        let r = ToolRobot(size: CGSize(width: 900, height: 640))
        defer {
            r.closeAll()
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active
            app.tool = saved.tool; app.foreground = saved.fg; app.background = saved.bg; app.brush = saved.brush
            app.eraser = saved.eraser; app.gradientTool = saved.gradient; app.bucket = saved.bucket
            AppActions.canvas = saved.canvas; AppActions.modalHook = saved.hook; CanvasView.primaryButtonDown = saved.button
            AppActions.lastFilter = saved.lastFilter
            app.dialog = saved.dialog
            print("docfixes: \(passes) checks passed, \(failures) failed")
        }
        quickMask(r)
        historySelection(r)
        warpText(r)
        grayscale(r, out)
        lockAll(r)
        filterMenu(r)
        freeTransform(r)
    }

    // MARK: Helpers

    static let W = 320, H = 240

    static func block(_ name: String, _ rect: CGRect, _ c1: RGBA, _ c2: RGBA, w: Int = W, h: Int = H) -> Layer {
        let buf = PixelBuffer(width: w, height: h)
        buf.context.setFillColor(c1.cgColor); buf.context.fill(rect)
        buf.context.setFillColor(c2.cgColor); buf.context.fill(rect.insetBy(dx: rect.width * 0.3, dy: rect.height * 0.3))
        buf.markDirty()
        return Layer.raster(name: name, buffer: buf)
    }

    static func baseState() -> DocumentState {
        var st = DocumentState(width: W, height: H)
        st.layers = [QAFixtures.background(W, H), block("Paint", CGRect(x: 40, y: 30, width: 240, height: 180), RGBA(hex: "2E86AB")!, RGBA(hex: "F6AE2D")!)]
        return st
    }

    /// Raw bytes of every raster (and mask) buffer of the document.
    static func pixelBytes(_ st: DocumentState) -> [Data] {
        var out: [Data] = []
        for l in st.allLayers {
            if let r = l.raster { out.append(Data(bytes: r.buffer.data, count: r.buffer.bytesPerRow * r.buffer.height)) }
            if let m = l.mask { out.append(Data(bytes: m.buffer.data, count: m.buffer.bytesPerRow * m.buffer.height)) }
        }
        return out
    }

    static func gray(_ b: PixelBuffer?, _ x: Int, _ y: Int) -> Int { b.map { Int($0.pixel(x, y).0) } ?? -1 }

    static func rgba(_ img: CIImage, _ st: DocumentState) -> PixelBuffer {
        let sp = CanvasSpace(width: st.width, height: st.height)
        return RenderEngine.renderBuffer(img.cropped(to: sp.ciCanvas), docRect: st.canvasRect, space: sp)
    }

    /// Largest channel spread (max − min of r, g, b) over the opaque pixels of a buffer.
    static func maxSpread(_ b: PixelBuffer, step: Int = 1) -> Int {
        var m = 0
        for y in stride(from: 0, to: b.height, by: step) {
            for x in stride(from: 0, to: b.width, by: step) {
                let p = b.pixel(x, y)
                if p.3 < 8 { continue }
                m = max(m, Int(max(p.0, p.1, p.2)) - Int(min(p.0, p.1, p.2)))
            }
        }
        return m
    }

    static func loadBase() -> Document? {
        guard let u = baseURL else { return nil }
        do { return try DocumentIO.load(url: u) } catch { info("could not load base.lumen: \(error)"); return nil }
    }

    static func layerNamed(_ d: Document, _ n: String) -> Layer? { d.state.allLayers.first { $0.name == n } }

    // MARK: B09 — painting in Quick Mask paints the mask, never the layer

    static func quickMask(_ r: ToolRobot) {
        let app = AppModel.shared
        let d = r.open(baseState(), name: "qm")
        let paintID = d.state.layers[1].id
        d.selectLayer(paintID)
        let rect = CGRect(x: 80, y: 60, width: 160, height: 120)
        d.setSelection(SelectionOps.rectMask(rect, width: W, height: H), commitName: "Rectangular Marquee")
        let before = pixelBytes(d.state)
        let steps0 = d.history.count
        AppActions.toggleQuickMask()
        check(d.quickMask, "B09 Q turns Quick Mask on")
        app.tool = .brush
        app.foreground = .black; app.background = .white
        var b = app.brush; b.size = 20; b.opacity = 1; b.flow = 1; b.hardness = 1; b.spacing = 0.1; app.brush = b
        var live = -1
        r.dragLine(CGPoint(x: 110, y: 120), CGPoint(x: 210, y: 120), steps: 8) { i in if i == 5 { live = gray(d.state.selection, 130, 120) } }
        check(pixelBytes(d.state) == before, "B09 brush in Quick Mask leaves every layer's pixels byte-identical")
        check(live >= 0 && live < 40, "B09 the mask changes while the stroke is being painted (live)", "mask at stroke mid-drag \(live)")
        check(gray(d.state.selection, 160, 120) < 40, "B09 black paints the mask (unselected)", "\(gray(d.state.selection, 160, 120))")
        check(gray(d.state.selection, 160, 80) == 255 && gray(d.state.selection, 20, 20) == 0, "B09 unpainted mask keeps the selection",
              "inside \(gray(d.state.selection, 160, 80)) outside \(gray(d.state.selection, 20, 20))")
        check(d.history.count == steps0 + 1, "B09 the stroke is one history step", "\(d.history.count - steps0)")
        // red overlay follows the painted mask
        let white = CIImage.color(.white, CanvasSpace(width: W, height: H).ciCanvas)
        let shown = rgba(CanvasRenderer.applyViewMode(white, doc: d), d.state)
        let onStroke = shown.pixel(160, 120), unpainted = shown.pixel(160, 80)
        check(onStroke.0 > 200 && onStroke.1 < 160 && unpainted.1 > 240, "B09 the red overlay shows the painted stroke",
              "stroke \(onStroke) unpainted \(unpainted)")
        // undo removes the mask stroke (and only that)
        d.undo()
        check(gray(d.state.selection, 160, 120) == 255 && pixelBytes(d.state) == before, "B09 undo removes the mask stroke",
              "mask \(gray(d.state.selection, 160, 120))")
        d.redo()
        // leaving Quick Mask: the painted mask is the selection
        AppActions.toggleQuickMask()
        check(!d.quickMask && gray(d.state.selection, 160, 120) < 40 && gray(d.state.selection, 160, 80) == 255 && gray(d.state.selection, 20, 20) == 0,
              "B09 leaving Quick Mask makes the painted mask the selection", "stroke \(gray(d.state.selection, 160, 120))")
        let edge = gray(d.state.selection, 160, 130)
        info("B09 selection across the stroke edge: \((108...132).map { gray(d.state.selection, 160, $0) })")
        check(pixelBytes(d.state) == before, "B09 layer pixels still untouched after leaving Quick Mask", "edge \(edge)")

        // other pixel tools and commands in Quick Mask
        AppActions.toggleQuickMask()
        func quick(_ name: String, _ body: () -> Void, _ expect: (Document) -> Bool) {
            let sel0 = d.state.selection.map { Data(bytes: $0.data, count: $0.bytesPerRow * $0.height) }
            body()
            let sel1 = d.state.selection.map { Data(bytes: $0.data, count: $0.bytesPerRow * $0.height) }
            check(pixelBytes(d.state) == before, "B09 \(name) in Quick Mask leaves the layer pixels alone")
            check(sel0 != sel1 && expect(d), "B09 \(name) in Quick Mask edits the mask")
        }
        app.tool = .eraser
        var e = app.eraser; e.size = 30; e.opacity = 1; e.hardness = 1; app.eraser = e
        quick("eraser", { r.dragLine(CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 20)) }, { gray($0.state.selection, 30, 20) == 255 })
        app.tool = .gradient
        quick("gradient", { r.dragLine(CGPoint(x: 0, y: 200), CGPoint(x: 300, y: 200)) }, { gray($0.state.selection, 10, 200) != gray($0.state.selection, 290, 200) })
        app.tool = .paintBucket
        var bk = app.bucket; bk.opacity = 1; bk.usePattern = false; app.bucket = bk
        quick("paint bucket", { r.click(CGPoint(x: 160, y: 80)) }, { gray($0.state.selection, 160, 80) < 10 })
        quick("Filter ▸ Gaussian Blur", {
            var f = FilterInstance(kind: .gaussianBlur); f.values["radius"] = 6; AppActions.applyFilter(f)
        }, { _ in true })
        quick("Edit ▸ Fill", { AppActions.fill(.white, opacity: 1, mode: .normal, preserveTransparency: false) }, { gray($0.state.selection, 5, 5) == 255 })
        quick("Image ▸ Adjustments ▸ Invert", { AppActions.invertActive() }, { gray($0.state.selection, 5, 5) == 0 })
        // tools that can't paint a mask are refused rather than painting the layer
        for k: ToolKind in [.healing, .historyBrush, .mixerBrush, .magicEraser, .colorReplacement] {
            app.tool = k
            let sel0 = d.state.selection.map { Data(bytes: $0.data, count: $0.bytesPerRow * $0.height) }
            r.dragLine(CGPoint(x: 100, y: 100), CGPoint(x: 150, y: 110))
            r.tool.commit()
            check(pixelBytes(d.state) == before && sel0 == d.state.selection.map { Data(bytes: $0.data, count: $0.bytesPerRow * $0.height) },
                  "B09 \(k.displayName) is refused in Quick Mask (layer and mask unchanged)")
        }
        AppActions.toggleQuickMask()

        // no selection: Quick Mask starts empty (nothing masked); a black stroke is left out of the new selection
        d.setSelection(nil, commitName: "Deselect")
        AppActions.toggleQuickMask()
        let noRed = rgba(CanvasRenderer.applyViewMode(white, doc: d), d.state).pixel(20, 20)
        check(noRed.1 > 240, "B09 Quick Mask without a selection shows nothing masked", "\(noRed)")
        app.tool = .brush
        r.dragLine(CGPoint(x: 60, y: 200), CGPoint(x: 120, y: 200))
        AppActions.toggleQuickMask()
        check(gray(d.state.selection, 90, 200) < 40 && gray(d.state.selection, 20, 20) == 255 && pixelBytes(d.state) == before,
              "B09 painting a Quick Mask started without a selection selects everything but the stroke")
        r.close(d)

        // the report's steps on base.lumen: rasterize Sonoma copy, marquee inside it, Q, brush, Q
        guard let bd = loadBase() else { info("B09 base.lumen replay skipped (LUMEN_DOCFIXES_BASE not set)"); return }
        app.documents.append(bd); app.activeDocumentID = bd.id
        r.activate(bd)
        r.setView(QAView(name: "base", zoom: 0.5, offset: CGPoint(x: 20, y: 20)))
        guard let so = layerNamed(bd, "Sonoma copy") else { check(false, "B09 base.lumen has Sonoma copy"); return }
        bd.selectLayer(so.id)
        AppActions.rasterizeLayer(so.id)
        guard let rb = Compositor.shared.contentBounds(bd.state.layer(so.id)!, state: bd.state) else { check(false, "B09 rasterized Sonoma copy has pixels"); return }
        let sr = rb.insetBy(dx: rb.width * 0.3, dy: rb.height * 0.3).integral
        bd.setSelection(SelectionOps.rectMask(sr, width: bd.state.width, height: bd.state.height), commitName: "Rectangular Marquee")
        let bBefore = pixelBytes(bd.state)
        AppActions.toggleQuickMask()
        app.tool = .brush
        var b2 = app.brush; b2.size = 30; app.brush = b2
        let y = sr.midY
        r.dragLine(CGPoint(x: sr.minX + 20, y: y), CGPoint(x: sr.maxX - 20, y: y))
        AppActions.toggleQuickMask()
        check(pixelBytes(bd.state) == bBefore, "B09 base.lumen: Sonoma copy pixels byte-identical after painting in Quick Mask")
        check(gray(bd.state.selection, Int(sr.midX), Int(y)) < 40 && gray(bd.state.selection, Int(sr.midX), Int(sr.minY) + 5) == 255,
              "B09 base.lumen: the selection has the painted stroke taken out")
        AppActions.deselect()
        check(pixelBytes(bd.state) == bBefore, "B09 base.lumen: nothing painted on the image after Deselect")
        r.close(bd)
    }

    // MARK: B08 — undo / redo bring back the layer selection of that state

    static func historySelection(_ r: ToolRobot) {
        func doc() -> (Document, UUID) {
            var st = baseState()
            st.layers.append(Layer(name: "Group 1", content: .group(GroupContent())))   // unrelated top layer
            let d = r.open(st, name: "hist")
            let src = st.layers[1].id
            d.selectLayer(src)
            return (d, src)
        }
        // Select and Mask ▸ Output To: New Layer
        do {
            let (d, src) = doc()
            d.setSelection(SelectionOps.rectMask(CGRect(x: 60, y: 50, width: 90, height: 70), width: W, height: H), commitName: "Rectangular Marquee")
            var s = RefineSettings(); s.output = .newLayer
            AppActions.applyRefinedSelection(d.state.selection!.copy(), settings: s)
            let made = d.activeLayerID
            check(made != src && d.activeLayer?.name == "Paint copy", "B08 Select and Mask made a new active layer")
            d.undo()
            check(d.activeLayerID == src, "B08 undo of Select and Mask ▸ New Layer selects the source layer again",
                  "active \(d.activeLayer?.name ?? "nil")")
            d.redo()
            check(d.activeLayerID == made, "B08 redo selects the output layer again", "active \(d.activeLayer?.name ?? "nil")")
            r.close(d)
        }
        // the same for every command that adds a layer
        let commands: [(String, () -> Void)] = [
            ("New Layer", { AppActions.newLayer() }), ("Duplicate Layer", { AppActions.duplicateLayers() }), ("New Group", { AppActions.newGroup() }),
            ("Group Layers", { AppActions.groupLayers() }), ("New Adjustment Layer", { AppActions.newAdjustmentLayer(.levels) }),
            ("New Fill Layer", { AppActions.newFillLayer(.color(.black), name: "Color Fill") }), ("Stamp Visible", { AppActions.stampVisible() }),
            ("Convert to Smart Object", { AppActions.convertToSmartObject() })]
        for (name, cmd) in commands {
            let (d, src) = doc()
            cmd()
            let after = d.activeLayerID
            d.undo()
            check(d.activeLayerID == src, "B08 undo of \(name) selects the layer that was selected before", "active \(d.activeLayer?.name ?? "nil")")
            d.redo()
            check(d.activeLayerID == after, "B08 redo of \(name) selects its result again", "active \(d.activeLayer?.name ?? "nil")")
            r.close(d)
        }
        // a layer picked between two steps is the one that comes back when undoing to that step
        do {
            let (d, src) = doc()
            let bg = d.state.layers[0].id
            d.selectLayer(bg)
            AppActions.newLayer()
            d.undo()
            check(d.activeLayerID == bg, "B08 undo returns to the layer picked after the previous step", "active \(d.activeLayer?.name ?? "nil") src \(src)")
            r.close(d)
        }
        // the report's steps on base.lumen
        guard let bd = loadBase() else { info("B08 base.lumen replay skipped"); return }
        AppModel.shared.documents.append(bd); AppModel.shared.activeDocumentID = bd.id
        r.activate(bd)
        guard let so = layerNamed(bd, "Sonoma copy") else { check(false, "B08 base.lumen has Sonoma copy"); return }
        bd.selectLayer(so.id)
        AppActions.rasterizeLayer(so.id)
        let b = Compositor.shared.contentBounds(bd.state.layer(so.id)!, state: bd.state) ?? bd.state.canvasCGRect
        bd.setSelection(SelectionOps.rectMask(b.insetBy(dx: b.width * 0.3, dy: b.height * 0.3), width: bd.state.width, height: bd.state.height),
                        commitName: "Rectangular Marquee")
        var s = RefineSettings(); s.output = .newLayer
        AppActions.applyRefinedSelection(bd.state.selection!.copy(), settings: s)
        bd.undo()
        check(bd.activeLayerID == so.id, "B08 base.lumen: undo of Select and Mask ▸ New Layer selects Sonoma copy, not Group 1",
              "active \(bd.activeLayer?.name ?? "nil")")
        r.close(bd)
    }

    // MARK: B12 — Warp Text Cancel restores the warp; OK is one undo step

    /// Hosts the app's dialog overlay off-screen (as the window shows it) and returns a way to press its buttons.
    final class DialogHost {
        let window: NSWindow
        let host: NSHostingView<AnyView>
        init() {
            FuzzAX.enable()
            host = NSHostingView(rootView: AnyView(DialogOverlay().environment(\.colorScheme, .dark).font(Theme.font).foregroundStyle(Theme.text)))
            host.frame = CGRect(x: 0, y: 0, width: 1100, height: 800)
            window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderFrontRegardless()
        }
        func pump(_ s: Double = 0.15) {
            host.layoutSubtreeIfNeeded()
            host.display()
            RunLoop.current.run(until: Date().addingTimeInterval(s))
        }
        func nodes() -> [FuzzAX.Node] { FuzzAX.tree(host) }
        @discardableResult
        func press(_ label: String) -> Bool {
            guard let n = nodes().first(where: { $0.label == label && $0.role.contains("Button") }) else { return false }
            return FuzzAX.press(n.element)
        }
        func labels() -> [String] { nodes().map(\.label).filter { !$0.isEmpty } }
        func close() { window.orderOut(nil); window.contentView = nil }
    }

    static func warpText(_ r: ToolRobot) {
        let app = AppModel.shared
        func doc() -> (Document, UUID) {
            var st = baseState()
            let t = QAFixtures.textLayer("Warp me", at: CGPoint(x: 40, y: 80), size: 40)
            st.layers.append(t)
            let d = r.open(st, name: "warp")
            d.selectLayer(t.id)
            d.markSaved()
            return (d, t.id)
        }
        let arc = TextWarp(style: .arc, bend: 50)
        // Cancel through the real dialog: the preview is what the style picker's change does (the layer is updated
        // without a history step); the dialog then re-renders with the document, as it does in the app.
        do {
            let (d, id) = doc()
            let steps = d.history.count
            let host = DialogHost()
            TypeEdit.openWarpDialog()
            host.pump()
            check(app.dialog == .warpText, "B12 Type ▸ Warp Text opens the dialog")
            d.updateLayer(id) { $0.text?.warp = arc }
            d.setNeedsRender()
            host.pump()
            check(d.state.layer(id)?.text?.warp == arc, "B12 the Arc preview is on the layer while the dialog is open")
            let pressed = host.press("Cancel")
            host.pump()
            check(pressed && app.dialog == nil, "B12 Cancel closes the dialog", "pressed \(pressed) labels \(host.labels().prefix(20))")
            check(d.state.layer(id)?.text?.warp == nil, "B12 Cancel restores the original (no) warp",
                  "warp \(String(describing: d.state.layer(id)?.text?.warp?.style))")
            check(d.history.count == steps && !d.isDirty, "B12 Cancel leaves no history step and a clean document")
            host.close()
            app.dialog = nil
            r.close(d)
        }
        // OK: exactly one step, document dirty; OK without a change: no step
        do {
            let (d, id) = doc()
            let steps = d.history.count
            Compat.warpOK(d, id, TextWarp(style: .none, bend: 50))
            check(d.history.count == steps && !d.isDirty, "B12 OK without a change records nothing", "\(d.history.count - steps) steps")
            Compat.warpPreview(d, id, TextWarp(style: .flag, bend: 20))
            Compat.warpPreview(d, id, arc)
            Compat.warpOK(d, id, arc)
            check(d.history.count == steps + 1 && d.history.last?.name == "Warp Text" && d.isDirty, "B12 OK records one Warp Text step and marks the document dirty",
                  "\(d.history.count - steps) steps")
            d.undo()
            check(d.state.layer(id)?.text?.warp == nil, "B12 undo of Warp Text restores the straight text")
            r.close(d)
        }
        guard let bd = loadBase() else { info("B12 base.lumen replay skipped"); return }
        app.documents.append(bd); app.activeDocumentID = bd.id
        r.activate(bd)
        bd.markSaved()
        guard let t = layerNamed(bd, "LUMEN QA") else { check(false, "B12 base.lumen has LUMEN QA"); return }
        bd.selectLayer(t.id)
        let orig = t.text?.warp
        let host = DialogHost()
        TypeEdit.openWarpDialog()
        host.pump()
        bd.updateLayer(t.id) { $0.text?.warp = arc }
        bd.setNeedsRender()
        host.pump()
        host.press("Cancel")
        host.pump()
        check(bd.state.layer(t.id)?.text?.warp == orig && !bd.isDirty && bd.history.count == 1, "B12 base.lumen: Warp Text Arc → Cancel restores LUMEN QA")
        host.close()
        app.dialog = nil
        r.close(bd)
    }

    // MARK: B13 — Grayscale renders the whole document gray

    static func grayscale(_ r: ToolRobot, _ out: URL) {
        func colourful() -> Document {
            var st = DocumentState(width: W, height: H)
            st.layers = [QAFixtures.background(W, H)]
            var fill = Layer(name: "Fill", content: .fill(FillContent(paint: .color(RGBA(hex: "20C040")!))))
            fill.mask = LayerMask(buffer: SelectionOps.rectMask(CGRect(x: 0, y: 0, width: 60, height: H), width: W, height: H), origin: .zero, outsideValue: 0)
            st.layers.append(fill)
            st.layers.append(block("Pixels", CGRect(x: 70, y: 10, width: 60, height: 60), RGBA(hex: "E02020")!, RGBA(hex: "2040E0")!))
            st.layers.append(block("Smart", CGRect(x: 150, y: 10, width: 70, height: 70), RGBA(hex: "E0A000")!, RGBA(hex: "8020C0")!))
            var shape = QAFixtures.shapeLayer(CGRect(x: 80, y: 120, width: 70, height: 60), RGBA(hex: "1060F0")!)
            shape.effects.dropShadow.enabled = true; shape.effects.dropShadow.color = RGBA(hex: "FF0000")!
            shape.effects.dropShadow.blendMode = .normal; shape.effects.dropShadow.opacity = 1; shape.effects.dropShadow.distance = 10
            st.layers.append(shape)
            var t = QAFixtures.textLayer("Aa", at: CGPoint(x: 180, y: 120), size: 60)
            if var tc = t.text { tc.color = RGBA(hex: "FF2060")!; t.content = .text(tc) }
            st.layers.append(t)
            var pf = AdjustmentSettings(kind: .photoFilter); pf.filterColor = RGBA(hex: "EC8A00")!
            st.layers.append(Layer(name: "Photo Filter", content: .adjustment(pf)))
            let d = r.open(st, name: "gray")
            d.selectLayer(st.layers[3].id)
            AppActions.convertToSmartObject()
            return d
        }
        let d = colourful()
        check(d.activeLayer?.isSmartObject == true, "B13 fixture has a smart object")
        info("B13 RGB composite spread \(maxSpread(rgba(Compositor.shared.composite(d.state), d.state), step: 2))")
        AppActions.convertMode(.grayscale)
        let comp = rgba(Compositor.shared.composite(d.state), d.state)
        check(d.state.colorMode == .grayscale && maxSpread(comp) <= 2, "B13 Grayscale: smart object, type, shape, fill, effects and adjustments composite gray",
              "max channel spread \(maxSpread(comp))")
        let png = out.appendingPathComponent("docfixes_grayscale.png")
        try? DocumentIO.export(d.state, to: png, format: .png, quality: 1, scale: 1)
        if let (cg, _) = DocumentIO.loadImage(url: png) {
            check(maxSpread(PixelBuffer(cgImage: cg)) <= 2, "B13 exported PNG of a Grayscale document is gray", "spread \(maxSpread(PixelBuffer(cgImage: cg)))")
        } else { check(false, "B13 PNG export readable") }
        d.undo()
        check(d.state.colorMode == .rgb && maxSpread(rgba(Compositor.shared.composite(d.state), d.state), step: 2) > 100, "B13 undo of Grayscale brings the colour back")
        // Grayscale → RGB: pixel layers stay gray; live content (smart objects, type…) keeps its own colours (as a smart object does in Photoshop)
        AppActions.convertMode(.grayscale)
        AppActions.convertMode(.rgb)
        if let px = layerNamed(d, "Pixels")?.raster { check(maxSpread(px.buffer) <= 2, "B13 Grayscale → RGB keeps pixel layers gray") }
        info("B13 Gray → RGB composite spread \(maxSpread(rgba(Compositor.shared.composite(d.state), d.state), step: 2)) (live layers show their colours again)")
        r.close(d)
        // the other modes: Bitmap, Indexed, Duotone flatten or remap the whole composite, CMYK proofs it
        do {
            let d2 = colourful()
            ColorModes.convertToBitmap(d2, BitmapOptions())
            check(maxSpread(rgba(ImagingDisplay.inks(Compositor.shared.composite(d2.state), state: d2.state), d2.state)) == 0, "B13 Bitmap: every layer kind ends up black / white")
            r.close(d2)
            let d3 = colourful()
            ColorModes.convertToDuotone(d3, DuotoneSettings.presets[0].1)
            check(maxSpread(rgba(ImagingDisplay.inks(Compositor.shared.composite(d3.state), state: d3.state), d3.state)) <= 2, "B13 Duotone (black monotone): every layer kind is inked from its gray")
            r.close(d3)
            let d4 = colourful()
            let smartBefore = rgba(Compositor.shared.composite(d4.state), d4.state).pixel(160, 20)
            ColorModes.convertToIndexed(d4, IndexedOptions())
            let idx = rgba(Compositor.shared.composite(d4.state), d4.state).pixel(160, 20)
            check(d4.state.layers.count == 1 && abs(Int(idx.0) - Int(smartBefore.0)) < 24, "B13 Indexed flattens the smart object with its colours", "\(smartBefore) → \(idx)")
            r.close(d4)
            let d5 = colourful()
            AppActions.convertMode(.cmyk)
            let shown = rgba(CanvasRenderer.applyViewMode(Compositor.shared.composite(d5.state), doc: d5), d5.state)
            let proofed = rgba(ColorConvert.softProof(ColorConvert.displayImage(Compositor.shared.composite(d5.state), profile: d5.state.profileName), settings: AppModel.shared.proof), d5.state)
            check(shown.pixel(160, 20) == proofed.pixel(160, 20), "B13 CMYK: smart object content is shown through the CMYK proof like pixel layers")
            r.close(d5)
        }
        guard let bd = loadBase() else { info("B13 base.lumen replay skipped"); return }
        AppModel.shared.documents.append(bd); AppModel.shared.activeDocumentID = bd.id
        r.activate(bd)
        AppActions.convertMode(.grayscale)
        let bc = rgba(Compositor.shared.composite(bd.state), bd.state)
        check(maxSpread(bc, step: 3) <= 2, "B13 base.lumen: Image ▸ Mode ▸ Grayscale leaves no colour (Sonoma smart objects included)", "spread \(maxSpread(bc, step: 3))")
        r.close(bd)
    }

    // MARK: B02 — Lock All freezes blend mode, opacity and fill

    static func lockAll(_ r: ToolRobot) {
        let d = r.open(baseState(), name: "lock")
        let id = d.state.layers[1].id
        d.selectLayer(id)
        AppActions.setLock(\.all)
        check(d.activeLayer?.locks.all == true, "B02 Lock All is on")
        let steps = d.history.count
        Compat.setBlending(d) { $0.blendMode = .multiply }
        Compat.setBlending(d) { $0.opacity = 0.3 }
        Compat.setBlending(d) { $0.fillOpacity = 0.2 }
        let l = d.activeLayer!
        check(l.blendMode == .normal && l.opacity == 1 && l.fillOpacity == 1, "B02 blend mode / opacity / fill of a Lock All layer can't change",
              "\(l.blendMode) \(l.opacity) \(l.fillOpacity)")
        _ = PaletteVerbs.perform(.blend(.screen))
        _ = PaletteVerbs.perform(.opacity(40))
        check(d.activeLayer?.blendMode == .normal && d.activeLayer?.opacity == 1 && d.history.count == steps,
              "B02 Command Palette blend / opacity verbs leave a Lock All layer alone")
        // the Layers panel shows its blend mode control disabled
        let app = AppModel.shared
        let host = NSHostingView(rootView: LayersPanel().environment(\.colorScheme, .dark).font(Theme.font).frame(width: 300, height: 400))
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 400), styleMask: .borderless, backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        win.orderFrontRegardless()
        FuzzAX.enable()
        host.layoutSubtreeIfNeeded(); host.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let mode = d.activeLayer?.blendMode.displayName ?? "Normal"
        let blend = FuzzAX.tree(host).first { $0.label == mode && ($0.role.contains("PopUp") || $0.role.contains("Button") || $0.role.contains("Menu")) }
        check(blend != nil && !FuzzAX.isEnabled(blend!.element), "B02 the Layers panel's blend mode menu is disabled under Lock All",
              blend == nil ? "not found: \(FuzzAX.tree(host).map { "\($0.role):\($0.label)" }.prefix(40))" : "enabled")
        AppActions.setLock(\.all)
        host.layoutSubtreeIfNeeded(); host.display()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let blend2 = FuzzAX.tree(host).first { $0.label == mode && ($0.role.contains("PopUp") || $0.role.contains("Button") || $0.role.contains("Menu")) }
        check(blend2.map { FuzzAX.isEnabled($0.element) } ?? false, "B02 …and enabled again after unlocking")
        win.orderOut(nil); win.contentView = nil
        Compat.setBlending(d) { $0.blendMode = .multiply }
        check(d.activeLayer?.blendMode == .multiply, "B02 an unlocked layer's blend mode still changes")
        _ = app
        r.close(d)
    }

    // MARK: B04 — every enabled Filter command can run on the active layer

    /// Active-layer kinds of the Filter / Transform checks.
    static func kinds(_ r: ToolRobot) -> [(String, () -> Document)] {
        func make(_ top: Layer?, select: Bool = true, _ post: ((Document) -> Void)? = nil) -> () -> Document {
            return {
                var st = baseState()
                if let t = top { st.layers.append(t) }
                let d = r.open(st, name: "kind")
                d.selectLayer(st.layers.last!.id)
                post?(d)
                d.markSaved()
                return d
            }
        }
        var locked = block("Locked", CGRect(x: 20, y: 20, width: 60, height: 60), .black, .white); locked.locks.position = true
        return [
            ("pixel", make(nil)),
            ("empty pixel", make(Layer.raster(name: "Empty", width: W, height: H))),
            ("smart object", make(block("SO", CGRect(x: 30, y: 30, width: 90, height: 80), .black, .white)) { _ in AppActions.convertToSmartObject() }),
            ("type", make(QAFixtures.textLayer())),
            ("shape", make(QAFixtures.shapeLayer())),
            ("fill", make(Layer(name: "Fill", content: .fill(FillContent(paint: .color(RGBA(hex: "20C040")!)))))),
            ("adjustment", make(Layer(name: "Levels", content: .adjustment(AdjustmentSettings(kind: .levels))))),
            ("group", make(Layer(name: "G", content: .group(GroupContent(children: [block("In", CGRect(x: 50, y: 50, width: 40, height: 40), .black, .white)]))))),
            ("empty group", make(Layer(name: "G0", content: .group(GroupContent())))),
            ("position-locked pixel", make(locked)),
        ]
    }

    static func filterMenu(_ r: ToolRobot) {
        let app = AppModel.shared
        let deadPhrases = ["Select a pixel layer first", "Select a layer first", "first."]
        func dialogIsDead() -> Bool {
            guard case .custom = app.dialog else { return false }
            let host = DialogHost()
            host.pump(0.1)
            let dead = host.labels().contains { l in deadPhrases.contains { l.contains($0) } }
            host.close()
            return dead
        }
        var custom: [(String, MenuItemSpec)] = []
        for m in ["Filter"] + FilterCategory.allCases.map { "Filter/" + $0.rawValue } {
            for it in MenuRegistry.items(for: m) where !["Recipe Filter…", "Neural Filters…", "AI Denoise…", "AI Sharpen / Deblur…"].contains(it.title) && it.submenu != "Textures" && it.submenu != "360 Panorama" {
                custom.append((it.title, it))
            }
        }
        check(custom.contains { $0.0 == "Adaptive Wide Angle…" } && custom.contains { $0.0 == "Vanishing Point…" }, "B04 Adaptive Wide Angle and Vanishing Point are in the Filter menu")
        let standard = FilterCategory.allCases.flatMap { FilterKind.byCategory($0) }.filter { ![.displace, .fieldBlur, .irisBlur, .pathBlur].contains($0) }
        for (kname, make) in kinds(r) {
            // registered Filter items (Adaptive Wide Angle, Vanishing Point…): enabled ⇒ a working dialog, or a rasterize offer that leads to one
            for (title, it) in custom {
                let d = make()
                modalLog = []; modalAnswer = true
                let enabled = it.enabled()
                if enabled {
                    it.action()
                    let dead = dialogIsDead()
                    check(!dead, "B04 \(title) on a \(kname) layer: enabled and opens a working dialog", "dialog asks for another layer (alerts \(modalLog))")
                } else {
                    info("B04 \(title) disabled for a \(kname) layer")
                }
                app.dialog = nil
                r.close(d)
            }
            // Liquify / standard filters: enabled ⇒ OK applies the filter (after rasterizing when asked)
            for k in standard {
                let d = make()
                modalLog = []; modalAnswer = true
                guard Compat.canRunFilter(d) else { r.close(d); continue }
                let id = d.activeLayerID
                FilterLauncher.launch(k)
                if case .filter(let fk, _, _)? = app.dialog, fk == k {
                    app.dialog = nil
                    AppActions.applyFilter(FilterInstance(kind: k, colors: [app.foreground, app.background]))   // what OK does
                }
                app.dialog = nil
                let applied = d.history.last?.name == k.displayName && d.state.layer(id) != nil
                check(applied, "B04 \(k.displayName) on a \(kname) layer: enabled and applied", "last step “\(d.history.last?.name ?? "")”, alerts \(modalLog)")
                r.close(d)
                if !applied && kname != "pixel" { break }   // one report per layer kind is enough
            }
        }
        // the report's case: Adaptive Wide Angle / Vanishing Point on a smart object offer to rasterize, then open for real
        for title in ["Adaptive Wide Angle…", "Vanishing Point…"] {
            guard let it = custom.first(where: { $0.0 == title })?.1, let make = kinds(r).first(where: { $0.0 == "smart object" })?.1 else { continue }
            let d = make()
            modalLog = []; modalAnswer = true
            it.action()
            check(d.activeLayer?.isRaster == true && app.dialog != nil && !dialogIsDead(), "B04 \(title) on a smart object: rasterize offered, then a working dialog",
                  "alerts \(modalLog), raster \(d.activeLayer?.isRaster == true)")
            app.dialog = nil
            r.close(d)
        }
    }

    // MARK: B06 — Free Transform is enabled exactly when there is something to transform

    static func freeTransform(_ r: ToolRobot) {
        for (kname, make) in kinds(r) {
            let d = make()
            let enabled = Compat.canFreeTransform()
            AppModel.shared.setStatus("")
            AppActions.freeTransform()
            let mt = r.toolOf(.move, MoveTool.self)
            let started = mt?.session != nil
            mt?.cancel()
            check(enabled == started, "B06 Free Transform on a \(kname) layer: enabled \(enabled), starts a session \(started)",
                  "status “\(AppModel.shared.statusMessage)”")
            r.close(d)
        }
    }
}

/// New API of the fixes, or the behaviour of the code before them (`swift build -Xswiftc -DDOCFIXES_OLD`, used once to
/// confirm that each check fails there).
enum Compat {
    #if DOCFIXES_OLD
    static func setBlending(_ d: Document, _ body: (inout Layer) -> Void) { for id in d.orderedSelection { d.updateLayer(id, body) } }
    static func canFreeTransform() -> Bool { AppActions.doc != nil }
    static func canRunFilter(_ d: Document) -> Bool { true }
    static func warpPreview(_ d: Document, _ id: UUID, _ w: TextWarp) { d.updateLayer(id) { $0.text?.warp = w.style == .none ? nil : w } }
    static func warpOK(_ d: Document, _ id: UUID, _ w: TextWarp) { warpPreview(d, id, w); d.commit("Warp Text") }
    #else
    static func setBlending(_ d: Document, _ body: (inout Layer) -> Void) { AppActions.setBlending(d, body) }
    static func canFreeTransform() -> Bool { AppActions.canFreeTransform }
    static func canRunFilter(_ d: Document) -> Bool { FilterLauncher.canRun() }
    static func warpPreview(_ d: Document, _ id: UUID, _ w: TextWarp) { WarpTextDialog.preview(d, id, w) }
    static func warpOK(_ d: Document, _ id: UUID, _ w: TextWarp) { WarpTextDialog.commit(d, id, w) }
    #endif
}
