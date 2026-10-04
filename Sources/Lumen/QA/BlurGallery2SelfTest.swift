import AppKit
import CoreImage
import SwiftUI
import ImageCratCore

/// Spin Blur, the Blur Gallery and the other blur filters with a feathered selection (QA report: “Spin blur does not
/// seem to be working when using a feathered lasso mask on an element”), on pixel layers, masked layers and smart
/// objects. Every filter runs through its real path (Filter menu → dialog or Blur Gallery session → live preview → OK).
///
///     LUMEN_SELFTEST_ONLY=blurgallery2 .build/debug/Lumen --selftest <dir>
///
/// Checked per case: outside the selection the pixels are unchanged; deep inside they are the filter's full result;
/// across the feather band they are the reference blend of filtered and original by the selection's alpha; the preview
/// equals what OK applies; OK is one undo step.
enum BlurGallery2SelfTest {
    static func register() { FeatureModules.selfTests.append(("blurgallery2", { run($0) })) }

    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") blurgallery2: \(name)\(d.isEmpty ? "" : " — " + d)")
    }
    static func info(_ s: String) { print("INFO blurgallery2: \(s)") }

    static let W = 320, H = 240
    static var dir = URL(fileURLWithPath: NSTemporaryDirectory())

    static func run(_ out: URL) {
        failures = 0; passes = 0
        dir = out.appendingPathComponent("blurgallery2")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, tool: app.tool, dialog: app.dialog, canvas: AppActions.canvas,
                     button: CanvasView.primaryButtonDown, lastFilter: AppActions.lastFilter, selection: app.selection,
                     payload: AppActions.pendingFilterPayload, hook: AppActions.modalHook)
        app.dialog = nil
        app.documents = []; app.activeDocumentID = nil
        app.selection.feather = 0
        AppActions.modalHook = { _, _ in true }
        CanvasView.primaryButtonDown = { ToolRobot.buttonDown }
        let r = ToolRobot(size: CGSize(width: 900, height: 640))
        defer {
            r.closeAll()
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active
            app.tool = saved.tool; app.selection = saved.selection
            AppActions.canvas = saved.canvas; CanvasView.primaryButtonDown = saved.button
            AppActions.lastFilter = saved.lastFilter; AppActions.pendingFilterPayload = saved.payload; AppActions.modalHook = saved.hook
            app.dialog = saved.dialog
            print("blurgallery2: \(passes) checks passed, \(failures) failed")
        }
        everyMode(r)
        selectionShapes(r)
        layerPlacement(r)
        maskedLayer(r)
        maskTargeted(r)
        smartObject(r)
        canvasPins(r)
        spinKernel(r)
        liquify(r)
    }

    // MARK: Fixtures

    /// Opaque 8 px checkerboard aligned to the document grid (a buffer placed at `origin`): every blur changes it visibly.
    static func texture(_ w: Int = W, _ h: Int = H, origin: IPoint = .zero) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        func floor8(_ v: Int) -> Int { Int((Double(v) / 8).rounded(.down)) * 8 }
        for gy in stride(from: floor8(origin.y), to: origin.y + h, by: 8) {
            for gx in stride(from: floor8(origin.x), to: origin.x + w, by: 8) {
                let on = ((gx / 8 + gy / 8) & 1) == 0
                c.setFillColor((on ? RGBA(hex: "1B1F3A")! : RGBA(hex: "F6AE2D")!).cgColor)
                c.fill(CGRect(x: gx - origin.x, y: gy - origin.y, width: 8, height: 8))
            }
        }
        b.markDirty()
        return b
    }

    static func texDoc(_ r: ToolRobot) -> Document {
        var st = DocumentState(width: W, height: H)
        st.layers = [QAFixtures.background(W, H), Layer.raster(name: "Texture", buffer: texture())]
        return r.open(st, active: st.layers[1].id)
    }

    /// Lasso drawn with the real Lasso tool (a 48-gon), optionally feathered with Select ▸ Modify ▸ Feather.
    static func lasso(_ r: ToolRobot, _ c: CGPoint, _ rad: CGFloat, feather: Double = 0) {
        r.select(.lasso)
        var pts: [CGPoint] = []
        for i in 0...48 { let a = Double(i % 48) / 48 * 2 * .pi; pts.append(CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))) }
        r.dragPath(pts)
        if feather > 0 { AppActions.modifySelection(.feather, amount: feather, direction: .centered) }
    }

    static func marquee(_ r: ToolRobot, _ rect: CGRect, toolFeather: Double) {
        let app = AppModel.shared
        let old = app.selection.feather
        app.selection.feather = toolFeather     // the marquee's own Feather option
        r.select(.marqueeRect)
        r.dragLine(rect.origin, CGPoint(x: rect.maxX, y: rect.maxY))
        app.selection.feather = old
    }

    // MARK: Running a filter through its UI path

    struct Run {
        var inst: FilterInstance
        var preview: PixelBuffer       // canvas while the dialog / session showed its preview
        var title: String
    }

    static let galleryKinds: [FilterKind] = [.fieldBlur, .irisBlur, .pathBlur]

    /// Filter menu → dialog (or Blur Gallery session) → preview → OK, with the dialog's default settings.
    static func runFilter(_ r: ToolRobot, _ k: FilterKind) -> Run? {
        let app = AppModel.shared
        guard let d = r.doc else { return nil }
        if galleryKinds.contains(k) {
            FilterLauncher.launch(k)
            guard let st = AppActions.blurGallery, app.dialog == .blurGallery else { return nil }
            AppActions.updateBlurGalleryPreview()
            let run = Run(inst: st.inst, preview: r.liveComposite(), title: st.inst.kind.displayName + AppActions.filterTargetSuffix(d))
            AppActions.finishBlurGallery(st, apply: true)
            return run
        }
        var smart: UUID? = nil
        if k == .displace {
            // (the menu command asks for the map file in an open panel first)
            let map = PixelBuffer(width: 64, height: 64)
            let g = CGGradient(colorsSpace: sRGBSpace, colors: [NSColor.black.cgColor, NSColor.white.cgColor] as CFArray, locations: [0, 1])!
            map.context.drawLinearGradient(g, start: .zero, end: CGPoint(x: 64, y: 64), options: [])
            map.markDirty()
            AppActions.pendingFilterPayload = map
            smart = d.activeLayer?.isSmartObject == true ? d.activeLayerID : nil
            app.dialog = .filter(k, smartLayer: smart, editingFilter: nil)
        } else {
            FilterLauncher.launch(k)
            guard case .filter(let fk, let sl, _)? = app.dialog, fk == k else { return nil }
            smart = sl
        }
        let dlg = FilterDialog(kind: k, smartLayer: smart, editingFilter: nil)
        dlg.updatePreview()
        let preview = r.liveComposite()
        dlg.ok()
        app.dialog = nil
        let inst: FilterInstance? = smart.flatMap { d.state.layer($0)?.smart?.filters.last } ?? AppActions.lastFilter
        guard let inst, inst.kind == k else { return nil }
        return Run(inst: inst, preview: preview, title: k.displayName + (smart != nil ? " (Smart Filter)" : AppActions.filterTargetSuffix(d)))
    }

    // MARK: Measuring

    @inline(__always) static func raw(_ b: PixelBuffer, _ x: Int, _ y: Int) -> SIMD4<Int> {
        let p = b.data.assumingMemoryBound(to: UInt8.self) + b.offset(x, y)
        return b.format == .gray ? SIMD4(Int(p[0]), Int(p[0]), Int(p[0]), 255) : SIMD4(Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }
    @inline(__always) static func dist(_ a: SIMD4<Int>, _ b: SIMD4<Int>) -> Int { max(max(abs(a.x - b.x), abs(a.y - b.y)), max(abs(a.z - b.z), abs(a.w - b.w))) }

    static func maxDiff(_ a: PixelBuffer, _ b: PixelBuffer) -> Int {
        guard a.width == b.width, a.height == b.height else { return 999 }
        var m = 0
        for y in 0..<a.height { for x in 0..<a.width { m = max(m, dist(raw(a, x, y), raw(b, x, y))) } }
        return m
    }

    struct Stats {
        var outside = 0, outsideMax = 0        // selection 0
        var deep = 0, deepMax = 0, deepChange = 0.0   // selection 255: vs the filtered reference; mean change vs the original
        var band = 0, bandMax = 0, soft = 0    // 0 < selection < 255: vs the reference blend; pixels clearly between both
        var desc: String { "outside \(outside) px max Δ\(outsideMax); deep \(deep) px max Δ\(deepMax) vs filtered, mean change \(String(format: "%.1f", deepChange)); band \(band) px max Δ\(bandMax) vs blend, \(soft) in-between" }
    }

    /// `orig`, `after`, `filtered`: buffers of one frame placed at `o` (document pixels); `sel`: canvas-size selection.
    static func measure(orig: PixelBuffer, after: PixelBuffer, filtered: PixelBuffer, at o: IPoint, sel: PixelBuffer) -> Stats {
        var s = Stats()
        var change = 0
        let x0 = max(0, o.x), y0 = max(0, o.y), x1 = min(W, o.x + orig.width), y1 = min(H, o.y + orig.height)
        guard x0 < x1, y0 < y1 else { return s }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let a = sel.alpha(x, y)
                let po = raw(orig, x - o.x, y - o.y), pa = raw(after, x - o.x, y - o.y), pf = raw(filtered, x - o.x, y - o.y)
                if a == 0 {
                    s.outside += 1; s.outsideMax = max(s.outsideMax, dist(pa, po))
                } else if a == 255 {
                    s.deep += 1; s.deepMax = max(s.deepMax, dist(pa, pf))
                    change += abs(pa.x - po.x) + abs(pa.y - po.y) + abs(pa.z - po.z)
                } else {
                    s.band += 1
                    let t = Double(a) / 255
                    let ref = SIMD4((0..<4).map { Int((Double(pf[$0]) * t + Double(po[$0]) * (1 - t)).rounded()) })
                    s.bandMax = max(s.bandMax, dist(pa, ref))
                    if dist(pf, po) > 40 && dist(pa, po) >= 8 && dist(pa, pf) >= 8 { s.soft += 1 }
                }
            }
        }
        s.deepChange = s.deep > 0 ? Double(change) / Double(s.deep * 3) : 0
        return s
    }

    /// The filter's full result on `buf` (placed at `o`), without any selection.
    static func filtered(_ f: FilterInstance, _ buf: PixelBuffer, at o: IPoint) -> PixelBuffer {
        let sp = CanvasSpace(width: W, height: H)
        let placed = sp.place(buf, at: o)
        return RenderEngine.renderBuffer(f.apply(placed, canvas: sp.ciCanvas).cropped(to: placed.extent), docRect: IRect(x: o.x, y: o.y, width: buf.width, height: buf.height), space: sp)
    }

    static func save(_ b: PixelBuffer, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: b.makeCGImage())
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    /// Runs `k` on the active pixel layer (or its layer content while a layer mask exists but isn't targeted) and
    /// checks the selection, the feather band, preview = commit and the undo step.
    @discardableResult
    static func pixelCase(_ r: ToolRobot, _ k: FilterKind, _ label: String, deepTol: Int = 2, minChange: Double = 2, expectBand: Bool = true, snap: String? = nil) -> Bool {
        guard let d = r.doc, let id = d.activeLayerID, let l0 = d.state.layer(id), let rc = l0.raster, let sel = d.state.selection?.copy() else {
            check(false, "\(label): fixture"); return false
        }
        let orig = rc.buffer.copy(), o = rc.origin
        let mask0 = l0.mask?.buffer.copy()
        let steps = d.history.count
        let before = r.liveComposite()
        guard let run = runFilter(r, k) else { check(false, "\(label) \(k.displayName): ran through its dialog / session", "dialog \(String(describing: AppModel.shared.dialog))"); return false }
        guard let after = d.state.layer(id)?.raster?.buffer, d.state.layer(id)?.raster?.origin == o else { check(false, "\(label) \(k.displayName): layer kept"); return false }
        let ref = filtered(run.inst, orig, at: o)
        let s = measure(orig: orig, after: after, filtered: ref, at: o, sel: sel)
        let name = "\(label) \(k.displayName)"
        var ok = true
        func c(_ b: Bool, _ what: String) { check(b, "\(name): \(what)", s.desc); ok = ok && b }
        c(s.outside > 0 && s.outsideMax <= 1, "outside the selection unchanged")
        c(s.deep > 0 && s.deepMax <= deepTol && s.deepChange >= minChange, "deep inside the selection fully filtered")
        if expectBand { c(s.band > 200 && s.bandMax <= 3 && s.soft > 20, "feather band = reference blend of filtered and original by the selection alpha") }
        else { c(s.bandMax <= 3, "edge pixels = reference blend") }
        let committed = r.liveComposite()
        let pd = maxDiff(run.preview, committed)
        check(pd <= 2, "\(name): preview equals the committed result", "max Δ\(pd)"); ok = ok && pd <= 2
        if let m = mask0 { let md = d.state.layer(id)?.mask.map { maxDiff($0.buffer, m) } ?? 999; check(md == 0, "\(name): the layer mask is untouched", "max Δ\(md)") }
        check(d.history.count == steps + 1 && d.history.last?.name == k.displayName, "\(name): OK is one undo step",
              "\(d.history.count - steps) steps, last “\(d.history.last?.name ?? "")”")
        if let snap { save(before, snap + "_before"); save(run.preview, snap + "_preview"); save(committed, snap + "_after") }
        d.undo()
        let back = d.state.layer(id)?.raster.map { maxDiff($0.buffer, orig) } ?? 999
        let selBack = d.state.selection.map { maxDiff($0, sel) } ?? 999
        check(back == 0 && selBack == 0, "\(name): undo restores the layer and keeps the selection", "layer Δ\(back) selection Δ\(selBack)")
        return ok
    }

    // MARK: Cases

    /// Every Blur Gallery mode and blur filter with a feathered lasso on a pixel layer.
    static func everyMode(_ r: ToolRobot) {
        let kinds: [FilterKind] = [.spinBlur, .fieldBlur, .irisBlur, .tiltShift, .pathBlur, .gaussianBlur, .motionBlur, .radialBlur, .lensBlur, .displace]
        for k in kinds {
            let d = texDoc(r)
            lasso(r, CGPoint(x: 112, y: 84), 56, feather: 12)
            pixelCase(r, k, "feathered lasso", deepTol: k == .lensBlur ? 3 : 2, minChange: k == .tiltShift ? 1 : 2, snap: k == .spinBlur ? "spin_feathered_lasso" : nil)
            if k == .spinBlur, let f = AppActions.lastFilter, let b = d.state.selection?.opaqueBounds() {
                let cx = (Double(b.x) + Double(b.width) / 2) / Double(W), cy = (Double(b.y) + Double(b.height) / 2) / Double(H)
                check(abs(f.value("cx") - cx) < 0.01 && abs(f.value("cy") - cy) < 0.01, "Spin Blur starts centred on the selected element",
                      String(format: "centre %.3f, %.3f vs selection %.3f, %.3f", f.value("cx"), f.value("cy"), cx, cy))
            }
            r.close(d)
        }
    }

    /// Hard vs feathered, small vs large feather, lasso vs marquee (Select ▸ Feather and the tool's Feather option).
    static func selectionShapes(_ r: ToolRobot) {
        for (label, feather) in [("hard-edged lasso", 0.0), ("lasso feather 2", 2.0), ("lasso feather 40", 40.0)] {
            for k in [FilterKind.spinBlur, .irisBlur] {
                let d = texDoc(r)
                lasso(r, CGPoint(x: 160, y: 120), feather > 20 ? 105 : 60, feather: feather)
                pixelCase(r, k, label, expectBand: feather > 0)
                r.close(d)
            }
        }
        for k in [FilterKind.spinBlur, .fieldBlur, .tiltShift] {
            let d = texDoc(r)
            marquee(r, CGRect(x: 60, y: 30, width: 150, height: 110), toolFeather: 10)
            pixelCase(r, k, "marquee with tool feather 10", minChange: k == .tiltShift ? 1 : 2, snap: k == .spinBlur ? "spin_marquee" : nil)
            r.close(d)
        }
    }

    /// Layers offset from the canvas origin, a selection only partly over the layer, a selection running off the canvas.
    static func layerPlacement(_ r: ToolRobot) {
        for k in [FilterKind.spinBlur, .fieldBlur, .irisBlur, .pathBlur, .tiltShift] {
            var st = DocumentState(width: W, height: H)
            let o = IPoint(x: 150, y: 50)
            st.layers = [QAFixtures.background(W, H), Layer.raster(name: "Element", buffer: texture(200, 150, origin: o), origin: o)]   // runs off the right edge
            let d = r.open(st, active: st.layers[1].id)
            lasso(r, CGPoint(x: 150, y: 110), 70, feather: 14)
            pixelCase(r, k, "offset layer partly under the selection", minChange: k == .tiltShift ? 0.5 : 2, snap: k == .spinBlur ? "spin_offset_layer" : nil)
            r.close(d)
        }
        for k in [FilterKind.spinBlur, .irisBlur] {
            let d = texDoc(r)
            lasso(r, CGPoint(x: 290, y: 40), 75, feather: 12)    // half of it outside the canvas
            pixelCase(r, k, "selection partly outside the canvas")
            r.close(d)
        }
    }

    /// A layer with a layer mask, the layer's pixels targeted: the blur changes the pixels, the mask still hides.
    static func maskedLayer(_ r: ToolRobot) {
        for k in [FilterKind.spinBlur, .irisBlur, .fieldBlur] {
            let d = texDoc(r)
            guard let id = d.activeLayerID else { continue }
            let m = PixelBuffer(width: W, height: H, gray: 255)
            m.context.setFillColor(gray: 0, alpha: 1); m.context.fill(CGRect(x: 200, y: 0, width: 120, height: H)); m.markDirty()
            d.updateLayer(id) { $0.mask = LayerMask(buffer: m, origin: .zero, outsideValue: 0) }
            d.commit("Mask")
            d.editTarget = .content
            lasso(r, CGPoint(x: 170, y: 110), 70, feather: 12)
            pixelCase(r, k, "masked layer (pixels targeted)", snap: k == .spinBlur ? "spin_masked_layer" : nil)
            r.close(d)
        }
    }

    /// The reported workflow: feathered lasso → Add Layer Mask (the mask is now the edit target) → Spin Blur.
    /// Photoshop filters the targeted mask; the preview must show exactly that (it showed the pixels spinning, OK then
    /// changed the mask: “Spin Blur does nothing”). The dialog says what it will change.
    static func maskTargeted(_ r: ToolRobot) {
        for k in [FilterKind.spinBlur, .irisBlur, .gaussianBlur] {
            let d = texDoc(r)
            guard let id = d.activeLayerID else { continue }
            lasso(r, CGPoint(x: 150, y: 110), 70, feather: 12)
            AppActions.addMask(.revealSelection)
            let pixels = d.state.layer(id)?.raster?.buffer.copy()
            let mask0 = d.state.layer(id)?.mask?.buffer.copy()
            let maskOrigin = d.state.layer(id)?.mask?.origin ?? .zero
            let steps = d.history.count
            guard d.editTarget == .mask, let pixels, let mask0, let run = runFilter(r, k) else { check(false, "mask targeted \(k.displayName): ran"); r.close(d); continue }
            let after = r.liveComposite()
            let pd = maxDiff(run.preview, after)
            check(pd <= 2, "mask targeted \(k.displayName): preview equals what OK applies", "max Δ\(pd)")
            check(run.title.hasSuffix("(Layer Mask)"), "mask targeted \(k.displayName): the dialog says it filters the layer mask", "title “\(run.title)”")
            let pix = d.state.layer(id)?.raster.map { maxDiff($0.buffer, pixels) } ?? 999
            let changed = d.state.layer(id)?.mask.map { maxDiff($0.buffer, mask0) } ?? 0
            let sp = CanvasSpace(width: W, height: H)
            let placed = sp.place(mask0, at: maskOrigin)
            let want = RenderEngine.renderBuffer(run.inst.apply(placed, canvas: sp.ciCanvas).cropped(to: placed.extent),
                                                 docRect: IRect(x: maskOrigin.x, y: maskOrigin.y, width: mask0.width, height: mask0.height), space: sp, format: .gray)
            let md = d.state.layer(id)?.mask.map { maxDiff($0.buffer, want) } ?? 999
            check(pix == 0 && changed > 0 && md <= 2, "mask targeted \(k.displayName): the mask is filtered, the pixels are not (Photoshop)",
                  "pixels Δ\(pix), mask changed by up to \(changed), Δ\(md) from the filtered mask")
            check(d.history.count == steps + 1, "mask targeted \(k.displayName): one undo step")
            if k == .spinBlur { save(run.preview, "spin_mask_targeted_preview"); save(after, "spin_mask_targeted_after") }
            // clicking the layer thumbnail targets the pixels again: the blur then goes to the element, inside a new selection
            d.editTarget = .content
            lasso(r, CGPoint(x: 150, y: 110), 60, feather: 12)
            pixelCase(r, k, "masked layer, pixels re-targeted", snap: k == .spinBlur ? "spin_mask_then_pixels" : nil)
            r.close(d)
        }
    }

    /// Smart object: the filter becomes a smart filter and the selection its filter mask.
    static func smartObject(_ r: ToolRobot) {
        for k in [FilterKind.spinBlur, .irisBlur, .fieldBlur, .pathBlur, .tiltShift, .gaussianBlur] {
            let d = texDoc(r)
            AppActions.convertToSmartObject()
            guard let id = d.activeLayerID, d.activeLayer?.isSmartObject == true else { check(false, "smart object fixture"); r.close(d); continue }
            lasso(r, CGPoint(x: 140, y: 100), 66, feather: 14)
            guard let sel = d.state.selection?.copy() else { continue }
            let before = r.liveComposite()
            let steps = d.history.count
            guard let run = runFilter(r, k) else { check(false, "smart object \(k.displayName): ran through its dialog / session"); r.close(d); continue }
            let after = r.liveComposite()
            let filters = d.state.layer(id)?.smart?.filters ?? []
            check(filters.count == 1 && filters[0].kind == k && filters[0].mask != nil, "smart object \(k.displayName): a smart filter with the selection as its filter mask",
                  "\(filters.count) filters, mask \(filters.first?.mask != nil)")
            var unmasked = d.state
            unmasked.updateLayer(id) { $0.smart?.filters[0].mask = nil }
            let full = QAMeasure.composite(unmasked)
            let s = measure(orig: before, after: after, filtered: full, at: .zero, sel: sel)
            check(s.outside > 0 && s.outsideMax <= 1, "smart object \(k.displayName): outside the selection unchanged", s.desc)
            check(s.deepMax <= 2 && s.deepChange >= (k == .tiltShift ? 0.5 : 2), "smart object \(k.displayName): deep inside fully filtered", s.desc)
            check(s.band > 200 && s.bandMax <= 3 && s.soft > 20, "smart object \(k.displayName): feather band = reference blend", s.desc)
            let pd = maxDiff(run.preview, after)
            check(pd <= 2, "smart object \(k.displayName): preview equals the committed result", "max Δ\(pd)")
            check(d.history.count == steps + 1 && d.history.last?.name == k.displayName, "smart object \(k.displayName): one undo step")
            if k == .spinBlur {
                save(before, "spin_smart_before"); save(run.preview, "spin_smart_preview"); save(after, "spin_smart_after")
                // the filter mask is saved with the document and moves with the layer
                if let f = filters.first, let data = try? JSONEncoder().encode(f), let back = try? JSONDecoder().decode(FilterInstance.self, from: data) {
                    check(back.mask.map { maxDiff($0.buffer, f.mask!.buffer) == 0 && $0.origin == f.mask!.origin } ?? false, "smart filter mask survives encoding")
                }
                d.updateLayer(id) { $0.translate(dx: 12, dy: -7) }
                check(d.state.layer(id)?.smart?.filters.first?.mask?.origin == IPoint(x: 12, y: -7), "smart filter mask moves with the layer",
                      "origin \(String(describing: d.state.layer(id)?.smart?.filters.first?.mask?.origin))")
                d.revertUncommitted()
                // an immediate filter / recorded action on a smart object gets the mask too
                AppActions.applyFilter(FilterInstance(kind: .average))
                check(d.state.layer(id)?.smart?.filters.last?.mask != nil, "smart filter added without a dialog takes the selection as its mask")
            }
            d.undo()
            check(d.state.layer(id)?.smart?.filters.count == (k == .spinBlur ? 1 : 0), "smart object \(k.displayName): undo removes it")
            r.close(d)
        }
    }

    /// The Blur Gallery's on-canvas controls with an active selection: hit-testing, dragging, pins, ants.
    static func canvasPins(_ r: ToolRobot) {
        let d = texDoc(r)
        lasso(r, CGPoint(x: 150, y: 110), 70, feather: 12)
        guard let sel = d.state.selection?.copy(), let pixels = d.activeLayer?.raster?.buffer.copy() else { return }
        AppActions.startBlurGallery(.irisBlur)
        guard let st = AppActions.blurGallery else { check(false, "Iris Blur session starts with a selection"); r.close(d); return }
        r.select(.move)
        r.dragLine(CGPoint(x: 160, y: 120), CGPoint(x: 130, y: 95), steps: 4)
        let p = st.inst.points.first
        check(p.map { abs($0.x * Double(W) - 130) < 1.5 && abs($0.y * Double(H) - 95) < 1.5 } ?? false, "Iris Blur: the centre pin drags inside a selection",
              "pin at \(p.map { "\($0.x * Double(W)), \($0.y * Double(H))" } ?? "none")")
        check(maxDiff(d.state.selection ?? PixelBuffer(width: 1, height: 1), sel) == 0, "Iris Blur: dragging a pin leaves the selection alone")
        check(d.activeLayer?.raster.map { maxDiff($0.buffer, pixels) } == 0 && AppModel.shared.dialog == .blurGallery, "Iris Blur: no pixels change until OK, the session stays open")
        check(d.showSelectionEdges && r.drawOverlay() != nil, "Iris Blur: overlay (ellipse, pins, marching ants) draws with a selection")
        r.saveOverlayPNG("blurgallery2_iris_overlay")
        AppActions.updateBlurGalleryPreview()
        let steps = d.history.count
        AppActions.finishBlurGallery(st, apply: true)
        check(d.history.count == steps + 1 && d.history.last?.name == "Iris Blur", "Iris Blur after dragging: one undo step")
        // Field Blur: a click inside the selection adds a pin
        AppActions.startBlurGallery(.fieldBlur)
        if let fs = AppActions.blurGallery {
            r.click(CGPoint(x: 120, y: 90))
            check(fs.inst.points.count == 2, "Field Blur: clicking inside the selection adds a pin", "\(fs.inst.points.count) pins")
            AppActions.finishBlurGallery(fs, apply: false)
        }
        r.close(d)
    }

    /// Spin Blur's own rendering: a true average of the rotated copies, smooth far from the centre.
    static func spinKernel(_ r: ToolRobot) {
        let sp = CanvasSpace(width: W, height: H)
        // a half-transparent disc spun about its own centre stays the same (copies composited source-over built up alpha)
        let disc = PixelBuffer(width: W, height: H)
        disc.context.setFillColor(RGBA(r: 0.2, g: 0.5, b: 0.9, a: 0.5).cgColor)
        disc.context.fillEllipse(in: CGRect(x: 100, y: 60, width: 120, height: 120))
        disc.markDirty()
        var f = FilterInstance(kind: .spinBlur)
        f.values["angle"] = 40
        let out = filtered(f, disc, at: .zero)
        var worst = 0
        for (x, y) in [(160, 120), (130, 120), (190, 100), (160, 70)] { worst = max(worst, dist(raw(out, x, y), raw(disc, x, y))) }
        check(worst <= 3, "Spin Blur: a half-transparent element spun about its centre keeps its opacity", "max Δ\(worst) (alpha \(raw(disc, 160, 120).w) → \(raw(out, 160, 120).w))")
        // smooth arcs: compare with a 720-sample reference far from the centre
        let tex = texture()
        f.values["angle"] = 30; f.values["cx"] = 0.1; f.values["cy"] = 0.1
        let got = filtered(f, tex, at: .zero)
        let c = CGPoint(x: 0.1 * Double(W), y: Double(H) - 0.1 * Double(H))
        let src = sp.place(tex, at: .zero).clampedToExtent()
        let n = 360
        var acc = [Double](repeating: 0, count: W * H * 4)
        for i in 0..<n {
            let a = CGFloat(30 * Double.pi / 180 * ((Double(i) + 0.5) / Double(n) - 0.5))
            let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: a).translatedBy(x: -c.x, y: -c.y)
            let b = RenderEngine.renderBuffer(src.transformed(by: t).cropped(to: sp.ciCanvas), docRect: d0, space: sp)
            for y in 0..<H { for x in 0..<W { let p = raw(b, x, y); for k in 0..<4 { acc[(y * W + x) * 4 + k] += Double(p[k]) } } }
        }
        let ref = PixelBuffer(width: W, height: H)
        let rp = ref.data.assumingMemoryBound(to: UInt8.self)
        for y in 0..<H { for x in 0..<W { for k in 0..<4 { rp[ref.offset(x, y) + k] = UInt8(max(0, min(255, (acc[(y * W + x) * 4 + k] / Double(n)).rounded()))) } } }
        ref.markDirty()
        var sum = 0, cnt = 0, mx = 0
        for y in 0..<H { for x in 0..<W where hypot(Double(x) - 32, Double(y) - 24) > 200 {
            let dd = dist(raw(got, x, y), raw(ref, x, y)); sum += dd; cnt += 1; mx = max(mx, dd)
        } }
        let mean = Double(sum) / Double(max(1, cnt))
        check(mean < 2.5 && mx <= 12, "Spin Blur: smooth arcs far from the centre (no ghost copies)", String(format: "mean Δ%.2f max Δ%d over %d px", mean, mx, cnt))
        save(got, "spin_far_from_centre"); save(ref, "spin_far_from_centre_reference")
        // render time on a large image (information)
        let big = PixelBuffer(width: 3000, height: 2000)
        big.context.setFillColor(RGBA(hex: "2E86AB")!.cgColor); big.context.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        big.context.setFillColor(RGBA(hex: "F6AE2D")!.cgColor)
        for i in 0..<60 { big.context.fill(CGRect(x: i * 50, y: 0, width: 20, height: 2000)) }
        big.markDirty()
        let bsp = CanvasSpace(width: 3000, height: 2000)
        for angle in [10.0, 60.0] {
            var g = FilterInstance(kind: .spinBlur); g.values["angle"] = angle
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = RenderEngine.renderBuffer(g.apply(bsp.place(big, at: .zero), canvas: bsp.ciCanvas), docRect: IRect(x: 0, y: 0, width: 3000, height: 2000), space: bsp)
            info(String(format: "Spin Blur %.0f° on 3000×2000: %.0f ms", angle, (CFAbsoluteTimeGetCurrent() - t0) * 1000))
        }
    }
    static let d0 = IRect(x: 0, y: 0, width: W, height: H)

    /// Liquify keeps its own preview: it must show the warp kept to the (feathered) selection, like OK applies it, and
    /// OK changes the layer's pixels even while its layer mask is targeted.
    static func liquify(_ r: ToolRobot) {
        let d = texDoc(r)
        lasso(r, CGPoint(x: 160, y: 120), 60, feather: 12)
        guard let sel = d.state.selection?.copy(), let id = d.activeLayerID else { return }
        let sp = CanvasSpace(width: W, height: H)
        let source = sp.place(d.activeLayer!.raster!.buffer, at: .zero)
        let field = DisplacementField(width: W, height: H)
        for i in 0..<20 { field.apply(mode: .forward, center: CGPoint(x: 60 + i * 10, y: 120), delta: CGPoint(x: 10, y: 6), radius: 140, pressure: 1) }
        func shot(_ fl: DisplacementField?, _ s: CIImage?) -> NSBitmapImageRep? {
            let v = LiquifyPreviewView(frame: CGRect(x: 0, y: 0, width: W, height: H))
            v.source = source; v.space = sp; v.field = fl ?? DisplacementField(width: W, height: H); v.selection = s; v.showMask = false
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
            v.cacheDisplay(in: v.bounds, to: rep)
            return rep
        }
        if let plain = shot(nil, nil), let warped = shot(field, sel.ciImage) {
            var outD = 0.0, inD = 0.0, nOut = 0, nIn = 0
            let k = Double(plain.pixelsWide) / Double(W)   // (the bitmap is at the backing scale)
            for y in stride(from: 2, to: H - 2, by: 2) { for x in stride(from: 2, to: W - 2, by: 2) {
                let bx = Int((Double(x) + 0.5) * k), by = Int((Double(y) + 0.5) * k)
                guard let a = plain.colorAt(x: bx, y: by), let b = warped.colorAt(x: bx, y: by) else { continue }
                let dd = abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
                let s = sel.alpha(x, y)
                if s == 0 { outD += Double(dd); nOut += 1 } else if s == 255 { inD += Double(dd); nIn += 1 }
            } }
            outD /= Double(max(1, nOut)); inD /= Double(max(1, nIn))
            check(outD < 0.01 && inD > 0.05, "Liquify preview: the warp shows only inside the selection, like OK applies it",
                  String(format: "mean change outside %.4f, inside %.4f", outD, inD))
            if let data = warped.representation(using: .png, properties: [:]) { try? data.write(to: dir.appendingPathComponent("liquify_preview_selection.png")) }
        } else {
            check(false, "Liquify preview renders offscreen")
        }
        // OK with the layer mask targeted: the pixels warp, the mask stays
        d.updateLayer(id) { $0.mask = .reveal(width: W, height: H) }
        d.commit("Mask")
        d.editTarget = .mask
        let mask0 = d.activeLayer!.mask!.buffer.copy(), px0 = d.activeLayer!.raster!.buffer.copy()
        AppActions.applyToActiveLayer(name: "Liquify", layerPixels: true) { field.warp($0, space: sp) }
        let md = maxDiff(d.activeLayer!.mask!.buffer, mask0), pd = maxDiff(d.activeLayer!.raster!.buffer, px0)
        check(md == 0 && pd > 20, "Liquify OK with the layer mask targeted warps the pixels, not the mask", "mask Δ\(md), pixels Δ\(pd)")
        r.close(d)
    }
}
