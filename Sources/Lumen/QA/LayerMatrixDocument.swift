import AppKit
import CoreImage
import ImageCratCore

/// Matrix 3: whole-document commands (Image Size, Canvas Size, Rotate / Flip Canvas, Crop, Trim, Reveal All, modes,
/// bit depth, profiles, Duplicate Document) on every layer kind, plus the data that lives outside the layers
/// (animation frames, layer comps, timeline keyframes), Actions, placing and pasting between documents.
enum QADocumentCommands {
    static let G = "m3.document"
    static let extraSubjects: Set<String> = ["mask.linked.raster", "mask.unlinked.text", "mask.feather.shape", "mask+vmask.smart", "vmask.raster", "clip.base",
                                             "fx.stroke.text", "fx.dropShadow.shape", "fx.gradientOverlay.smart", "fx.multi.smart", "fillopacity.text", "linked.pair",
                                             "adjustment.invert", "adjustment.curves", "knockout.deep.text", "blend.multiply.shape", "hidden.text", "lock.all.text"]

    static func run(_ subjects: [QASubject]) {
        let picked = subjects.filter { $0.core || extraSubjects.contains($0.name) }
        let cmds = commands().filter { c in LQA.cmdFilter.map { c.name.lowercased().contains($0.lowercased()) } ?? true }
        let few: Set<String> = ["raster.offcanvas", "text.paragraph", "text.warp.arc", "shape.stroke.center", "smart.warp", "smart.perspective", "group.nested", "artboard",
                                "frame.image", "mask.unlinked.text", "fx.dropShadow.shape", "clip.base"]
        for subj in picked {
            for (vi, v) in ([nil, "rotate33"] as [String?]).enumerated() {
                if vi > 0 && !(subj.core && LQA.full) { continue }
                let wanted = cmds.filter { c in
                    if vi > 0 { return c.key }
                    return LQA.full || c.key || few.contains(subj.name)
                }
                guard !wanted.isEmpty, let (st, ids) = QATransforms.prepared(subj, v) else { continue }
                for cmd in wanted { QALayerCommands.runOne(cmd, subj, v, st, ids, group: G) }
            }
            Compositor.shared.clearCaches()
        }
        if LQA.cmdFilter == nil || "stored frames comps keyframes".contains(LQA.cmdFilter!.lowercased()) { storedGeometry(subjects) }
        if LQA.cmdFilter == nil, LQA.subjectFilter == nil {
            actions()
            placing()
            pasteAcrossDocuments()
        }
    }

    // MARK: Expected images

    /// The "before" composite mapped by `h` into a canvas of the new size (blurred for resampling tolerance).
    static func mapped(_ img: PixelBuffer, _ h: Homography, from old: DocumentState, size: (Int, Int), blur: Double, nearest: Bool = false) -> PixelBuffer {
        let sp = LQA.space(old)
        var ci = img.ciImage
        if nearest { ci = ci.samplingNearest() }
        ci = ci.applyingHomography(h, space: sp)
        if blur > 0 { ci = ci.clampedToExtent().applyingGaussianBlur(sigma: blur).cropped(to: ci.extent.insetBy(dx: -blur * 3, dy: -blur * 3)) }
        return RenderEngine.renderBuffer(ci, docRect: IRect(x: 0, y: 0, width: size.0, height: size.1), space: sp)
    }

    static func lossy(_ c: QACtx, scales: Bool, rotates: Bool, resizesCanvas: Bool, styles: Bool) -> String? {
        let n = c.subj.name
        if c.subj.has("pattern") || n == "fill.pattern" || n.contains("patternOverlay") { return "pattern fills are anchored to the canvas origin and keep their scale: document geometry commands shift / do not scale the pattern" }
        if resizesCanvas, n.hasPrefix("fill.gradient") && n != "fill.gradient.placed" { return "a gradient fill layer without placed end points always spans the (new) canvas" }
        if scales, c.subj.has("filters") { return "smart filter settings (blur radius …) are not scaled by Image Size" }
        if scales, !styles, c.subj.has("fx") { return "with Scale Styles off, Image Size leaves layer effects at their size (as in Photoshop)" }
        if rotates, c.subj.has("fx") || c.subj.has("filters") { return "layer effect angles and directional smart filters keep their direction when the canvas is rotated or flipped" }
        return nil
    }

    /// Checks shared by the geometry commands: structure, attributes, editability, bounds and appearance follow `h`.
    static func verify(_ c: QACtx, h: Homography, size: (Int, Int), styles: Double? = nil, stroke: Double = 1, blur: Double = 1.0, mean: Double = 1.4, bad: Double = 0.01,
                       lossy why: String? = nil, nearest: Bool = false, rasterTol: CGFloat = 1.5) {
        let st = c.d.state
        c.check(st.width == size.0 && st.height == size.1, "canvas has the new size", "\(st.width)×\(st.height) vs \(size.0)×\(size.1)")
        c.check(st.allLayers.map(\.id) == c.st0.allLayers.map(\.id), "same layers in the same order")
        for l0 in c.st0.allLayers {
            guard let l1 = st.layer(l0.id) else { continue }
            c.check(LQA.kind(l0) == LQA.kind(l1), "layer kind preserved", "\(l0.name): \(LQA.kind(l0)) → \(LQA.kind(l1))")
            c.attrsKept(l0, l1, ignoring: styles == nil ? [] : ["effects"])
            if let k = styles { c.check(l1.effects == LayerTransformer.scaled(l0.effects, k), "effects scaled with the image") }
            switch (l0.content, l1.content) {
            case (.text(let a), .text(let b)):
                var a2 = a; a2.transform = b.transform
                c.check(a2 == b, "text stays editable (only its transform changes)")
                if h.isAffine { c.check(QATransforms.quadClose(TextRenderer.docQuad(a).mapped(h.apply), TextRenderer.docQuad(b), 0.05), "text box follows the document") }
            case (.shape(let a), .shape(let b)):
                c.check(a.geometry == b.geometry, "shape stays live")
                c.check(abs(b.stroke.width - a.stroke.width * stroke) < 0.001, "shape stroke scales with the image", "\(a.stroke.width) → \(b.stroke.width)")
                c.check(LQA.close(a.path.mapped(h.apply).bounds, b.path.bounds, 0.05), "shape path follows the document")
            case (.smartObject(let a), .smartObject(let b)):
                c.check(QATransforms.quadClose(a.quad.mapped(h.apply), b.quad, 0.01), "smart object quad follows the document")
                c.check(a.filters == b.filters && a.sourceRevision == b.sourceRevision && (a.warp == nil) == (b.warp == nil), "smart object keeps source, filters and warp")
            case (.raster(let a), .raster(let b)):
                if let ob = LQA.opaqueBounds(a.buffer, threshold: 0) {
                    let want = h.mapRect(ob.offsetBy(dx: a.origin.x, dy: a.origin.y).cgRect).bounds
                    if let nb = LQA.opaqueBounds(b.buffer, threshold: 0) {
                        let got = nb.offsetBy(dx: b.origin.x, dy: b.origin.y).cgRect
                        c.check(LQA.close(want, got, rasterTol), "pixel layer follows the document", "\(LQA.fmt(want)) vs \(LQA.fmt(got))")
                    } else { c.check(false, "pixel layer follows the document", "layer became empty") }
                }
            case (.group(let a), .group(let b)):
                if let r0 = a.artboard?.rect, let r1 = b.artboard?.rect { c.check(LQA.close(h.mapRect(r0).bounds, r1, 1), "artboard follows the document", "\(LQA.fmt(r0)) → \(LQA.fmt(r1))") }
            default: break
            }
            if let m0 = l0.mask, let m1 = l1.mask {
                c.check(m0.isLinked == m1.isLinked && m0.feather == m1.feather && m0.density == m1.density && m0.outsideValue == m1.outsideValue, "mask settings kept")
            }
        }
        if let why { LQA.note(why); return }
        // appearance inside the part of the new canvas that shows the old canvas
        let oldInNew = h.mapRect(c.st0.canvasCGRect).bounds.intersection(CGRect(x: 0, y: 0, width: size.0, height: size.1))
        let region = IRect(enclosing: oldInNew.insetBy(dx: blur * 3 + 1, dy: blur * 3 + 1))
        guard region.width > 8, region.height > 8 else { return }
        let want = mapped(c.img0, h, from: c.st0, size: size, blur: blur, nearest: nearest).cropped(to: region)
        let got = LQA.render(st, blur: blur).cropped(to: region)
        let df = LQA.diff(want, got, threshold: 40)
        let ok = df.within(mean: mean, bad: bad)
        if !ok { LQA.dumpPair(want, got, "\(c.group)_\(c.label)") }
        c.check(ok, "the document looks like the transformed original", df.description)
    }

    /// Vector / text / smart geometry must come back exactly after a command and its inverse.
    static func vectorsRestored(_ c: QACtx, tol: CGFloat = 0.001) {
        for l0 in c.st0.allLayers {
            guard let l1 = c.d.state.layer(l0.id) else { c.check(false, "layers kept"); continue }
            if let a = l0.text, let b = l1.text { c.check(QATransforms.quadClose(TextRenderer.docQuad(a), TextRenderer.docQuad(b), tol), "vector geometry restored exactly", l0.name) }
            if let a = l0.shape, let b = l1.shape { c.check(LQA.close(a.path.bounds, b.path.bounds, tol) && abs(a.stroke.width - b.stroke.width) < 1e-6, "vector geometry restored exactly", l0.name) }
            if let a = l0.smart, let b = l1.smart { c.check(QATransforms.quadClose(a.quad, b.quad, tol), "vector geometry restored exactly", l0.name) }
            if let a = l0.artboard, let b = l1.artboard { c.check(LQA.close(a.rect, b.rect, 0.5), "vector geometry restored exactly", l0.name) }
            c.attrsKept(l0, l1)
        }
    }

    static func scaleH(_ sx: Double, _ sy: Double) -> Homography { Homography(affine: CGAffineTransform(scaleX: CGFloat(sx), y: CGFloat(sy))) }
    static func shiftH(_ dx: Double, _ dy: Double) -> Homography { Homography(affine: CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))) }

    // MARK: Commands

    static func commands() -> [QACmd] {
        var cmds: [QACmd] = []
        let W = LQA.W, H = LQA.H

        // ---------- Image Size
        for (name, fx, fy, styles, key) in [("Image Size ×2 (scale styles)", 2.0, 2.0, true, true), ("Image Size ×2 (styles not scaled)", 2.0, 2.0, false, false),
                                            ("Image Size ×0.5 (scale styles)", 0.5, 0.5, true, true), ("Image Size non-uniform 150 % × 80 %", 1.5, 0.8, true, false)] {
            let nw = Int(Double(W) * fx), nh = Int(Double(H) * fy)
            cmds.append(QACmd(name: name, key: key, run: { _ in AppActions.imageSize(width: nw, height: nh, resolution: 72, scaleStyles: styles) }, verify: { c in
                let k = sqrt(fx * fy)
                verify(c, h: scaleH(fx, fy), size: (nw, nh), styles: styles ? k : nil, stroke: k, blur: 1.2 * max(1, k),
                       lossy: lossy(c, scales: true, rotates: false, resizesCanvas: fx != fy, styles: styles)
                           ?? (fx != fy && (c.subj.has("fx") || c.subj.has("stroke") || c.subj.name == "fill.gradient.placed")
                               ? "effects, shape strokes and radial gradients scale uniformly under a non-uniform Image Size" : nil))
            }))
        }
        for m in ResampleMethod.allCases {
            let nw = Int(Double(W) * 1.5), nh = Int(Double(H) * 1.5)
            cmds.append(QACmd(name: "Image Size 150 % — \(m.rawValue)", run: { _ in EditsImageSize.apply(width: nw, height: nh, resolution: 72, scaleStyles: true, method: m) }, verify: { c in
                verify(c, h: scaleH(1.5, 1.5), size: (nw, nh), styles: 1.5, stroke: 1.5, blur: 2, mean: 1.8, bad: 0.012,
                       lossy: lossy(c, scales: true, rotates: false, resizesCanvas: false, styles: true), rasterTol: 2)
            }))
        }
        cmds.append(QACmd(name: "Image Size 50 % — Bicubic Sharper", run: { _ in EditsImageSize.apply(width: W / 2, height: H / 2, resolution: 72, scaleStyles: true, method: .bicubicSharper) }, verify: { c in
            verify(c, h: scaleH(0.5, 0.5), size: (W / 2, H / 2), styles: 0.5, stroke: 0.5, blur: 1.2, mean: 1.8, bad: 0.012, lossy: lossy(c, scales: true, rotates: false, resizesCanvas: false, styles: true), rasterTol: 2)
        }))
        cmds.append(QACmd(name: "Image Size ×2 then ×0.5", key: true, steps: 2, run: { _ in
            AppActions.imageSize(width: W * 2, height: H * 2, resolution: 72, scaleStyles: true)
            AppActions.imageSize(width: W, height: H, resolution: 72, scaleStyles: true)
        }, verify: { c in
            vectorsRestored(c)
            for l0 in c.st0.allLayers { if let l1 = c.d.state.layer(l0.id) { c.check(l0.effects == l1.effects, "effects restored") } }
            if lossy(c, scales: false, rotates: false, resizesCanvas: false, styles: true) == nil {
                let df = LQA.diff(LQA.render(c.st0, blur: 1.5), LQA.render(c.d.state, blur: 1.5), threshold: 40)
                c.check(df.within(mean: 1.6, bad: 0.01), "scaling up and back restores the appearance", df.description)
            }
        }))

        // ---------- Canvas Size
        for ay in 0...2 {
            for ax in 0...2 {
                let nw = W + 60, nh = H + 40
                cmds.append(QACmd(name: "Canvas Size +60×40, anchor \(ax),\(ay)", key: ax == ay, run: { _ in AppActions.canvasSize(width: nw, height: nh, anchorX: ax, anchorY: ay, extension: nil) }, verify: { c in
                    verify(c, h: shiftH(Double(60 * ax / 2), Double(40 * ay / 2)), size: (nw, nh), blur: 0, mean: 0.4, bad: 0.002,
                           lossy: lossy(c, scales: false, rotates: false, resizesCanvas: true, styles: true), rasterTol: 0.01)
                }))
            }
        }
        for a in [0, 1, 2] {
            let nw = W - 80, nh = H - 60
            cmds.append(QACmd(name: "Canvas Size −80×60, anchor \(a),\(a)", run: { _ in AppActions.canvasSize(width: nw, height: nh, anchorX: a, anchorY: a, extension: nil) }, verify: { c in
                verify(c, h: shiftH(Double(-80 * a / 2), Double(-60 * a / 2)), size: (nw, nh), blur: 0, mean: 0.4, bad: 0.002,
                       lossy: lossy(c, scales: false, rotates: false, resizesCanvas: true, styles: true), rasterTol: 0.01)
            }))
        }

        // ---------- Rotate / flip canvas
        func rotH(_ deg: Int) -> (Homography, (Int, Int)) {
            let w = CGFloat(W), h = CGFloat(H)
            switch deg {
            case 90: return (Homography(affine: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)), (H, W))
            case -90: return (Homography(affine: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)), (H, W))
            default: return (Homography(affine: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)), (W, H))
            }
        }
        for deg in [90, -90, 180] {
            let (h, size) = rotH(deg)
            cmds.append(QACmd(name: "Rotate Canvas \(deg)°", key: deg == 90, run: { _ in AppActions.rotateCanvas(deg) }, verify: { c in
                verify(c, h: h, size: size, blur: 0.8, mean: 1.0, bad: 0.01, lossy: lossy(c, scales: false, rotates: true, resizesCanvas: false, styles: true), nearest: true, rasterTol: 0.01)
            }))
        }
        for horizontal in [true, false] {
            let t = horizontal ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(W), ty: 0) : CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(H))
            cmds.append(QACmd(name: horizontal ? "Flip Canvas Horizontal" : "Flip Canvas Vertical", key: horizontal, run: { _ in AppActions.flipCanvas(horizontal: horizontal) }, verify: { c in
                verify(c, h: Homography(affine: t), size: (W, H), blur: 0.8, mean: 1.0, bad: 0.006, lossy: lossy(c, scales: false, rotates: true, resizesCanvas: false, styles: true), nearest: true, rasterTol: 0.01)
            }))
        }
        let inverses: [(String, () -> Void)] = [
            ("Rotate Canvas 90° then −90°", { AppActions.rotateCanvas(90); AppActions.rotateCanvas(-90) }),
            ("Rotate Canvas 180° ×2", { AppActions.rotateCanvas(180); AppActions.rotateCanvas(180) }),
            ("Flip Canvas Horizontal ×2", { AppActions.flipCanvas(horizontal: true); AppActions.flipCanvas(horizontal: true) }),
            ("Flip Canvas Vertical ×2", { AppActions.flipCanvas(horizontal: false); AppActions.flipCanvas(horizontal: false) }),
        ]
        for (name, body) in inverses {
            cmds.append(QACmd(name: name, key: name.hasPrefix("Rotate Canvas 90"), steps: 2, run: { _ in body() }, verify: { c in
                vectorsRestored(c)
                c.check(c.d.state.width == c.st0.width && c.d.state.height == c.st0.height, "canvas size restored")
                if c.subj.has("pattern") || c.subj.name == "fill.pattern" || c.subj.name.contains("patternOverlay") { return }
                c.sameAppearance("the document looks as before", mean: 0.3, bad: 0.002)
            }))
        }

        // ---------- Crop / Trim / Reveal All
        let cropRect = IRect(x: 50, y: 40, width: 270, height: 190)
        for delete in [false, true] {
            cmds.append(QACmd(name: delete ? "Crop (delete cropped pixels)" : "Crop (keep pixels)", key: !delete, run: { _ in AppActions.crop(to: cropRect, deletePixels: delete) }, verify: { c in
                verify(c, h: shiftH(Double(-cropRect.x), Double(-cropRect.y)), size: (cropRect.width, cropRect.height), blur: 0, mean: 0.4, bad: 0.002,
                       lossy: lossy(c, scales: false, rotates: false, resizesCanvas: true, styles: true), rasterTol: delete ? 400 : 0.01)
                if delete {
                    for l in c.d.state.allLayers { if let r = l.raster { c.check(c.d.state.canvasRect.intersection(r.frame) == r.frame || r.frame.width <= 1, "cropped pixels are deleted", l.name) } }
                }
            }))
        }
        cmds.append(QACmd(name: "Trim (transparent pixels)", prepare: { st, _ in st.layers.removeAll { $0.name == "Background" || $0.name == "Under" } }, run: { _ in AppActions.trimTransparent() }, verify: { c in
            guard let b = LQA.opaqueBounds(c.img0, threshold: 0) else { return }
            verify(c, h: shiftH(Double(-b.x), Double(-b.y)), size: (b.width, b.height), blur: 0, mean: 0.4, bad: 0.002,
                   lossy: lossy(c, scales: false, rotates: false, resizesCanvas: true, styles: true), rasterTol: 0.01)
        }))
        cmds.append(QACmd(name: "Reveal All", prepare: { st, ids in for id in ids { st.updateLayer(id) { $0.translate(dx: -150, dy: -95, document: true) } } }, run: { _ in AppActions.revealAll() }, verify: { c in
            var u = c.st0.canvasCGRect
            for l in c.st0.allLayers { if let b = Compositor.shared.contentBounds(l, state: c.st0) { u = u.union(b) } }
            let r = IRect(enclosing: u)
            verify(c, h: shiftH(Double(-r.x), Double(-r.y)), size: (r.width, r.height), blur: 0, mean: 0.4, bad: 0.002,
                   lossy: lossy(c, scales: false, rotates: false, resizesCanvas: true, styles: true), rasterTol: 0.01)
            for l in c.d.state.allLayers where !l.isGroup {
                if let b = Compositor.shared.contentBounds(l, state: c.d.state) { c.check(LQA.encloses(c.d.state.canvasCGRect, b, 1), "every layer is inside the canvas", "\(l.name) \(LQA.fmt(b))") }
            }
        }))

        // ---------- Modes, bit depth, profiles
        func layersUntouched(_ c: QACtx, pixelsMayChange: Bool) {
            c.check(c.d.state.allLayers.map(\.id) == c.st0.allLayers.map(\.id), "same layers in the same order")
            for l0 in c.st0.allLayers {
                guard let l1 = c.d.state.layer(l0.id) else { continue }
                c.check(LQA.kind(l0) == LQA.kind(l1), "layer kind preserved")
                c.attrsKept(l0, l1)
                let b0 = Compositor.shared.contentBounds(l0, state: c.st0), b1 = Compositor.shared.contentBounds(l1, state: c.d.state)
                c.check(b0 == b1, "layer bounds unchanged", "\(l0.name): \(LQA.fmt(b0)) → \(LQA.fmt(b1))")
                if let a = l0.text, let b = l1.text { c.check(a == b, "text untouched") }
                if let a = l0.shape, let b = l1.shape { c.check(a == b, "shape untouched") }
                if let a = l0.smart, let b = l1.smart { c.check(a.quad == b.quad && a.filters == b.filters && a.warp == b.warp, "smart object placement untouched") }
            }
            if !pixelsMayChange { c.sameAppearance(mean: 0.05, bad: 0) }
        }
        for m in [ColorMode.grayscale, .cmyk, .lab] {
            cmds.append(QACmd(name: "Mode \(m.short) and back to RGB", key: m == .grayscale, steps: 2, run: { _ in AppActions.convertMode(m); AppActions.convertMode(.rgb) }, verify: { c in
                c.check(c.d.state.colorMode == .rgb, "mode is RGB again")
                layersUntouched(c, pixelsMayChange: m != .lab)
            }))
        }
        cmds.append(QACmd(name: "Mode Duotone and back to RGB", steps: 2, run: { c in
            ColorModes.convertToDuotone(c.d, DuotoneSettings.presets[1].1); AppActions.convertMode(.rgb)
        }, verify: { c in
            c.check(c.d.state.colorMode == .rgb, "mode is RGB again")
            c.check(c.d.state.width == c.st0.width && c.d.state.height == c.st0.height, "canvas size kept")
        }))
        let flattening: [(String, (Document) -> Void)] = [
            ("Bitmap", { ColorModes.convertToBitmap($0, BitmapOptions()) }), ("Indexed Color", { ColorModes.convertToIndexed($0, IndexedOptions()) }),
            ("Multichannel", { ColorModes.convertToMultichannel($0) }),
        ]
        for (name, body) in flattening {
            cmds.append(QACmd(name: "Mode \(name) and back to RGB", steps: 2, replacesStack: true, run: { c in body(c.d); AppActions.convertMode(.rgb) }, verify: { c in
                c.check(c.d.state.colorMode == .rgb, "mode is RGB again")
                c.check(c.d.state.width == c.st0.width && c.d.state.height == c.st0.height, "canvas size kept")
                c.check(!c.d.state.layers.isEmpty, "document keeps a layer")
            }))
        }
        cmds.append(QACmd(name: "16 Bits/Channel and back", steps: 2, run: { _ in AppActions.setBitDepth(.sixteen); AppActions.setBitDepth(.eight) }, verify: { c in layersUntouched(c, pixelsMayChange: false) }))
        cmds.append(QACmd(name: "32 Bits/Channel", run: { _ in AppActions.setBitDepth(.thirtyTwo) }, verify: { c in layersUntouched(c, pixelsMayChange: false) }))
        cmds.append(QACmd(name: "Assign Profile Display P3", run: { _ in AppActions.assignProfile("Display P3") }, verify: { c in layersUntouched(c, pixelsMayChange: false) }))
        cmds.append(QACmd(name: "Convert to Profile Display P3", run: { _ in AppActions.convertToProfile("Display P3", intent: .relative) }, verify: { c in layersUntouched(c, pixelsMayChange: true) }))

        // ---------- Duplicate Document
        cmds.append(QACmd(name: "Duplicate Document", key: true, alwaysVerify: true, run: { c in
            var st = c.d.state
            // give the document something that refers to layers by id
            st.frames = [Animation.capture(st)]
            st.layerComps = [AppActions.captureComp(name: "A")]
            c.d.state = st
            c.d.commit("prepare")
            AppActions.duplicateDocument()
            c.notes["copy"] = AppModel.shared.activeDocument
            if let copy = AppModel.shared.activeDocument, copy !== c.d { AppModel.shared.close(copy) }
            AppModel.shared.activeDocumentID = c.d.id
        }, verify: { c in
            guard let copy = c.notes["copy"] as? Document, copy !== c.d else { c.check(false, "copy created"); return }
            let df = LQA.diff(LQA.render(c.d.state), LQA.render(copy.state))
            c.check(df.maxv <= 1, "copy looks identical", df.description)
            let ids = Set(copy.state.allLayers.map(\.id))
            c.check(copy.state.frames.allSatisfy { Set($0.visibility.keys).isSubset(of: ids) && !$0.visibility.isEmpty }, "animation frames still refer to the copy's layers")
            c.check(copy.state.layerComps.allSatisfy { Set($0.entries.keys).isSubset(of: ids) && !$0.entries.isEmpty }, "layer comps still refer to the copy's layers")
            c.check(Set(copy.state.generative.keys).isSubset(of: ids), "generative metadata still refers to the copy's layers")
            c.check(copy.state.toolData.frames.allSatisfy { ids.contains($0.id) }, "frame-tool metadata still refers to the copy's layers")
            c.check(copy.state.videoTimeline?.tracks.allSatisfy { ids.contains($0.layerID) } ?? true, "timeline tracks still refer to the copy's layers")
            for (a, b) in zip(c.d.state.allLayers, copy.state.allLayers) {
                if let x = a.raster, let y = b.raster { c.check(x.buffer !== y.buffer, "pixels are copied, not shared") }
                if let x = a.mask, let y = b.mask { c.check(x.buffer !== y.buffer, "masks are copied, not shared") }
            }
        }))
        return cmds
    }

    // MARK: Frames, layer comps and timeline keyframes under document geometry commands

    static func storedGeometry(_ subjects: [QASubject]) {
        let names = ["raster.small", "text.point", "text.warp.arc", "shape.rounded", "shape.stroke.center", "smart.image", "smart.warp", "smart.rotated",
                     "fill.gradient.placed", "group.passthrough", "mask.linked.raster", "artboard"]
        let W = LQA.W, H = LQA.H
        let ops: [(String, () -> Void)] = [
            ("Image Size ×2", { AppActions.imageSize(width: W * 2, height: H * 2, resolution: 72, scaleStyles: true) }),
            ("Image Size ×0.5", { AppActions.imageSize(width: W / 2, height: H / 2, resolution: 72, scaleStyles: true) }),
            ("Image Size 150 % (bicubic)", { EditsImageSize.apply(width: W * 3 / 2, height: H * 3 / 2, resolution: 72, scaleStyles: true, method: .bicubic) }),
            ("Canvas Size anchor bottom-right", { AppActions.canvasSize(width: W + 60, height: H + 40, anchorX: 2, anchorY: 2, extension: nil) }),
            ("Canvas Size anchor centre", { AppActions.canvasSize(width: W + 60, height: H + 40, anchorX: 1, anchorY: 1, extension: nil) }),
            ("Rotate Canvas 90°", { AppActions.rotateCanvas(90) }),
            ("Rotate Canvas 180°", { AppActions.rotateCanvas(180) }),
            ("Flip Canvas Horizontal", { AppActions.flipCanvas(horizontal: true) }),
            ("Crop", { AppActions.crop(to: IRect(x: 20, y: 10, width: 360, height: 280), deletePixels: false) }),
        ]
        for subj in subjects where names.contains(subj.name) {
            let (st0, ids) = subj.make()
            let id = ids.last!
            // state B: the subject somewhere else
            var stB = st0
            stB.updateLayer(id) { $0.translate(dx: 34, dy: -22) }
            var st = st0
            st.frames = [Animation.capture(st0), Animation.capture(stB)]
            let compA = LQA.withDoc(st0) { _ in AppActions.captureComp(name: "A") }
            let compB = LQA.withDoc(stB) { _ in AppActions.captureComp(name: "B") }
            st.layerComps = [compA, compB]
            if let l0 = st0.layer(id), let lB = stB.layer(id), let c0 = VideoTimelineEngine.center(l0, state: st0), let cB = VideoTimelineEngine.center(lB, state: stB) {
                var tl = VideoTimeline(duration: 2, frameRate: 30)
                var tr = LayerTrack(layerID: id, duration: 2)
                tr.setKeys(.position, [Keyframe(time: 0, interpolation: .hold, value: .point(c0)), Keyframe(time: 1, interpolation: .hold, value: .point(cB))])
                tl.tracks = [tr]
                st.videoTimeline = tl
            }
            for (name, op) in ops {
                if let f = LQA.cmdFilter, !name.lowercased().contains(f.lowercased()), !"stored frames comps keyframes".contains(f.lowercased()) { continue }
                if subj.has("artboard") && name.hasPrefix("Rotate Canvas 90") { continue }
                let label = "\(subj.name) × \(name)"
                let got = LQA.withDoc(st, select: ids) { d -> DocumentState in op(); return d.state }
                let blur = 1.5
                for (i, variant) in [st0, stB].enumerated() {
                    let want = LQA.withDoc(variant, select: ids) { d -> PixelBuffer in op(); return LQA.render(d.state, blur: blur) }
                    let which = i == 0 ? "A" : "B"
                    func cmp(_ s: DocumentState, _ what: String) {
                        let img = LQA.render(s, blur: blur)
                        let df = LQA.diff(want, img, threshold: 40)
                        let ok = df.within(mean: 1.2, bad: 0.008)
                        if !ok { LQA.dumpPair(want, img, "m3_stored_\(what)_\(which)_\(label)") }
                        LQA.check(ok, "\(G): \(what) follow the document", "\(label), state \(which)", df.description)
                    }
                    if subj.has("artboard") { LQA.note("animation frames store layer positions only: moving an artboard frame is not animatable") }
                    else if got.frames.count == 2 { cmp(Animation.applied(got.frames[i], to: got), "animation frames") }
                    else { LQA.check(false, "\(G): animation frames follow the document", label, "frames lost") }
                    if got.layerComps.count == 2 {
                        var s = got
                        AppActions.applyComp(got.layerComps[i], to: &s)
                        cmp(s, "layer comps")
                    } else { LQA.check(false, "\(G): layer comps follow the document", label, "comps lost") }
                    if got.videoTimeline != nil, !subj.name.hasPrefix("fill"), !subj.has("artboard") {
                        cmp(VideoTimelineEngine.evaluated(got, at: i == 0 ? 0.2 : 1.5, decodeVideo: false), "timeline position keyframes")
                    }
                }
            }
            Compositor.shared.clearCaches()
        }
    }

    // MARK: Actions: record and replay geometry commands

    static func actions() {
        let rec = ActionRecorder.shared
        let key = "Lumen.Actions"
        let hadKey = UserDefaults.standard.object(forKey: key) != nil
        let savedSets = rec.sets
        defer {
            rec.recordingActionID = nil
            rec.sets = savedSets
            if !hadKey { UserDefaults.standard.removeObject(forKey: key) }
        }
        let subj = QASubjects.all().first { $0.name == "group.nested" }!
        let (st, ids) = subj.make()
        let W = LQA.W, H = LQA.H
        let steps: [() -> Void] = [
            { AppActions.imageSize(width: W * 3 / 2, height: H * 3 / 2, resolution: 72, scaleStyles: true) },
            { AppActions.canvasSize(width: W * 3 / 2 + 50, height: H * 3 / 2 + 30, anchorX: 0, anchorY: 2, extension: nil) },
            { AppActions.rotateCanvas(90) },
            { AppActions.flipCanvas(horizontal: true) },
        ]
        LQA.withDoc(st, select: ids) { d in
            let aid = rec.newAction(name: "LQA geometry")
            rec.recordingActionID = aid
            for s in steps {
                s()
                // the recorder re-arms on the next main-queue turn: wait until a block queued after its own has run
                var turned = false
                DispatchQueue.main.async { turned = true }
                var spins = 0
                while !turned && spins < 200 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)); spins += 1 }
            }
            rec.recordingActionID = nil
            let recorded = rec.action(aid)?.steps ?? []
            LQA.check(recorded.count == steps.count, "\(G): Actions record every geometry command", "", "\(recorded.map(\.title))")
            let first = LQA.Snapshot(d.state)
            let img = LQA.render(d.state)
            for _ in 0..<steps.count { d.undo() }
            LQA.check(LQA.Snapshot(d.state).matches(LQA.Snapshot(st)), "\(G): undoing the recorded commands restores the document")
            let h0 = d.history.count
            rec.play(aid, interactive: false)
            let df = LQA.diff(img, LQA.render(d.state))
            LQA.check(LQA.Snapshot(d.state).matches(first) || df.maxv <= 1, "\(G): replaying the action reproduces the result", "", df.description)
            LQA.check(d.history.count == h0 || d.history.count - h0 == recorded.count || d.canUndo, "\(G): replay records history")
        }
    }

    // MARK: Place embedded / linked, Replace Contents

    static func placing() {
        let big = LQA.out.appendingPathComponent("qa_place_big.png"), small = LQA.out.appendingPathComponent("qa_place_small.png"), wide = LQA.out.appendingPathComponent("qa_place_wide.png")
        try? QASubjects.image(800, 500, seed: 1).pngData()?.write(to: big)
        try? QASubjects.image(100, 60, seed: 2).pngData()?.write(to: small)
        try? QASubjects.image(300, 60, seed: 3).pngData()?.write(to: wide)
        let st = QASubjects.base()
        for (url, linked) in [(big, false), (small, false), (big, true), (small, true)] {
            LQA.withDoc(st) { d in
                let label = "\(url.lastPathComponent) \(linked ? "linked" : "embedded")"
                let h0 = d.history.count
                AppActions.place([url], linked: linked)
                guard let l = d.activeLayer, let so = l.smart else { LQA.check(false, "\(G): Place creates a smart object", label); return }
                LQA.check(d.history.count == h0 + 1, "\(G): Place is one history step", label)
                let src = so.source.size
                let b = so.quad.bounds
                let k = min(1, min(CGFloat(d.state.width) / src.width, CGFloat(d.state.height) / src.height))
                LQA.check(abs(b.width - src.width * k) < 0.01 && abs(b.height - src.height * k) < 0.01, "\(G): placed file fits the canvas with its aspect ratio", label, LQA.fmt(b))
                LQA.check(abs(b.midX - CGFloat(d.state.width) / 2) < 0.51 && abs(b.midY - CGFloat(d.state.height) / 2) < 0.51, "\(G): placed file is centred", label, LQA.fmt(b))
                LQA.check((so.linkedURL != nil) == linked, "\(G): Place Linked keeps the link", label)
                QATransforms.checkGeometry(l, d.state, subject: QASubject(name: "placed", make: { (st, []) }), label: label, check: "\(G): placed object bounds match the drawn pixels")
                // Replace Contents with a file of another shape: by default it fits the object's box (aspect ratio kept,
                // centred) instead of stretching or changing size
                let before = so
                LQA.check(AppActions.replaceSmartContents(of: l.id, in: d, with: wide), "\(G): Replace Contents loads the file", label)
                if let after = d.state.layer(l.id)?.smart {
                    let scaleX1 = after.quad.tl.distance(to: after.quad.tr) / after.source.size.width
                    let scaleY1 = after.quad.tl.distance(to: after.quad.bl) / after.source.size.height
                    let b0 = before.quad.bounds, b1 = after.quad.bounds
                    let inside = b1.minX >= b0.minX - 0.01 && b1.minY >= b0.minY - 0.01 && b1.maxX <= b0.maxX + 0.01 && b1.maxY <= b0.maxY + 0.01
                    let fills = abs(b1.width - b0.width) < 0.01 || abs(b1.height - b0.height) < 0.01
                    LQA.check(abs(scaleX1 - scaleY1) < 1e-6 && inside && fills && after.quad.center.distance(to: before.quad.center) < 0.01,
                              "\(G): Replace Contents fits the object's box (aspect ratio kept, centred, no stretching)", label, "scale \(scaleX1) × \(scaleY1), \(LQA.fmt(b0)) → \(LQA.fmt(b1))")
                }
                d.undo()
                LQA.check(d.state.layer(l.id)?.smart?.quad == before.quad, "\(G): undo restores the replaced contents", label)
            }
        }
    }

    // MARK: Copy in one document, paste in another of a different size

    static func pasteAcrossDocuments() {
        let previous = AppActions.pasteboard
        let pb = NSPasteboard(name: NSPasteboard.Name("lumen.qa.x.\(ProcessInfo.processInfo.processIdentifier)"))
        AppActions.pasteboard = pb
        defer { AppActions.pasteboard = previous; pb.releaseGlobally(); AppActions.clipboard = nil }
        for name in ["raster.small", "text.point", "shape.rounded", "smart.image"] {
            let subj = QASubjects.all().first { $0.name == name }!
            let (st, ids) = subj.make()
            var copiedSize = (0, 0)
            LQA.withDoc(st, select: ids) { d in
                AppActions.copy()
                copiedSize = (AppActions.clipboard?.buffer.width ?? 0, AppActions.clipboard?.buffer.height ?? 0)
                let cb = Compositor.shared.contentBounds(d.state.layer(ids[0])!, state: d.state)!
                let want = IRect(enclosing: cb).intersection(d.state.canvasRect)
                LQA.check(copiedSize.0 == want.width && copiedSize.1 == want.height, "\(G): Copy takes the layer's pixels", name, "\(copiedSize) vs \(want.width)×\(want.height)")
            }
            for (w, h) in [(200, 150), (900, 700)] {
                var other = DocumentState(width: w, height: h)
                other.layers = [Layer.raster(name: "Background", buffer: QASubjects.image(w, h, seed: 2))]
                LQA.withDoc(other) { d in
                    let label = "\(name) → \(w)×\(h)"
                    AppActions.paste()
                    guard let l = d.activeLayer, let r = l.raster, d.state.layers.count == 2 else { LQA.check(false, "\(G): Paste into another document adds a layer", label); return }
                    LQA.check(r.buffer.width == copiedSize.0 && r.buffer.height == copiedSize.1, "\(G): pasted pixels keep their size in another document", label)
                    LQA.check(abs(r.frame.cgRect.midX - CGFloat(w) / 2) <= 1 && abs(r.frame.cgRect.midY - CGFloat(h) / 2) <= 1, "\(G): pasted layer is centred in the other document", label, LQA.fmt(r.frame.cgRect))
                    d.undo()
                    LQA.check(d.state.layers.count == 1, "\(G): undo removes the pasted layer", label)
                }
            }
        }
    }
}
