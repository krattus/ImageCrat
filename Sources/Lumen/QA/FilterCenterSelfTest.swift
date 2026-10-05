import AppKit
import CoreImage
import SwiftUI
import ImageCratCore

/// The Center option of Twirl and the other filters that work about a centre point (QA report: “When I choose twirl
/// effect it takes the centre point for the object to be the centre of the whole document”). Runs every case through
/// the real path (Filter menu → dialog → live preview → OK) on a big document with a small off-centre object.
///
///     LUMEN_SELFTEST_ONLY=filtercenter .build/debug/Lumen --selftest <dir>
///
/// The centre is measured from the result pixels: the middle of the area a distortion changed (its disc), or the
/// change-weighted centroid for the radial blurs. Checked: Object (alpha bounds, not the layer's buffer), Canvas (= the
/// result before the option), Selection, Custom, preview = commit at 100 % and reduced zoom, the radius sized from the
/// object, smart filters following a moved object, Repeat Filter and actions re-centring, the remembered mode,
/// `.imagecrat` / PSD round trips and filters saved before the option.
enum FilterCenterSelfTest {
    static func register() { FeatureModules.selfTests.append(("filtercenter", { run($0) })) }

    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passes += 1 } else { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL") filtercenter: \(name)\(d.isEmpty ? "" : " — " + d)")
    }

    static let W = 1200, H = 800
    /// The object: an opaque 200 × 200 square at (860, 120) inside a bigger, mostly transparent buffer (so the layer's
    /// buffer middle (930, 200) is not the object's middle (960, 220)).
    static let objectRect = CGRect(x: 860, y: 120, width: 200, height: 200)
    static let bufferOrigin = IPoint(x: 740, y: 40)
    static var dir = URL(fileURLWithPath: NSTemporaryDirectory())
    static let kinds: [FilterKind] = [.twirl, .pinch, .spherize, .radialBlur]

    static func run(_ out: URL) {
        failures = 0; passes = 0
        dir = out.appendingPathComponent("filtercenter")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = AppModel.shared
        let saved = (docs: app.documents, active: app.activeDocumentID, dialog: app.dialog, canvas: AppActions.canvas,
                     lastFilter: AppActions.lastFilter, memory: FilterCenterMemory.memory, hook: AppActions.modalHook)
        let userPrefs = UserDefaults.standard.object(forKey: FilterCenterMemory.key) as? NSObject
        app.dialog = nil
        app.documents = []; app.activeDocumentID = nil
        AppActions.modalHook = { _, _ in true }
        let r = ToolRobot(size: CGSize(width: 900, height: 640))
        defer {
            r.closeAll()
            app.dialog = nil
            app.documents = saved.docs; app.activeDocumentID = saved.active
            AppActions.canvas = saved.canvas
            AppActions.lastFilter = saved.lastFilter; AppActions.modalHook = saved.hook
            FilterCenterMemory.memory = saved.memory
            app.dialog = saved.dialog
            print("filtercenter: \(passes) checks passed, \(failures) failed")
        }
        catalogue()
        for k in kinds {
            objectMode(r, k)
            canvasMode(r, k)
            selectionMode(r, k)
            customMode(r, k)
            smartFilter(r, k)
            repeatFilter(r, k)
        }
        otherKinds(r)
        actions(r)
        remembered(r)
        roundTrips(r)
        legacy()
        recipeNode()
        dialogPicture(r)
        let now = UserDefaults.standard.object(forKey: FilterCenterMemory.key) as? NSObject
        check(now == userPrefs, "the user's remembered Center modes are neither read nor written by the tests")
    }

    // MARK: Fixtures

    /// Opaque 10 px checkerboard of two colours with a diagonal colour ramp (every distortion and blur changes it).
    static func texture(_ w: Int, _ h: Int) -> PixelBuffer {
        let b = PixelBuffer(width: w, height: h)
        let c = b.context
        for gy in stride(from: 0, to: h, by: 10) {
            for gx in stride(from: 0, to: w, by: 10) {
                let on = ((gx / 10 + gy / 10) & 1) == 0
                let t = Double(gx + gy) / Double(max(1, w + h))
                c.setFillColor((on ? RGBA(r: 0.1, g: 0.12, b: 0.25 + 0.5 * t, a: 1) : RGBA(r: 0.95, g: 0.7 - 0.4 * t, b: 0.2, a: 1)).cgColor)
                c.fill(CGRect(x: gx, y: gy, width: 10, height: 10))
            }
        }
        b.markDirty()
        return b
    }

    static func white() -> Layer {
        let b = PixelBuffer(width: W, height: H)
        b.context.setFillColor(RGBA.white.cgColor); b.context.fill(CGRect(x: 0, y: 0, width: W, height: H)); b.markDirty()
        return Layer.raster(name: "Background", buffer: b)
    }

    /// The off-centre object on its own layer (a buffer with uneven transparent margins).
    static func objectLayer(_ rect: CGRect = objectRect, margins: (l: Int, t: Int, r: Int, b: Int) = (120, 80, 60, 40), name: String = "Object") -> Layer {
        let w = Int(rect.width), h = Int(rect.height)
        let buf = PixelBuffer(width: w + margins.l + margins.r, height: h + margins.t + margins.b)
        buf.copyPixels(from: texture(w, h), at: IPoint(x: margins.l, y: margins.t))
        buf.markDirty()
        return Layer.raster(name: name, buffer: buf, origin: IPoint(x: Int(rect.minX) - margins.l, y: Int(rect.minY) - margins.t))
    }

    static func objectDoc(_ r: ToolRobot) -> Document {
        var st = DocumentState(width: W, height: H)
        st.layers = [white(), objectLayer()]
        return r.open(st, active: st.layers[1].id)
    }

    /// Full-canvas textured layer (for Selection / Custom, where the effect's area must be all pixels).
    static func textureDoc(_ r: ToolRobot) -> Document {
        var st = DocumentState(width: W, height: H)
        st.layers = [white(), Layer.raster(name: "Photo", buffer: texture(W, H))]
        return r.open(st, active: st.layers[1].id)
    }

    static func rectSelection(_ rect: CGRect) -> PixelBuffer {
        let s = PixelBuffer(width: W, height: H, format: .gray)
        let p = s.data.assumingMemoryBound(to: UInt8.self)
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) { p[s.offset(x, y)] = 255 } }
        s.markDirty()
        return s
    }

    static func save(_ b: PixelBuffer, _ name: String) {
        let rep = NSBitmapImageRep(cgImage: b.makeCGImage())
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name + ".png"))
    }

    // MARK: Running a filter through its dialog

    struct Run {
        var inst: FilterInstance
        var preview: PixelBuffer
        var zoomPreviews: [PixelBuffer]
    }
    static let zooms: [CGFloat] = [0.25, 0.5, 1]

    /// Filter menu → dialog (remembered mode, or `seed`) → live preview (also at reduced zoom) → OK.
    static func runDialog(_ r: ToolRobot, _ k: FilterKind, seed: FilterInstance? = nil) -> Run? {
        let app = AppModel.shared
        guard let d = r.doc else { return nil }
        FilterLauncher.launch(k)
        guard case .filter(let fk, let smart, _)? = app.dialog, fk == k else { return nil }
        let dlg = FilterDialog(kind: k, smartLayer: smart, editingFilter: nil, seed: seed)
        dlg.updatePreview()
        let preview = r.liveComposite()
        let zp = zooms.map { ZoomFXSelfTest.shown(d, $0) }
        dlg.ok()
        app.dialog = nil
        let inst: FilterInstance? = smart.flatMap { d.state.layer($0)?.smart?.filters.last } ?? AppActions.lastFilter
        guard let inst, inst.kind == k else { return nil }
        return Run(inst: inst, preview: preview, zoomPreviews: zp)
    }

    /// Preview = commit at 100 % (composite) and at every reduced zoom the canvas shows.
    static func previewEqualsCommit(_ r: ToolRobot, _ run: Run, _ name: String) {
        guard let d = r.doc else { return }
        let committed = r.liveComposite()
        let m = BlurGallery2SelfTest.maxDiff(run.preview, committed)
        check(m <= 1, "\(name): the preview equals the committed result", "max Δ\(m)")
        for (z, p) in zip(zooms, run.zoomPreviews) {
            let c = ZoomFXSelfTest.shown(d, z)
            let dz = ZoomFXSelfTest.diff(p, c)
            check(dz.max <= 1, "\(name): preview = commit on the canvas at \(Int(z * 100)) %", "max Δ\(dz.max)")
        }
        d.zoom = 1
    }

    // MARK: Measuring

    struct Change {
        var bbox: CGRect?          // pixels changed by more than the threshold
        var centroid: CGPoint?     // change-weighted
        var count = 0
        var bboxCenter: CGPoint? { bbox.map { CGPoint(x: $0.midX, y: $0.midY) } }
    }

    /// What changed between two canvas-size buffers inside `area`.
    static func change(_ a: PixelBuffer, _ b: PixelBuffer, in area: CGRect? = nil, threshold: Int = 24) -> Change {
        var c = Change()
        let r = (area ?? CGRect(x: 0, y: 0, width: a.width, height: a.height)).intersection(CGRect(x: 0, y: 0, width: a.width, height: a.height))
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        var sx = 0.0, sy = 0.0, sw = 0.0
        for y in Int(r.minY)..<Int(r.maxY) {
            for x in Int(r.minX)..<Int(r.maxX) {
                let dv = BlurGallery2SelfTest.dist(BlurGallery2SelfTest.raw(a, x, y), BlurGallery2SelfTest.raw(b, x, y))
                if dv > threshold {
                    c.count += 1
                    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
                }
                if dv > 2 { sx += Double(x) * Double(dv); sy += Double(y) * Double(dv); sw += Double(dv) }
            }
        }
        if x1 >= 0 { c.bbox = CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1) }
        if sw > 0 { c.centroid = CGPoint(x: sx / sw + 0.5, y: sy / sw + 0.5) }
        return c
    }

    static func isBlur(_ k: FilterKind) -> Bool { k == .radialBlur || k == .spinBlur }

    /// The centre measured from the change: the middle of a distortion's disc, a blur's change centroid.
    static func measured(_ k: FilterKind, _ c: Change) -> CGPoint? { isBlur(k) ? c.centroid : c.bboxCenter }

    static func near(_ p: CGPoint?, _ q: CGPoint, _ tol: CGFloat) -> Bool { p.map { hypot($0.x - q.x, $0.y - q.y) <= tol } ?? false }
    static func fmt(_ p: CGPoint?) -> String { p.map { String(format: "(%.1f, %.1f)", $0.x, $0.y) } ?? "nil" }
    static func fmt(_ r: CGRect?) -> String { r.map { String(format: "(%.0f, %.0f %.0f×%.0f)", $0.minX, $0.minY, $0.width, $0.height) } ?? "nil" }
    static func tol(_ k: FilterKind) -> CGFloat { isBlur(k) ? 8 : 3 }

    static func normCenter(_ f: FilterInstance) -> CGPoint { let c = f.centerPixel(canvasWidth: Double(W), canvasHeight: Double(H)); return CGPoint(x: c.x, y: c.y) }

    // MARK: Cases

    /// Every centre-based filter has the option and the controls; the others don't.
    static func catalogue() {
        let expected: Set<FilterKind> = [.twirl, .pinch, .spherize, .vortex, .polarCoordinates, .kaleidoscope, .radialBlur, .spinBlur, .lensFlare, .spotlight, .vignette]
        check(Set(FilterKind.centerKinds) == expected, "the Center option is on every filter that works about a centre", FilterKind.centerKinds.map(\.rawValue).joined(separator: ", "))
        check(!FilterKind.gaussianBlur.usesCenter && !FilterKind.ripple.usesCenter && !FilterKind.wave.usesCenter, "filters without a centre (Gaussian Blur, Ripple, Wave) have no Center option")
        check(FilterKind.twirl.defaultCenterMode == .object && FilterKind.lensFlare.defaultCenterMode == .custom, "new filters centre on the object (a lens flare keeps its off-centre spot)")
    }

    /// Object mode: centred on the alpha bounds of the layer's pixels, sized from them.
    static func objectMode(_ r: ToolRobot, _ k: FilterKind) {
        FilterCenterMemory.memory = [:]
        let d = objectDoc(r)
        let before = r.liveComposite()
        guard let run = runDialog(r, k) else { check(false, "\(k.displayName) Object: ran through its dialog"); r.close(d); return }
        let name = "\(k.displayName) Object"
        let want = CGPoint(x: objectRect.midX, y: objectRect.midY)
        check(run.inst.centerMode == .object, "\(name): a new filter starts in Object mode", "\(String(describing: run.inst.centerMode))")
        check(near(normCenter(run.inst), want, 0.01), "\(name): the stored centre is the middle of the object's pixels (not of the layer's buffer or the canvas)", fmt(normCenter(run.inst)))
        let box = run.inst.centerBox
        check(abs(box.width * Double(W) - 200) < 0.01 && abs(box.height * Double(H) - 200) < 0.01, "\(name): sized from the object's bounds", "\(box.width * Double(W)) × \(box.height * Double(H))")
        let after = r.liveComposite()
        let c = change(before, after, in: isBlur(k) ? objectRect : nil)   // (a blur also spreads into the transparent margins, clipped unevenly by the buffer)
        check(near(measured(k, c), want, tol(k)), "\(name): the effect is centred on the object, measured from the pixels", "measured \(fmt(measured(k, c))) want \(fmt(want)); changed \(fmt(c.bbox))")
        if !isBlur(k), let bb = c.bbox, k.params.contains(where: { $0.key == "radius" }) {
            let rad = run.inst.value("radius") * 200
            // (Core Image's pinch reaches a little past its radius)
            check(bb.width <= 2 * rad * (k == .pinch ? 1.15 : 1) + 4 && bb.width >= 2 * rad * 0.6, "\(name): the radius is the object's (\(Int(rad)) px), not the canvas's", "changed area \(fmt(bb))")
        }
        if !isBlur(k), let bb = c.bbox {
            check(objectRect.insetBy(dx: k == .pinch ? -16 : -2, dy: k == .pinch ? -16 : -2).contains(bb), "\(name): nothing far from the object changed", fmt(bb))
        }
        previewEqualsCommit(r, run, name)
        if k == .twirl || k == .radialBlur {
            let slug = k.rawValue
            save(before, "\(slug)_object_before"); save(after, "\(slug)_object_after")
        }
        r.close(d)
    }

    /// Canvas mode: exactly the result from before the option (a filter without a Center mode).
    static func canvasMode(_ r: ToolRobot, _ k: FilterKind) {
        FilterCenterMemory.memory = [k.rawValue: [Double(FilterCenterMode.canvas.rawValue), 0.5, 0.5]]
        let d = objectDoc(r)
        let before = r.liveComposite()
        guard let run = runDialog(r, k) else { check(false, "\(k.displayName) Canvas: ran through its dialog"); r.close(d); return }
        let name = "\(k.displayName) Canvas"
        check(run.inst.centerMode == .canvas && near(normCenter(run.inst), CGPoint(x: W / 2, y: H / 2), 0.01), "\(name): the remembered Canvas mode is used, centred on the document", fmt(normCenter(run.inst)))
        let canvasResult = r.liveComposite()
        previewEqualsCommit(r, run, name)
        r.close(d)
        // the same document, filtered the old way
        let d2 = objectDoc(r)
        AppActions.applyFilter(FilterInstance(kind: k))
        let old = r.liveComposite()
        let m = BlurGallery2SelfTest.maxDiff(canvasResult, old)
        check(m == 0, "\(name): identical to the result before the Center option", "max Δ\(m)")
        if k == .twirl {
            save(canvasResult, "twirl_canvas_after")
            let c = change(before, canvasResult)
            check(!near(c.bboxCenter, CGPoint(x: objectRect.midX, y: objectRect.midY), 20), "\(name): (the old behaviour this replaces: not centred on the object)", "changed \(fmt(c.bbox))")
        }
        r.close(d2)
    }

    /// Selection mode: automatic while a selection is active, centred on (and sized from) the selection's bounds.
    static func selectionMode(_ r: ToolRobot, _ k: FilterKind) {
        FilterCenterMemory.memory = [:]
        let d = textureDoc(r)
        let selRect = CGRect(x: 100, y: 450, width: 300, height: 250)
        d.state.selection = rectSelection(selRect)
        let before = r.liveComposite()
        guard let run = runDialog(r, k) else { check(false, "\(k.displayName) Selection: ran through its dialog"); r.close(d); return }
        let name = "\(k.displayName) Selection"
        let want = CGPoint(x: selRect.midX, y: selRect.midY)
        check(run.inst.centerMode == .selection, "\(name): Selection is chosen automatically while a selection is active", "\(String(describing: run.inst.centerMode))")
        check(near(normCenter(run.inst), want, 0.01), "\(name): the stored centre is the selection's middle", fmt(normCenter(run.inst)))
        let after = r.liveComposite()
        let c = change(before, after, in: selRect)
        check(near(measured(k, c), want, tol(k)), "\(name): the effect is centred on the selection, measured from the pixels", "measured \(fmt(measured(k, c))) want \(fmt(want))")
        let outside = change(before, after, threshold: 1)
        if let bb = outside.bbox { check(selRect.insetBy(dx: -1, dy: -1).contains(bb), "\(name): nothing outside the selection changed", fmt(bb)) }
        previewEqualsCommit(r, run, name)
        if k == .twirl { save(before, "twirl_selection_before"); save(after, "twirl_selection_after") }
        r.close(d)
    }

    /// Custom: the chosen point (the radius keeps the size it was resolved with).
    static func customMode(_ r: ToolRobot, _ k: FilterKind) {
        FilterCenterMemory.memory = [:]
        let d = textureDoc(r)
        let before = r.liveComposite()
        var seed = FilterInstance(kind: k, colors: [AppModel.shared.foreground, AppModel.shared.background])
        seed.resolveCenter(FilterCenterContext(canvasWidth: Double(W), canvasHeight: Double(H), object: CGRect(x: 0, y: 0, width: 220, height: 220)), mode: .object)
        let want = CGPoint(x: 420, y: 300)
        seed.setCustomCenter(x: Double(want.x), y: Double(want.y), canvasWidth: Double(W), canvasHeight: Double(H))
        guard let run = runDialog(r, k, seed: seed) else { check(false, "\(k.displayName) Custom: ran through its dialog"); r.close(d); return }
        let name = "\(k.displayName) Custom"
        check(run.inst.centerMode == .custom && near(normCenter(run.inst), want, 0.01), "\(name): the chosen point is stored", fmt(normCenter(run.inst)))
        let after = r.liveComposite()
        let area = CGRect(x: want.x - 160, y: want.y - 160, width: 320, height: 320)
        let c = change(before, after, in: area)
        check(near(measured(k, c), want, tol(k)), "\(name): the effect is centred on the chosen point, measured from the pixels", "measured \(fmt(measured(k, c))) want \(fmt(want))")
        previewEqualsCommit(r, run, name)
        if k == .twirl { save(after, "twirl_custom_after") }
        r.close(d)
    }

    /// A smart filter in Object mode follows the object when the layer moves.
    static func smartFilter(_ r: ToolRobot, _ k: FilterKind) {
        FilterCenterMemory.memory = [:]
        var st = DocumentState(width: W, height: H)
        let so = SmartObjectContent(source: .image(texture(200, 200)), quad: Quad(rect: objectRect), sourceName: "Object")
        st.layers = [white(), Layer(name: "Smart", content: .smartObject(so))]
        let d = r.open(st, active: st.layers[1].id)
        let id = st.layers[1].id
        let before = r.liveComposite()
        guard let run = runDialog(r, k) else { check(false, "\(k.displayName) smart filter: ran through its dialog"); r.close(d); return }
        let name = "\(k.displayName) smart filter"
        check(d.state.layer(id)?.smart?.filters.count == 1 && run.inst.centerMode == .object, "\(name): added as a smart filter in Object mode")
        let after = r.liveComposite()
        let want = CGPoint(x: objectRect.midX, y: objectRect.midY)
        let c = change(before, after)
        check(near(measured(k, c), want, tol(k)), "\(name): centred on the smart object", "measured \(fmt(measured(k, c)))")
        let m = BlurGallery2SelfTest.maxDiff(run.preview, after)
        check(m <= 1, "\(name): the preview equals the committed smart filter", "max Δ\(m)")
        // move the layer: the filter re-renders about the object where it is now
        let dx = -500.0, dy = 300.0
        d.updateLayer(id) { l in if let q = l.smart?.quad { l.smart?.quad = q.applying(CGAffineTransform(translationX: dx, y: dy)) } }
        d.commit("Move")
        let moved = r.liveComposite()
        var plain = d.state; plain.layers[1].smart?.filters = []
        let movedPlain = RenderEngine.renderBuffer(Compositor.shared.composite(plain), docRect: plain.canvasRect, space: CanvasSpace(width: W, height: H))
        let want2 = CGPoint(x: want.x + dx, y: want.y + dy)
        let c2 = change(movedPlain, moved)
        check(near(measured(k, c2), want2, tol(k)), "\(name): after moving the layer the effect is centred on the object's new place", "measured \(fmt(measured(k, c2))) want \(fmt(want2))")
        let a = after.cropped(to: IRect(enclosing: objectRect.insetBy(dx: -4, dy: -4)))
        let b = moved.cropped(to: IRect(enclosing: objectRect.insetBy(dx: -4, dy: -4).offsetBy(dx: dx, dy: dy)))
        let md = BlurGallery2SelfTest.maxDiff(a, b)
        check(md <= 1, "\(name): the moved result is the same picture, just moved", "max Δ\(md)")
        if k == .twirl { save(after, "twirl_smart_before_move"); save(moved, "twirl_smart_after_move") }
        r.close(d)
    }

    /// Repeat Filter re-centres an Object-mode filter on the active layer's object; a Canvas one stays on the canvas.
    static func repeatFilter(_ r: ToolRobot, _ k: FilterKind) {
        FilterCenterMemory.memory = [:]
        var st = DocumentState(width: W, height: H)
        let other = CGRect(x: 150, y: 450, width: 160, height: 160)
        st.layers = [white(), objectLayer(), objectLayer(other, margins: (10, 30, 50, 20), name: "Other")]
        let d = r.open(st, active: st.layers[1].id)
        guard runDialog(r, k) != nil else { check(false, "\(k.displayName) repeat: first run"); r.close(d); return }
        d.selectLayer(st.layers[2].id)
        let before = r.liveComposite()
        AppActions.repeatLastFilter()
        let after = r.liveComposite()
        let name = "\(k.displayName) Repeat Filter"
        let want = CGPoint(x: other.midX, y: other.midY)
        check(AppActions.lastFilter?.centerMode == .object && near(AppActions.lastFilter.map(normCenter), want, 0.01),
              "\(name): replays Object mode, re-resolved for the other layer", fmt(AppActions.lastFilter.map(normCenter)))
        let c = change(before, after, in: isBlur(k) ? other : other.insetBy(dx: -40, dy: -40))
        check(near(measured(k, c), want, tol(k)), "\(name): the repeated effect is centred on the other object, measured from the pixels", "measured \(fmt(measured(k, c))) want \(fmt(want))")
        check(d.state.layer(st.layers[1].id)?.raster?.buffer !== nil, "\(name): history intact")
        r.close(d)
    }

    /// The remaining centre-based filters: Object mode lands on the object; Canvas mode is the old result.
    static func otherKinds(_ r: ToolRobot) {
        for k in [FilterKind.vortex, .polarCoordinates, .kaleidoscope, .spinBlur, .lensFlare, .spotlight, .vignette] {
            FilterCenterMemory.memory = [:]
            var seed = FilterInstance(kind: k, colors: [AppModel.shared.foreground, AppModel.shared.background])
            let d = objectDoc(r)
            seed.resolveCenter(FilterCenterResolver.context(d), mode: .object)
            guard let run = runDialog(r, k, seed: k == .lensFlare ? seed : nil) else { check(false, "\(k.displayName): ran through its dialog"); r.close(d); continue }
            check(run.inst.centerMode == .object && near(normCenter(run.inst), CGPoint(x: objectRect.midX, y: objectRect.midY), 0.01),
                  "\(k.displayName) Object: centred on the object", fmt(normCenter(run.inst)))
            previewEqualsCommit(r, run, "\(k.displayName) Object")
            r.close(d)
            // Canvas mode = before
            FilterCenterMemory.memory = [k.rawValue: [Double(FilterCenterMode.canvas.rawValue), 0.5, 0.5]]
            let d1 = objectDoc(r)
            var legacy = FilterInstance(kind: k, colors: [AppModel.shared.foreground, AppModel.shared.background])
            if k == .lensFlare { legacy.values["cx"] = 0.5; legacy.values["cy"] = 0.5 }
            _ = runDialog(r, k)
            let a = r.liveComposite()
            r.close(d1)
            let d2 = objectDoc(r)
            AppActions.applyFilter(legacy)
            let b = r.liveComposite()
            r.close(d2)
            let m = BlurGallery2SelfTest.maxDiff(a, b)
            check(m == 0, "\(k.displayName) Canvas: identical to the result before the Center option", "max Δ\(m)")
        }
    }

    /// Recorded actions store the mode and re-centre on replay; old action files decode.
    static func actions(_ r: ToolRobot) {
        FilterCenterMemory.memory = [:]
        let d = objectDoc(r)
        guard let run = runDialog(r, .twirl) else { check(false, "action: first run"); r.close(d); return }
        let step = ActionStep.filter(run.inst)
        guard let data = try? JSONEncoder().encode(step), let back = try? JSONDecoder().decode(ActionStep.self, from: data),
              case .filter(let f) = back else { check(false, "action step round trip"); r.close(d); return }
        check(f.centerMode == .object && f.values == run.inst.values, "a recorded filter step keeps the Center mode and centre")
        check(step.detail?.contains("center: object") == true && step.detail?.contains("centerW") == false, "the Actions panel shows the Center mode, not its internal values", step.detail ?? "")
        r.close(d)
        // replay on a document where the object sits elsewhere
        var st = DocumentState(width: W, height: H)
        let other = CGRect(x: 300, y: 380, width: 240, height: 240)
        st.layers = [white(), objectLayer(other, margins: (0, 0, 0, 0))]
        let d2 = r.open(st, active: st.layers[1].id)
        let before = r.liveComposite()
        ActionRecorder.perform(back)
        let c = change(before, r.liveComposite())
        check(near(c.bboxCenter, CGPoint(x: other.midX, y: other.midY), 3), "a replayed action centres Object mode on the object of the document it runs on", "changed \(fmt(c.bbox))")
        r.close(d2)
        let oldJSON = #"{"filter":{"_0":{"kind":"twirl","values":{"angle":200,"radius":0.5,"cx":0.5,"cy":0.5}}}}"#
        let old = try? JSONDecoder().decode(ActionStep.self, from: Data(oldJSON.utf8))
        if case .filter(let o)? = old { check(o.centerMode == nil && o.kind == .twirl, "an action recorded before the Center option decodes (and keeps its canvas centre)") }
        else { check(false, "an action recorded before the Center option decodes", String(describing: old)) }
    }

    /// The last mode is remembered per filter (OK saves it); another filter keeps its own.
    static func remembered(_ r: ToolRobot) {
        FilterCenterMemory.memory = [:]
        let d = objectDoc(r)
        var seed = FilterInstance(kind: .pinch)
        seed.resolveCenter(FilterCenterResolver.context(d), mode: .canvas)
        _ = runDialog(r, .pinch, seed: seed)
        check(FilterCenterMemory.mode(for: .pinch) == .canvas, "OK remembers Pinch's Center mode")
        check(FilterCenterMemory.mode(for: .twirl) == .object, "Twirl keeps its own mode")
        guard let again = runDialog(r, .pinch) else { check(false, "pinch again"); r.close(d); return }
        check(again.inst.centerMode == .canvas, "the next Pinch starts in the remembered mode")
        d.state.selection = rectSelection(CGRect(x: 10, y: 10, width: 100, height: 100))
        FilterCenterMemory.memory = [:]
        var probe = FilterInstance(kind: .twirl)
        FilterCenterMemory.start(&probe, FilterCenterResolver.context(d))
        check(probe.centerMode == .selection, "with a selection, Object becomes Selection automatically")
        d.state.selection = nil
        FilterCenterMemory.memory = [FilterKind.twirl.rawValue: [Double(FilterCenterMode.selection.rawValue), 0.5, 0.5]]
        var probe2 = FilterInstance(kind: .twirl)
        FilterCenterMemory.start(&probe2, FilterCenterResolver.context(d))
        check(probe2.centerMode == .object, "a remembered Selection mode without a selection falls back to Object")
        r.close(d)
    }

    /// `.imagecrat` and PSD keep the setting; the smart filter renders the same afterwards.
    static func roundTrips(_ r: ToolRobot) {
        FilterCenterMemory.memory = [:]
        var st = DocumentState(width: W, height: H)
        let so = SmartObjectContent(source: .image(texture(200, 200)), quad: Quad(rect: objectRect), sourceName: "Object")
        st.layers = [white(), Layer(name: "Smart", content: .smartObject(so))]
        let d = r.open(st, active: st.layers[1].id)
        guard runDialog(r, .twirl) != nil, let f0 = d.state.layers[1].smart?.filters.first else { check(false, "round trip fixture"); r.close(d); return }
        let flat0 = r.liveComposite()
        let url = dir.appendingPathComponent("twirl_center.imagecrat")
        do {
            try DocumentIO.saveNative(d, to: url)
            let back = try DocumentIO.load(url: url)
            let f1 = back.state.layers.first { $0.isSmartObject }?.smart?.filters.first
            check(f1?.centerMode == .object && f1?.values == f0.values, ".imagecrat: the smart filter keeps its Center mode and centre")
            let flat1 = RenderEngine.renderBuffer(Compositor.shared.composite(back.state), docRect: back.state.canvasRect, space: CanvasSpace(width: W, height: H))
            let m = BlurGallery2SelfTest.maxDiff(flat0, flat1)
            check(m <= 1, ".imagecrat: renders the same after reopening", "max Δ\(m)")
        } catch { check(false, ".imagecrat round trip", "\(error)") }
        let psd = dir.appendingPathComponent("twirl_center.psd")
        do {
            try PSDWriter.write(d.state, to: psd, large: false)
            let res = try PSDImporter.read(data: try Data(contentsOf: psd), name: psd.lastPathComponent, baseURL: dir)
            let f2 = res.state.layers.first { $0.isSmartObject }?.smart?.filters.first
            check(f2?.centerMode == .object && f2?.values == f0.values, "PSD: the smart filter's Center mode and centre come back from the file")
            let flat2 = RenderEngine.renderBuffer(Compositor.shared.composite(res.state), docRect: res.state.canvasRect, space: CanvasSpace(width: W, height: H))
            let m = BlurGallery2SelfTest.maxDiff(flat0, flat2)
            check(m <= 2, "PSD: renders the same after the round trip", "max Δ\(m)")
        } catch { check(false, "PSD round trip", "\(error)") }
        r.close(d)
    }

    /// Filters saved before the Center option decode with their old centre, render as before, and open as Canvas / Custom.
    static func legacy() {
        let sp = CanvasSpace(width: W, height: H)
        let img = sp.place(objectLayer().raster!.buffer, at: bufferOrigin)
        for (json, k, mode) in [(#"{"kind":"twirl","values":{"angle":200,"radius":0.5,"cx":0.5,"cy":0.5}}"#, FilterKind.twirl, FilterCenterMode.canvas),
                                (#"{"kind":"spinBlur","values":{"angle":10,"cx":0.3,"cy":0.7}}"#, .spinBlur, .custom),
                                (#"{"kind":"pinch","values":{"amount":50,"radius":0.5}}"#, .pinch, .canvas)] {
            guard let f = try? JSONDecoder().decode(FilterInstance.self, from: Data(json.utf8)) else { check(false, "old \(k.displayName) decodes"); continue }
            check(f.centerMode == nil, "an old \(k.displayName) decodes without a Center mode")
            var adopted = f
            adopted.adoptLegacyCenter()
            check(adopted.centerMode == mode, "an old \(k.displayName) opens as \(mode.title)", "\(String(describing: adopted.centerMode))")
            var reference = FilterInstance(kind: k)
            for (key, v) in f.values { reference.values[key] = v }
            let a = RenderEngine.renderBuffer(f.apply(img, canvas: sp.ciCanvas), docRect: IRect(x: 0, y: 0, width: W, height: H), space: sp)
            let b = RenderEngine.renderBuffer(adopted.apply(img, canvas: sp.ciCanvas), docRect: IRect(x: 0, y: 0, width: W, height: H), space: sp)
            let m = BlurGallery2SelfTest.maxDiff(a, b)
            check(m == 0, "an old \(k.displayName) renders exactly as before, also once it has a mode", "max Δ\(m)")
        }
        // a filter that was never resolved (scripts) keeps rendering about its stored point and the canvas
        let plain = FilterInstance(kind: .twirl)
        check(plain.centerMode == nil && plain.centerBox == (1, 1), "a filter made in code without a mode keeps the canvas behaviour")
    }

    /// Recipe filter nodes: "Object" centres on the input's pixels; the default "Point" is the old behaviour.
    static func recipeNode() {
        let canvas = CGRect(x: 0, y: 0, width: W, height: H)
        let sp = CanvasSpace(width: W, height: H)
        let img = sp.place(objectLayer().raster!.buffer, at: bufferOrigin)
        guard let ob = FilterCenterResolver.alphaBounds(img, canvas: canvas) else { check(false, "recipe: alpha bounds of the input"); return }
        check(abs(ob.midX - objectRect.midX) <= 3 && abs(ob.midY - objectRect.midY) <= 3, "recipe nodes measure the input's object", fmt(ob))
        let spec = RecipeLibrary.all.first { $0.type == "filter.twirl" }
        check(spec?.params.contains { $0.key == RecipeLibrary.centerOnKey && $0.def == 0 } == true, "the Twirl recipe node has a Center choice that defaults to its point (old graphs keep their look)")
    }

    /// Picture of the dialog's Center controls (rendered off screen) for a visual check.
    static func dialogPicture(_ r: ToolRobot) {
        FilterCenterMemory.memory = [:]
        let d = objectDoc(r)
        var f = FilterInstance(kind: .twirl)
        let ctx = FilterCenterResolver.context(d)
        f.resolveCenter(ctx, mode: .object)
        let thumb = FilterCenterSection.thumbnail(d.state)
        check(thumb != nil, "the dialog renders a thumbnail of the document for placing the centre")
        let view = FilterCenterSection(f: .constant(f), ctx: ctx, thumbnail: thumb).padding(12).frame(width: 360).background(Color(white: 0.2))
        let image: CGImage? = MainActor.assumeIsolated {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            return renderer.cgImage
        }
        if let cg = image {
            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("dialog_center_controls.png"))
        }
        r.close(d)
    }
}
